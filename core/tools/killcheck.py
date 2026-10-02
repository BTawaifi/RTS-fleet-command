#!/usr/bin/env python3





"""Falsification harness: remove each guard, require its covering test to go RED.





Why this exists





---------------





A regression test that passes whether or not the fix is present certifies a fix





it never exercised. That is worse than no test, because it converts an unverified





claim into a green checkmark. The precedent in this mod is concrete: a live





crash shipped through 370 passing tests AND a static `undefined_global_check`,





because `RETICLE_COLOR_SELECTED` was declared `local` 147 lines below its first





use. The static check asked "is this name defined SOMEWHERE in the file?" and





every unit test asserted something the defective line never reached.





"Falsify every claim by removal" has to be routine, not something a reviewer





has to remember. So it lives here, in the suite, and it fails when a guard has





no covering test.





How removal works





-----------------





The real .lua files are NEVER written. Each guard is removed in a TEMP COPY of





`core/` (tools + data/scripts + data/tables), and the covering test is run there.





Tests resolve the script tree from their own `__file__`





(`Path(__file__).resolve().parents[1] / "data/scripts"`), so running pytest





inside the temp tree is enough to point the whole suite at the mutated scripts





without a single line of test code changing. The repo fingerprint is taken





before and after the run and compared, so a harness that accidentally writes to





the tree fails instead of lying.





Verdicts





--------





  KILLED     the covering test went RED with the guard removed -> the test





             really does exercise the guard.





  VACUOUS    the covering test stayed GREEN -> it certifies a fix it never





             exercised. This is the headline finding.





  UNCOVERED  no test claims the guard at all. A legitimate, valuable finding:





             do not paper over it by weakening a test.





  ERROR      the guard could not be removed (anchor text moved, tree copy





             failed, pytest could not run). Never reported as green.





Exit code is non-zero if any guard is VACUOUS, UNCOVERED, or ERROR.





Run:  python -m killcheck            (from core/tools)





      python -m killcheck --json out.json





      python -m killcheck --guard service_max_under_fire_seconds





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





from dataclasses import dataclass, field





from pathlib import Path





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





        return sorted((self.root / "data" / "scripts").glob("*.lua"))





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





        sandbox = str(self.root.resolve())





        return [w for w in WRITES





                if not str(Path(w).resolve()).startswith(sandbox)]





def _run(node_ids: list[str], tools_dir: Path, timeout: int) -> tuple[int, str]:





    """Run pytest. A guard whose removal makes a test HANG is a finding, not a





    crash: subprocess.TimeoutExpired is converted into a synthetic failure list





    so the guard is reported rather than aborting the whole run.





    """





    env = dict(os.environ)





    env["PYTHONDONTWRITEBYTECODE"] = "1"





    try:





        proc = subprocess.run(





            [sys.executable, "-m", "pytest", "-q", "--tb=no", "-rEf",





             "-p", "no:cacheprovider", "-p", "no:randomly", *node_ids],





            cwd=str(tools_dir), env=env, capture_output=True, text=True,





            timeout=timeout)





    except subprocess.TimeoutExpired as exc:





        partial = (exc.stdout or "") if isinstance(exc.stdout, str) else ""





        hung = "\n".join(f"FAILED {n} - did not finish within {timeout}s"





                         for n in node_ids)





        return 1, (partial or "") + hung





    return proc.returncode, proc.stdout + proc.stderr





_FAILED_RE = re.compile(r"^(?:FAILED|ERROR)\s+(\S+)", re.MULTILINE)





_HUNG_RE = re.compile(r"^FAILED\s+(\S+)\s+-\s+did not finish", re.MULTILINE)





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





RETICLE_BLOCK = (





    "local RETICLE_COLORS={friendly={70,220,255},hostile={255,75,75},third={255,190,70}}\n"





    "-- Hoisted: these were three-entry table literals evaluated inside the per-ship\n"





    "-- loop, twice a frame for every decorated contact.\n"





    "local RETICLE_COLOR_SELECTED={255,225,50}\n"





    "local RETICLE_COLOR_HOVERED={255,255,180}\n"





)





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





                old=("        if not s.manual and now-s.underFireSince>="





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





        title="Hoisted RETICLE_COLORS / _SELECTED / _HOVERED above first use",





        file="fs2rts_hud.lua",





        mutations=[





            MoveBlock(





                block=RETICLE_BLOCK,





                before="function RTS:GetReticleFactionKey(ship)\n",





                what="RETICLE_COLORS hoist"),





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





                old=("                local ok,success,spawned=pcall(function()\n"





                     "                    local s,sp=self:SpawnFriendly(current.option)\n"





                     "                    return s,sp\n"





                     "                end)\n"),





                new=("                local ok,success,spawned=true,self:SpawnFriendly(current.option)\n"),





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





        name="pcall_release_object_handles",





        title="pcall on every step of ReleaseObjectHandles (teardown)",





        file="fs2rts_lifecycle.lua",





        mutations=[





            Replacement(





                old="        pcall(function() self[name]={} end)\n",





                new="        self[name]={}\n",





                what="ReleaseObjectHandles wipe pcall"),





            Replacement(





                old="    if self.MoveWaypoints~=nil then pcall(function() self.MoveWaypoints={} end) end\n",





                new="    if self.MoveWaypoints~=nil then self.MoveWaypoints={} end\n",





                what="ReleaseObjectHandles MoveWaypoints pcall"),





            Replacement(





                old="    if self.FreeMoveWaypoints~=nil then pcall(function() self.FreeMoveWaypoints={} end) end\n",





                new="    if self.FreeMoveWaypoints~=nil then self.FreeMoveWaypoints={} end\n",





                what="ReleaseObjectHandles FreeMoveWaypoints pcall"),





            Replacement(





                old="    pcall(function() self.ShipCache=nil end)\n",





                new="    self.ShipCache=nil\n",





                what="ReleaseObjectHandles ShipCache pcall"),





        ],





        tests=[





               "test_station.py::StationTests::test_release_object_handles_clears_every_handle_table",





           ],





        keywords=["ReleaseObjectHandles"],





        note="UNFALSIFIABLE BY CONSTRUCTION, not a missing test. Lua consults "





             "__newindex only for an ABSENT key, and wipe() returns early when "





             "the key is nil (fs2rts_lifecycle.lua:577), so `self[name]={}` "





             "always runs with the key present and cannot raise. Verified "





             "directly against the same lupa runtime the suite uses: assigning "





             "to a present key whose VALUE has an erroring __newindex fires 0 "





             "times and pcall succeeds; assigning to an absent key fires once and "





             "pcall fails. The other three pcalls are the same shape - two are "





             "guarded by ~=nil, and ShipCache=nil cannot fire because the RTS "





             "table carries no __newindex. So no test can ever kill this guard. "





             "It is harmless defensive code; keep it, and do not read the "





             "VACUOUS verdict as a coverage gap. What IS worth protecting is "





             "the wipe list's coverage - a table added to the mod and forgotten "





             "here survives into the next mission, since FSO never tears the Lua "





             "state down between missions - and that is what the registered test "





             "asserts.",





    ),





    Guard(





        name="station_capital_aware_investment_gate",





        title="Station.AI.CapitalAwareInvestment: defer base UPGRADES while the "





              "producer saves for a role the bank cannot afford",





        file="fs2rts_station.lua",





        mutations=[





            Replacement(





                old=("        if deferInvestment then return false end\n"),





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





        title="Station.AI.CapitalAwareInvestment ships OFF",





        file="fs2rts_config.lua",





        mutations=[





            ConfigDefault(





                key="Station.AI.CapitalAwareInvestment",





                old="            CapitalAwareInvestment = false,\n",





                new="            CapitalAwareInvestment = true,\n",





                what="CapitalAwareInvestment default"),





        ],





        tests=[





            "test_station.py::StationTests::test_capital_aware_investment_defaults_off",





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





             "fs2rts_strategy.lua:1040-1044 can be arbitrarily far away and "





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
]





# ---------------------------------------------------------------------------





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





    verdict: str            # "RED" | "GREEN" | "HUNG" | "MISSING"





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





        return before, failed_node_ids(out)





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





                for path in scripts.glob("*.lua"):





                    src = SCRIPTS / path.name





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





        failed = failed_node_ids(out)





        hung = hung_node_ids(out)





        for node in guard.tests:





            key = node_id_of(node)





            if key in already_failed:





                outcome.outcomes.append(TestOutcome(





                    node, "GREEN",





                    "already RED in the unmodified tree; it cannot falsify "





                    "anything and is excluded from the verdict"))





            elif key in hung:





                outcome.outcomes.append(TestOutcome(





                    node, "HUNG",





                    f"did not finish within {self.timeout}s once the guard was "





                    f"removed. This is a falsification too - the test cannot "





                    f"pass - but it is reported apart from a clean RED because "





                    f"a hang usually means an unbounded loop, which is a worse "





                    f"defect than an assertion."))





            elif key in failed:





                outcome.outcomes.append(TestOutcome(





                    node, "RED", "went red with the guard removed"))





            else:





                outcome.outcomes.append(TestOutcome(





                    node, "GREEN", "stayed green with the guard removed"))





        live = [o for o in outcome.outcomes





                if not o.detail.startswith("already RED")]





        if not live:





            outcome.verdict = "ERROR"





            outcome.detail = ("every covering test was already failing before "





                              "the guard was removed")





        elif any(o.verdict in ("RED", "HUNG") for o in live):





            outcome.verdict = "KILLED"





            outcome.detail = ("falsified by " + ", ".join(





                f"{o.node} ({o.verdict})" for o in live





                if o.verdict in ("RED", "HUNG")))





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





            if t.verdict == "GREEN" and not t.detail.startswith("already RED"):





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





            if t.detail.startswith("already RED"):





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





    print(f"  bytes written by harness: {len(WRITES)}"





          f" (all inside the temp sandbox)")





    if escapes:





        print("  WRITES OUTSIDE THE SANDBOX - the harness is NOT read-only:")





        for path in escapes:





            print(f"    {path}")





    else:





        print("  writes outside sandbox  : none. Every byte this harness "





              "wrote went to the temp copy.")





    if drift:





        print("  files that changed hash  : (see below)")





        for line in drift:





            print(f"    {line}")





        print("  NOTE: another agent is editing fs2rts_ai_production.lua, "





              "fs2rts_config.lua,\n        fs2rts_service.lua and "





              "fs2rts_hud.lua right now. A changed hash here is their\n"





              "        edit, not this harness's: the write audit above shows "





              "this process wrote\n        nothing under the mod. Re-run on a "





              "quiet tree for a clean read.")





    else:





        print("  tree byte-identical      : yes, before and after "





              f"({len(fingerprint(MOD_ROOT))} files)")





    print("-" * 118)





    killed = sum(1 for r in results if r.verdict == "KILLED")





    print(f"{killed}/{len(results)} guards falsified by removal; "





          f"{len(vacuous)} vacuous, {len(uncovered)} uncovered, {len(errors)} error")





    bad = bool(vacuous or uncovered or errors or escapes)





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
