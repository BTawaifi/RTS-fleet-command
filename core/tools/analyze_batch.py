"""Turn a headless RTS batch into per-feature verdicts and an outcome diagnosis.

Reads each match's telemetry JSONL (the mod's rts-ai-*.jsonl probe log), the
engine result *when the runner managed to write one*, and the engine logs.
Answers one question per requested change, and for a finished battle it says who
killed which base, with what, and from what state, using the OUTCOME_CAUSE record
the mod emits the instant a command station dies.

A missing engine-result.json is NOT a crash. A 3,000 s headless match reaches the
simulation cap and then dies at mission teardown with no Lua error and no engine
output, so the runner never gets to write engine-result.json while the telemetry
on disk is complete and well formed. This tool therefore classifies the run by
what the telemetry itself proves -- records read, last simulated second, cap
progress, BATTLE_END, OUTCOME_CAUSE -- and only calls a match crashed when there
is no usable telemetry at all or the engine result itself says it crashed.

    python tools/analyze_batch.py <batch-output-dir> [--baseline <other-output-dir>]

FIELD SEMANTICS THAT LOOK LIKE BUGS BUT ARE NOT, verified against real batches:

FACTION.losses is CUMULATIVE per sample, not per interval. The emitter writes
`AIStats.losses[kind]` straight through and never resets it, so summing the
series would multiply the loss count by the sample count. Keep the last sample.

FACTION.replacementValueByClass is SURVIVING fleet value, not losses. It is
accumulated in the same walk that builds `composition`, so its classes sum to
`replacementValue` on every sample. The name invites reading it as the cost of
what was destroyed; it is what is still flying.

FACTION.received is CUMULATIVE (`AIStats.received`, monotone non-decreasing).
FACTION.offense is NOT an interval and is NOT damage: it is the fleet value
currently assigned to PRIMARY/ESCORT missions, rebuilt from scratch in every
FACTION record, so it rises on assignment and falls on release. Real BLUE series
run 0, 1264, 1264, 2423, 0, 1231, 2044, 3417, 2860, 1353, 3304, 0 -- it returns
to 0 inside a single match. Summing it produces a number that scales with the
sample count and measures neither damage nor spend. Read mean/max/last.

OUTCOME_CAUSE.snapshot.*.stationHull is a FRACTION (0..1), under the same key
name FACTION.stationHull uses for an absolute hull figure. Formatting one with
the other's rule is wrong by a factor of the station's size.

COUNTERS records carry NO faction field. They are process-wide
(`AIStats.decisions`, `AIOrderTelemetry`), and are emitted cumulatively, so only
the last record in a run is meaningful.

`seed` reaches telemetry two ways and neither is optional in general:
engine-result.json when the engine exits on its own, and
results/results.jsonl (one record per replicate, carrying `seed` and the
`workspace` it ran in) which the runner appends as matches finish. Reading only
the first loses the seed for every killed run, and then two batches look
unpairable when the mapping was on disk beside them. Both paths are read here.
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import re
import sys
from pathlib import Path

CAPITAL_ROLES = {"capital", "heavy", "juggernaut"}
MIN_ENEMY_SEPARATION = 12000.0
MAX_STATION_RADIUS = 9000.0
STALL_SECONDS = 30.0
ERROR_PATTERNS = re.compile(
    r"(attempt to (?:index|call|perform|concatenate)\b|stack overflow|syntax error|"
    r"is not valid|not found!|Script error|error loading|unpack_loop|nil value)",
    re.IGNORECASE,
)
FACTIONS = ("BLUE", "RED", "GOLD")

# A match that reached this fraction of the planned simulation cap was stopped by
# the cap, not by a defect. Below it, the run was killed and we say so.
CAP_REACHED_FRACTION = 0.98

# engine-result.json termination strings that really do mean a crash.
CRASH_TERMINATIONS = {"crash", "crashed", "error", "aborted", "killed", "signal"}


def dist(a, b) -> float:
    return math.hypot(a["x"] - b["x"], a["z"] - b["z"])


def median(values):
    ordered = sorted(values)
    return ordered[len(ordered) // 2] if ordered else 0.0


def pct(part, whole) -> float:
    return 100.0 * part / whole if whole else 0.0


def telemetry_files(run: Path):
    """Telemetry lives at probe/data/rts-ai-*.jsonl in a runner workspace, but
    harvested evidence is often flattened to run/rts-ai-*.jsonl. Look in both,
    and return every candidate rather than only the newest so a flattened
    folder holding two matches is not silently counted once."""
    found = sorted((run / "probe" / "data").glob("rts-ai-*.jsonl"))
    if not found:
        found = sorted(run.glob("rts-ai-*.jsonl"))
    if not found:
        found = sorted(run.rglob("rts-ai-*.jsonl"))
    return found


def newest_telemetry(run: Path):
    found = telemetry_files(run)
    return found[-1] if found else None


def find_result_seeds(run: Path):
    """Seed per run from <batch>/results/results.jsonl.

    The runner writes one record per replicate with both `seed` and the
    `workspace` path it ran in, so a batch CAN be paired by seed even when the
    engine never got round to writing engine-result.json. Reading only
    engine-result.json lost the seed for every killed run, which made two
    batches look unpairable when the mapping was sitting on disk next to them.
    Returns {} when the file is missing or unreadable - including the case where
    it exists but is empty because the run was killed before the first record.
    """
    for parent in [run] + list(run.parents)[:6]:
        candidate = parent / "results" / "results.jsonl"
        if not candidate.is_file():
            continue
        try:
            lines = candidate.read_text(encoding="utf-8").splitlines()
        except OSError:
            return {}
        seeds = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue
            seed = record.get("seed")
            workspace = record.get("workspace")
            if seed is None or not workspace:
                continue
            try:
                seeds[str(Path(workspace).resolve()).lower()] = seed
            except OSError:
                continue
        return seeds
    return {}


def find_plan(run: Path):
    """batch.plan.json records the sim cap the batch was launched with, so a run
    that stops just short of it can still be told apart from one that died at
    400 s. Walk up out of the run folder looking for it."""
    for parent in [run] + list(run.parents)[:6]:
        candidate = parent / "batch.plan.json"
        if candidate.is_file():
            try:
                plan = json.loads(candidate.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return {}
            return plan if isinstance(plan, dict) else {}
    return {}


def new_match():
    return {
        "run": None,
        "seed": None, "seed_source": None, "termination": None, "termination_detail": None,
        "simulated_seconds": 0.0, "wall_seconds": 0.0,
        "time_limit": False, "cap_inferred": False, "cap_seconds": 0.0, "cap_progress": 0.0,
        "records": 0, "malformed_lines": 0, "truncated_tail": False,
        "telemetry": None, "telemetry_state": "absent", "result_present": False,
        "first_time": None, "last_time": None,
        "battle_end": False, "outcome": None, "crashed": False, "log_errors": [],
        "events": collections.Counter(),
        "unhandled_events": collections.Counter(),
        "capital_spawns": [], "cp_spent": collections.Counter(), "cp_queued": collections.Counter(),
        "cp_sentry": collections.Counter(),
        "units_spawned": collections.Counter(), "prod_actions": collections.Counter(),
        "sentry_actions": collections.Counter(),
        "base_damage": collections.defaultdict(lambda: [0.0, 0.0, 0]),   # weapon -> [hits, hullDamage, beam]
        "base_damage_by_faction": collections.defaultdict(lambda: [0.0, 0.0]),
        "stations": {}, "capital_missions": collections.Counter(),
        "decision_roles": collections.Counter(), "decision_missions": collections.Counter(),
        "decision_reasons": collections.Counter(),
        "contest": collections.defaultdict(list), "outcome_cause": None,
        "battle": collections.defaultdict(list),
        "build": collections.defaultdict(lambda: {
            "samples": 0, "reasons": collections.Counter(), "roles": collections.Counter(),
            "tiers": collections.Counter(), "zero_affordable": 0, "zero_unlocked": 0,
            "zero_fleet_fit": 0, "banked": 0, "cp": [], "affordable": [],
            "selected": collections.Counter(), "times": [],
        }),
        "execution": collections.defaultdict(lambda: {
            "status": collections.Counter(), "mode": collections.Counter(),
            "pursuit": 0, "hit": 0, "goal": collections.Counter(), "samples": 0,
            "hull_loss": 0.0,
        }),
        "counters": None, "counters_samples": 0,
        "losses": collections.defaultdict(lambda: {
            "count": 0, "by_class": collections.Counter(), "by_killer": collections.Counter(),
            "replacement": 0.0, "bounty": 0.0,
        }),
        "operations": collections.defaultdict(list),
        "friendly": collections.defaultdict(lambda: {
            "count": 0, "mission": collections.Counter(), "kind": collections.Counter(), "pairs": collections.Counter(),
        }),
        "service": collections.defaultdict(lambda: {
            "phase": collections.Counter(), "reason": collections.Counter(),
            "work": 0, "spent": 0.0, "healed": 0.0, "interrupted": 0,
        }),
        "repair": collections.defaultdict(lambda: {
            "interval": 0.0, "cumulative": 0.0, "samples": 0,
            "below_ceiling_samples": 0, "ceiling_gap_samples": 0.0, "max_gap": 0.0,
        }),
        "cp_service": collections.defaultdict(float),
        "cp_spend_ledger": collections.defaultdict(float),
        "cp_spend_entries": 0,
        "upgrade_spend": collections.defaultdict(float),
        "flow_cumulative": collections.defaultdict(collections.Counter),
        "repair_unlocked": collections.defaultdict(bool),
        "repair_gate_known": collections.defaultdict(bool),
        "flow": collections.defaultdict(collections.Counter),
        "flow_samples": collections.Counter(),
        "damage": collections.defaultdict(lambda: {"dealt": 0.0, "station_dealt": 0.0, "received": 0.0}),
        "contract": collections.Counter(),
    }


# --------------------------------------------------------------------------
# streaming accumulation
# --------------------------------------------------------------------------

def _scan_line(line: str, out) -> bool:
    """Fold one telemetry line into the accumulators. False means the line did
    not parse -- a killed run can leave the last record half written."""
    try:
        record = json.loads(line)
        if not isinstance(record, dict):
            raise ValueError("record is not a JSON object")
    except ValueError:
        out["malformed_lines"] += 1
        return False
    out["records"] += 1
    accumulate(out, record)
    return True


def scan_telemetry(path: Path, out) -> None:
    """One streaming pass over a 20-27 MB / 20,000-26,000 record file. Nothing is
    retained that a later report still needs, so peak memory is a few thousand
    entries per match rather than one dict per record."""
    out["records"] = 0
    out["malformed_lines"] = 0
    out["truncated_tail"] = False
    pending = None
    tail_bad = False
    with path.open(encoding="utf-8", errors="replace") as stream:
        for raw in stream:
            if pending is not None:
                _scan_line(pending, out)          # not the tail: count only
            line = raw.strip()
            pending = line or None
        if pending is not None:
            tail_bad = not _scan_line(pending, out)
    out["truncated_tail"] = tail_bad
    if out["records"] == 0:
        out["telemetry_state"] = "empty" if not tail_bad else "empty_truncated"
    else:
        out["telemetry_state"] = "truncated" if tail_bad else "ok"


def _number(value):
    """The emitter writes numbers for most telemetry fields, but a few were the
    literal string 'unknown' in every record before a fix. Accept either and let
    the caller count what it got, rather than dropping the record."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def accumulate(out, record) -> None:
    event = record.get("event")
    data = record.get("data") or {}
    out["events"][event] += 1
    when = _number(record.get("time"))
    if when is not None:
        if out["first_time"] is None or when < out["first_time"]:
            out["first_time"] = when
        if out["last_time"] is None or when > out["last_time"]:
            out["last_time"] = when

    if event == "FACTION":
        _faction(out, data, record.get("time"))
    elif event == "DECISION":
        out["decision_roles"][data.get("role")] += 1
        out["decision_missions"][data.get("mission")] += 1
        out["decision_reasons"][data.get("reason")] += 1
        if data.get("role") in CAPITAL_ROLES:
            out["capital_missions"][data.get("mission")] += 1
    elif event == "PRODUCTION":
        action = data.get("action")
        out["prod_actions"][action] += 1
        faction = data.get("faction")
        if action in ("UNIT_SPAWNED", "WAVE_SPAWNED"):
            out["units_spawned"][faction] += int(_number(data.get("spawnedCount")) or 0)
            if data.get("role") in CAPITAL_ROLES and data.get("placements"):
                out["capital_spawns"].append({"faction": faction, "class": data.get("class"),
                                              "placements": data["placements"]})
        elif action == "QUEUE_ACCEPTED" and data.get("cost") is not None:
            out["cp_spent"][faction] += float(data["cost"])
            out["cp_queued"][faction] += 1
    elif event == "SENTRY_BUILD":
        # Sentries are bought through SENTRY_BUILD, not PRODUCTION, so a spend
        # total that only reads QUEUE_ACCEPTED under-counts by every sentry.
        # BUILD_COMPLETED and BUILD_CANCELLED repeat the same cost, so charge it
        # once, on the purchase.
        action = data.get("action")
        out["sentry_actions"][action] += 1
        if action == "BUILD_STARTED" and data.get("cost") is not None:
            out["cp_sentry"][data.get("faction")] += float(data["cost"])
    elif event == "AI_BUILD_DECISION":
        _build_decision(out, data, record.get("time"))
    elif event == "EXECUTION":
        _execution(out, data)
    elif event == "COUNTERS":
        _counters(out, data)
    elif event == "LOSS":
        _loss(out, data)
    elif event == "OPERATION":
        _operation(out, data, record.get("time"))
    elif event == "FRIENDLY_HIT":
        _friendly(out, data)
    elif event == "CONTEST":
        out["contest"][data.get("faction")].append({
            "t": record.get("time"), "groups": data.get("groupCount"),
            "onBase": data.get("valueOnPrimary"), "onGroups": data.get("valueOnGroups"),
            "stalled": data.get("stalledGroups"), "worst": data.get("worstStallSeconds"),
            "stale": data.get("staleOrders"), "serviced": data.get("servicedShips"),
            "hull": data.get("stationHull"),
            "missions": data.get("missionCounts") or {},
        })
    elif event == "BATTLE_END":
        out["battle_end"] = True
        out["outcome"] = data.get("result")
    elif event == "OUTCOME_CAUSE":
        out["outcome_cause"] = data
    elif event == "ACCEPTANCE_SETUP":
        for kind, pos in (data.get("stationPositions") or {}).items():
            if isinstance(pos, dict) and "x" in pos:
                out["stations"][kind] = pos
    elif event == "FLEET_SERVICE":
        slot = out["service"][data.get("faction")]
        slot["phase"][data.get("phase")] += 1
        slot["reason"][data.get("reason")] += 1
    elif event == "FLEET_SERVICE_WORK":
        slot = out["service"][data.get("faction")]
        slot["work"] += 1
        spent = _number(data.get("spent")) or 0.0
        slot["spent"] += spent
        slot["healed"] += _number(data.get("healed")) or 0.0
        # Fleet service buys hull, subsystem and ammo repair out of the same bank
        # as everything else and records it in productionSpend, so it is a spend
        # path like QUEUE_ACCEPTED and SENTRY_BUILD. Reading only those two left
        # this out and turned a reconcilable total into a gap. `spent` is the
        # per-tick charge; the sibling `totalSpent` is the ship's running total
        # and summing it would multiply the charge by the tick count.
        out["cp_service"][data.get("faction")] += spent
    elif event == "FLEET_SERVICE_INTERRUPTED":
        out["service"][data.get("faction")]["interrupted"] += 1
    elif event == "CP_SPEND":
        # Per-deduction ledger emitted by RecordAIEconomyFlow, the single chokepoint
        # every CP movement passes through. Present so productionSpend can be
        # reconciled exactly; the emitter gap it closed was the station upgrade
        # track and the faction ability, neither of which emits a purchase event.
        if data.get("flow") == "productionSpend":
            out["cp_spend_ledger"][data.get("faction")] += _number(data.get("amount")) or 0.0
            out["cp_spend_entries"] += 1
    elif event == "STATION_REPAIR":
        slot = out["repair"][data.get("faction")]
        slot["samples"] += 1
        slot["interval"] += _number(data.get("repaired")) or 0.0
        total = _number(data.get("totalRepaired"))
        if total is not None:
            slot["cumulative"] = max(slot["cumulative"], total)
        # Why repair ran or did not: hull against the ceiling scarHull imposes.
        # A faction sitting at its ceiling has nothing to repair, which is a
        # different fact from a station whose repair never fires at all.
        hull = _number(data.get("hull"))
        ceiling = _number(data.get("repairCeiling"))
        if hull is not None and ceiling is not None:
            slot["below_ceiling_samples"] += 1 if hull < ceiling else 0
            slot["ceiling_gap_samples"] += max(0.0, ceiling - hull)
            slot["max_gap"] = max(slot["max_gap"], max(0.0, ceiling - hull))
    else:
        out["unhandled_events"][event] += 1


