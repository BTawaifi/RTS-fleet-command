#!/usr/bin/env python3
"""Remove a guard in an isolated copy and require its test assertion to fail.

KILLED requires an observed green original and a Python/Lua assertion failure.
VACUOUS means the test stayed green; UNCOVERED means no covering test exists.
ERROR includes missing anchors, skips, setup/runtime errors and timeouts.
Source drift and recorded writes outside the sandbox also fail the gate.
These checks establish coverage of selected guards, not native gameplay quality.

Run from the mod root:
    python core/tools/killcheck.py --guard service_max_under_fire_seconds --json out.json
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

from script_modules import module_files
TOOLS = Path(__file__).resolve().parent
CORE = TOOLS.parent
SCRIPTS = CORE / "data" / "scripts"
CONFIG = SCRIPTS / "fs2rts_config.lua"
MOD_ROOT = CORE.parent
# Directories copied into the sandbox. The suite resolves the script tree from
# its own location, so the sandbox must reproduce that relationship exactly.
SANDBOX_DIRS = ("tools", "data/scripts", "data/tables")
# Never copied, never hashed into the mutation set: interpreter caches.
CACHE_NAMES = {"__pycache__", ".pytest_cache", ".kilo"}

# ---------------------------------------------------------------------------
# Repo fingerprint: proof the tree is untouched

# ---------------------------------------------------------------------------

def fingerprint(root: Path) -> dict[str, str]:
    """sha256 of every non-cache file under `root`, keyed by relative path."""
    out: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(part in CACHE_NAMES for part in path.relative_to(root).parts):
            continue
        out[path.relative_to(root).as_posix()] = hashlib.sha256(
            path.read_bytes()).hexdigest()
    return out

def diff_fingerprints(before: dict[str, str],
                      after: dict[str, str]) -> list[str]:
    changed = []
    for key in sorted(set(before) | set(after)):
        a, b = before.get(key), after.get(key)
        if a != b:
            changed.append(f"{key}: {a or '<absent>'} -> {b or '<absent>'}")
    return changed

# ---------------------------------------------------------------------------
# Mutations

# ---------------------------------------------------------------------------

class MutationError(RuntimeError):
    """A guard's anchor text could not be found exactly once.

    Raised instead of silently doing nothing. A removal that quietly no-ops

    would report the covering test GREEN and label it VACUOUS, which is a false

    accusation of the test and a false all-clear for the guard.

    """

def replace_once(text: str, old: str, new: str, *, what: str) -> str:
    count = text.count(old)
    if count != 1:
        raise MutationError(
            f"{what}: anchor found {count} times, expected exactly 1. "
            f"Anchor: {old[:120]!r}")
    return text.replace(old, new, 1)

@dataclass

class Replacement:
    """One exact-anchor text substitution inside a single .lua file."""
    old: str
    new: str
    what: str

    def apply(self, text: str) -> str:
        return replace_once(text, self.old, self.new, what=self.what)

@dataclass

class MoveBlock:
    """Delete a block and re-insert it immediately above an anchor line.

    This is the shape of the real RETICLE_COLORS defect: the declaration

    existed, just below its first use. Deleting it outright would produce an

    `unresolved-global` instead of the `out-of-scope-local` the checker was

    written for, so the block is relocated rather than removed.

    """
    block: str
    before: str
    what: str

    def apply(self, text: str) -> str:
        if text.count(self.block) != 1:
            raise MutationError(
                f"{self.what}: block found {text.count(self.block)} times")
        if text.count(self.before) != 1:
            raise MutationError(
                f"{self.what}: destination anchor found "
                f"{text.count(self.before)} times")
        text = text.replace(self.block, "", 1)
        return text.replace(self.before, self.block + self.before, 1)

@dataclass

class ConfigDefault:
    """Flip the default value of a named key in fs2rts_config.lua.

    Only for a guard that IS a shipped default. A code path gated on a flag

    whose default is the guard has to be disabled in the consuming code, not

    here, or the flip is indistinguishable from the guard doing its job.

    """
    key: str
    old: str
    new: str
    what: str

    def apply(self, text: str) -> str:
        return replace_once(text, self.old, self.new, what=self.what)
Mutation = Replacement | MoveBlock | ConfigDefault


def anchor_of(mutation: Mutation) -> str:
    return getattr(mutation, "old", None) or mutation.block


def target_rel(guard_file: str, mutations: list[Mutation]) -> str:
    """Script (relative to data/scripts) that holds every anchor of a guard.

    A split module keeps its anchors in one part file, and its aggregator holds
    none, so the first file of the module that contains each anchor exactly once
    is the target. An unsplit file is its own only candidate. If no file fits,
    the guard file is returned so the anchor test reports the real counts.
    """
    for path in module_files(SCRIPTS, guard_file[:-len(".lua")]):
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        if all(text.count(anchor_of(m)) == 1 for m in mutations):
            return path.relative_to(SCRIPTS).as_posix()
    return guard_file
# Every path this harness writes to, recorded. The sandbox is outside the mod,
# so a correct run leaves this list entirely inside the temp directory. It is
# reported rather than asserted so a reader can check the claim instead of
# taking it on trust, and so a regression that writes to the real tree shows up
# as an explicit path rather than as a mystery hash change.
WRITES: list[str] = []

def _record_write(path: Path) -> None:
    WRITES.append(str(path))

@dataclass

class Guard:
    name: str
    title: str
    file: str                                  # relative to data/scripts
    mutations: list[Mutation]
    tests: list[str]                           # node ids claiming coverage
    note: str = ""
    # Tests that merely MENTION the guard. Reported so a keyword reference is
    # never mistaken for coverage.
    keywords: list[str] = field(default_factory=list)

# ---------------------------------------------------------------------------
# Sandbox

# ---------------------------------------------------------------------------

class Sandbox:
    """A throwaway copy of core/ that the suite can be run against."""

    def __init__(self, dest: Path):
        self.root = dest
        (dest / "data").mkdir(parents=True, exist_ok=True)
        for rel in SANDBOX_DIRS:
            src = CORE / rel
            if not src.is_dir():
                raise MutationError(f"missing source directory: {src}")
            shutil.copytree(src, dest / rel,
                            ignore=shutil.ignore_patterns(*CACHE_NAMES))
        self.pristine: dict[Path, bytes] = {
            p: (dest / p).read_bytes() for p in self._script_files()}

    def _script_files(self) -> list[Path]:
        return sorted((self.root / "data" / "scripts").rglob("*.lua"))

    def reprime(self) -> None:
        """Re-snapshot the sandbox as the new pristine baseline.

        Called after a torn-read recovery re-copies the tree, so `restore()`

        returns to what the source actually says now rather than to a

        half-written file captured earlier.

        """
        self.pristine = {p: p.read_bytes() for p in self._script_files()}

    def restore(self) -> None:
        for path, data in self.pristine.items():
            if path.read_bytes() != data:
                path.write_bytes(data)
                _record_write(path)

    def apply(self, mutations: list[Mutation], file_rel: str) -> list[str]:
        """Apply mutations to one script. Returns the list of files changed."""
        file_rel = target_rel(file_rel, mutations)
        target = self.root / "data" / "scripts" / file_rel
        text = target.read_text(encoding="utf-8")
        for mutation in mutations:
            text = mutation.apply(text)
        target.write_text(text, encoding="utf-8")
        _record_write(target)
        return [file_rel]

    def writes_outside_sandbox(self) -> list[str]:
        """Writes that landed in the mod rather than in the temp copy.

        This is the safety property stated as a fact about actual behaviour

        rather than as an intention: it inspects where bytes were written, not

        what the code intended to write.

        """
        sandbox = self.root.resolve()
        return [w for w in WRITES
                if not Path(w).resolve().is_relative_to(sandbox)]

def _run(node_ids: list[str], tools_dir: Path, timeout: int) -> tuple[int, str]:
    """Require per-test runner evidence; setup errors and hangs are not kills."""
    if not node_ids:
        return 2, "no covering tests selected"
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    with tempfile.TemporaryDirectory(prefix="runner_", dir=tools_dir) as folder:
        result_path = Path(folder) / "results.xml"
        try:
            proc = subprocess.run(
                [sys.executable, "-m", "pytest", "-q", "--tb=short", "-rEf",
                 "-p", "no:cacheprovider", f"--junitxml={result_path}", *node_ids],
                cwd=str(tools_dir), env=env, capture_output=True, text=True,
                timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            partial = exc.stdout if isinstance(exc.stdout, str) else ""
            hung = "\n".join(f"FAILED {n} - did not finish within {timeout}s" for n in node_ids)
            return 1, partial + "\n" + hung
        output = proc.stdout + proc.stderr
        try:
            cases = ET.parse(result_path).iter("testcase")
            for case in cases:
                parts = case.get("classname", "").split(".")
                node = parts[0] + ".py::" + "::".join(parts[1:] + [case.get("name", "")])
                failure = case.find("failure")
                if all(case.find(tag) is None for tag in ("failure", "error", "skipped")):
                    output += f"\nTEST_PASSED {node}\n"
                elif failure is not None:
                    message = failure.get("message", "")
                    if message.startswith(("AssertionError", "assert ")) or re.search(
                            r"(?m)^(?:E\s+)?AssertionError\b", failure.text or "") or (
                            "lupa." in message and "LuaError:" in message and re.search(
                                r"(?m)^\s*(?:E\s+)?\[C\]: in function 'assert'\s*$", failure.text or "")):
                        output += f"\nASSERTION_FAILURE {node}\n"
                    else:
                        output += f"\nTEST_UNVERIFIED {node}\n"
                else:
                    output += f"\nTEST_UNVERIFIED {node}\n"
        except (OSError, ET.ParseError) as exc:
            return proc.returncode or 2, output + f"\nrunner evidence unavailable: {exc}"
    return proc.returncode, output
_FAILED_RE = re.compile(r"^(?:FAILED|ERROR)\s+(\S+)", re.MULTILINE)
_HUNG_RE = re.compile(r"^FAILED\s+(\S+)\s+-\s+did not finish", re.MULTILINE)
_PASSED_RE = re.compile(r"^TEST_PASSED\s+(\S+)", re.MULTILINE)
_ASSERTION_RE = re.compile(r"^ASSERTION_FAILURE\s+(\S+)", re.MULTILINE)
_UNVERIFIED_RE = re.compile(r"^TEST_UNVERIFIED\s+(\S+)", re.MULTILINE)

def failed_node_ids(output: str) -> set[str]:
    """Node ids pytest reported as failed or errored."""
    return set(_FAILED_RE.findall(output))

def hung_node_ids(output: str) -> set[str]:
    """Node ids that timed out rather than failed.

    Kept separate from `failed_node_ids` so a hang is never silently reported

    as a clean RED. A hang means an unbounded loop, which is a different

    defect with a different severity.

    """
    return set(_HUNG_RE.findall(output))

def node_id_of(node: str) -> str:
    """Normalise so 'test_x.py::C::t' and 'test_x.py::C::t[param]' compare."""
    return node.split("[", 1)[0]

# ---------------------------------------------------------------------------
# The guard inventory

# ---------------------------------------------------------------------------
# Anchors are exact strings. If a concurrent edit moves one, the guard reports
# ERROR ("anchor found 0 times"), which is the honest outcome: a falsification
# that could not be performed is not a pass.
# The reticle colour tables live in fs2rts_hud/common.lua and reach the parts
# through their import line. The defect class is an import (or declaration)
# that lands below a read in the same file, so the import line is what moves.
RETICLE_IMPORT = "local RTS, clamp, RETICLE_COLORS = _shared.RTS, _shared.clamp, _shared.RETICLE_COLORS\n"
GUARDS: list[Guard] = [
    # ---- configuration defaults that ARE the guard ------------------------
    Guard(
        name="station_ai_station_reserve_cap",
        title="Station.AI.StationReserveCap caps the base-investment hurdle",
        file="fs2rts_station.lua",
        mutations=[
            Replacement(
                old=("        local stationReserve=math.min(reserve,"
                     "math.max(0,tonumber(aiCfg.StationReserveCap) or 1500))\n"),
                new="        local stationReserve=reserve\n",
                what="StationReserveCap clamp"),
        ],
        tests=[
            "test_station.py::StationTests::test_station_reserve_cap_lets_the_base_invest_while_the_fleet_saves",
            "test_station.py::StationTests::test_ai_never_spends_player_cp_from_the_real_station_ai",
            "test_station.py::StationTests::test_factory_reservation_and_saving_deadline",
            "test_station.py::StationTests::test_ai_builds_opening_fleet_before_defense_ring",
        ],
        keywords=["StationReserveCap", "stationReserve"],
        note="Cap removed: affordable() no longer reserves anything, so the "
             "producer's full productionReserve blocks base investment. This "
             "guard was first reported VACUOUS - the three older candidate tests "
             "all passed with the clamp deleted - and the conclusion drawn from "
             "that, that the cap has no observable behaviour, was WRONG: it is "
             "observable in the engine (uncapped, a sentry needs cost + ~13,000 "
             "CP; capped, cost + 1,500) and it is the reason sentry builds "
             "recovered from 7 per 4 matches to 111 once FieldCheapHullWhileSaving "
             "was reverted. The gap was coverage, not dead code. "
             "test_station_reserve_cap_lets_the_base_invest_while_the_fleet_saves "
             "now makes the clamp the difference and goes RED without it, verified "
             "by hand: setting StationReserveCap to 1e8 in config fails it.",
    ),
    Guard(
        name="ai_field_cheap_hull_while_saving",
        title="AI.FieldCheapHullWhileSaving ships OFF (the producer goes dark to save)",
        file="fs2rts_config.lua",
        mutations=[
            ConfigDefault(
                key="AI.FieldCheapHullWhileSaving",
                old="        FieldCheapHullWhileSaving = false,\n",
                new="        FieldCheapHullWhileSaving = true,\n",
                what="FieldCheapHullWhileSaving default"),
        ],
        tests=[
            "test_station.py::StationTests::test_field_cheap_hull_while_saving_ships_off",
            "test_station.py::StationTests::test_saving_clock_default_keeps_the_pre_flag_clearing_behaviour",
            "test_station.py::StationTests::test_saving_clock_survives_fielding_a_cheap_hull",
            "test_station.py::StationTests::test_saving_is_only_skipped_when_the_bank_can_actually_reach_the_goal",
        ],
        keywords=["FieldCheapHullWhileSaving", "savingAlongside"],
        note="Ships false: during a saving window the producer goes dark so the bank "
             "can reach the target. Flipping it true was diagnosed from a "
             "PRODUCTION_BLACKOUT anomaly that was actually the AI saving correctly "
             "- bank climbing ~10,000 CP toward the capital target with 15-20 options "
             "affordable - and it zeroed capital/heavy/juggernaut production in 4 of 4 "
             "headless matches. The alongside tests now set the flag explicitly, so "
             "this mutation checks the default rather than an inherited fixture.",
    ),
    Guard(
        name="ai_preserve_saving_clock_while_fielding",
        title="AI.PreserveSavingClockWhileFielding: keep savingSince across the "
              "alongside purchase (the livelock fix)",
        file="fs2rts_ai_production.lua",
        mutations=[
            Replacement(
                old=("    local fieldingAlongside = decision.savingAlongside==true\n"
                     "        and self.Config.AI.PreserveSavingClockWhileFielding==true\n"),
                new="    local fieldingAlongside = false\n",
                what="PreserveSavingClockWhileFielding consumer"),
        ],
        tests=[
            "test_station.py::StationTests::test_saving_clock_survives_fielding_a_cheap_hull",
            "test_station.py::StationTests::test_saving_is_only_skipped_when_the_bank_can_actually_reach_the_goal",
            "test_station.py::StationTests::test_saving_clock_default_keeps_the_pre_flag_clearing_behaviour",
        ],
        keywords=["PreserveSavingClockWhileFielding", "savingSince", "fieldingAlongside"],
        note="Consumer neutered: the saving clock is cleared on every "
             "purchase again, which is the permanent SAVING_FOR_DESIRED_ROLE "
             "livelock (0 capital builds in 4/4 headless matches).",
    ),
    # ---- code guards -------------------------------------------------------
    Guard(
        name="service_max_under_fire_seconds",
        title="Service.MaxUnderFireSeconds: release a refit that cannot repair",
        file="fs2rts_service.lua",
        mutations=[
            Replacement(
                old=("        if not s.manual and serviceBlocked and now-s.underFireSince>="
                     "(c.MaxUnderFireSeconds or 240) then\n"),
                new="        if false then\n",
                what="MaxUnderFireSeconds release branch"),
        ],
        tests=[
            "test_service.py::ServiceTests::test_refit_under_persistent_threat_is_released_not_parked_forever",
        ],
        keywords=["MaxUnderFireSeconds", "underFireSince"],
        note="The bound that releases a permanently UNDER_FIRE hull. Removing "
             "it parks the hull on the pad for the rest of the mission.",
    ),
    Guard(
        name="service_retry_seconds_cooldown_gate",
        title="Service.RetrySeconds: the retryReady cooldown gate at "
              "fs2rts_service.lua:548",
        file="fs2rts_service.lua",
        mutations=[
            Replacement(
                old="            local retryReady=now>=(self.FleetServiceCooldown[id] or 0)\n",
                new="            local retryReady=true\n",
                what="retryReady cooldown gate"),
        ],
        tests=[
            "test_service.py::ServiceTests::test_service_retry_cooldown_blocks_danger_loop_but_not_critical_hull",
        ],
        keywords=["retryReady", "FleetServiceCooldown", "RetrySeconds"],
        note="Cooldown gate forced open: a hull re-enters service on the very "
             "next think after release, which is the danger loop the gate exists "
             "to break.",
    ),
    Guard(
        name="hud_reticle_color_hoist",
        title="RETICLE_COLORS import in fs2rts_hud/reticles.lua above its first use",
        file="fs2rts_hud.lua",
        mutations=[
            MoveBlock(
                block=RETICLE_IMPORT,
                before="function RTS:GetReticlePixelSize(ship)\n",
                what="RETICLE_COLORS import hoist"),
        ],
        tests=[
            "test_lua_scope_order.py::ShippedModTests::test_no_shipped_script_has_an_out_of_scope_read",
        ],
        keywords=["RETICLE_COLOR_SELECTED", "RETICLE_COLORS", "RETICLE_COLOR_HOVERED"],
        note="Block relocated back below its first use, reproducing the exact "
             "shipped defect. lua_scope_order_check must report "
             "out-of-scope-local again.",
    ),
    Guard(
        name="pcall_spawn_friendly",
        title="pcall around SpawnFriendly in the BLUE build-completion path",
        file="fs2rts_production.lua",
        mutations=[
            Replacement(
                old=("                local ok,success,returned=pcall(function()\n"
                     "                    local s,sp=self:SpawnFriendly(current.option,spawned,current)\n"
                     "                    return s,sp\n"
                     "                end)\n"),
                new=("                local ok,success,returned=true,self:SpawnFriendly(current.option,spawned,current)\n"),
                what="SpawnFriendly pcall",
            ),
        ],
tests=[
               "test_station.py::StationTests::test_build_queue_retires_an_item_whose_spawn_raises",
           ],
           keywords=["SpawnFriendly", "SPAWN RAISED", "spawnFails"],
        note="The pcall keeps a raising spawn from aborting OnFrame before "
             "table.remove, which turned one transient fault into dozens of "
             "duplicate hulls latched into fleet slots. UNCOVERED: the only "
             "test references to SpawnFriendly are the harness's own stub "
             "(`r.SpawnFriendly=function() return true,{} end`) and the "
             "spawnFails flag used for PlaceSentry. No test drives the "
             "build-completion path with a RAISING SpawnFriendly, so the pcall "
             "is never the difference between pass and fail. Note the harness "
             "makes SpawnFriendly RAISE, not merely return nil - the test stub "
             "flag is spawnFails, which drives PlaceSentry's nil path, a "
             "different branch. "
             "test_station.py::StationTests::test_sentry_validation_refund_and_sell "
             "was the nearest candidate and stayed GREEN with the pcall removed.",
    ),
    Guard(
        name="release_waypoint_handles",
        title="Mission teardown releases pooled waypoint handles",
        file="fs2rts_lifecycle.lua",
        mutations=[Replacement(
            old="    if self.MoveWaypoints~=nil then pcall(function() self.MoveWaypoints={} end) end\n",
            new="",
            what="omit waypoint handle cleanup")],
        tests=["test_station.py::StationTests::test_release_object_handles_clears_every_handle_table"],
        note="Guard observable cleanup; plain table-assignment pcall removal has no behavior difference.",
    ),
    Guard(
        name="station_capital_aware_investment_gate",
        title="Station.AI.CapitalAwareInvestment: defer base UPGRADES while the "
              "producer saves for a role the bank cannot afford",
        file="fs2rts_station.lua",
        mutations=[
            Replacement(
                old=("        if deferInvestment and not (track==\"armor\" and criticalStationHull) then return false end\n"),
                new="        if false then return false end\n",
                what="CapitalAwareInvestment upgrade gate"),
        ],
        tests=[
            "test_station.py::StationTests::test_capital_gate_defers_upgrades_while_the_fleet_saves",
            "test_station.py::StationTests::test_capital_gate_does_not_starve_the_defence_ring",
            "test_station.py::StationTests::test_capital_gate_releases_once_the_bank_can_afford_the_role",
            "test_station.py::StationTests::test_capital_gate_releases_when_the_producer_stops_saving",
            "test_station.py::StationTests::test_capital_gate_deferral_is_bounded",
            "test_station.py::StationTests::test_capital_gate_off_keeps_the_shipped_drain",
        ],
        keywords=["CapitalAwareInvestment", "deferInvestment", "capitalGateSince",
                  "savingRole"],
        note="Ships FALSE, so with the flag off nothing changes and the test "
             "above pins that. The mutation removes the CONSUMER, not the "
             "default, because the default is already the off state and a "
             "ConfigDefault flip to true would be indistinguishable from the "
             "gate doing its job. Removing the guard makes the base buy "
             "LOGISTICS L2 at cp 3000 while the producer banks toward a 13,000 "
             "CP capital - the measured 29-38% of income that produced 0 "
             "capital/heavy/juggernaut hulls in 4 of 4 headless matches. "
             "Note the two release tests and the bound test stay GREEN under "
             "this mutation by construction: they assert the gate lets go, "
             "which a gate that never engages also satisfies. The KILLING "
             "tests are the deferral and the defence-ring ones.",
    ),
    Guard(
        name="station_capital_aware_investment_default",
        title="Station.AI.CapitalAwareInvestment protects fleet savings by default",
        file="fs2rts_config.lua",
        mutations=[
            ConfigDefault(
                key="Station.AI.CapitalAwareInvestment",
                old="            CapitalAwareInvestment = true,\n",
                new="            CapitalAwareInvestment = false,\n",
                what="CapitalAwareInvestment default"),
        ],
        tests=[
            "test_station.py::StationTests::test_capital_aware_investment_defaults_on",
            "test_station.py::StationTests::test_capital_gate_off_keeps_the_shipped_drain",
            "test_station.py::StationTests::test_ai_reserves_mobile_wing_and_limits_idle_defenses",
            "test_station.py::StationTests::test_ai_builds_opening_fleet_before_defense_ring",
            "test_station.py::StationTests::test_ai_selects_flak_for_fighter_threats",
            "test_station.py::StationTests::test_ai_never_spends_player_cp_from_the_real_station_ai",
            "test_station.py::StationTests::test_station_upgrade_spend_routes_through_the_cp_ledger",
            "test_station.py::StationTests::test_each_upgrade_level_for_every_faction",
        ],
        keywords=["CapitalAwareInvestment"],
        note="Default flipped on. This is the whole balance surface of the "
             "change: the flag must stay off until an A/B proves it, and "
             "flipping it must be visible in the shipped tests rather than "
             "silently reallocating the bank.",
    ),
    Guard(
        name="station_capital_gate_deferral_bound",
        title="The capital gate's escape bound: release after the producer's own "
              "longest save window",
        file="fs2rts_station.lua",
        mutations=[
            Replacement(
                old=("        if (now-(state.capitalGateSince or now))<limit then\n"
                     "            deferInvestment=true\n"
                     "        else\n"
                     "            state.capitalGateSince=nil\n"
                     "        end\n"),
                new=("        deferInvestment=true\n"),
                what="capital gate bound"),
        ],
        tests=[
            "test_station.py::StationTests::test_capital_gate_deferral_is_bounded",
            "test_station.py::StationTests::test_capital_gate_releases_once_the_bank_can_afford_the_role",
        ],
        keywords=["capitalGateSince", "CapitalAwareInvestmentMaxSeconds"],
        note="Bound removed: deferInvestment is unconditional while the producer "
             "is saving. That is the hang this guard exists to prevent - a "
             "producer whose 13,000-31,275 CP target is unreachable at the "
             "measured 180-230 CP per think never buys, so savingRole is never "
             "cleared and the base would never upgrade again for the rest of "
             "the match. The override (MaxSeconds=0 fails open) is covered by "
             "the same test.",
    ),
    # ---- heavy assault objective lock --------------------------------------
    #
    # Each of these falsifies a DIFFERENT clause of ApplyAssaultObjectiveLock,
    # because the clauses are independent: a mutation that only breaks the
    # reactive test must not be able to leave the tests green just because the
    # corridor clause happens to admit the same fixture.
    Guard(
        name="assault_objective_lock_call_site",
        title="The assault objective lock is called at all",
        file="fs2rts_strategy.lua",
        mutations=[
            Replacement(
                old=("        target,mission=self:ApplyAIOperationOrder(g,target,mission,context,station,now,coverage)\n"
                     "        target,mission=self:ApplyAssaultObjectiveLock(g,target,mission,context)\n"),
                new=("        target,mission=self:ApplyAIOperationOrder(g,target,mission,context,station,now,coverage)\n"),
                what="ApplyAssaultObjectiveLock call"),
        ],
        tests=[
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_the_gate_runs_between_operations_and_commit",
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_a_sentry_that_is_not_a_threat_is_vetoed_and_the_station_stays",
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_non_heavy_groups_are_unaffected",
        ],
        keywords=["ApplyAssaultObjectiveLock"],
        note="The gate deleted from the per-group loop. This is the shipped "
             "symptom returning verbatim - 44.8% of heavy PRIMARY decisions "
             "chasing a sentry, 16.4% on the station - with no error anywhere, "
             "because a veto that is never called looks exactly like a veto that "
             "has nothing to veto. Split from the ordering guard below because "
             "two mutations in one guard share a sandbox: removing the call "
             "destroys the anchor the reordering mutation needs.",
    ),
    Guard(
        name="assault_objective_lock_ordering",
        title="The gate runs AFTER operations picks the target and BEFORE commit",
        file="fs2rts_strategy.lua",
        mutations=[
            Replacement(
                old=("        target,mission=self:ApplyAIOperationOrder(g,target,mission,context,station,now,coverage)\n"
                     "        target,mission=self:ApplyAssaultObjectiveLock(g,target,mission,context)\n"),
                new=("        target,mission=self:ApplyAssaultObjectiveLock(g,target,mission,context)\n"
                     "        target,mission=self:ApplyAIOperationOrder(g,target,mission,context,station,now,coverage)\n"),
                what="gate moved before operations"),
        ],
        tests=[
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_the_gate_runs_between_operations_and_commit",
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_a_sentry_that_is_not_a_threat_is_vetoed_and_the_station_stays",
        ],
        keywords=["ApplyAssaultObjectiveLock"],
        note="Same two lines, order swapped. A veto placed before the value it "
             "vetoes exists sees the station rather than the sentry, so it has "
             "nothing to do and the operations layer then overwrites its result. "
             "Silent, and indistinguishable from a working gate by any "
             "telemetry that only reads the committed target - which is why the "
             "ordering is asserted directly from the source instead of inferred.",
    ),
    Guard(
        name="assault_objective_lock_reactive_clause",
        title="A sentry that IS the local threat is still engaged",
        file="fs2rts_strategy.lua",
        mutations=[
            Replacement(
                old=("    if shipValid(g.localThreat) and g.localThreat:getSignature()==target:getSignature() then\n"),
                new=("    if false and shipValid(g.localThreat) and g.localThreat:getSignature()==target:getSignature() then\n"),
                what="reactive identity test"),
            Replacement(
                old=("        reactive=threatDistance>=0 and threatDistance<=bound\n"),
                new=("        reactive=false\n"),
                what="reactive distance bound"),
        ],
        tests=[
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_a_sentry_that_is_the_local_threat_is_still_engaged",
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_the_reactive_bound_is_enforced_and_configurable",
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_hard_local_threat_alone_does_not_admit_an_unrelated_sentry",
        ],
        keywords=["localThreatSignature", "AssaultStaticDefenceThreatDistance"],
        note="Two separate falsifications. The first removes the identity test, "
             "so NO sentry is ever reactive and the gate refuses to clear a way "
             "even at point-blank range - the opposite defect, and the one that "
             "would make a capital walk into a turret ring it can shoot back at. "
             "The second removes only the distance bound, so a stale localThreat "
             "re-bound by the INTERCEPT retention swap at "
             "fs2rts_strategy/strategic_plan.lua:86-90 can be arbitrarily far away and "
             "still re-appear as a group's objective. The first mutation is "
             "covered by the reactive test; the second only by the bound test, "
             "which is why that test exists separately.",
    ),
    Guard(
        name="assault_objective_lock_hold_geometry",
        title="A non-reactive sentry restores the station as the objective",
        file="fs2rts_strategy.lua",
        mutations=[
            Replacement(
                old=("    if reactive or inCorridor then return target,mission end\n"),
                new=("    if true then return target,mission end\n"),
                what="hold condition"),
            Replacement(
                old=("    g.assaultLock={held=op.target:getSignature(),rejected=target:getSignature(),\n"
                     "        staticDefence=isStatic,threatDistance=threatDistance,corridorOffset=corridorOffset}\n"
                     "    context.reason='ASSAULT_OBJECTIVE_HELD'\n"
                     "    return op.target,mission\n"),
                new=("    return target,mission\n"),
                what="the hold itself (target, reason and telemetry)"),
            Replacement(
                old=("                inCorridor=along>0 and along<length and corridorOffset<=corridor\n"),
                new=("                inCorridor=true\n"),
                what="corridor test"),
        ],
        tests=[
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_a_sentry_that_is_not_a_threat_is_vetoed_and_the_station_stays",
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_a_sentry_in_the_corridor_is_engaged_but_one_beside_the_lane_is_not",
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_the_gate_only_fires_on_a_primary_assault_against_a_command_station",
        ],
        keywords=["ASSAULT_OBJECTIVE_HELD", "corridorOffset"],
        note="Three falsifications, one per behaviour. (1) Never hold: the "
             "original defect verbatim, 44.8% sentry / 16.4% station. (2) Hold "
             "without substituting the station or recording it: the group would "
             "be left with a stale target and no telemetry, and this is the "
             "mutation that proves the assaultLock field and the reason string "
             "are load-bearing rather than decorative. (3) Corridor always true: "
             "the clause stops discriminating, which is exactly its measured "
             "behaviour at any width >= 3000 m, and the beside-the-lane case is "
             "the only thing that catches it.",
    ),
    Guard(
        name="assault_objective_lock_defaults",
        title="Both assault locks ship OFF with the corridor clause disabled",
        file="fs2rts_config.lua",
        mutations=[
            ConfigDefault(
                key="AI.Doctrine.AssaultStaticDefenceLock",
                old="            AssaultStaticDefenceLock = false,\n",
                new="            AssaultStaticDefenceLock = true,\n",
                what="AssaultStaticDefenceLock default"),
            ConfigDefault(
                key="AI.Doctrine.AssaultMobileThreatLock",
                old="            AssaultMobileThreatLock = false,\n",
                new="            AssaultMobileThreatLock = true,\n",
                what="AssaultMobileThreatLock default"),
            ConfigDefault(
                key="AI.Doctrine.AssaultStaticDefenceCorridorWidth",
                old="            AssaultStaticDefenceCorridorWidth = 0,\n",
                new="            AssaultStaticDefenceCorridorWidth = 3000,\n",
                what="AssaultStaticDefenceCorridorWidth default"),
        ],
        tests=[
            "test_ai_assault_doctrine.py::AssaultDoctrineGuardTests::test_both_locks_ship_off_and_the_gate_is_a_no_op",
        ],
        keywords=["AssaultStaticDefenceLock", "AssaultMobileThreatLock",
                  "AssaultStaticDefenceCorridorWidth"],
        note="Each default flipped independently. The two locks default false "
             "because there is no A/B behind either yet. The corridor width "
             "defaults to 0 rather than to a plausible-looking 3000 because it "
             "is measurably vacuous at 3000: over the 1301 sentry diversions in "
             "capgate-20261001 the perpendicular offset from the "
             "centroid->station axis is p50 689 m / p90 2008 m, so a 3000 m "
             "corridor admits 97.5% of them. Shipping 0 is the honest default; "
             "shipping 3000 would look like the requested behaviour while "
             "changing nothing measurable.",
    ),

    # ---------------------------------------------------------------- sentry
    # Two defects, both measured against capgate-20261001 (4 matches streamed
    # in full, 14,635 UNIT samples). Each guard removes ONE mechanism, so a
    # covering test that stays green is a real accusation rather than an
    # artefact of both being reverted at once.
    Guard(
        name="sentry_aims_at_the_hostile_for_every_role",
        title="Every sentry role is oriented at a hostile hull, not just the beam role",
        file="fs2rts_station.lua",
        mutations=[
            # Restore the beam-only gate. This was the original defect: the
            # orientation override sat behind `if option.role=="beam"`, so
            # 99.26% of every ring built in capgate - screen, flak and missile
            # hulls - inherited station.Orientation, measured 30 deg off the
            # enemy axis before placement scatter and p50 bearing error 29-37
            # deg once scattered. Turret FOV is a hard engine gate
            # (aiturret.cpp:2667), so those hulls could not fire at a target
            # they were already in range of.
            Replacement(
                old='    local aimX, aimZ = self:SentryAimVector(kind, pos)\n'
                    '    if aimX then',
                new='    local aimX, aimZ = nil, nil\n'
                    '    if option.role=="beam" then aimX, aimZ = self:SentryAimVector(kind, pos) end\n'
                    '    if aimX then',
                what="restrict sentry aiming to the beam role again",
            ),
            # Separately: pass the aim as the UP vector, which is what the code
            # actually did. The engine signature is [fvec, uvec, rvec]
            # (base.cpp:179) and vm_vector_2_matrix copies the FIRST vector
            # straight into m.vec.fvec (vecmat.cpp:898), so the old call built
            # every explicitly aimed sentry with its nose pointed at the floor.
            # This is the one role that DID get aimed, and it was aimed down.
            Replacement(
                old='        orientation=ba.createOrientationFromVectors(vec(aimX,0,aimZ))',
                new='        orientation=ba.createOrientationFromVectors(vec(0,-1,0),vec(aimX,0,aimZ))',
                what="restore the inverted fvec/uvec orientation call",
            ),
        ],
        tests=[
            "test_station.py::StationTests::test_every_sentry_role_aims_at_the_hostile_not_the_station",
        ],
        keywords=["SentryAimVector", "aimX", "createOrientationFromVectors"],
        note="Two mutations because two independent defects produced the same "
             "observable - a ring that cannot engage. The role gate is the one "
             "reported from telemetry; the argument order was found while "
             "writing the covering test, when the harness double (deliberately "
             "built to follow base.cpp:179 rather than to be permissive) "
             "reported the old beam hull aiming at z=0. Both must be removed "
             "for the test to pass, and the suite reports KILLED only when it "
             "is, so neither can hide behind the other. The aim test asserts an "
             "exact bearing (dot > 0.999) rather than a sign, because a sign "
             "check would still pass on a hull aimed at the wrong faction's "
             "station.",
    ),
    Guard(
        name="sentry_aim_scan_avoids_ipairs",
        title="Sentry aiming walks mn.Ships numerically; ipairs crashes the engine",
        file="fs2rts_station.lua",
        mutations=[
            # SentryAimVector's ship scan, changed back to the iteration form.
            # This is the only mechanism in the whole sentry fix that a UNIT TEST
            # CANNOT see: the failure is a C++ exception (0xE06D7363) in the
            # engine, not a Lua error, so every test in this repo passes with
            # the crashing line in place. It surfaced only because a headless
            # batch died at t=310 s with an empty stdout and a non-zero exit.
            # Bisected: this exact line, alone inside capgate's CreateSentry,
            # reproduces exit 0xE06D7363; the numeric form exits 0.
            Replacement(
                old="        for i=1,#mn.Ships do\n"
                    "            local other = mn.Ships[i]",
                new="        for _, other in ipairs(mn.Ships or {}) do",
                what="restore ipairs(mn.Ships) in the sentry aim scan",
            ),
        ],
        tests=[
            "test_station.py::StationTests::test_sentry_aim_scan_uses_the_numeric_ship_idiom_not_ipairs",
        ],
        keywords=["#mn.Ships", "ipairs(mn.Ships"],
        note="The covering test asserts SOURCE SHAPE, not behaviour: it strips "
             "Lua comments and then requires the numeric walk to be present and "
             "the ipairs walk absent. That is the strongest automated guard "
             "available for a C++ crash, and it is deliberately a source check "
             "so a future edit that reintroduces ipairs fails in milliseconds "
             "instead of at the end of a twenty-minute batch.",
    ),
    Guard(
        name="fighters_cannot_damage_station_subsystems",
        title="The station damage hook blocks fighter projectiles from hulls and turrets",
        file="fs2rts_ai_telemetry.lua",
        mutations=[
            Replacement(
                old=("                    return blocked\n"
                     "                end\n"
                     "                local a,b=hv['Self'],hv['ShipB']\n"),
                new=("                    return false\n"
                     "                end\n"
                     "                local a,b=hv['Self'],hv['ShipB']\n"),
                what="allow blocked fighter projectile to hit command station",
            ),
        ],
        tests=[
            "test_player_feedback.py::PlayerFeedbackTests::test_fighter_station_guard_blocks_hull_and_turret_damage",
        ],
        note="The test checks fighter hull and turret impacts, selected-turret "
             "attacks, beam hits, and eligible bomber/capital controls.",
    ),
    Guard(
        name="station_turrets_repair_after_quiet",
        title="Station turret subsystems recover after the shared quiet period",
        file="fs2rts_station.lua",
        mutations=[
            Replacement(
                old="                    if hp<max then turret.HitpointsLeft=math.min(max,hp+max*subsystemRate*dt) end\n",
                new="                    if hp<max then end\n",
                what="remove passive station-turret repair",
            ),
        ],
        tests=[
            "test_station.py::StationTests::test_station_turrets_repair_after_quiet_but_not_during_survivor_phase",
        ],
        note="The regression asserts the hit restarts the delay, repair rate, "
             "and the no-repair survivor phase.",
    ),
    Guard(
        name="auto_build_request_saves_until_specific_hull",
        title="A pending Blue auto-build request takes priority once funded",
        file="fs2rts_ai_production.lua",
        mutations=[
            Replacement(
                old="                    if request and requestedEntry and request.tier<=tier then\n",
                new="                    if false then\n",
                what="specific-hull request production branch"),
        ],
        tests=[
            "test_station.py::StationTests::test_auto_build_request_saves_shared_cp_and_completes_once",
        ],
        note="Removing the request branch prevents the requested hull from completing.",
    ),
    Guard(
        name="outmatched_service_requires_recovery_need",
        title="Only damaged, focused, outmatched ships automatically withdraw for service",
        file="fs2rts_service.lua",
        mutations=[
            Replacement(
                old="            and hp<c.ReturnHull)\n",
                new="            and (hp<c.ReturnHull or self:IsFleetFocusedByHostiles(ship,now)))\n",
                what="recovery eligibility before threat sampling"),
            Replacement(
                old=("        elseif retryReady and not order and focused and outmatched and not assaultHold[ship:getSignature()]\n"
                     "            and hp<c.ReturnHull and enemy>math.max(1,friend)*c.AvoidFightRatio then reason='AVOID_OVERWHELMING_FIGHT'\n"
                     "        elseif retryReady and not order and focused and outmatched and not assaultHold[ship:getSignature()]\n"
                     "            and hp<c.ReturnHull and now-(self.SurvivalDangerSince[id] or now)>=c.DangerSeconds then reason='OUTMATCHED'\n"),
                new=("        elseif retryReady and not order and focused and outmatched and not assaultHold[ship:getSignature()]\n"
                     "            and enemy>math.max(1,friend)*c.AvoidFightRatio then reason='AVOID_OVERWHELMING_FIGHT'\n"
                     "        elseif retryReady and not order and focused and outmatched and not assaultHold[ship:getSignature()]\n"
                     "            and now-(self.SurvivalDangerSince[id] or now)>=c.DangerSeconds then reason='OUTMATCHED'\n"),
                what="healthy outmatched withdrawal filter"),
        ],
        tests=[
            "test_service.py::ServiceTests::test_healthy_outmatched_ships_keep_fighting_and_damaged_ships_service",
            "test_service.py::ServiceTests::test_healthy_ship_does_not_withdraw_from_an_overwhelming_local_fight",
        ],
        note="Removing the damage gate makes healthy ships withdraw from local pressure.",
    ),
    Guard(
        name="funded_player_request_protects_station_investments",
        title="A Blue build request waiting for cap protects CP once its hull is funded",
        file="fs2rts_station.lua",
        mutations=[
            Replacement(
                old="    local protectAutoBuild=request~=nil and request.status~=\"BUILDING\" and not requestEmergencyFresh\n",
                new="    local protectAutoBuild=false\n",
                what="request-aware station investment gate"),
        ],
        tests=[
            "test_station.py::StationTests::test_pending_player_request_protects_a_funded_bank_until_capacity_opens",
        ],
        note="Removing the request gate lets the funded, cap-blocked request spend on upgrades or paid abilities.",
    ),
    Guard(
        name="critical_station_armor_overrides_player_build_request",
        title="A critical station may buy armor while a specific hull request waits",
        file="fs2rts_station.lua",
        mutations=[
            Replacement(
                old="        if protectAutoBuild and not (track==\"armor\" and criticalStationHull) then return false end\n",
                new="        if protectAutoBuild then return false end\n",
                what="critical armor exception"),
        ],
        tests=[
            "test_station.py::StationTests::test_pending_player_request_protects_a_funded_bank_until_capacity_opens",
        ],
        note="Removing the exception freezes armor investment at critical base hull.",
    ),
    Guard(
        name="auto_target_filter_precedes_cached_iff",
        title="CanAutoEngage filters extraction targets before cached IFF is returned",
        file="fs2rts_ai_planning.lua",
        mutations=[
            Replacement(
                old="        permitted=self:IsAutomaticTargetPermitted(ship,row.ship)\n",
                new="        permitted=true\n",
                what="pre-cache extraction target filter"),
        ],
        tests=[
            "test_ai_concentration.py::ConcentrationGuardTests::test_cached_iff_cannot_make_a_withdrawing_hull_an_auto_target",
        ],
        note="Removing the filter lets a withdrawing hostile through the cached IFF result.",
    ),
    Guard(
        name="withdrawal_owner_rejects_strategic_orders",
        title="Committed withdrawal owners cannot receive another strategic order",
        file="fs2rts_strategy.lua",
        mutations=[
            Replacement(
                old="    if not shipAlive(ship) or not shipAlive(target) or (self.IsShipWithdrawing and self:IsShipWithdrawing(ship)) then return false end\n",
                new="    if not shipAlive(ship) or not shipAlive(target) then return false end\n",
                what="withdrawal-owner order guard"),
        ],
        tests=[
            "test_review_regressions.py::ReviewRegressions::test_withdrawal_blocks_orders_after_a_successful_native_order_control",
        ],
        note="Removing the owner guard permits strategic retasking after withdrawal commitment.",
    ),
    Guard(
        name="sentry_aim_skips_withdrawing_contacts",
        title="Sentry facing and active aim exclude corridor-protected withdrawals",
        file="fs2rts_station.lua",
        mutations=[Replacement(
            old="                    and canAutoEngage(self,station,other) then\n",
            new="                    then\n",
            what="sentry facing withdrawal filter")],
        tests=["test_station.py::StationTests::test_sentry_aim_prefers_the_nearest_hostile_hull_over_the_nearest_station"],
        note="Removing the filter makes initial and active sentry aiming prefer the withdrawn nearer hull.",
    ),
    Guard(
        name="station_point_defense_skips_withdrawing_contacts",
        title="Station screen batteries do not acquire corridor-protected ships",
        file="fs2rts_station.lua",
        mutations=[Replacement(
            old="and canAutoEngage(self,station,ship)\n                                and turret:isPositionInFOV",
            new="and self:AreEnemies(station,ship)\n                                and turret:isPositionInFOV",
            what="station point-defense withdrawal filter")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_station_screen_tracks_incoming_fighters_instead_of_remote_base"],
        note="Restoring pure IFF lets point defense select a withdrawn fighter.",
    ),
    Guard(
        name="active_sentry_aim_skips_withdrawing_contacts",
        title="Active sentry tracking excludes corridor-protected withdrawal targets",
        file="fs2rts_station.lua",
        mutations=[Replacement(
            old="if shipAlive(other) and canAutoEngage(self,sentry,other) and other.Name~=self.Config.ObserverShip then",
            new="if shipAlive(other) and self:AreEnemies(sentry,other) and other.Name~=self.Config.ObserverShip then",
            what="active sentry withdrawal filter")],
        tests=["test_station.py::StationTests::test_sentry_aim_prefers_the_nearest_hostile_hull_over_the_nearest_station"],
        note="Removing the active tracking filter turns the sentry toward the withdrawn nearer hull.",
    ),
    Guard(
        name="beam_sentry_range_skips_withdrawing_contacts",
        title="Beam sentries do not unlock beyond-range guns for corridor-protected ships",
        file="fs2rts_station.lua",
        mutations=[Replacement(
            old="dx*dx+dz*dz<=reach*reach and canAutoEngage(self,beam.ship,enemy) then",
            new="dx*dx+dz*dz<=reach*reach and self:AreEnemies(beam.ship,enemy) then",
            what="Mjolnir range withdrawal filter")],
        tests=["test_station.py::StationTests::test_mjolnir_locks_beyond_its_range_and_reacquires_near_targets"],
        note="Removing the target policy unlocks the beam while only a corridor-protected enemy is in range.",
    ),
    Guard(
        name="station_strike_skips_withdrawing_contacts",
        title="The AI's paid station strike target selector respects withdrawal permission",
        file="fs2rts_station.lua",
        mutations=[Replacement(
            old="            and canAutoEngage(self,station,ship)\n            and ship.Position:getDistance(station.Position)",
            new="            and self:AreEnemies(station,ship)\n            and ship.Position:getDistance(station.Position)",
            what="automatic strike target withdrawal filter")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_station_strike_auto_target_obeys_withdrawal_policy"],
        note="Restoring IFF-only acquisition makes the stronger withdrawn hull win the strike selector.",
    ),
    Guard(
        name="fleet_life_click_regions",
        title="Fleet recovery controls capture clicks before world gestures",
        file="fs2rts_input.lua",
        mutations=[Replacement(
            old="    for _,rect in pairs(self.FleetLifeButtonRects or {}) do\n        if self:PointInside(rect,x,y) then return true end\n    end\n",
            new="",
            what="remove fleet control hit regions")],
        tests=["test_hud_layout.py::HudLayoutTests::test_fleet_controls_and_recovery_card_avoid_side_panels_and_capture_clicks"],
        note="The real hit detector must recognize controls in the free center band.",
    ),
    Guard(
        name="service_idle_threat_scan_gate",
        title="Healthy idle ships avoid threat scans without dropping service safety",
        file="fs2rts_service.lua",
        mutations=[Replacement(
            old="        if needsDanger then\n",
            new="        if not threat then\n",
            what="restore unconditional danger scanning")],
        tests=["test_service.py::ServiceTests::test_healthy_idle_units_skip_threat_scans_but_service_admission_samples_danger"],
        note="The test counts scan calls and verifies damaged admission and active service still scan.",
    ),
    Guard(
        name="fleet_life_layout_clearance",
        title="Fleet controls stay clear of selected-unit stats",
        file="fs2rts_hud.lua",
        mutations=[Replacement(
            old="    local x=(left+right-3*bw-16)/2\n",
            new="    local x=12\n",
            what="restore left-panel overlap")],
        tests=["test_hud_layout.py::HudLayoutTests::test_fleet_controls_and_recovery_card_avoid_side_panels_and_capture_clicks"],
        note="Restoring the former left origin must fail the panel-clearance check.",
    ),
    Guard(
        name="scene_music_index_is_independent",
        title="Unselected music cannot inherit the nebula index",
        file="fs2rts_hud.lua",
        mutations=[Replacement(
            old="            local selected\n            if kind=='music' then selected=self.EnvironmentMusicIndex else selected=self.EnvironmentBackdropIndex end\n",
            new="            local selected=kind=='music' and self.EnvironmentMusicIndex or self.EnvironmentBackdropIndex\n",
            what="restore nil-sensitive music/backdrop selection")],
        tests=["test_hud_layout.py::HudLayoutTests::test_scene_picker_does_not_use_backdrop_index_for_unselected_music"],
        note="An absent music choice must stay random even when the backdrop index names a valid track.",
    ),
    Guard(
        name="strategic_result_is_immutable",
        title="Later station destruction cannot rewrite the strategic result",
        file="fs2rts_lifecycle.lua",
        mutations=[Replacement(
            old="    if not self.StrategicResult and #living<=1 then\n",
            new="    if #living<=1 then\n",
            what="remove strategic-result snapshot guard")],
        tests=["test_fleet_life.py::FleetLifeTests::test_strategic_snapshot_is_immutable_after_station_loss_and_fleet_survival"],
        note="A winner-station loss after Resume must retain the original result object.",
    ),
    Guard(
        name="terminal_callback_cannot_recommission_ship",
        title="A terminal but still-valid native ship cannot become a new history record",
        file="fs2rts_fleet_life.lua",
        mutations=[Replacement(
            old="    if (self.TerminalShipSignatures or {})[ship:getSignature()] and not newCommission then return old end\n",
            new="",
            what="remove terminal native lifetime guard")],
        tests=["test_fleet_life.py::FleetLifeTests::test_archive_keeps_original_wing_and_reused_signature_has_a_fresh_lifetime"],
        note="Polling the departure callback window must not invent a second commissioning; explicit creation still may reuse a signature.",
    ),
    Guard(
        name="empty_withdrawal_faction_queries",
        title="Ordinary faction queries avoid withdrawal signature reads",
        file="fs2rts_factions.lua",
        mutations=[Replacement(
            old="    local withdrawal=self.Withdrawals and next(self.Withdrawals) and self.Withdrawals[ship:getSignature()]\n",
            new="    local withdrawal=self.Withdrawals and self.Withdrawals[ship:getSignature()]\n",
            what="restore native signature read in faction lookup")],
        tests=["test_fleet_life.py::FleetLifeTests::test_normal_faction_queries_skip_withdrawal_signature_reads"],
        note="Counter control covers ordinary and active-withdrawal faction/IFF queries.",
    ),
    Guard(
        name="empty_withdrawal_iff_queries",
        title="Ordinary IFF queries avoid withdrawal signature reads",
        file="fs2rts_factions.lua",
        mutations=[Replacement(
            old="    local withdrawals=self.Withdrawals and next(self.Withdrawals) and self.Withdrawals\n",
            new="    local withdrawals=self.Withdrawals\n",
            what="restore native signature reads in IFF lookup")],
        tests=["test_fleet_life.py::FleetLifeTests::test_normal_faction_queries_skip_withdrawal_signature_reads"],
        note="Each query fast path is removed independently.",
    ),
    Guard(
        name="empty_withdrawal_target_queries",
        title="Ordinary target permission queries avoid withdrawal signature reads",
        file="fs2rts_fleet_life.lua",
        mutations=[Replacement(
            old="    if not self.Withdrawals or next(self.Withdrawals)==nil then return true end\n",
            new="",
            what="restore native signature read in target permission")],
        tests=["test_fleet_life.py::FleetLifeTests::test_normal_faction_queries_skip_withdrawal_signature_reads"],
        note="The active withdrawal control must still enforce passage policy.",
    ),
    Guard(
        name="bomber_keeps_station_objective",
        title="Bomber operation targeting does not divert to mobile capital escorts",
        file="fs2rts_operations.lua",
        mutations=[Replacement(
            old="local suitable=(strike(g) and ((g.role~='bomber' and self:IsCapitalTarget(target))\n",
            new="local suitable=(strike(g) and ((true and self:IsCapitalTarget(target))\n",
            what="restore bomber escort detour")],
        tests=["test_operations.py::OperationTests::test_bomber_commits_to_base_instead_of_chasing_mobile_capital_escort"],
        note="Control assertions retain heavy-capital detours, local-threat interception and nearby sentry clearing.",
    ),
    Guard(
        name="range_ring_geometry_cache",
        title="Repeated range rings reuse projected geometry",
        file="fs2rts_hud.lua",
        mutations=[Replacement(
            old="    if entry==nil and cameraKey~=nil then\n",
            new="    if cameraKey~=nil then\n",
            what="force range ring projection cache misses")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_world_range_ring_keeps_true_range_and_projects_each_world_point"],
        note="Removing cache hits must repeat native vertex projections while preserving the same visible ring.",
    ),
    Guard(
        name="defeated_fleet_auto_extraction",
        title="Defeated AI extraction runs only after station loss",
        file="fs2rts_strategy.lua",
        mutations=[Replacement(
            old="    self:UpdateDefeatedFleetExtraction(now)\n",
            new="    self:UpdateFleetLife(now)\n",
            what="remove stationless AI withdrawal/cover pass")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_defeated_ai_retaliates_and_explicit_player_withdrawal_passage_is_policy_gated"],
        note="The regression verifies surviving AI ships keep an attack and retaliate after station loss.",
    ),
    Guard(
        name="active_ai_fleet_stays_in_battle",
        title="A living faction station prevents defeated-fleet extraction",
        file="fs2rts_fleet_life.lua",
        mutations=[Replacement(
            old="        if self:IsFactionEliminated(kind) and (kind~='BLUE' or self.AutoPlayerMode) then\n",
            new="        if (kind~='BLUE' or self.AutoPlayerMode) then\n",
            what="allow extraction before faction station loss")],
        tests=["test_fleet_life.py::FleetLifeTests::test_defeated_ai_withdraws_while_a_rearguard_attacks_the_killer"],
        note="The first half of this regression runs the same fleet with its station alive.",
    ),
    Guard(
        name="out_of_map_ai_reassignment",
        title="An AI ship outside the tactical map receives an inward strategic order",
        file="fs2rts_lifecycle.lua",
        mutations=[Replacement(
            old="                        if state==nil or not shipAlive(target) or outsideTarget or outsideDestination then\n",
            new="                        if false then\n",
            what="remove out-of-map AI recovery")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_out_of_map_ai_units_retarget_inward_without_overriding_player_orders"],
        note="The regression also verifies a player-owned Blue attack is not retasked.",
    ),
    Guard(
        name="exit_menu_action_routing",
        title="The Exit menu routes visible actions and resumes the battle",
        file="fs2rts_input.lua",
        mutations=[Replacement(
            old="            if self:PointInside(rect,x,y) then return self:HandleExitMenuAction(action) end\n",
            new="            if self:PointInside(rect,x,y) then return true end\n",
            what="remove Exit menu click actions")],
        tests=["test_hud_layout.py::HudLayoutTests::test_exit_button_opens_action_menu_and_resumes_paused_battle"],
        note="The test clicks Resume through the real mouse release handler and checks restart/quit routing.",
    ),
    Guard(
        name="rts_escape_opens_exit_menu",
        title="RTS Escape opens the actual action menu",
        file="fs2rts_input.lua",
        mutations=[Replacement(
            old="            else self:OpenExitMenu() end\n",
            new="            else self:TogglePause() end\n",
            what="replace the exit menu with a mod pause")],
        tests=["test_hud_layout.py::HudLayoutTests::test_rts_escape_opens_exit_menu_from_live_or_paused"],
        note="Pilot Escape exits possession; live and paused RTS Escape must open the action menu.",
    ),
    Guard(
        name="automatic_targets_stay_inside_map",
        title="Automatic AI targeting cannot chase hostile hulls beyond the tactical map",
        file="fs2rts_fleet_life.lua",
        mutations=[Replacement(
            old="    return math.abs(p.x)<=half and math.abs(p.z)<=half\n",
            new="    return true\n",
            what="remove automatic-target map boundary")],
        tests=["test_fleet_life.py::FleetLifeTests::test_automatic_targets_outside_map_are_rejected_but_manual_passage_intercepts_remain"],
        note="The same check is passed cached spatial positions and preserves explicit corridor interception.",
    ),
]

# ---------------------------------------------------------------------------
GUARDS.extend([
    Guard(name='spawn_search_checks_arena_bounds',title='Arena bounds are checked while searching spawn candidates',file='fs2rts_factions.lua',
        mutations=[Replacement(old='        return bounded~=nil and bounded:getDistance(pos)<=.01 and clear(pos) and not tooClose(pos)\n',
            new='        return clear(pos) and not tooClose(pos)\n',what='remove spawn-search arena validation')],
        tests=['test_review_regressions.py::ReviewRegressions::test_capital_search_skips_outside_arena_candidates_for_a_clear_alternate'],
        note='Central placement and an explicit clear edge alternative control the rejection regression.'),
    Guard(name='player_rejects_illegal_spawn',title='Rejected geometry cannot create a player hull',file='fs2rts_production.lua',
        mutations=[Replacement(old='        if pos==nil then failed=true; break end\n',new='',what='player spawn admission')],
        tests=['test_review_regressions.py::ReviewRegressions::test_rejected_spawn_never_calls_native_creation_and_refunds_once'],
        note='No native creation, full refund and no repeated attempt are checked together.'),
    Guard(name='ai_rejects_illegal_spawn',title='Rejected geometry cannot create an AI hull',file='fs2rts_production.lua',
        mutations=[Replacement(old='    if pos==nil then return nil end\n',new='',what='AI spawn admission')],
        tests=['test_review_regressions.py::ReviewRegressions::test_rejected_spawn_never_calls_native_creation_and_refunds_once'],
        note='The same control covers the faction producer.'),
    Guard(name='unique_production_job_ids',title='Same-frame build jobs have distinct IDs',file='fs2rts_production.lua',
        mutations=[Replacement(old='    self.ProductionJobSerial=(self.ProductionJobSerial or 0)+1\n',new='    self.ProductionJobSerial=1\n',what='constant production ID')],
        tests=['test_review_regressions.py::ReviewRegressions::test_same_frame_queue_admission_has_unique_persistent_job_ids'],
        note='Actual queue admission and emitted IDs are checked.'),
    Guard(name="ui_world_hover_respects_panels",title="World hover cannot inspect ships through UI",file="fs2rts_hud.lua",
        mutations=[Replacement(old="local hovered=not self:IsPointOnRTSUI(mx,my) and self:GetShipAtScreen(mx,my,true,true,true,1) or nil",
            new="local hovered=self:GetShipAtScreen(mx,my,true,true,true,1)",what="UI hover exclusion")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_world_hover_is_blocked_by_rts_panels"],note="Recreates the overlapping build and ship tooltips."),
    Guard(name="ui_pilot_comm_clearance",title="Native comm menu is not covered",file="fs2rts_hud.lua",
        mutations=[Replacement(old="    if self.PilotCommMenuActive then return end\n",new="",what="pilot comm visibility gate")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_pilot_comm_keeps_custom_panel_out_of_native_menu_and_resets_on_close"],note="The panel must return when the menu closes."),
    Guard(name="ui_notification_column",title="Notifications stay clear of sidebar controls",file="fs2rts_hud.lua",
        mutations=[Replacement(old="    local left=self:GetSelectionPanelRect(sw,sh).x2+m.gap\n",new="    local left=m.margin\n",what="notification safe column")],
        tests=["test_hud_layout.py::HudLayoutTests::test_notifications_stay_between_sidebar_controls_and_stack"],note="Checks multiple resolutions, stacking and hint clearance."),
    Guard(name="ui_capital_hull_portrait",title="Shieldless capitals render a real-hull portrait",file="fs2rts_hud.lua",
        mutations=[Replacement(old="        local texture=want and self:GetShipThumbTexture(ship.Class.Name)\n",new="        local texture=nil\n",what="hull portrait")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_capital_portrait_uses_native_gauge_coordinates_and_restores_override"],note="Native probe also resolves the real upstream gauge names."),
    Guard(name="ui_all_weapon_cycles",title="Every weapon type is visible",file="fs2rts_hud.lua",
        mutations=[Replacement(old="                for i=1,#cycles do\n",new="                for i=1,math.min(4,#cycles) do\n",what="weapon cycle display limit")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_pilot_cycles_show_every_weapon_type_with_readable_names"],note="Uses five weapon types and local gunner status."),
    Guard(name="ui_body_font_scope",title="Existing larger face is scoped to custom UI",file="fs2rts_hud.lua",
        mutations=[Replacement(old="    local body=gr.Fonts and gr.Fonts[3]\n",new="    local body=gr.Fonts and gr.Fonts[1]\n",what="body font selection")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_body_font_uses_existing_larger_face_and_restores_native_font"],note="The native font is restored after drawing."),
    Guard(name="ui_selected_reticle_cluster",title="Close selected contacts have a counted bracket",file="fs2rts_hud.lua",
        mutations=[Replacement(old="if g.key==key and c.x-half<=g.x2",new="if false and c.x-half<=g.x2",what="selected contact merge")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_selected_contact_clusters_keep_counts_classes_factions_and_damage"],note="Preserves class separation, count and the most damaged member."),
    Guard(name="ui_build_button_badge_gap",title="AI button and type badge have separate columns",file="fs2rts_hud.lua",
        mutations=[Replacement(old="        local ar={x1=badgeX-m.sectionGap-autoWidth,x2=badgeX-m.sectionGap,\n",
            new="        local ar={x1=badgeX-autoWidth,x2=badgeX,\n",what="AI to badge gap")],
        tests=["test_hud_layout.py::HudLayoutTests::test_build_ai_button_badge_and_details_have_separate_padded_columns"],note="Cost and build time remain visible in a separate line."),
    Guard(name="ui_button_glyph_alignment",title="Button labels are visually centered",file="fs2rts_hud.lua",
        mutations=[Replacement(old="        self:DrawCenteredTextClipped(line,textLeft,rect.x2-inset,textY+(i-1)*m.lineHeight)\n",
            new="        gr.drawString(line,textLeft,textY+(i-1)*m.lineHeight)\n",what="button centering")],
        tests=["test_hud_layout.py::HudLayoutTests::test_button_labels_are_centered_using_actual_glyph_height"],note="Checks measured glyph bounds rather than guessed offsets."),
    Guard(
        name="healthy_focused_service_scan_gate",
        title="Healthy focused hulls do not run unusable recovery strength scans",
        file="fs2rts_service.lua",
        mutations=[Replacement(old="            and hp<c.ReturnHull)\n",new="            and (hp<c.ReturnHull or self:IsFleetFocusedByHostiles(ship,now)))\n",what="healthy focus threat-work gate")],
        tests=["test_service.py::ServiceTests::test_healthy_focused_units_defer_strength_scan_until_recovery_is_possible"],
        note="The same hull becomes damaged and must still enter service immediately.",
    ),
    Guard(
        name="ai_context_geometry_reuse",
        title="Local strength and service use the spatial context geometry",
        file="fs2rts_ai_planning.lua",
        mutations=[Replacement(old="    return math.sqrt(dx*dx+dy*dy+dz*dz)\n",new="    return (row.position or row.ship.Position):getDistance(ba.createVector(x,y,z))\n",what="native distance query elimination")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_strength_and_service_threat_reuse_context_geometry_until_rebuild"],
        note="A changed position is observed after rebuilding the same context; fallback callers keep live geometry.",
    ),
    Guard(
        name="ai_context_iff_reuse",
        title="Automatic scoring reuses cached IFF while honoring current permissions",
        file="fs2rts_fleet_life.lua",
        mutations=[Replacement(old="        if row and row.ship==target and row.hostileTo then\n",new="        if false then\n",what="context IFF reuse")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_automatic_queries_reuse_context_iff_but_recheck_live_permissions_and_teams"],
        note="Includes target capture and a newly denied extraction target, so speed cannot bypass targeting rules.",
    ),
    Guard(
        name="pilot_countermeasure_native_ownership",
        title="Native decoys consume the real pilot hull's ammo once",
        file="fs2rts_pilot.lua",
        mutations=[Replacement(old="    weapon.Parent=ship\n",new="    weapon.Parent=source\n",what="decoy ownership transfer")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_capital_binding_override_cycles_turrets_and_suppresses_native_bank_message"],
        note="Native lifecycle additionally proves a single weapon is created, rather than two launches.",
    ),
    Guard(
        name="pilot_energy_transfer_keeps_real_spend",
        title="Proxy energy deltas preserve simultaneous real firing cost",
        file="fs2rts_pilot.lua",
        mutations=[Replacement(old="        ship.WeaponEnergyLeft=clamp(ship.WeaponEnergyLeft+delta,0,ship.WeaponEnergyMax)\n",new="        ship.WeaponEnergyLeft=observer.WeaponEnergyLeft\n",what="delta energy transfer")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_manual_energy_transfer_on_proxy_reaches_live_ship_once"],
        note="The test applies a native transfer and an independent real-hull expenditure in the same frame.",
    ),
    Guard(
        name="excluded_hostile_is_not_friendly_support",
        title="An ineligible hostile cannot inflate friendly strength",
        file="fs2rts_ai_planning.lua",
        mutations=[Replacement(old="                local friendlyContact=not rawHostile\n",new="                local friendlyContact=not hostile\n",what="raw IFF support classification")],
        tests=["test_player_feedback.py::PlayerFeedbackTests::test_excluded_hostiles_never_inflate_friendly_strength_or_support"],
        note="Covers protected and out-of-arena hostiles plus an ordinary hostile control.",
    ),
    Guard(
        name="extraction_does_not_expand_active_arena",
        title="Extraction display growth never expands active combat bounds",
        file="fs2rts_input.lua",
        mutations=[Replacement(old="d*0.72+2000,self.ScenarioMapHalfExtent or 0)",new="d*0.72+2000,self.ScenarioMapHalfExtent or 0,self.ExtractionExtent or 0)",what="battle/display boundary separation")],
        tests=["test_fleet_life.py::FleetLifeTests::test_extraction_expands_display_without_expanding_active_combat_bounds"],
        note="The rejected target is reevaluated after creating an extraction sector.",
    ),
])
# Inventory derived from the sources, not from the list above

# ---------------------------------------------------------------------------
GUARDED_CONFIG_RE = re.compile(
    r"^\s*([A-Za-z_]\w*)\s*=\s*(true|false)\s*,\s*$", re.MULTILINE)

def discover_boolean_config_keys() -> set[str]:
    """Every boolean default in fs2rts_config.lua."""
    text = CONFIG.read_text(encoding="utf-8", errors="replace")
    return {m.group(1) for m in GUARDED_CONFIG_RE.finditer(text)}

def test_files() -> list[Path]:
    return sorted(p for p in TOOLS.glob("test_*.py")
                  if p.name != "test_killcheck.py")

def keywords_mentioned(keywords: list[str]) -> dict[str, list[str]]:
    """Which test FILES merely mention each keyword.

    A mention is not coverage. It is listed so a reader can tell the

    difference between "a test names this guard" and "a test asserts it".

    """
    out: dict[str, list[str]] = {}
    for kw in keywords:
        hits = []
        for path in test_files():
            if kw in path.read_text(encoding="utf-8", errors="replace"):
                hits.append(path.name)
        out[kw] = hits
    return out

# ---------------------------------------------------------------------------
# Execution

# ---------------------------------------------------------------------------

@dataclass

class TestOutcome:
    node: str
    verdict: str            # "RED" | "GREEN" | "HUNG" | "ERROR"
    detail: str = ""

@dataclass

class GuardOutcome:
    name: str
    title: str
    file: str
    verdict: str            # "KILLED" | "VACUOUS" | "UNCOVERED" | "ERROR"
    note: str
    outcomes: list[TestOutcome] = field(default_factory=list)
    detail: str = ""
    mutation_removed: bool = False
    changed_files: list[str] = field(default_factory=list)
    keywords: dict[str, list[str]] = field(default_factory=dict)

    def as_dict(self) -> dict:
        return {
            "name": self.name, "title": self.title, "file": self.file,
            "verdict": self.verdict, "note": self.note, "detail": self.detail,
            "mutation_removed": self.mutation_removed,
            "changed_files": self.changed_files,
            "tests": [{"node": t.node, "verdict": t.verdict,
                       "detail": t.detail} for t in self.outcomes],
            "keyword_mentions": self.keywords,
        }

class KillCheck:

    def __init__(self, guards: list[Guard] | None = None,
                 keep_sandbox: bool = False, timeout: int = 300):
        self.guards = list(guards if guards is not None else GUARDS)
        self.keep_sandbox = keep_sandbox
        self.timeout = timeout
        self._tmp: tempfile.TemporaryDirectory | None = None
        self.sandbox: Sandbox | None = None
        self.sandbox_path: Path | None = None

    def __enter__(self) -> "KillCheck":
        self._tmp = tempfile.TemporaryDirectory(prefix="killcheck_")
        dest = Path(self._tmp.name) / "core"
        self.sandbox = Sandbox(dest)
        self.sandbox_path = dest
        return self

    def __exit__(self, *exc) -> None:
        if self._tmp and not self.keep_sandbox:
            self._tmp.cleanup()
        elif self._tmp:
            print(f"sandbox kept at {self._tmp.name}", file=sys.stderr)
    # -- baseline ----------------------------------------------------------

    def baseline(self) -> tuple[dict[str, str], set[str]]:
        """Tests as they are today. Anything already RED cannot falsify

        anything: it was failing before the guard was removed."""
        assert self.sandbox is not None
        code, out = _run(self._all_nodes(), self.sandbox.root / "tools",
                         self.timeout)
        before = fingerprint(MOD_ROOT)
        passed = {node_id_of(n) for n in _PASSED_RE.findall(out)}
        failed = {node_id_of(n) for n in failed_node_ids(out)}
        failed |= {node_id_of(n) for n in _UNVERIFIED_RE.findall(out)}
        if code != 0:
            return before, set(self._all_nodes())
        return before, failed | (set(self._all_nodes()) - passed)

    def _all_nodes(self) -> list[str]:
        seen, nodes = set(), []
        for guard in self.guards:
            for node in guard.tests:
                key = node_id_of(node)
                if key not in seen:
                    seen.add(key)
                    nodes.append(key)
        return nodes
    # -- one guard ---------------------------------------------------------

    def _apply_with_retry(self, guard: Guard, attempts: int = 3) -> tuple[bool, str]:
        """Apply the guard's mutations, re-copying the tree on a torn read.

        Other agents are editing these .lua files right now. A sandbox copy

        taken mid-write can contain a half-written file, and the mutation's

        anchor then misses for a reason that has nothing to do with the guard.

        Reporting ERROR there would be a false accusation of the guard's own

        stability, so the copy is retaken and the mutation retried. A genuine

        anchor drift still fails, because a real mismatch fails every attempt.

        """
        last = ""
        for attempt in range(attempts):
            self.sandbox.restore()
            try:
                self.sandbox.apply(guard.mutations, guard.file)
                return True, f"removed on attempt {attempt + 1}"
            except MutationError as exc:
                last = f"attempt {attempt + 1}: {exc}"
                # Re-copy the whole tree from the (possibly now-stable) source.
                scripts = self.sandbox.root / "data" / "scripts"
                for path in scripts.rglob("*.lua"):
                    src = SCRIPTS / path.relative_to(scripts)
                    try:
                        shutil.copyfile(src, path)
                    except OSError:
                        pass
                self.sandbox.reprime()
                time.sleep(1.5)
        return False, last

    def run_guard(self, guard: Guard, already_failed: set[str]) -> GuardOutcome:
        outcome = GuardOutcome(
            name=guard.name, title=guard.title, file=guard.file,
            verdict="ERROR", note=guard.note, keywords=keywords_mentioned(guard.keywords))
        assert self.sandbox is not None
        if not guard.tests:
            outcome.verdict = "UNCOVERED"
            applied, detail = self._apply_with_retry(guard)
            outcome.mutation_removed = applied
            if not applied:
                outcome.detail = f"mutation failed: {detail}"
                return outcome
            outcome.detail = ("no test names this guard; the mutation was still "
                              "applied and every covering test in the inventory "
                              "re-run, to check nothing depends on it silently")
            code, out = _run(self._all_nodes(), self.sandbox.root / "tools",
                             self.timeout)
            newly = failed_node_ids(out) - already_failed
            outcome.changed_files = [guard.file]
            outcome.detail += f"; removing it broke {sorted(newly) or 'nothing'}"
            return outcome
        applied, detail = self._apply_with_retry(guard)
        outcome.mutation_removed = applied
        if not applied:
            outcome.detail = (f"mutation failed after {3} attempts, so this "
                              f"guard was NOT falsified either way: {detail}")
            return outcome
        outcome.changed_files = [guard.file]
        code, out = _run([node_id_of(n) for n in guard.tests],
                         self.sandbox.root / "tools", self.timeout)
        failed = {node_id_of(n) for n in failed_node_ids(out)}
        hung = {node_id_of(n) for n in hung_node_ids(out)}
        assertions = {node_id_of(n) for n in _ASSERTION_RE.findall(out)}
        passed = {node_id_of(n) for n in _PASSED_RE.findall(out)}
        unverified = {node_id_of(n) for n in _UNVERIFIED_RE.findall(out)}
        for node in guard.tests:
            key = node_id_of(node)
            if key in already_failed:
                outcome.outcomes.append(TestOutcome(
                    node, "ERROR",
                    "original test did not demonstrably pass; it cannot falsify "
                    "anything"))
            elif key in hung:
                outcome.outcomes.append(TestOutcome(
                    node, "HUNG",
                    f"did not finish within {self.timeout}s once the guard was "
                    f"removed. Investigate the timeout; it does not prove an intended assertion."))
            elif key in unverified or code not in (0, 1):
                outcome.outcomes.append(TestOutcome(
                    node, "ERROR", "runner/setup/non-assertion failure or skipped parameter\n" + out[-4000:]))
            elif key in assertions and code == 1:
                outcome.outcomes.append(TestOutcome(
                    node, "RED", "went red with the guard removed"))
            elif key in passed and key not in failed and code in (0, 1):
                outcome.outcomes.append(TestOutcome(
                    node, "GREEN", "stayed green with the guard removed"))
            else:
                outcome.outcomes.append(TestOutcome(
                    node, "ERROR", "runner/setup/non-assertion failure or missing completion evidence"))
        live = outcome.outcomes
        if any(o.verdict in ("ERROR", "HUNG") for o in live):
            outcome.verdict = "ERROR"
            outcome.detail = "covering evidence contains an error or timeout; not a behavioral kill"
        elif any(o.verdict == "RED" for o in live):
            outcome.verdict = "KILLED"
            outcome.detail = ("falsified by " + ", ".join(
                f"{o.node} ({o.verdict})" for o in live
                if o.verdict == "RED"))
        else:
            outcome.verdict = "VACUOUS"
            outcome.detail = ("no covering test noticed the guard's removal: "
                              + ", ".join(o.node for o in live))
        return outcome

    def run(self) -> tuple[list[GuardOutcome], list[str]]:
        assert self.sandbox is not None
        _say(f"baseline: running {len(self._all_nodes())} node ids against the "
             f"unmodified tree in the sandbox...")
        before, already_failed = self.baseline()
        _say(f"baseline done; {len(already_failed)} already failing")
        results = []
        for guard in self.guards:
            _say(f"  falsifying {guard.name} ...")
            outcome = self.run_guard(guard, already_failed)
            _say(f"    -> {outcome.verdict}")
            results.append(outcome)
        after = fingerprint(MOD_ROOT)
        return results, diff_fingerprints(before, after)

# ---------------------------------------------------------------------------
# Reporting

# ---------------------------------------------------------------------------

def _say(text: str = "") -> None:
    """Print and flush.

    A run takes minutes. Without the flush, piping to a file or a log shows

    nothing at all until the end, which reads as a hung process rather than as

    a harness that is simply working.

    """
    print(text, flush=True)

def render_table(results: list[GuardOutcome]) -> str:
    lines = [f"{'guard':<42} {'verdict':<10} covering tests (guard removed)",
             "-" * 118]
    for r in results:
        if r.verdict == "UNCOVERED":
            detail = "NONE - no test claims this guard"
        else:
            detail = ", ".join(f"{t.node.split('::')[-1]}={t.verdict}"
                               for t in r.outcomes) or "(none run)"
        lines.append(f"{r.name:<42} {r.verdict:<10} {detail}")
    return "\n".join(lines)

def report(results: list[GuardOutcome], drift: list[str],
           unguarded: list[str], escapes: list[str]) -> int:
    _say("=" * 118)
    _say("KILLCHECK - every guard removed in a temp copy, covering tests re-run")
    _say("=" * 118)
    _say("")
    _say(render_table(results))
    _say("")
    vacuous = [r for r in results if r.verdict == "VACUOUS"]
    uncovered = [r for r in results if r.verdict == "UNCOVERED"]
    errors = [r for r in results if r.verdict == "ERROR"]
    for r in vacuous:
        _say(f"VACUOUS  {r.name}")
        _say(f"         {r.title}")
        _say(f"         {r.note}")
        for t in r.outcomes:
            if t.verdict == "GREEN":
                _say(f"         stayed green: {t.node}")
        _say("")
    hung = [(r, t) for r in results for t in r.outcomes if t.verdict == "HUNG"]
    if hung:
        _say("HUNG - removing the guard made these tests stop terminating:")
        for r, t in hung:
            _say(f"  {r.name}: {t.node}")
        _say("")
    for r in uncovered:
        _say(f"UNCOVERED  {r.name}: {r.title}")
        _say(f"         {r.detail}")
        _say("")
    for r in errors:
        _say(f"ERROR  {r.name}: {r.title}")
        _say(f"         {r.detail}")
        for t in r.outcomes:
            if t.verdict == "ERROR":
                _say(f"         {t.node}: {t.detail}")
        _say("")
    if unguarded:
        print("config boolean keys with no guard in the inventory above "
              "(not necessarily guards - reported so nothing is silent):")
        for key in unguarded:
            print(f"  {key}")
        print()
    print("-" * 118)
    print("WORKING TREE PROOF")
    print(f"  files hashed            : {len(fingerprint(MOD_ROOT))}")
    print(f"  recorded write calls    : {len(WRITES)}"
          f" (all inside the temp sandbox)")
    if escapes:
        print("  WRITES OUTSIDE THE SANDBOX - the harness is NOT read-only:")
        for path in escapes:
            print(f"    {path}")
    else:
        print("  recorded sandbox writes : no paths outside the sandbox; "
              "source drift checked separately.")
    if drift:
        print("  files that changed hash  : (see below)")
        for line in drift:
            print(f"    {line}")
        print("  NOTE: the source tree changed during this run. The write audit\n"
              "        shows this harness wrote nothing under the mod; the cause\n"
              "        of the external edits is not determined here. Re-run on a\n"
              "        quiet tree for a clean fingerprint comparison.")
    else:
        print("  tree byte-identical      : yes, before and after "
              f"({len(fingerprint(MOD_ROOT))} files)")
    print("-" * 118)
    killed = sum(1 for r in results if r.verdict == "KILLED")
    print(f"{killed}/{len(results)} guards falsified by removal; "
          f"{len(vacuous)} vacuous, {len(uncovered)} uncovered, {len(errors)} error")
    bad = bool(vacuous or uncovered or errors or escapes or drift)
    return 1 if bad else 0

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Remove each guard in a temp copy and require its covering "
                    "test to go red.")
    parser.add_argument("--guard", action="append", dest="guards",
                        help="only this guard; repeatable")
    parser.add_argument("--json", dest="json_path",
                        help="write the machine-readable report here")
    parser.add_argument("--keep-sandbox", action="store_true",
                        help="leave the temp copy in place for inspection")
    parser.add_argument("--list", action="store_true",
                        help="list the guard inventory and exit")
    args = parser.parse_args(argv)
    if args.list:
        for g in GUARDS:
            print(f"{g.name}\n  {g.title}\n  file: {g.file}\n  tests: "
                  + (", ".join(g.tests) or "NONE"))
        return 0
    guards = GUARDS
    if args.guards:
        wanted = set(args.guards)
        guards = [g for g in GUARDS if g.name in wanted]
        missing = wanted - {g.name for g in guards}
        if missing:
            print(f"unknown guard(s): {sorted(missing)}", file=sys.stderr)
            return 2
    if not SCRIPTS.is_dir():
        print(f"cannot find the script tree at {SCRIPTS}", file=sys.stderr)
        return 2
    before = fingerprint(MOD_ROOT)
    WRITES.clear()
    with KillCheck(guards, keep_sandbox=args.keep_sandbox) as kc:
        results, drift = kc.run()
        escapes = kc.sandbox.writes_outside_sandbox() if kc.sandbox else []
    after = fingerprint(MOD_ROOT)
    drift = diff_fingerprints(before, after) or drift
    # Config keys that are the SUBJECT of a ConfigDefault guard are guarded by
    # definition. Everything else that ships as a boolean default is reported,
    # so a flag nobody has thought about is visible rather than silent.
    config_guard_keys = {
        m.key.split(".")[-1]
        for g in guards for m in g.mutations
        if isinstance(m, ConfigDefault)}
    unguarded = sorted(discover_boolean_config_keys() - config_guard_keys)
    code = report(results, drift, unguarded, escapes)
    if args.json_path:
        Path(args.json_path).write_text(json.dumps({
            "guards": [r.as_dict() for r in results],
            "working_tree_drift": drift,
            "exit_code": code,
        }, indent=2), encoding="utf-8")
    return code
if __name__ == "__main__":
    sys.exit(main())