def _faction(out, data, when) -> None:
    kind = data.get("faction")
    if data.get("stationPosition"):
        out["stations"][kind] = data["stationPosition"]
    out["contract"]["faction_records"] += 1

    # value fields: the analyzer wants combatantValue, the emitter wrote
    # replacementValue, and both are emitted today. Accept either and record
    # which one the batch actually carried.
    replacement = _number(data.get("replacementValue"))
    combatant = _number(data.get("combatantValue"))
    if combatant is None and replacement is None:
        out["contract"]["value_absent"] += 1
    elif combatant is None:
        out["contract"]["value_replacement_only"] += 1
    elif replacement is not None and combatant != replacement:
        out["contract"]["value_disagrees"] += 1
    else:
        out["contract"]["value_present"] += 1
    value = combatant if combatant is not None else replacement

    for field in ("damageDealt", "stationDamageDealt"):
        out["contract"][f"{field}_numeric" if _number(data.get(field)) is not None
                         else f"{field}_non_numeric"] += 1
    dealt = _number(data.get("damageDealt"))
    station_dealt = _number(data.get("stationDamageDealt"))
    received = _number(data.get("received"))
    slot = out["damage"][kind]
    # cumulative totals: keep the maximum, never sum a running total.
    if dealt is not None:
        slot["dealt"] = max(slot["dealt"], dealt)
    if station_dealt is not None:
        slot["station_dealt"] = max(slot["station_dealt"], station_dealt)
    if received is not None:
        slot["received"] = max(slot["received"], received)

    if kind and _number(data.get("stationHull")) is not None:
        out["battle"][kind].append((when, {
            "cp": data.get("commandPoints"), "units": data.get("combatants"),
            "value": value, "hull": data.get("stationHull"),
            "max": data.get("stationMax"), "posture": (data.get("plan") or {}).get("posture"),
        }))

    # economy.flow is an INTERVAL, reset by the emitter after every FACTION
    # record. Summing the series is the only correct reading; the last sample
    # alone reads ~0 and looks exactly like an AI that never built anything.
    economy = data.get("economy") or {}
    flow = economy.get("flow") or {}
    if flow:
        out["flow_samples"][kind] += 1
        for name, amount in flow.items():
            number = _number(amount)
            if number is not None:
                out["flow"][kind][name] += number

    # upgradeSpend is a CUMULATIVE gauge (it only ever rises as tracks are
    # bought), so keep the last value per faction. repairUnlocked is the ARMOR L2
    # gate on station self-repair, and is what makes a totalRepaired of 0
    # readable as "never bought ARMOR L2" instead of "repair is broken".
    upgrade_spend = _number(economy.get("upgradeSpend"))
    if upgrade_spend is not None:
        out["upgrade_spend"][kind] = max(out["upgrade_spend"][kind], upgrade_spend)
    # flowCumulative is the running total behind economy.flow, so it accounts for
    # spend made after the final FACTION record - the trailing tail that makes
    # the summed intervals disagree with the event stream on every run. Another
    # cumulative gauge, so last value wins, not a sum of the series.
    cumulative_flow = economy.get("flowCumulative") or {}
    for name, total in cumulative_flow.items():
        number = _number(total)
        if number is not None:
            out["flow_cumulative"][kind][name] = max(
                out["flow_cumulative"][kind][name], number)
    if "repairUnlocked" in economy:
        out["repair_gate_known"][kind] = True
        if economy.get("repairUnlocked") is True:
            out["repair_unlocked"][kind] = True

    # baseDamageTelemetry.cumulative is a running per-faction total. Summing it
    # once per FACTION record would multiply it by the sample count, so keep the
    # last snapshot per faction and let the report add matches together.
    cumulative = (data.get("baseDamageTelemetry") or {}).get("cumulative") or {}
    weapons = cumulative.get("byWeapon") or []
    if weapons and (_number(cumulative.get("hitCount")) or 0) > 0:
        totals = out["base_damage_by_faction"][kind]
        totals[0] = _number(cumulative.get("hitCount")) or 0.0
        totals[1] = _number(cumulative.get("hullDamage")) or 0.0
        for weapon in weapons:
            hits = _number(weapon.get("hitCount")) or 0.0
            if hits <= 0:
                continue          # the emitter seeds every roster weapon at zero
            slot = out["base_damage"][(weapon.get("weaponClass"), bool(weapon.get("beamWeapon")))]
            slot[0] = hits
            slot[1] = _number(weapon.get("hullDamage")) or 0.0
            slot[2] = 1 if weapon.get("beamWeapon") else 0


def _build_decision(out, data, when) -> None:
    slot = out["build"][data.get("faction")]
    slot["samples"] += 1
    slot["reasons"][data.get("reason")] += 1
    slot["roles"][data.get("desiredRole")] += 1
    tier = _number(data.get("tier"))
    if tier is not None:
        slot["tiers"][int(tier)] += 1
    if when is not None:
        slot["times"].append(float(when))
    cp = _number(data.get("commandPoints"))
    affordable = _number(data.get("affordableOptions"))
    if cp is not None:
        slot["cp"].append(cp)
    if affordable is not None:
        slot["affordable"].append(affordable)
        if affordable <= 0:
            slot["zero_affordable"] += 1
    if (_number(data.get("unlockedOptions")) or 0) <= 0:
        slot["zero_unlocked"] += 1
    if (_number(data.get("fleetFitOptions")) or 0) <= 0:
        slot["zero_fleet_fit"] += 1
    bank_target = _number(data.get("bankTarget"))
    if bank_target is not None and cp is not None and cp < bank_target:
        slot["banked"] += 1
    if data.get("selectedClass"):
        slot["selected"][data.get("selectedClass")] += 1


def _execution(out, data) -> None:
    slot = out["execution"][data.get("faction")]
    slot["samples"] += 1
    slot["status"][data.get("status")] += 1
    slot["mode"][data.get("mode")] += 1
    if data.get("pursuit"):
        slot["pursuit"] += 1
    if data.get("hitObserved"):
        slot["hit"] += 1
    goal = data.get("goalPresent")
    if goal is True:
        slot["goal"]["present"] += 1
    elif goal is False:
        slot["goal"]["absent"] += 1
    else:
        slot["goal"][str(goal)] += 1
    slot["hull_loss"] += _number(data.get("hullLoss")) or 0.0


def _counters(out, data) -> None:
    """COUNTERS is the session's cumulative AIStats snapshot, not an interval,
    and it carries no faction key: the per-mission breakdown is keyed by
    faction inside orders.byMission. Keep the last snapshot of the match."""
    out["counters_samples"] += 1
    out["counters"] = data


def _loss(out, data) -> None:
    slot = out["losses"][data.get("faction")]
    slot["count"] += 1
    slot["by_class"][data.get("class")] += 1
    lethal = data.get("lethalHit") or {}
    slot["by_killer"][lethal.get("attackerFaction") or "?"] += 1
    slot["replacement"] += _number(data.get("replacementCost")) or 0.0
    slot["bounty"] += _number(data.get("bountyCP")) or 0.0


def _operation(out, data, when) -> None:
    out["operations"][data.get("faction")].append(
        (when, data.get("phase"), data.get("reason"), data.get("previous"), data.get("serial")))


def _friendly(out, data) -> None:
    slot = out["friendly"][data.get("faction")]
    slot["count"] += 1
    slot["mission"][data.get("mission") or "?"] += 1
    slot["kind"][data.get("sourceKind") or "?"] += 1
    slot["pairs"][f"{data.get('sourceName')} -> {data.get('targetName')}"] += 1


# --------------------------------------------------------------------------
# termination
# --------------------------------------------------------------------------

def classify(out) -> None:
    """Decide what actually ended the match, from the evidence on disk, and set
    `crashed` only when nothing usable came out of the run."""
    plan_cap = out["cap_seconds"]
    reached = (out["records"] > 0 and plan_cap > 0
               and out["last_time"] is not None
               and out["last_time"] >= CAP_REACHED_FRACTION * plan_cap)

    if out["records"] == 0:
        out["termination"] = "no_telemetry"
        out["termination_detail"] = (
            "telemetry file is empty" if out["telemetry_state"].startswith("empty")
            else "no telemetry JSONL found")
        out["crashed"] = True
        return

    reported = (out["result_termination"] or "").lower()
    if reported in CRASH_TERMINATIONS or out["result_crashed"]:
        out["termination"] = "engine_crash"
        out["termination_detail"] = f"engine-result termination={out['result_termination']!r}"
        out["crashed"] = True
    elif reported in ("mission_exit", "battle_end", "victory", "defeat", "complete"):
        out["termination"] = "mission_exit"
        out["termination_detail"] = f"engine-result termination={out['result_termination']!r}"
    elif out["battle_end"]:
        out["termination"] = "battle_end"
        out["termination_detail"] = f"BATTLE_END result={out['outcome']!r}"
    elif out["outcome_cause"]:
        out["termination"] = "station_destroyed"
        out["termination_detail"] = ("OUTCOME_CAUSE emitted but no BATTLE_END; "
                                     "mission did not return a result")
    elif out["result_time_limit"] or "time" in reported or reached:
        out["termination"] = "simulation_cap"
        out["cap_inferred"] = bool(reached and not out["result_time_limit"])
        progress = pct(out["last_time"], plan_cap) if plan_cap else 0.0
        out["termination_detail"] = (
            f"stopped at t={out['last_time']:.0f}s of the {plan_cap:.0f}s cap ({progress:.1f}%)"
            + (", engine-result time_limit_reached" if out["result_time_limit"] else
               ", inferred from cap progress (no engine-result.json)"))
        out["time_limit"] = True
    elif reported:
        out["termination"] = out["result_termination"]
        out["termination_detail"] = f"engine-result termination={out['result_termination']!r}"
    else:
        out["termination"] = "killed_without_result"
        out["termination_detail"] = (
            f"telemetry ends at t={out['last_time']:.0f}s, "
            f"{pct(out['last_time'], plan_cap):.1f}% of the {plan_cap:.0f}s cap, "
            "and the runner wrote no engine-result.json: stopped before the cap, "
            "killed mid-match (a wall-clock runner timeout and an engine teardown "
            "crash look identical without wall_seconds)"
            if plan_cap else
            "telemetry ends mid-match and the runner wrote no engine-result.json")

    if out["telemetry_state"] in ("truncated", "empty_truncated"):
        out["termination_detail"] += "; last JSONL record was truncated (killed mid-write)"


def analyze(run: Path, telemetry: Path | None = None) -> dict:
    out = new_match()
    out["run"] = str(run)

    result_path = run / "engine-result.json"
    out["result_present"] = result_path.is_file()
    out["result_termination"] = None
    out["result_time_limit"] = False
    out["result_crashed"] = False
    if out["result_present"]:
        try:
            result = json.loads(result_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            out["log_errors"].append(f"unreadable engine-result.json: {exc}")
        else:
            if isinstance(result, dict):
                out["seed"] = result.get("seed")
                out["result_termination"] = result.get("termination")
                out["simulated_seconds"] = float(result.get("simulated_seconds") or 0.0)
                out["wall_seconds"] = float(result.get("wall_seconds") or 0.0)
                out["result_time_limit"] = bool(result.get("time_limit_reached"))
                out["result_crashed"] = bool(result.get("crashed"))
    # Missing engine-result.json is normal for a cap-terminated match; only say
    # so when there is nothing else to go on.
    if not out["result_present"] and not out["log_errors"]:
        out["log_errors"].append(
            "no engine-result.json (normal for a cap-terminated headless run; "
            "termination inferred from telemetry)")
    if out["seed"] is None:
        # engine-result.json carries `seed`, but the engine only flushes it when
        # it exits on its own. results/results.jsonl records the same seed per
        # replicate alongside the workspace, so fall back to that before giving up.
        fallback = find_result_seeds(run).get(str(run.resolve()).lower())
        if fallback is not None:
            out["seed"] = fallback
            out["seed_source"] = "results.jsonl"
    else:
        out["seed_source"] = "engine-result.json"

    for name in ("stdout.log", "stderr.log"):
        path = run / name
        if path.is_file():
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                if ERROR_PATTERNS.search(line):
                    out["log_errors"].append(f"{name}: {line.strip()[:200]}")

    plan = find_plan(run)
    out["cap_seconds"] = float(plan.get("max_sim_time") or 0.0)

    path = telemetry if telemetry is not None else newest_telemetry(run)
    if path is None:
        out["telemetry_state"] = "absent"
        out["termination"] = "no_telemetry"
        out["termination_detail"] = "no telemetry JSONL under this run folder"
        out["crashed"] = True
        return out
    out["telemetry"] = path.name
    scan_telemetry(path, out)
    out["cap_progress"] = (pct(out["last_time"], out["cap_seconds"])
                           if out["cap_seconds"] and out["last_time"] else 0.0)
    classify(out)
    return out


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

def _top(counter, limit=8):
    return ", ".join(f"{k} x{v}" for k, v in counter.most_common(limit))


def _build_stats(slot):
    """Longest run of consecutive 'no affordable option' samples, in simulated
    seconds. This is the production blackout: the planner wanted something, the
    bank could not pay for anything."""
    times = slot.get("times") or []
    stats = {"cadence": 0.0, "longest_blackout": 0.0}
    if len(times) > 1:
        deltas = [b - a for a, b in zip(times, times[1:]) if b > a]
        if deltas:
            stats["cadence"] = sum(deltas) / len(deltas)
    # affordability and timestamps are parallel arrays only if every sample
    # carried both, so pair them by index and fall back to the sample count.
    affordable = slot.get("affordable") or []
    if len(times) == len(affordable) and stats["cadence"] > 0:
        run_start = None
        longest = 0.0
        for when, options in zip(times, affordable):
            if options <= 0:
                run_start = when if run_start is None else run_start
            elif run_start is not None:
                longest = max(longest, when - run_start)
                run_start = None
        if run_start is not None:
            longest = max(longest, times[-1] - run_start)
        stats["longest_blackout"] = longest
    return stats


def report(matches, label, verbose):
    print(f"\n{'=' * 78}\n{label}  ({len(matches)} matches)\n{'=' * 78}")
    crashed = [m for m in matches if m["crashed"]]
    natural = [m for m in matches if m["termination"] in ("mission_exit", "battle_end")]
    capped = [m for m in matches if m["time_limit"]]
    killed = [m for m in matches if m["termination"] == "killed_without_result"]
    errors = [e for m in matches for e in m["log_errors"] if not e.startswith("no engine-result")]
    print(f"crashed / no telemetry : {len(crashed)}")
    print(f"natural terminal       : {len(natural)}  (mission_exit + BATTLE_END)")
    print(f"hit simulation cap     : {len(capped)}")
    print(f"stopped short of cap   : {len(killed)}  (telemetry healthy, no engine-result.json)")
    print(f"telemetry records      : {sum(m['records'] for m in matches)}")
    print(f"engine log errors      : {len(errors)}")
    for line in errors[:10]:
        print(f"    {line}")

    reasons = collections.Counter(m["termination"] for m in matches)
    print("termination breakdown  : " + (", ".join(f"{k} {v}" for k, v in reasons.most_common()) or "none"))
    states = collections.Counter(m["telemetry_state"] for m in matches)
    print("telemetry state        : " + ", ".join(f"{k} {v}" for k, v in states.most_common()))
    with_records = [m for m in matches if m["records"] > 0]
    if with_records:
        print(f"records per match      : min {min(m['records'] for m in with_records)} "
              f"max {max(m['records'] for m in with_records)}")
    caps = [m for m in matches if m["cap_progress"] > 0]
    if caps:
        print(f"cap progress           : {min(c['cap_progress'] for c in caps):.1f}% - "
              f"{max(c['cap_progress'] for c in caps):.1f}% of the "
              f"{caps[0]['cap_seconds']:.0f}s cap (batch.plan.json)")
    for match in matches:
        run = Path(match["run"])
        where = f"{run.parent.name[:8]}/{run.name}" if run.parent.name else run.name
        print(f"    {where:34} {match['termination']:22} "
              f"{match['records']:7} records  t={match['last_time'] or 0:.0f}s"
              + (f"  cap {match['cap_progress']:.0f}%" if match["cap_progress"] else "")
              + (f"  [{match['termination_detail']}]" if verbose else ""))

    flow_queued = sum(sum(m["cp_spent"].values()) + sum(m["cp_sentry"].values())
                      + sum(m["cp_service"].values()) for m in matches)
    flow_series = sum(sum(m["flow"][f].get("productionSpend", 0.0) for f in FACTIONS) for m in matches)
    spend_method = "summed data.economy.flow.productionSpend over every FACTION sample"
    if flow_queued and flow_series:
        spend_method += (f" (cross-checked against {int(sum(sum(m['cp_queued'].values()) for m in matches))}"
                         f" QUEUE_ACCEPTED events)")
    print("\n-- production --")
    print(f"  method: {spend_method}")
    print(f"  data.economy.flow.productionSpend is an INTERVAL (the emitter zeroes it after each"
          f" FACTION record), so the last sample alone reads ~0")
    print(f"  the flow is written by the single RecordAIEconomyFlow chokepoint and is therefore the"
          f" authoritative total")
    print(f"  spend paths: QUEUE_ACCEPTED (units) + SENTRY_BUILD/BUILD_STARTED (sentries)"
          f" + FLEET_SERVICE_WORK.spent (repair/ammo) + station upgrades + faction ability")
    for faction in FACTIONS:
        queued = sum(m["cp_spent"].get(faction, 0) for m in matches)
        sentry = sum(m["cp_sentry"].get(faction, 0) for m in matches)
        service = sum(m["cp_service"].get(faction, 0) for m in matches)
        series = sum(m["flow"][faction].get("productionSpend", 0.0) for m in matches)
        running = sum(m["flow_cumulative"][faction].get("productionSpend", 0.0)
                      for m in matches)
        ledger = sum(m["cp_spend_ledger"].get(faction, 0) for m in matches)
        upgrades = sum(m["upgrade_spend"].get(faction, 0) for m in matches)
        income = sum(m["flow"][faction].get("income", 0.0) for m in matches)
        bounty = sum(m["flow"][faction].get("bounty", 0.0) for m in matches)
        spawned = sum(m["units_spawned"].get(faction, 0) for m in matches)
        print(f"  {faction:5} queued {queued:10.0f}  sentries {sentry:9.0f}  service {service:8.0f}  "
              f"total {queued + sentry + service:10.0f}  flow spend {series:10.0f}  "
              f"unattributed {series - queued - sentry - service:8.0f}  income {income:9.0f}  bounty {bounty:8.0f}"
              f"   units spawned {spawned:6}")
        if ledger:
            print(f"        CP_SPEND ledger {ledger:10.0f} in {sum(m['cp_spend_entries'] for m in matches)}"
                  f" deductions   economy.flowCumulative {running:10.0f}"
                  f"   station upgrade spend {upgrades:.0f}")
    # The reconciliation assertion, and the two ways it can fail.
    #
    # `unattributed` above is not itself a defect: station upgrades and the
    # faction ability reach the flow without a purchase event. What must hold is
    # CP_SPEND (one record per CP movement) against economy.flowCumulative (the
    # running total behind the interval flow). Both are written by the same
    # chokepoint, so any drift means a CP movement stopped being recorded.
    ledger_total = sum(sum(m["cp_spend_ledger"].values()) for m in matches)
    running_total = sum(sum(m["flow_cumulative"][f].get("productionSpend", 0.0)
                            for f in FACTIONS) for m in matches)
    entries = sum(m["cp_spend_entries"] for m in matches)
    if entries:
        drift = ledger_total - running_total
        share = abs(drift) / running_total * 100 if running_total else 0.0
        status = "OK" if share <= 0.5 else "MISMATCH"
        print(f"  reconciliation: CP_SPEND ledger {ledger_total:.0f} CP over {entries} deductions"
              f" vs economy.flowCumulative {running_total:.0f} CP"
              f" -> drift {drift:+.0f} CP ({share:.2f}%) {status}")
        tail = running_total - flow_series
        if abs(tail) > 0.5:
            print(f"    summed intervals under-report by {tail:.0f} CP: spend after the final"
                  f" FACTION record of each match belongs to an interval nobody reports")
        if status != "OK":
            print("    a CP movement is not reaching RecordAIEconomyFlow, so the flow total"
                  " and the per-deduction ledger have diverged")
    elif running_total:
        print(f"  reconciliation: no CP_SPEND records, so economy.flowCumulative {running_total:.0f} CP"
              f" has no second view to be checked against")
    else:
        print("  reconciliation: no CP_SPEND or economy.flowCumulative records in this batch"
              " (predates both); unattributed spend can only be bounded, not attributed")

    rows = []
    for match in matches:
        for spawn in match["capital_spawns"]:
            own = match["stations"].get(spawn["faction"])
            if not own:
                continue
            enemy = [p for k, p in match["stations"].items() if k != spawn["faction"]]
            for place in spawn["placements"]:
                rows.append({"faction": spawn["faction"], "class": spawn["class"],
                             "own": dist(place, own),
                             "enemy": min((dist(place, e) for e in enemy), default=math.inf)})
    print(f"\n-- capital spawn placement ({len(rows)} hulls) --")
    if not rows:
        print("  no capital or heavy hull was ever spawned in this batch")
    else:
        own = sorted(r["own"] for r in rows)
        enemy = sorted(r["enemy"] for r in rows)
        print(f"  from own station   : min {own[0]:.0f}  median {median(own):.0f}  max {own[-1]:.0f}")
        print(f"  from enemy station : min {enemy[0]:.0f}  median {median(enemy):.0f}  max {enemy[-1]:.0f}")
        too_close = [r for r in rows if r["enemy"] < MIN_ENEMY_SEPARATION]
        too_far = [r for r in rows if r["own"] > MAX_STATION_RADIUS]
        print(f"  inside {MIN_ENEMY_SEPARATION:.0f} m of an enemy base: {len(too_close)}")
        print(f"  beyond {MAX_STATION_RADIUS:.0f} m from own base     : {len(too_far)}")
        for row in sorted(too_close, key=lambda r: r["enemy"])[:8]:
            print(f"    {str(row['class']):20} {str(row['faction']):5} enemy {row['enemy']:.0f} m")
        counts = collections.Counter(str(r["class"]) for r in rows)
        print("  hulls seen: " + ", ".join(f"{k} x{v}" for k, v in counts.most_common()))

    print("\n-- base damage per hit (15% beam cap) --")
    print("  cumulative per-faction totals, last FACTION snapshot of each match")
    hits, damage = collections.Counter(), collections.Counter()
    for match in matches:
        for key, (h, d, _beam) in match["base_damage"].items():
            hits[key] += h
            damage[key] += d
    beams = sorted(((damage[k] / hits[k], k[0], hits[k]) for k in hits if k[1] and hits[k]))
    projectiles = sorted(((damage[k] / hits[k], k[0], hits[k]) for k in hits if not k[1] and hits[k]))
    for value, name, count in beams:
        print(f"  BEAM  {str(name):22} {count:8.0f} hits  {value:9.3f} dmg/hit")
    for value, name, count in projectiles:
        print(f"  PROJ  {str(name):22} {count:8.0f} hits  {value:9.3f} dmg/hit")
    if beams and projectiles:
        best_projectile = max(v for v, _, _ in projectiles)
        worst_beam = max(v for v, _, _ in beams)
        print(f"  worst beam {worst_beam:.3f} vs best projectile {best_projectile:.1f} dmg/hit "
              f"-> {best_projectile / max(worst_beam, 1e-4):.0f}x separation")
        print(f"  ({len(projectiles)} projectile weapons, {len(beams)} beam weapons reached a base)")
    if not hits:
        print("  no weapon ever registered a hit on a base in this batch")

    print("\n-- station damage dealt (FACTION.damageDealt / stationDamageDealt) --")
    print(f"  {'faction':6} {'hull dealt':>12} {'station hull':>14} {'received':>12}  numeric FACTION samples")
    any_damage = False
    for faction in FACTIONS:
        dealt = sum(m["damage"][faction]["dealt"] for m in matches)
        station = sum(m["damage"][faction]["station_dealt"] for m in matches)
        received = sum(m["damage"][faction]["received"] for m in matches)
        numeric = sum(m["contract"].get("damageDealt_numeric", 0) for m in matches)
        non_numeric = sum(m["contract"].get("damageDealt_non_numeric", 0) for m in matches)
        if dealt or station or received:
            any_damage = True
        print(f"  {faction:6} {dealt:12.0f} {station:14.0f} {received:12.0f}  {numeric}"
              + (f"  ({non_numeric} records carried the string 'unknown')" if non_numeric else ""))
    if not any_damage:
        print("  no damage totals in this batch (the emitter wrote the string 'unknown' before the fix)")
    for faction in FACTIONS:
        by_faction = [m["base_damage_by_faction"].get(faction) for m in matches]
        by_faction = [slot for slot in by_faction if slot]
        if not by_faction:
            continue
        print(f"  {faction:5} attributed hull damage on a station: "
              f"{sum(slot[1] for slot in by_faction):10.0f} in "
              f"{sum(slot[0] for slot in by_faction):7.0f} hits")

    print("\n-- order compliance and progress (CONTEST) --")
    for faction in FACTIONS:
        samples = [s for m in matches for s in m["contest"].get(faction, [])]
        if not samples:
            continue
        stalled = [s["stalled"] or 0 for s in samples]
        worst = [s["worst"] or 0 for s in samples]
        stale = [s["stale"] or 0 for s in samples]
        serviced = [s["serviced"] or 0 for s in samples]
        over = sum(1 for s in stalled if s > 0)
        print(f"  {faction:5} samples {len(samples):5}  samples with a stalled attack group "
              f"{over:4} ({pct(over, len(samples)):.1f}%)  worst stall {max(worst):6.0f} s  "
              f"max stale orders {max(stale):3}  max serviced {max(serviced):3}")

    _report_build_decisions(matches)
    _report_execution(matches)
    _report_counters(matches)
    _report_losses(matches)
    _report_operations(matches)
    _report_friendly(matches)
    _report_service(matches)
    _report_event_mix(matches)

    print("\n-- outcome cause (who killed which base) --")
    causes = [m for m in matches if m["outcome_cause"]]
    if not causes:
        print("  no OUTCOME_CAUSE record (no station was destroyed in this batch)")
    for match in causes:
        cause = match["outcome_cause"]
        print(f"  seed {match['seed']}: {cause.get('faction')} station "
              f"({cause.get('targetName')}) destroyed at t={cause.get('elapsed', 0):.0f}s, "
              f"{cause.get('totalAttributedHullDamage', 0):.0f} hull damage attributed")
        for killer in (cause.get("killers") or [])[:3]:
            print(f"      {str(killer.get('weapon')):22} from {str(killer.get('attackerFaction')):5} "
                  f"beam={str(killer.get('beam')):5} {killer.get('hullDamage', 0):10.0f} hull "
                  f"({100 * (killer.get('share') or 0):.1f}%)")
        snapshot = cause.get("snapshot") or {}
        line = "      at that moment: "
        for faction in FACTIONS:
            state = snapshot.get(faction) or {}
            line += (f"{faction} cp={state.get('commandPoints', 0):.0f} "
                     f"hull={100 * (state.get('stationHull') or 0):.0f}%  ")
        print(line)

    print("\n-- arms race (who led on surviving combatant value) --")
    led = collections.Counter()
    samples_total = 0
    lead_changes = 0
    comparable = 0
    for match in matches:
        series = {k: sorted(v) for k, v in match["battle"].items()}
        blue = series.get("BLUE") or []
        red = series.get("RED") or []
        gold = series.get("GOLD") or []
        if not blue or not (red or gold):
            continue
        comparable += 1
        previous = None
        changes = 0
        for index, (t, state) in enumerate(blue):
            value = state.get("value") or 0
            rivals = []
            for other in (red, gold):
                if index < len(other):
                    rivals.append(other[index][1].get("value") or 0)
            if not rivals:
                continue
            samples_total += 1
            leader = "BLUE" if value > max(rivals) else "OTHER"
            led[leader] += 1
            if previous is not None and leader != previous:
                changes += 1
            previous = leader
        lead_changes += 1 if changes else 0
    if samples_total:
        print(f"  compared {comparable} matches over {samples_total} samples "
              f"(combatantValue, falling back to replacementValue)")
        for faction, count in led.most_common():
            print(f"  {faction:6} led {pct(count, samples_total):5.1f}% of samples")
        print(f"  the lead changed hands in {lead_changes} of {comparable} matches")
    else:
        print("  no comparable FACTION value series in this batch")

    print("\n-- outcomes --")
    outcomes = collections.Counter()
    for match in matches:
        outcomes[match["outcome"] or ("UNFINISHED" if match["time_limit"] else
                                      (match["termination"] or "?").upper())] += 1
    for outcome, count in outcomes.most_common():
        print(f"  {outcome:20} {count}")
    speeds = [m["simulated_seconds"] / m["wall_seconds"] for m in matches if m["wall_seconds"] > 0]
    if speeds:
        print(f"\nthroughput: {sum(speeds) / len(speeds):.1f}x realtime "
              f"(needs engine-result.json wall_seconds; absent for cap-terminated runs)")
    return metrics(matches, crashed, natural, capped, errors, rows, flow_queued, flow_series)


def _report_build_decisions(matches):
    print("\n-- build decisions (AI_BUILD_DECISION) --")
    totals = collections.Counter()
    reasons = collections.Counter()
    roles = collections.Counter()
    for match in matches:
        for faction, slot in match["build"].items():
            totals[faction] += slot["samples"]
            reasons.update(slot["reasons"])
            roles.update(slot["roles"])
    if not totals:
        print("  no AI_BUILD_DECISION records")
        return
    print(f"  decisions {sum(totals.values())}: " + ", ".join(f"{k} {v}" for k, v in totals.most_common()))
    print(f"  reason    : {_top(reasons, 10)}")
    print(f"  desiredRole: {_top(roles, 8)}")
    for faction in FACTIONS:
        slots = [m["build"][faction] for m in matches if m["build"].get(faction)]
        if not slots:
            continue
        samples = sum(s["samples"] for s in slots)
        zero_aff = sum(s["zero_affordable"] for s in slots)
        zero_unlock = sum(s["zero_unlocked"] for s in slots)
        zero_fit = sum(s["zero_fleet_fit"] for s in slots)
        banked = sum(s["banked"] for s in slots)
        cp = [v for s in slots for v in s["cp"]]
        affordable = [v for s in slots for v in s["affordable"]]
        blacks = [_build_stats(s)["longest_blackout"] for s in slots]
        cadence = [c for c in (_build_stats(s)["cadence"] for s in slots) if c]
        print(f"  {faction:5} samples {samples:5}  no affordable option {zero_aff:4} "
              f"({pct(zero_aff, samples):5.1f}%)  nothing unlocked {zero_unlock:4}  "
              f"nothing fits fleet cap {zero_fit:4}  banked below target {banked:4} "
              f"({pct(banked, samples):4.1f}%)")
        if cp:
            print(f"        command points min {min(cp):7.0f} median {median(cp):7.0f} max {max(cp):7.0f}"
                  + (f"  affordable options median {median(affordable):.0f} max {max(affordable):.0f}"
                     if affordable else ""))
        if blacks and max(blacks) > 0:
            unit = f" (sample every {median(cadence):.0f}s)" if cadence else ""
            print(f"        longest no-affordable-option run {max(blacks):.0f}s{unit}")
    selected = collections.Counter()
    for match in matches:
        for slot in match["build"].values():
            selected.update(slot["selected"])
    if selected:
        print(f"  selected hulls: {_top(selected, 8)}")


def _report_execution(matches):
    print("\n-- execution (EXECUTION) --")
    samples = sum(sum(s["samples"] for s in m["execution"].values()) for m in matches)
    if not samples:
        print("  no EXECUTION records")
        return
    status, mode, goal = collections.Counter(), collections.Counter(), collections.Counter()
    pursuit = hit = 0
    for match in matches:
        for slot in match["execution"].values():
            status.update(slot["status"])
            mode.update(slot["mode"])
            goal.update(slot["goal"])
            pursuit += slot["pursuit"]
            hit += slot["hit"]
    print(f"  samples {samples}")
    print(f"  status   : {_top(status, 10)}")
    print(f"  mode     : {_top(mode, 10)}")
    print(f"  goalPresent: {_top(goal, 6)}   pursuit {pursuit} ({pct(pursuit, samples):.1f}%)"
          f"   hit observed {hit} ({pct(hit, samples):.1f}%)")
    stalled = sum(m["execution"][f]["mode"].get("STALLED", 0)
                  for m in matches for f in m["execution"])
    preempted = sum(m["execution"][f]["status"].get("NATIVE_ORDER_PREEMPTED", 0)
                    for m in matches for f in m["execution"])
    print(f"  STALLED mode {stalled}   NATIVE_ORDER_PREEMPTED {preempted}")


def _report_counters(matches):
    print("\n-- order telemetry (COUNTERS, cumulative per match) --")
    totals = collections.Counter()
    by_mission = collections.defaultdict(collections.Counter)
    samples = 0
    for match in matches:
        counters = match["counters"]
        if not counters:
            continue
        samples += 1
        orders = counters.get("orders") or {}
        for name in ("attempts", "success", "failed", "rejected", "unchanged"):
            totals["orders." + name] += _number(orders.get(name)) or 0.0
        for name in ("decisions", "retained", "switches", "reissued", "nativeChanges"):
            totals[name] += _number(counters.get(name)) or 0.0
        for faction, missions in (orders.get("byMission") or {}).items():
            if not isinstance(missions, dict):
                continue
            for mission, outcomes in missions.items():
                if not isinstance(outcomes, dict):
                    continue
                for outcome, count in outcomes.items():
                    amount = _number(count) or 0.0
                    if amount:
                        # the emitter pre-creates all four outcome keys, so the
                        # zero rows carry no information
                        by_mission[faction][f"{mission}.{outcome}"] += amount
    if not samples:
        print("  no COUNTERS records")
        return
    attempts = totals["orders.attempts"]
    print(f"  {samples} matches with a COUNTERS snapshot (last one per match, these are "
          f"cumulative session totals, not intervals)")
    print(f"  decisions {totals['decisions']:.0f}  retained {totals['retained']:.0f} "
          f"({pct(totals['retained'], totals['decisions']):.1f}%)  switches {totals['switches']:.0f} "
          f"reissued {totals['reissued']:.0f}  nativeChanges {totals['nativeChanges']:.0f}")
    print(f"  orders attempts {attempts:.0f}  success {totals['orders.success']:.0f} "
          f"({pct(totals['orders.success'], attempts):.1f}%)  failed {totals['orders.failed']:.0f} "
          f"  rejected {totals['orders.rejected']:.0f}  unchanged {totals['orders.unchanged']:.0f}")
    for faction in FACTIONS:
        entries = by_mission.get(faction)
        if not entries:
            continue
        print(f"  {faction} by mission: {_top(entries, 10)}")


def _report_losses(matches):
    print("\n-- losses (LOSS) --")
    total = sum(sum(s["count"] for s in m["losses"].values()) for m in matches)
    if not total:
        print("  no LOSS records")
        return
    print(f"  total {total}")
    for faction in FACTIONS:
        slots = [m["losses"][faction] for m in matches if m["losses"].get(faction)]
        if not slots:
            continue
        count = sum(s["count"] for s in slots)
        by_class = collections.Counter()
        by_killer = collections.Counter()
        for slot in slots:
            by_class.update(slot["by_class"])
            by_killer.update(slot["by_killer"])
        replacement = sum(s["replacement"] for s in slots)
        bounty = sum(s["bounty"] for s in slots)
        print(f"  {faction:5} lost {count:5}  replacement cost {replacement:9.0f}  "
              f"bounty CP paid {bounty:8.0f}  killed by {_top(by_killer, 4)}")
        print(f"        hulls lost: {_top(by_class, 6)}")


def _report_operations(matches):
    print("\n-- operations (OPERATION) --")
    total = sum(len(v) for m in matches for v in m["operations"].values())
    if not total:
        print("  no OPERATION records")
        return
    transitions = collections.Counter()
    reasons = collections.Counter()
    dwell = collections.defaultdict(collections.Counter)
    for match in matches:
        for faction, entries in match["operations"].items():
            previous = None
            previous_time = None
            for when, phase, reason, reported_previous, _serial in entries:
                before = reported_previous or previous
                transitions[f"{before or 'START'} -> {phase}"] += 1
                reasons[reason] += 1
                if when is not None and previous_time is not None:
                    dwell[faction][phase] += max(0.0, float(when) - previous_time)
                previous = phase
                previous_time = float(when) if when is not None else previous_time
    print(f"  records {total}")
    print(f"  transitions: {_top(transitions, 10)}")
    print(f"  reasons    : {_top(reasons, 10)}")
    share = collections.Counter()
    for phases in dwell.values():
        for phase, seconds in phases.items():
            share[phase] += seconds
    if share:
        window = sum(share.values()) or 1.0
        print("  time in phase: " + ", ".join(
            f"{k} {pct(v, window):.1f}%" for k, v in sorted(share.items(), key=lambda kv: -kv[1])))


def _report_friendly(matches):
    print("\n-- friendly fire (FRIENDLY_HIT) --")
    total = sum(sum(s["count"] for s in m["friendly"].values()) for m in matches)
    if not total:
        print("  no FRIENDLY_HIT records")
        return
    print(f"  total {total}")
    for faction in FACTIONS:
        slots = [m["friendly"][faction] for m in matches if m["friendly"].get(faction)]
        if not slots:
            continue
        count = sum(s["count"] for s in slots)
        mission = collections.Counter()
        kind = collections.Counter()
        pairs = collections.Counter()
        for slot in slots:
            mission.update(slot["mission"])
            kind.update(slot["kind"])
            pairs.update(slot["pairs"])
        print(f"  {faction:5} {count:5}  mission {_top(mission, 6)}")
        print(f"        source {_top(kind, 4)}   worst pairs: {_top(pairs, 4)}")


def _report_service(matches):
    print("\n-- fleet service and station repair --")
    phases = collections.Counter()
    reasons = collections.Counter()
    work = spent = healed = interrupted = 0
    for match in matches:
        for slot in match["service"].values():
            phases.update(slot["phase"])
            reasons.update(slot["reason"])
            work += slot["work"]
            spent += slot["spent"]
            healed += slot["healed"]
            interrupted += slot["interrupted"]
    repairs = collections.defaultdict(lambda: {
        "interval": 0.0, "cumulative": 0.0, "samples": 0,
        "below_ceiling_samples": 0, "ceiling_gap_samples": 0.0, "max_gap": 0.0,
    })
    for match in matches:
        for faction, slot in match["repair"].items():
            repairs[faction]["interval"] += slot["interval"]
            repairs[faction]["samples"] += slot["samples"]
            repairs[faction]["below_ceiling_samples"] += slot["below_ceiling_samples"]
            repairs[faction]["ceiling_gap_samples"] += slot["ceiling_gap_samples"]
            repairs[faction]["max_gap"] = max(repairs[faction]["max_gap"], slot["max_gap"])
            repairs[faction]["cumulative"] = max(repairs[faction]["cumulative"], slot["cumulative"])
    if not phases and not repairs:
        print("  no FLEET_SERVICE or STATION_REPAIR records in this batch")
        return
    if phases:
        print(f"  service phase: {_top(phases, 8)}")
        print(f"  service reason: {_top(reasons, 8)}")
        print(f"  work samples {work}  spent {spent:.1f}  healed {healed:.1f}  interrupted {interrupted}")
    print("  station self-repair needs ARMOR L2 or better AND hull below the ceiling that")
    print("  scarHull imposes. A zero below is one of those two, not a broken emitter:")
    for faction in FACTIONS:
        slot = repairs.get(faction)
        if not slot:
            continue
        unlocked = any(m["repair_unlocked"].get(faction) for m in matches)
        known = any(m["repair_gate_known"].get(faction) for m in matches)
        if not known:
            # Older batches carry no repairUnlocked at all. Saying "never reached
            # ARMOR L2" there would be a claim, not a reading.
            unlocked_text = "gate not reported by this batch"
        elif unlocked:
            unlocked_text = "ARMOR L2+"
        else:
            unlocked_text = "never reached ARMOR L2"
        print(f"  {faction:5} station repair interval total {slot['interval']:10.0f}"
              f"  last cumulative {slot['cumulative']:10.0f}  samples {slot['samples']}"
              f"  gate: {unlocked_text}"
              f"  below ceiling on {slot['below_ceiling_samples']}/{slot['samples']} samples"
              f"  largest shortfall {slot['max_gap']:.0f} hull")


def _report_event_mix(matches):
    print("\n-- event mix --")
    total = collections.Counter()
    for match in matches:
        total.update(match["events"])
    if not total:
        return
    print(f"  {sum(total.values())} records: " + ", ".join(f"{k} {v}" for k, v in total.most_common()))
    unhandled = collections.Counter()
    for match in matches:
        unhandled.update(match["unhandled_events"])
    if unhandled:
        print(f"  NOT analysed ({sum(unhandled.values())} records): " + _top(unhandled, 12))
    else:
        print("  every observed event type has an accumulator (nothing counted but ignored)")
    contract = collections.Counter()
    for match in matches:
        contract.update(match["contract"])
    if contract:
        print("  FACTION field contract: " + ", ".join(f"{k} {v}" for k, v in sorted(contract.items())))
        if contract.get("value_replacement_only"):
            print("    (batch predates combatantValue; replacementValue was used instead)")


# --------------------------------------------------------------------------
# baseline
# --------------------------------------------------------------------------

def metrics(matches, crashed, natural, capped, errors, rows, flow_queued, flow_series):
    out = {
        "matches": len(matches),
        "crashed": len(crashed),
        "natural": len(natural),
        "capped": len(capped),
        "errors": len(errors),
        "capitals": len(rows),
        "too_close": sum(1 for r in rows if r["enemy"] < MIN_ENEMY_SEPARATION),
        "records": sum(m["records"] for m in matches),
        "spawned": sum(sum(m["units_spawned"].values()) for m in matches),
        "queued_spend": flow_queued,
        "flow_spend": flow_series,
        # Per-deduction ledger and its drift against the flow. Drift is the
        # regression guard: a CP movement that stops reaching RecordAIEconomyFlow
        # shows up here instead of quietly becoming unattributed spend.
        "cp_spend_ledger": sum(sum(m["cp_spend_ledger"].values()) for m in matches),
        "cp_spend_drift": (sum(sum(m["cp_spend_ledger"].values()) for m in matches)
                           - flow_series),
        "cap_progress": (sum(m["cap_progress"] for m in matches) / len(matches)) if matches else 0.0,
        "losses": sum(sum(s["count"] for s in m["losses"].values()) for m in matches),
        "friendly": sum(sum(s["count"] for s in m["friendly"].values()) for m in matches),
        "operations": sum(len(v) for m in matches for v in m["operations"].values()),
        "station_damage": sum(sum(m["damage"][f]["station_dealt"] for f in FACTIONS) for m in matches),
        "station_damage_attributed": sum(sum(slot[1] for slot in m["base_damage_by_faction"].values())
                                          for m in matches),
    }
    for faction in FACTIONS:
        out[f"spawned.{faction}"] = sum(m["units_spawned"].get(faction, 0) for m in matches)
        out[f"queued.{faction}"] = (sum(m["cp_spent"].get(faction, 0) for m in matches)
                                     + sum(m["cp_sentry"].get(faction, 0) for m in matches)
                                     + sum(m["cp_service"].get(faction, 0) for m in matches))
        out[f"service.{faction}"] = sum(m["cp_service"].get(faction, 0) for m in matches)
        out[f"upgrade.{faction}"] = sum(m["upgrade_spend"].get(faction, 0) for m in matches)
        out[f"repair_unlocked.{faction}"] = 1.0 if any(
            m["repair_unlocked"].get(faction) for m in matches) else 0.0
        out[f"ledger.{faction}"] = sum(m["cp_spend_ledger"].get(faction, 0) for m in matches)
        out[f"unattributed.{faction}"] = (
            sum(m["flow"][faction].get("productionSpend", 0.0) for m in matches)
            - out[f"queued.{faction}"])
        out[f"flow.{faction}"] = sum(m["flow"][faction].get("productionSpend", 0.0) for m in matches)
        out[f"losses.{faction}"] = sum(s["count"] for s in (m["losses"].get(faction) for m in matches)
                                       if s is not None)
        slots = [m["build"][faction] for m in matches if m["build"].get(faction)]
        samples = sum(s["samples"] for s in slots)
        out[f"build_blackout.{faction}"] = pct(sum(s["zero_affordable"] for s in slots), samples)
    out["decisions"] = sum(_number(m["counters"].get("decisions")) or 0.0
                           for m in matches if m["counters"])
    out["retained_pct"] = pct(sum(_number(m["counters"].get("retained")) or 0.0 for m in matches if m["counters"]),
                              out["decisions"])
    out["switches"] = sum(_number(m["counters"].get("switches")) or 0.0 for m in matches if m["counters"])
    order_success = sum(_number(((m["counters"] or {}).get("orders") or {}).get("success")) or 0.0
                        for m in matches if m["counters"])
    order_attempts = sum(_number(((m["counters"] or {}).get("orders") or {}).get("attempts")) or 0.0
                         for m in matches if m["counters"])
    out["order_success_pct"] = pct(order_success, order_attempts)
    out["outcomes"] = dict(collections.Counter(
        m["outcome"] or ("UNFINISHED" if m["time_limit"] else (m["termination"] or "?").upper())
        for m in matches))
    return out


COMPARE_ROWS = (
    ("matches", "{:d}"), ("records", "{:d}"), ("crashed", "{:d}"), ("capped", "{:d}"),
    ("natural", "{:d}"), ("cap_progress", "{:.1f}%"), ("errors", "{:d}"),
    ("spawned", "{:d}"), ("queued_spend", "{:.0f}"), ("flow_spend", "{:.0f}"),
    ("cp_spend_ledger", "{:.0f}"), ("cp_spend_drift", "{:+.0f}"),
    ("spawned.BLUE", "{:d}"), ("spawned.RED", "{:d}"), ("spawned.GOLD", "{:d}"),
    ("queued.BLUE", "{:.0f}"), ("queued.RED", "{:.0f}"), ("queued.GOLD", "{:.0f}"),
    ("flow.BLUE", "{:.0f}"), ("flow.RED", "{:.0f}"), ("flow.GOLD", "{:.0f}"),
    ("unattributed.BLUE", "{:.0f}"), ("unattributed.RED", "{:.0f}"),
    ("unattributed.GOLD", "{:.0f}"),
    ("upgrade.BLUE", "{:.0f}"), ("upgrade.RED", "{:.0f}"), ("upgrade.GOLD", "{:.0f}"),
    ("capitals", "{:d}"), ("too_close", "{:d}"),
    ("build_blackout.BLUE", "{:.1f}%"), ("build_blackout.RED", "{:.1f}%"),
    ("build_blackout.GOLD", "{:.1f}%"),
    ("decisions", "{:.0f}"), ("retained_pct", "{:.1f}%"), ("switches", "{:.0f}"),
    ("order_success_pct", "{:.1f}%"),
    ("losses", "{:d}"), ("losses.BLUE", "{:d}"), ("losses.RED", "{:d}"), ("losses.GOLD", "{:d}"),
    ("friendly", "{:d}"), ("operations", "{:d}"),
    ("station_damage", "{:.0f}"), ("station_damage_attributed", "{:.0f}"),
)


def compare(current, baseline, current_label, baseline_label):
    """Side-by-side of the metrics this tool already computes. compare_batches.py
    and ai_timeline.py supersede this for real A/B work."""
    print("\n-- side-by-side --")
    print(f"  {'metric':22} {current_label:>16} {baseline_label:>16} {'delta':>16}")
    for name, fmt in COMPARE_ROWS:
        left = current.get(name, 0)
        right = baseline.get(name, 0)
        try:
            if fmt.endswith("d}"):
                delta = fmt.format(int(left) - int(right))
            else:
                delta = fmt.format(float(left) - float(right))
        except (ValueError, TypeError):
            delta = "-"
        print(f"  {name:22} {fmt.format(left):>16} {fmt.format(right):>16} {delta:>16}")
    print(f"  {'outcomes':22} {str(current['outcomes']):>16}")
    print(f"  {'':22} {str(baseline['outcomes']):>16}")
    print("  note: compare_batches.py and ai_timeline.py supersede this table for")
    print("        real A/B and per-match timeline work; it only restates these metrics.")


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------

def discover_jobs(root: Path):
    """A match is a run folder. Find them by engine-result.json OR by telemetry,
    because a cap-terminated run has no engine-result.json at all, and key each
    job on the telemetry FILE so two matches flattened into one folder stay two
    matches instead of one."""
    orphans = {path.parent for path in root.rglob("engine-result.json")}
    jobs = []
    for path in sorted(root.rglob("rts-ai-*.jsonl")):
        run = path.parent
        if run.name == "data" and run.parent.name == "probe":
            run = run.parent.parent
        orphans.discard(run)
        jobs.append((run, path))
    jobs.extend((run, None) for run in sorted(orphans))
    return sorted(jobs, key=lambda job: (str(job[0]), str(job[1])))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    if not args.output_dir.is_dir():
        raise SystemExit(f"No such batch output: {args.output_dir}")
    jobs = discover_jobs(args.output_dir)
    if not jobs:
        raise SystemExit(f"No engine-result.json or rts-ai-*.jsonl under {args.output_dir}")
    current = report([analyze(run, telemetry) for run, telemetry in jobs], "CURRENT MOD", True)
    if args.baseline and args.baseline.is_dir():
        base_jobs = discover_jobs(args.baseline)
        if not base_jobs:
            print(f"\n(no engine-result.json or telemetry under baseline {args.baseline})")
        else:
            baseline = report([analyze(run, telemetry) for run, telemetry in base_jobs],
                              "BASELINE", True)
            compare(current, baseline, "current", "baseline")
    return 0 if current["crashed"] == 0 and current["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())