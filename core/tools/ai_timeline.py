"""Turn the mod's headless AI telemetry into a readable per-faction timeline.

The engine dumps 20,000-26,000 JSONL records per match across 22 event types.
This tool streams each file once, keeps only compact per-bucket accumulators,
and answers the four questions a maintainer has after a headless run:

  1. What did each faction's numbers do over time, properly aggregated?
  2. What state transitions did the AI go through, and when?
  3. What went wrong, with a time window and evidence?
  4. How did the match end, and who damaged what?

    python tools/ai_timeline.py <batch-or-run-dir> [--faction GOLD]
                                [--from 0 --to 1800] [--resolution 60]
                                [--json out.json] [--events]

engine-result.json is deliberately NOT required: these runs hit the engine's
-max-sim-time, the process is killed, and the engine never flushes it.

INTERVAL vs CUMULATIVE vs GAUGE -- the traps this file exists partly to avoid.
data.economy.flow.productionSpend is an INTERVAL flow, not a total.
fs2rts_ai_planning.lua emits the FACTION record and then, on the next line,
runs self.AIEconomyFlow[kind]={income=0,productionSpend=0,bounty=0,refund=0}.
So the LAST FACTION record of any run reports productionSpend 0.0 no matter how
much was built.  Read as a total that prints 0 and reads as "the AI never built
anything", which is the opposite of the truth.  Everything here sums the
intervals, and cross-checks the sum against PRODUCTION/QUEUE_ACCEPTED cost plus
SENTRY_BUILD cost plus FLEET_SERVICE_WORK.spent. Both numbers are printed side
by side so the reconciliation stays visible, and CP_SPEND -- one record per CP
movement through RecordAIEconomyFlow -- is summed alongside them as the check
that must hold at zero drift.

Two further readings, verified against real batches:

  FACTION.losses is CUMULATIVE per sample. AIStats.losses is passed straight
  through and never reset, so the series is a running count. Summing it
  multiplies every loss by the sample count.

  FACTION.offense is a GAUGE and not an interval flow, despite resetting to 0
  each sample like one. It is the fleet value currently assigned to
  PRIMARY/ESCORT missions and is rebuilt from scratch on every FACTION record,
  so it rises when missions are assigned and falls when groups are released. A
  real BLUE series runs 0, 1264, 1264, 2423, 0, 1231, 2044, 3417, 2860, 1353,
  3304, 0 - it returns to 0 inside a single match. Summing it gives a number
  that grows with the sample count and measures neither damage nor spend, which
  is why it is reported as a mean/max/last triple instead.

Others confirmed correct and read accordingly: FACTION.received is cumulative;
FACTION.replacementValueByClass is SURVIVING fleet value built from the same
walk as composition, not a loss cost; OUTCOME_CAUSE.snapshot.*.stationHull is a
FRACTION under the same key name FACTION.stationHull uses for an absolute figure;
COUNTERS records carry no faction field and are cumulative.
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path

TELEMETRY_GLOB = "rts-ai-*.jsonl"
BLOCKS = " .:-=+*#%@"
PHASES = ("ASSEMBLE", "APPROACH", "ENGAGE", "EXPLOIT", "WITHDRAW")
PHASE_INDEX = {name: i for i, name in enumerate(PHASES)}
BUY_REASONS = {"PURCHASE_SELECTED", "EMERGENCY_DEFENSE_PURCHASE"}
DEFER_REASONS = {"SAVING_FOR_DESIRED_ROLE"}
ALL_FACTIONS = "_all"

# A deferral window whose bank closed at least this fraction of the remaining
# gap to its bankTarget is the AI saving correctly, not stalling.  Measured in
# session-fix-20260930 the successful capital saves closed 81-100% of the gap
# (bank 1,286 -> 11,496 against a 13,825 CP target); a genuine stall closes ~0.
# Half is a deliberately conservative split that keeps genuinely stuck factions
# flagged even when some unrelated income trickles in.
SAVING_ON_TRACK_FRACTION = 0.5

# Default anomaly thresholds.  Every one is overridable on the command line so a
# maintainer can tune against a batch they already understand.
THRESHOLDS = {
    "blackout_seconds": 90.0,      # defer run length before it is called a blackout
    "stuck_reason_seconds": 120.0,  # any single AI_BUILD_DECISION reason held this long
    "idle_seconds": 90.0,          # sustained FACTION.idle > 0
    "stalled_seconds": 45.0,       # contiguous buckets reporting stalled groups
    "unengaged_fraction": 0.90,    # unengagedSeconds / unitSeconds
    "flap_per_minute": 2.0,        # posture transitions per minute
    "thrash_entries": 3,           # service entries for one ship inside the window
    "thrash_window": 180.0,
    "friendly_fire_cluster": 3,    # hits inside one cluster window
    "friendly_fire_gap": 60.0,
    "order_failure_min": 1.0,
    "reissue_per_minute": 3.0,
}


# ----------------------------------------------------------------- utilities

def num(value):
    """Coerce a telemetry number, tolerating the "unknown" strings the mod emits."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def first_num(source, *keys):
    if not isinstance(source, dict):
        return None
    for key in keys:
        got = num(source.get(key))
        if got is not None:
            return got
    return None


def fmt(value, digits=0):
    got = num(value)
    if got is None:
        return "-"
    return f"{got:,.{digits}f}" if digits else f"{got:,.0f}"


def clamp(value, low, high):
    return low if value < low else (high if value > high else value)


def ratio(part, whole):
    part, whole = num(part), num(whole)
    if part is None or not whole:
        return None
    return part / whole


def as_percent(part, whole):
    got = ratio(part, whole)
    return None if got is None else 100.0 * got


def buckets_of(time, resolution):
    return int(time // resolution)


def sparkline(series, width=0):
    """Block-glyph sparkline, one glyph per bucket, scaled over the series range."""
    if not series:
        return ""
    if width and len(series) > width:
        series = resample(series, width)
    values = [v for v in series if v is not None]
    if not values:
        return " " * len(series)
    low, high = min(values), max(values)
    span = high - low
    top = len(BLOCKS) - 1
    out = []
    for value in series:
        if value is None:
            out.append(BLOCKS[0])
        elif span <= 0:
            out.append(BLOCKS[top])
        else:
            out.append(BLOCKS[clamp(int(round((value - low) / span * top)), 0, top)])
    return "".join(out)


def resample(series, width):
    """Mean-resample down to `width` points so a 2600 s match still fits a terminal."""
    if len(series) <= width:
        return list(series)
    count = len(series)
    out = []
    for slot in range(width):
        start = slot * count // width
        end = max(start + 1, (slot + 1) * count // width)
        chunk = [v for v in series[start:end] if v is not None]
        out.append(sum(chunk) / len(chunk) if chunk else None)
    return out


# ------------------------------------------------------------- run discovery

def find_telemetry(target: Path):
    """Telemetry lives at results/w/<worker>/a-<id>/probe/data/rts-ai-*.jsonl.
    Prefer results/ so we never walk the multi-gigabyte base/ workspace, and
    fall back to a full rglob for a single harvested run directory."""
    for root in ([target / "results", target] if (target / "results").is_dir() else [target]):
        found = sorted(root.rglob(TELEMETRY_GLOB))
        if found:
            return found
    return []


def batch_plan(target: Path):
    """batch.plan.json carries max_sim_time, the only way to tell a
    simulation-cap stop from a truncated kill without engine-result.json."""
    for candidate in [target, *target.parents]:
        plan = candidate / "batch.plan.json"
        if plan.is_file():
            try:
                return json.loads(plan.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return {}
    return {}


# --------------------------------------------------------------- accumulators

def new_bucket(index, start, end):
    return {
        "index": index, "t": start, "t_end": end, "n": 0,
        "combatants": None, "combatants_max": None,
        "idle": None, "idle_max": None,
        "cp": None, "cp_min": None, "cp_max": None,
        "cum_spend": None, "spend": 0.0,
        "income": 0.0, "bounty": 0.0, "refund": 0.0,
        "fleet_cap": None, "cap_util": None,
        "hull": None, "hull_pct": None,
        "dealt": None, "received": None,
        "posture": None, "missions": {}, "objectives": {},
        "emergency": False, "critical": False, "urgent": False,
        "stalled": None, "unengaged": None, "unit_seconds": None,
        "servicing": 0, "service_max": None,
        "losses": 0, "loss_value": 0.0, "spawned": 0, "queued_cost": 0.0,
        "reissued": 0.0, "switches": 0.0,
        "orders_failed": 0.0, "orders_rejected": 0.0,
        "orders_attempts": 0.0, "orders_success": 0.0,
    }


def new_faction(name):
    return {
        "name": name, "buckets": {},
        "cum_spend": 0.0, "cum_queued": 0.0, "cum_income": 0.0,
        "cum_bounty": 0.0, "cum_refund": 0.0,
        "cum_dealt": 0.0, "cum_received": None, "received_resets": 0,
        # FACTION.offense is a gauge (current PRIMARY/ESCORT fleet value), not a
        # flow, so it gets a mean/max/last triple rather than a running sum.
        "offense_sum": 0.0, "offense_samples": 0, "offense_max": None, "offense_last": None,
        "cp_spend_ledger": 0.0, "cp_spend_entries": 0, "cp_service": 0.0,
        "repair_unlocked": False,
        "losses": {}, "loss_count": 0, "loss_value": 0.0,
        "units_spawned": 0, "queued_count": 0,
        "sentries": 0, "sentry_cost": 0.0, "sentry_checkpoints": [],
        "queued_checkpoints": [],
        "last_cp": None, "max_cp": 0.0,
        "last_hull": None, "last_hull_pct": None,
        "last_combatants": None, "last_fleet_cap": None, "last_value": None,
        "last_posture": None, "last_plan_missions": {},
        "max_idle": 0.0, "max_servicing": 0,
        "first_seen": None, "last_seen": None,
        "emergency_first": None, "critical_first": None, "urgent_first": None,
        "emergency_total": 0, "critical_total": 0,
        "unengaged": 0.0, "unit_seconds": 0.0,
        "spend_checkpoints": [], "posture_history": [],
        "operation_phases": [],
        "service_entries": collections.defaultdict(list),
        "service_phases": collections.Counter(), "service_reasons": collections.Counter(),
        "friendly_fire_times": [], "friendly_fire_detail": collections.Counter(),
        "build_decisions": 0, "build_reasons": collections.Counter(),
        "execution_status": collections.Counter(), "execution_modes": collections.Counter(),
        "objective_status": collections.Counter(),
        "orders": collections.defaultdict(lambda: collections.Counter()),
        "order_failed": 0.0, "order_rejected": 0.0, "order_attempts": 0.0,
        "order_success": 0.0, "order_unchanged": 0.0,
        "reissued": 0.0, "switches": 0.0,
    }


def new_span(kind, start):
    return {
        "kind": kind, "start": start, "end": start, "n": 0,
        "max_cp": 0.0, "max_affordable": 0.0, "min_cp": None,
        "reasons": collections.Counter(), "tiers": collections.Counter(),
        "roles": collections.Counter(), "bank_targets": collections.Counter(),
        "max_slots": 0.0,
    }


class _SpanTracker:
    """Tracks one kind of contiguous span per faction and archives finished runs."""

    def __init__(self, kind):
        self.kind = kind
        self.open = {}
        self.done = collections.defaultdict(list)

    def feed(self, faction, time, active):
        """Returns the OPEN span to accumulate into, or None when inactive.

        Closing returns nothing on purpose: a caller that records into a span it
        just closed would attribute the closing record to the finished span.
        """
        if active:
            span = self.open.get(faction)
            if span is None:
                span = new_span(self.kind, time)
                self.open[faction] = span
            span["end"] = time
            return span
        self.close(faction, time)
        return None

    def close(self, faction, time):
        """Archive the open span. `end` stays at the last ACTIVE observation.

        It must not be moved to the closing record's time: for a deferral the
        closing record is the purchase decision, and folding that timestamp in
        would pull the purchase itself inside the window the anomaly is about.
        """
        span = self.open.pop(faction, None)
        if span is not None:
            self.done[faction].append(span)
        return span

    def close_all(self, end_time):
        for faction in list(self.open):
            self.close(faction, end_time)


# --------------------------------------------------------------- the streamer

class MatchTimeline:
    """One match's telemetry folded into compact accumulators in a single pass.

    No parsed record is retained.  What survives is one small dict per
    (faction, time bucket), a few bounded event lists used as anomaly evidence,
    and counters.
    """

    def __init__(self, path, resolution=60.0):
        self.path = Path(path)
        self.resolution = float(resolution) if resolution and resolution > 0 else 60.0
        self.records = 0
        self.malformed = 0
        self.truncated_tail = False
        self.events = collections.Counter()
        self.factions = {}
        self.first_time = None
        self.last_time = None
        self.first_seq = None
        self.last_seq = None
        self.seq_regressions = 0
        self.run_meta = {}
        self.setup = {}
        self.outcome_causes = []
        self.battle_end = None
        self.beam_hits = collections.Counter()
        self.base_damage = collections.defaultdict(lambda: {"hits": 0.0, "hull": 0.0})
        self.base_elapsed = None
        self.defer_spans = _SpanTracker("defer")
        self.reason_spans = _SpanTracker("reason")
        self.no_option_spans = _SpanTracker("no_option")
        self.idle_spans = _SpanTracker("idle")
        self.stalled_spans = _SpanTracker("stalled")
        self._counter_state = {}
        self._counter_deltas = []

    # -- helpers ---------------------------------------------------------
    def faction(self, name):
        acc = self.factions.get(name)
        if acc is None:
            acc = new_faction(name)
            self.factions[name] = acc
        return acc

    def bucket(self, acc, time):
        index = buckets_of(time, self.resolution)
        slot = acc["buckets"].get(index)
        if slot is None:
            slot = new_bucket(index, index * self.resolution,
                              (index + 1) * self.resolution)
            acc["buckets"][index] = slot
        return slot

    @staticmethod
    def _put(target, key, value, mode="last"):
        if value is None:
            return
        if mode == "last":
            target[key] = value
        elif mode == "max":
            if target.get(key) is None or value > target[key]:
                target[key] = value
        elif mode == "min":
            if target.get(key) is None or value < target[key]:
                target[key] = value

    def real_factions(self):
        return sorted(f for f in self.factions if f != ALL_FACTIONS)

    # -- main loop -------------------------------------------------------
    def consume(self):
        handlers = {
            "RUN": self.on_run, "ACCEPTANCE_SETUP": self.on_setup,
            "FACTION": self.on_faction, "AI_BUILD_DECISION": self.on_build,
            "PRODUCTION": self.on_production, "SENTRY_BUILD": self.on_sentry,
            "COUNTERS": self.on_counters, "OBJECTIVE": self.on_objective,
            "LOSS": self.on_loss, "DECISION": self.on_decision,
            "OPERATION": self.on_operation, "CONTEST": self.on_contest,
            "EXECUTION": self.on_execution, "FLEET_SERVICE": self.on_service,
            "FLEET_SERVICE_INTERRUPTED": self.on_service_interrupted,
            "FRIENDLY_HIT": self.on_friendly_fire, "STATION_BEAM_HIT": self.on_beam_hit,
            "FLEET_SERVICE_WORK": self.on_service_work,
            "CP_SPEND": self.on_cp_spend,
            "OUTCOME_CAUSE": self.on_outcome_cause, "BATTLE_END": self.on_battle_end,
        }
        with self.path.open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    # A killed run leaves a half-written final line.  Count it,
                    # keep going; one bad line must not lose a whole batch.
                    self.malformed += 1
                    self.truncated_tail = True
                    continue
                if not isinstance(record, dict):
                    self.malformed += 1
                    continue
                event = record.get("event")
                self.records += 1
                self.events[event] += 1
                time = num(record.get("time")) or 0.0
                sequence = num(record.get("sequence"))
                if self.first_time is None or time < self.first_time:
                    self.first_time = time
                if self.last_time is None or time > self.last_time:
                    self.last_time = time
                if sequence is not None:
                    if self.first_seq is None:
                        self.first_seq = sequence
                    elif sequence < self.last_seq:
                        self.seq_regressions += 1
                    self.last_seq = sequence
                data = record.get("data")
                handler = handlers.get(event)
                if handler is not None:
                    handler(time, data if isinstance(data, dict) else {})
        tail = self.last_time or 0.0
        self.defer_spans.close_all(tail)
        self.reason_spans.close_all(tail)
        self.no_option_spans.close_all(tail)
        self.idle_spans.close_all(tail)
        self.stalled_spans.close_all(tail)
        return self

    # -- handlers --------------------------------------------------------
    def on_run(self, time, data):
        keep = ("planner", "difficulty", "distance", "economy", "factions",
                "normalStart", "detailedDecisionTelemetry", "detailedUnitTelemetry")
        self.run_meta = {k: data.get(k) for k in keep if k in data}

    def on_setup(self, time, data):
        self.setup = data

    def on_faction(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        acc = self.faction(faction)
        slot = self.bucket(acc, time)
        plan = data.get("plan") if isinstance(data.get("plan"), dict) else {}
        economy = data.get("economy") if isinstance(data.get("economy"), dict) else {}
        flow = economy.get("flow") if isinstance(economy.get("flow"), dict) else {}

        acc["first_seen"] = time if acc["first_seen"] is None else min(acc["first_seen"], time)
        acc["last_seen"] = time

        # ---- interval flows: SUM.  The mod zeroes AIEconomyFlow immediately
        # after emitting this record, so each value covers one window only.
        spend = num(flow.get("productionSpend"))
        if spend:
            acc["cum_spend"] += spend
            slot["spend"] += spend
        for key, field in (("income", "cum_income"), ("bounty", "cum_bounty"),
                           ("refund", "cum_refund")):
            amount = num(flow.get(key))
            if amount:
                acc[field] += amount
                slot[key] += amount
        acc["spend_checkpoints"].append((time, acc["cum_spend"], num(economy.get("commandPoints"))))
        slot["cum_spend"] = acc["cum_spend"]

        # ---- gauges: last observation in the window wins.
        cp = first_num(economy, "commandPoints")
        self._put(slot, "cp", cp)
        self._put(slot, "cp_min", cp, "min")
        self._put(slot, "cp_max", cp, "max")
        if cp is not None:
            acc["last_cp"] = cp
            self._put(acc, "max_cp", cp, "max")

        combatants = first_num(economy, "combatants")
        if combatants is None:
            combatants = first_num(data, "combatants", "committedUnits")
        self._put(slot, "combatants", combatants)
        self._put(slot, "combatants_max", combatants, "max")
        acc["last_combatants"] = combatants

        fleet_cap = num(economy.get("fleetCap"))
        slot["fleet_cap"] = fleet_cap
        acc["last_fleet_cap"] = fleet_cap
        if fleet_cap:
            util = as_percent(combatants, fleet_cap)
            self._put(slot, "cap_util", util, "max")

        idle = num(data.get("idle"))
        self._put(slot, "idle", idle)
        self._put(slot, "idle_max", idle, "max")
        if idle is not None:
            self._put(acc, "max_idle", idle, "max")

        # Station self-repair is gated on ARMOR L2 (fs2rts_station.lua), so
        # STATION_REPAIR reporting 0 hull restored means the gate was never
        # bought unless this says otherwise. Without it the two are
        # indistinguishable and every station-repair analysis reads as broken.
        if economy.get("repairUnlocked") is True:
            acc["repair_unlocked"] = True

        servicing = num(data.get("servicing"))
        self._put(slot, "servicing", servicing, "max")
        self._put(slot, "service_max", servicing, "max")
        if servicing is not None:
            self._put(acc, "max_servicing", servicing, "max")

        hull = num(data.get("stationHull"))
        slot["hull"] = hull
        hull_pct = as_percent(data.get("stationHull"), data.get("stationMax"))
        self._put(slot, "hull_pct", hull_pct)
        acc["last_hull"] = hull
        if hull_pct is not None:
            acc["last_hull_pct"] = hull_pct

        # Damage semantics differ per field and were checked against real runs:
        #   received - monotone, never decreases -> already cumulative, take last
        #   offense  - a GAUGE, not a flow: it is the fleet value assigned to
        #               PRIMARY/ESCORT missions, rebuilt from scratch in every
        #               FACTION record, so it rises when missions are assigned and
        #               falls back when groups are released. Summing it produced a
        #               number that grows with the sample count and reads as
        #               "damage dealt" while measuring neither damage nor spend.
        #               Real BLUE series: 0, 1264, 1264, 2423, 0, 1231, 2044, 3417,
        #               2860, 1353, 3304, 0 - it returns to 0 within a match.
        #               Taken as mean/max/last instead.
        #   combatDamageTelemetry.interval.hullDamage - interval, sum it
        # Treating `received` as an interval would multiply the total by the
        # number of windows.
        combat = data.get("combatDamageTelemetry")
        combat = combat if isinstance(combat, dict) else {}
        interval = combat.get("interval") if isinstance(combat.get("interval"), dict) else {}
        dealt = num(interval.get("hullDamage"))
        if dealt is None:
            dealt = num(data.get("damageDealt"))
        offense = num(data.get("offense"))
        if dealt:
            acc["cum_dealt"] += dealt
        if offense is not None:
            acc["offense_sum"] += offense
            acc["offense_samples"] += 1
            acc["offense_max"] = offense if acc["offense_max"] is None else max(acc["offense_max"], offense)
            acc["offense_last"] = offense
        received = num(data.get("received"))
        if received is not None and (acc["cum_received"] is None
                                     or received >= acc["cum_received"]):
            acc["cum_received"] = received
        else:
            acc["received_resets"] += 1
        slot["dealt"] = acc["cum_dealt"]
        slot["received"] = acc["cum_received"]

        posture = plan.get("posture")
        if posture:
            slot["posture"] = slot["posture"] or posture
            if acc["last_posture"] != posture:
                acc["posture_history"].append((time, posture))
                acc["last_posture"] = posture
        counts = plan.get("missionCounts")
        if isinstance(counts, dict) and counts:
            acc["last_plan_missions"] = dict(counts)

        for flag, total_key, first_key in (("emergency", "emergency_total", "emergency_first"),
                                           ("critical", "critical_total", "critical_first"),
                                           ("urgent", None, "urgent_first")):
            if plan.get(flag):
                slot[flag] = True
                if total_key:
                    acc[total_key] += 1
                if acc[first_key] is None:
                    acc[first_key] = time

        stalled = num(data.get("stalled"))
        self._put(slot, "stalled", stalled, "max")
        self._put(slot, "unengaged", num(data.get("unengagedSeconds")))
        self._put(slot, "unit_seconds", num(data.get("unitSeconds")))
        acc["unengaged"] = num(data.get("unengagedSeconds")) or acc["unengaged"]
        acc["unit_seconds"] = num(data.get("unitSeconds")) or acc["unit_seconds"]

        value = num(data.get("value"))
        if value is not None:
            acc["last_value"] = value
        if data.get("baseDamageTelemetry"):
            self._absorb_base_damage(faction, data["baseDamageTelemetry"])

        slot["n"] += 1
        self.idle_spans.feed(faction, time, bool(idle))
        self.stalled_spans.feed(faction, time, bool(stalled))

    def _absorb_base_damage(self, station_faction, telemetry):
        """baseDamageTelemetry.cumulative.byWeapon is a CUMULATIVE snapshot of
        damage done TO the emitting faction's station, keyed by attacking
        faction and weapon class.

        It is emitted once per FACTION record, so it must be REPLACED, not
        accumulated: adding each snapshot would multiply the totals by the
        number of telemetry windows.
        """
        cumulative = telemetry.get("cumulative")
        cumulative = cumulative if isinstance(cumulative, dict) else {}
        self.base_elapsed = num(cumulative.get("elapsedSeconds"))
        for entry in cumulative.get("byWeapon") or ():
            if not isinstance(entry, dict):
                continue
            attacker = entry.get("attackerFaction") or "UNKNOWN"
            weapon = entry.get("weaponClass") or "?"
            key = (station_faction, attacker, weapon, bool(entry.get("beamWeapon")))
            slot = self.base_damage[key]
            slot["hits"] = num(entry.get("hitCount")) or 0.0
            slot["hull"] = num(entry.get("hullDamage")) or 0.0

    def on_build(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        acc = self.faction(faction)
        acc["build_decisions"] += 1
        reason = data.get("reason") or "UNKNOWN"
        acc["build_reasons"][reason] += 1
        affordable = first_num(data, "affordableOptions")
        if affordable is None:
            affordable = float(len([o for o in (data.get("options") or ())
                                    if isinstance(o, dict) and o.get("affordable")]))
        cp = num(data.get("commandPoints")) or 0.0
        target = num(data.get("bankTarget"))
        tier = num(data.get("tier"))
        role = data.get("desiredRole")
        slots = first_num(data, "slots")
        bought = reason in BUY_REASONS

        def record(span):
            if span is None:
                return
            span["n"] += 1
            span["max_cp"] = max(span["max_cp"], cp)
            span["min_cp"] = cp if span["min_cp"] is None else min(span["min_cp"], cp)
            span["max_affordable"] = max(span["max_affordable"], affordable)
            span["reasons"][reason] += 1
            if tier is not None:
                span["tiers"][tier] += 1
            if role:
                span["roles"][role] += 1
            if target is not None:
                span["bank_targets"][target] += 1
            if slots is not None:
                span["max_slots"] = max(span["max_slots"], slots)

        if bought:
            self.defer_spans.feed(faction, time, False)
            self.no_option_spans.feed(faction, time, False)
            self.reason_spans.close(faction, time)
            return
        if affordable > 0:
            # Options were affordable and the AI still declined to buy.
            record(self.defer_spans.feed(faction, time, True))
            self.no_option_spans.feed(faction, time, False)
        else:
            self.defer_spans.feed(faction, time, False)
            record(self.no_option_spans.feed(faction, time, True))
        # "Stuck on one reason" is a per-reason run, so it closes whenever the
        # reason changes. Keyed by faction; the reason is carried on the span.
        open_span = self.reason_spans.open.get(faction)
        if open_span is not None and open_span["reasons"] and \
                open_span["reasons"].most_common(1)[0][0] != reason:
            self.reason_spans.close(faction, time)
            open_span = None
        record(self.reason_spans.feed(faction, time, True))

    def on_production(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        acc = self.faction(faction)
        slot = self.bucket(acc, time)
        action = data.get("action")
        cost = num(data.get("cost"))
        if action == "QUEUE_ACCEPTED":
            if cost:
                acc["cum_queued"] += cost
                slot["queued_cost"] += cost
            acc["queued_count"] += 1
            # Discrete purchase events with exact timestamps. Used to decide
            # whether a deferral window really contained zero purchases, because
            # the economy.flow interval bucket straddles the closing purchase.
            if cost:
                acc["queued_checkpoints"].append((time, acc["cum_queued"]))
        elif action == "UNIT_SPAWNED":
            spawned = int(first_num(data, "spawnedCount", "count") or 0)
            acc["units_spawned"] += spawned
            slot["spawned"] += spawned

    def on_sentry(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        acc = self.faction(faction)
        acc["sentries"] += 1
        cost = num(data.get("cost")) or 0.0
        acc["sentry_cost"] += cost
        # Sentry construction is recorded into the SAME economy.productionSpend
        # interval flow as unit purchases (fs2rts_station.lua), but it never
        # passes through the AI_BUILD_DECISION loop. Track it separately so a
        # blackout window's residual spend can be attributed.
        acc["sentry_checkpoints"].append((time, acc["sentry_cost"]))

    def on_service_work(self, time, data):
        """Fleet service spends out of the same bank as everything else and lands in
        economy.flow.productionSpend, so it is a spend path. `spent` is this
        tick's charge; `totalSpent` is the ship's running total and summing it
        would multiply the cost by the tick count."""
        faction = data.get("faction")
        if not faction:
            return
        acc = self.faction(faction)
        spent = num(data.get("spent"))
        if spent:
            acc["cp_service"] += spent

    def on_cp_spend(self, time, data):
        """CP_SPEND is one record per CP movement through RecordAIEconomyFlow, the
        single chokepoint that writes economy.flow. It is the only spend series
        that covers the station upgrade track and the faction ability, neither of
        which publishes a purchase event, so it reconciles against the flow sum
        where QUEUE_ACCEPTED plus SENTRY_BUILD cannot."""
        if data.get("flow") != "productionSpend":
            return
        faction = data.get("faction")
        if not faction:
            return
        acc = self.faction(faction)
        amount = num(data.get("amount"))
        if amount:
            acc["cp_spend_ledger"] += amount
            acc["cp_spend_entries"] += 1

    def on_counters(self, time, data):
        """COUNTERS is cumulative and global (no faction field).  Deltas give the
        per-window order pressure that drives the reissue-storm anomaly."""
        orders = data.get("orders") if isinstance(data.get("orders"), dict) else {}
        current = {
            "attempts": first_num(orders, "attempts") or 0.0,
            "success": first_num(orders, "success") or 0.0,
            "failed": first_num(orders, "failed") or 0.0,
            "rejected": first_num(orders, "rejected") or 0.0,
            "unchanged": first_num(orders, "unchanged") or 0.0,
            "reissued": num(data.get("reissued")) or 0.0,
            "switches": num(data.get("switches")) or 0.0,
            "decisions": num(data.get("decisions")) or 0.0,
            "time": time,
        }
        previous = self._counter_state.get("global")
        if previous is not None and current["time"] > previous["time"]:
            delta = {k: current[k] - previous[k] for k in
                     ("attempts", "success", "failed", "rejected", "unchanged",
                      "reissued", "switches", "decisions")}
            delta["span"] = current["time"] - previous["time"]
            self._counter_deltas.append((current["time"], delta))
            slot = self.bucket(self.faction(ALL_FACTIONS), time)
            for key in ("attempts", "success", "failed", "rejected", "unchanged"):
                slot["orders_" + key] = (slot.get("orders_" + key) or 0.0) + max(0.0, delta[key])
            slot["reissued"] = (slot["reissued"] or 0.0) + max(0.0, delta["reissued"])
            slot["switches"] = (slot["switches"] or 0.0) + max(0.0, delta["switches"])
        self._counter_state["global"] = current

        # Per-faction order outcomes live in orders.byMission[faction][mission].
        by_mission = orders.get("byMission")
        if isinstance(by_mission, dict):
            for faction_name, missions in by_mission.items():
                if not isinstance(missions, dict):
                    continue
                acc = self.faction(faction_name)
                for mission, outcome in missions.items():
                    if not isinstance(outcome, dict):
                        continue
                    row = acc["orders"][mission]
                    for key in ("failed", "rejected", "success", "unchanged"):
                        row[key] += num(outcome.get(key)) or 0.0

    def on_objective(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        acc = self.faction(faction)
        slot = self.bucket(acc, time)
        mission = data.get("mission") or "UNKNOWN"
        slot["objectives"][mission] = slot["objectives"].get(mission, 0) + 1
        if data.get("status"):
            acc["objective_status"][data["status"]] += 1

    def on_loss(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        acc = self.faction(faction)
        cls = data.get("class") or "UNKNOWN"
        acc["losses"][cls] = acc["losses"].get(cls, 0.0) + 1.0
        acc["loss_count"] += 1
        value = num(data.get("baseUnitCost")) or 0.0
        acc["loss_value"] += value
        slot = self.bucket(acc, time)
        slot["losses"] += 1
        slot["loss_value"] += value

    def on_decision(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        slot = self.bucket(self.faction(faction), time)
        mission = data.get("mission")
        if mission:
            slot["missions"][mission] = slot["missions"].get(mission, 0) + 1

    def on_operation(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        self.faction(faction)["operation_phases"].append(
            (time, data.get("phase"), data.get("reason"),
             data.get("serial"), data.get("front")))

    def on_contest(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        slot = self.bucket(self.faction(faction), time)
        self._put(slot, "stalled", num(data.get("stalledGroups")), "max")
        self._put(slot, "service_max", num(data.get("servicedShips")), "max")
        counts = data.get("missionCounts")
        if isinstance(counts, dict):
            for mission, value in counts.items():
                slot["missions"][mission] = slot["missions"].get(mission, 0) + (num(value) or 0.0)

    def on_execution(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        acc = self.faction(faction)
        if data.get("status"):
            acc["execution_status"][data["status"]] += 1
        if data.get("mode"):
            acc["execution_modes"][data["mode"]] += 1

    def on_service(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        acc = self.faction(faction)
        acc["service_phases"][data.get("phase") or "UNKNOWN"] += 1
        if data.get("reason"):
            acc["service_reasons"][data["reason"]] += 1
        ship = data.get("ship")
        slot = self.bucket(acc, time)
        slot["servicing"] = (slot["servicing"] or 0) + 1
        if ship is not None:
            entries = acc["service_entries"][ship]
            if len(entries) < 400:
                entries.append(time)

    def on_service_interrupted(self, time, data):
        faction = data.get("faction")
        if not faction:
            return
        self.faction(faction)["service_reasons"]["INTERRUPTED"] += 1

    def on_friendly_fire(self, time, data):
        faction = data.get("faction") or "UNKNOWN"
        acc = self.faction(faction)
        if len(acc["friendly_fire_times"]) < 500:
            acc["friendly_fire_times"].append(time)
        acc["friendly_fire_detail"][
            (data.get("sourceKind") or "?", str(data.get("evidence") or "")[:48])] += 1

    def on_beam_hit(self, time, data):
        key = ((data.get("attackerFaction") or "?"), (data.get("targetFaction") or "?"))
        self.beam_hits[key] += 1

    def on_outcome_cause(self, time, data):
        if len(self.outcome_causes) < 16:
            self.outcome_causes.append((time, data))

    def on_battle_end(self, time, data):
        if self.battle_end is None:
            self.battle_end = (time, data)

    # -- views -----------------------------------------------------------
    def series(self, faction):
        acc = self.factions.get(faction)
        if acc is None:
            return []
        return [acc["buckets"][i] for i in sorted(acc["buckets"])]


# ----------------------------------------------------------------- anomalies

def _value_at(checkpoints, time, inclusive=True):
    """Running total of `checkpoints` as of `time`.

    inclusive=True counts a checkpoint landing exactly on `time`; False excludes
    it. Excluding the endpoint matters when bracketing a deferral window: the
    purchase that CLOSES the window lands at or after its end and must not be
    counted as spend inside the window.
    """
    total = 0.0
    for row in checkpoints:
        if (row[0] <= time) if inclusive else (row[0] < time):
            total = row[1]
        else:
            break
    return total


def _spend_in_window(checkpoints, start, end):
    """Total booked strictly inside (start, end] -> excludes the closing purchase."""
    return max(0.0, _value_at(checkpoints, end, False) - _value_at(checkpoints, start, True))


def _delta_between(checkpoints, start, end, field=1):
    """Loose bracket of a running-total list: value at or before `start`, and the
    first value at or after `end`. Used for the flow field, whose interval bucket
    genuinely straddles the window edge."""
    before, after = 0.0, None
    for row in checkpoints:
        if row[0] <= start:
            before = row[field]
        if row[0] >= end and after is None:
            after = row[field]
    if after is None and checkpoints:
        after = checkpoints[-1][field]
    return before, (after if after is not None else before)


def _spend_between(acc, start, end):
    return _delta_between(acc["spend_checkpoints"], start, end)


def detect_anomalies(match, limits=None):
    limits = dict(THRESHOLDS, **(limits or {}))
    found = []
    for faction in match.real_factions():
        acc = match.factions[faction]
        found += _production_blackout(match, acc, limits)
        found += _stuck_reason(match, acc, limits)
        found += _sustained_idle(match, acc, limits)
        found += _order_pressure(match, acc, limits)
        found += _stall_and_engagement(match, acc, limits)
        found += _posture_flapping(match, acc, limits)
        found += _service_thrash(match, acc, limits)
        found += _friendly_fire(match, acc, limits)
    found += _global_order_failures(match, limits)
    found.sort(key=lambda a: (a["severity"], -a["duration"]))
    return found


def _anomaly(**kw):
    kw.setdefault("severity", "warn")
    kw.setdefault("evidence", {})
    kw.setdefault("cause", "")
    return kw


def _production_blackout(match, acc, limits):
    """The acceptance anomaly.

    A run of AI_BUILD_DECISION records where roster options were affordable and
    the AI still did not buy. The evidence is deliberately stated as what was
    actually measured - zero purchases, and a bank that grew across the window -
    rather than "spend was flat", because the flow bucket that straddles the
    closing purchase still books spend inside the window.

    Three outcomes, not two: the AI reached its target and still declined
    (critical - CP is not the gate); it spent on the tier it held while deferring
    a higher one (deferral); or it neither bought nor banked toward the target
    (genuine blackout). A window whose bank is climbing toward the target is
    reported as PRODUCTION_SAVING at info severity, because that is the AI
    working, not failing.
    """
    out = []
    for span in match.defer_spans.done.get(acc["name"], ()):
        duration = span["end"] - span["start"]
        if duration < limits["blackout_seconds"]:
            continue
        spend_before, spend_after = _spend_between(acc, span["start"], span["end"])
        flow_spend_in_window = spend_after - spend_before
        sentry_in_window = _spend_in_window(acc["sentry_checkpoints"], span["start"], span["end"])
        unit_spend = _spend_in_window(acc["queued_checkpoints"], span["start"], span["end"])
        bank_start = span["min_cp"] or 0.0
        bank_peak = span["max_cp"]
        bank_growth = bank_peak - bank_start
        target_top = span["bank_targets"].most_common(1)
        target_value = target_top[0][0] if target_top else None
        met_target = target_value is not None and bank_peak >= target_value
        # Deliberate saving is not a blackout. A bank that is CLIMBING toward
        # the target at a decent fraction of the remaining gap is the AI saving
        # correctly and is about to release; a flat bank at the same level is a
        # stall. Without this distinction the tool reported the baseline's
        # successful capital saves (bank 1,286 -> 11,496 against a 13,825 CP
        # target, 20 options affordable) as 9 "genuine blackout" anomalies, and
        # that misreading is what flipped AI.FieldCheapHullWhileSaving on - which
        # in turn zeroed capital production in 4 of 4 matches.
        gap = (target_value - bank_start) if target_value is not None else None
        on_track = (gap is not None and gap > 0
                    and bank_growth >= SAVING_ON_TRACK_FRACTION * gap)
        tiers = ", ".join(str(int(k)) for k, _ in span["tiers"].most_common(2)) or "-"
        roles = ", ".join(str(k) for k, _ in span["roles"].most_common(2)) or "-"
        if on_track and not met_target:
            severity = "info"
        else:
            severity = "critical" if met_target else "warn"
        if met_target:
            cause = (f"the bank reached {fmt(bank_peak)} CP, at or above the "
                     f"{fmt(target_value)} CP bankTarget for tier {tiers} {roles}, and the "
                     f"AI still declined to buy with {int(span['max_affordable'])} options "
                     f"affordable. CP alone is not releasing the gate - something else in "
                     f"the decision (fleetCap slots, tier unlock, draw) is holding it")
        elif on_track:
            cause = (f"deliberate saving, not a blackout: the bank climbed "
                     f"{fmt(bank_growth)} CP toward a {fmt(target_value)} CP bankTarget for "
                     f"tier {tiers} {roles}, closing {100.0 * bank_growth / gap:.0f}% of the "
                     f"{fmt(gap)} CP gap while {int(span['max_affordable'])} options were "
                     f"affordable. The AI was holding for a higher tier and was on track to "
                     f"release; a real stall has a flat bank here")
        elif unit_spend > 1.0:
            cause = (f"not a blackout: {fmt(unit_spend)} CP of QUEUE_ACCEPTED purchases "
                     f"landed inside this deferral window (the AI banked for a higher tier "
                     f"while still spending on the tier it was holding)")
        else:
            cause = (f"genuine blackout: zero unit purchases across {span['n']} decisions "
                     f"while the bank grew {fmt(bank_growth)} CP and "
                     f"{int(span['max_affordable'])} roster options were affordable. The AI "
                     f"was holding for tier {tiers} {roles} at a {fmt(target_value)} CP "
                     f"bankTarget and never released")
        out.append(_anomaly(
            code=("PRODUCTION_DEFERRAL" if unit_spend > 1.0
                  else "PRODUCTION_SAVING" if on_track and not met_target
                  else "PRODUCTION_BLACKOUT"),
            faction=acc["name"], severity=severity,
            start=span["start"], end=span["end"], duration=duration,
            title=(f"no purchase for {duration:.0f} s across {span['n']} build decisions; "
                   f"bank {fmt(bank_start)} -> {fmt(bank_peak)} CP, "
                   f"{int(span['max_affordable'])} options affordable"),
            evidence={
                "build_decisions_in_window": span["n"],
                "purchases_in_window": 0,
                "reasons": ", ".join(f"{k} x{v}" for k, v in span["reasons"].most_common(3)),
                "max_affordable_options": int(span["max_affordable"]),
                "cp_banked_start": bank_start,
                "cp_banked_peak": bank_peak,
                "cp_banked_growth": bank_growth,
                "unit_purchase_spend_in_window": unit_spend,
                "sentry_spend_in_window": sentry_in_window,
                "flow_spend_in_window": flow_spend_in_window,
                "cumulative_spend_match_total": spend_after,
                "bank_target": target_value,
                "bank_target_met": met_target,
                "tier": tiers, "desired_roles": roles,
                "free_fleet_slots_max": span["max_slots"],
                "idle_peak_in_window": _peak_between(acc, "idle_max", span, match.resolution),
                "fleet_cap": acc["last_fleet_cap"],
                "top_losses_to_date": dict(sorted(acc["losses"].items(),
                                                  key=lambda kv: -kv[1])[:4]),
            },
            cause=cause,
            hint=("the fleet had free slots and affordable hulls but the tier gate never "
                  "opened; compare bankTarget with currentTierDesiredCost in the same "
                  "AI_BUILD_DECISION records"),
        ))
    return out


def _peak_between(acc, field, span, resolution):
    peak = None
    for index in range(buckets_of(span["start"], resolution),
                       buckets_of(span["end"], resolution) + 1):
        slot = acc["buckets"].get(index)
        if slot is None:
            continue
        value = slot.get(field)
        if value is not None and (peak is None or value > peak):
            peak = value
    return peak


def _stuck_reason(match, acc, limits):
    """One AI_BUILD_DECISION reason held for an extended period. The span closes
    as soon as the reason changes, so a span by construction has one reason."""
    out = []
    for span in match.reason_spans.done.get(acc["name"], ()):
        if len(span["reasons"]) != 1:
            continue
        duration = span["end"] - span["start"]
        if duration < limits["stuck_reason_seconds"] or span["n"] < 3:
            continue
        reason = next(iter(span["reasons"]))
        if reason in BUY_REASONS:
            continue
        out.append(_anomaly(
            code="STUCK_BUILD_REASON", faction=acc["name"],
            severity="warn" if reason in DEFER_REASONS else "info",
            start=span["start"], end=span["end"], duration=duration,
            title=f"AI_BUILD_DECISION reason held {reason} for {duration:.0f} s",
            evidence={"decisions": span["n"], "reason": reason,
                      "cp_range": [span["min_cp"], span["max_cp"]],
                      "max_affordable_options": int(span["max_affordable"]),
                      "tiers": {str(int(k)): v for k, v in span["tiers"].items()},
                      "bank_targets": {fmt(k): v for k, v in span["bank_targets"].items()},
                      "fleet_slots_max": span["max_slots"]},
            cause=("tier gate: banking for a higher tier instead of buying a cheaper "
                   "affordable option" if reason in DEFER_REASONS else
                   f"planner emitted {reason} for every decision in the window"),
        ))
    return out


def _sustained_idle(match, acc, limits):
    out = []
    for span in match.idle_spans.done.get(acc["name"], ()):
        duration = span["end"] - span["start"]
        if duration < limits["idle_seconds"]:
            continue
        peak = _peak_between(acc, "idle_max", span, match.resolution)
        out.append(_anomaly(
            code="SUSTAINED_IDLE", faction=acc["name"], severity="warn",
            start=span["start"], end=span["end"], duration=duration,
            title=f"FACTION.idle stayed > 0 for {duration:.0f} s",
            evidence={"peak_idle": peak, "max_idle_match": acc["max_idle"],
                      "final_combatants": acc["last_combatants"],
                      "fleet_cap": acc["last_fleet_cap"],
                      "cap_util_pct": as_percent(acc["last_combatants"], acc["last_fleet_cap"]),
                      "cp_banked_peak_in_window": _peak_between(acc, "cp_max", span, match.resolution),
                      "execution_modes": dict(acc["execution_modes"].most_common(4))},
            cause=("hulls were alive with no strategic order while CP kept banking; the idle "
                   "ships and the unspent CP are the same problem seen from two records"),
        ))
    return out


def _order_pressure(match, acc, limits):
    """Per-faction order failures and sustained reissue, read from the
    cumulative COUNTERS.orders.byMission table plus the global reissue rate."""
    out = []
    failed = sum(row["failed"] for row in acc["orders"].values())
    rejected = sum(row["rejected"] for row in acc["orders"].values())
    attempts = sum(row["success"] for row in acc["orders"].values())
    if failed + rejected >= limits["order_failure_min"]:
        worst = sorted(acc["orders"].items(), key=lambda kv: -(kv[1]["failed"] + kv[1]["rejected"]))[:3]
        out.append(_anomaly(
            code="ORDER_FAILURES", faction=acc["name"], severity="critical",
            start=match.first_time, end=match.last_time,
            duration=(match.last_time or 0) - (match.first_time or 0),
            title=f"{failed + rejected:.0f} native order failures/rejections over the match",
            evidence={"failed": failed, "rejected": rejected, "succeeded": attempts,
                      "worst_missions": {k: dict(v) for k, v in worst}},
            cause="orders.byMission reports failures; the native order pipeline rejected them",
        ))
    deltas = match._counter_deltas
    hot = []
    for time, delta in deltas:
        span = max(1e-6, delta["span"])
        rate = delta["reissued"] / span * 60.0
        if rate >= limits["reissue_per_minute"]:
            hot.append((time, rate, delta["reissued"]))
    if hot:
        total = sum(r for _, r, _ in hot)
        out.append(_anomaly(
            code="REISSUE_STORM", faction=acc["name"], severity="warn",
            start=hot[0][0], end=hot[-1][0], duration=hot[-1][0] - hot[0][0],
            title=f"objective reissue rate above {limits['reissue_per_minute']}/min in "
                  f"{len(hot)} windows",
            evidence={"windows": len(hot), "reissues": sum(c for _, _, c in hot),
                      "peak_per_minute": max(r for _, r, _ in hot),
                      "objective_status": dict(acc["objective_status"]),
                      "top_window": {"t": hot[0][0], "rate_per_min": hot[0][1]}},
            cause="OBJECTIVE status ORDER_REISSUED climbing - groups churn between targets "
                  "instead of completing",
        ))
    return out


def _stall_and_engagement(match, acc, limits):
    out = []
    series = match.series(acc["name"])
    for span in match.stalled_spans.done.get(acc["name"], ()):
        duration = span["end"] - span["start"]
        if duration < limits["stalled_seconds"]:
            continue
        peak = _peak_between(acc, "stalled", span, match.resolution)
        out.append(_anomaly(
            code="STALLED_GROUPS", faction=acc["name"], severity="warn",
            start=span["start"], end=span["end"], duration=duration,
            title=f"groups reported stalled for {duration:.0f} s",
            evidence={"peak_stalled_groups": peak,
                      "unengaged_at_end": _peak_between(acc, "unengaged", span, match.resolution),
                      "execution_modes": dict(acc["execution_modes"].most_common(4))},
            cause="CONTEST.stalledGroups / FACTION.stalled > 0 - groups had orders but were "
                  "not making progress toward them",
        ))
    unengaged_fraction = ratio(acc["unengaged"], acc["unit_seconds"])
    if unengaged_fraction is not None and unengaged_fraction >= limits["unengaged_fraction"]:
        series_unengaged = [(s["t"], s["unengaged"]) for s in series if s["unengaged"] is not None]
        out.append(_anomaly(
            code="UNENGAGED_FLEET", faction=acc["name"], severity="warn",
            start=series_unengaged[0][0] if series_unengaged else 0,
            end=series_unengaged[-1][0] if series_unengaged else 0,
            duration=(series_unengaged[-1][0] - series_unengaged[0][0]) if len(series_unengaged) > 1 else 0,
            title=f"{100 * unengaged_fraction:.1f}% of all unit-seconds were unengaged",
            evidence={"unengaged_seconds": acc["unengaged"],
                      "unit_seconds": acc["unit_seconds"],
                      "fraction": unengaged_fraction,
                      "final_combatants": acc["last_combatants"],
                      "cumulative_damage_dealt": acc["cum_dealt"]},
            cause="fleet accumulated unit-seconds without contact - groups holding "
                  "REGROUP/SCREEN rather than pressing a target",
        ))
    return out


def _posture_flapping(match, acc, limits):
    history = acc["posture_history"]
    if len(history) < 2:
        return []
    worst_rate, worst_window = 0.0, (0, 0)
    for i in range(len(history)):
        for j in range(i + 1, len(history)):
            span = history[j][0] - history[i][0]
            if span <= 0:
                continue
            rate = (j - i) / (span / 60.0)
            if rate > worst_rate:
                worst_rate, worst_window = rate, (history[i][0], history[j][0])
    if worst_rate < limits["flap_per_minute"]:
        return []
    return [_anomaly(
        code="POSTURE_FLAPPING", faction=acc["name"], severity="warn",
        start=worst_window[0], end=worst_window[1],
        duration=worst_window[1] - worst_window[0],
        title=f"posture changed {worst_rate:.1f}/min (threshold {limits['flap_per_minute']})",
        evidence={"peak_rate_per_minute": worst_rate, "transitions": len(history),
                  "sequence": [p for _, p in history[:24]]},
        cause="plan.posture oscillating between BALANCED/OFFENSIVE/DEFENSIVE; the threat "
              "snapshot feeding posture is crossing its thresholds repeatedly",
    )]


def _service_thrash(match, acc, limits):
    out = []
    window = limits["thrash_window"]
    need = int(limits["thrash_entries"])
    hits = []
    for ship, times in acc["service_entries"].items():
        times = sorted(times)
        left = 0
        for right in range(len(times)):
            while times[right] - times[left] > window:
                left += 1
            if right - left + 1 >= need:
                hits.append((times[left], times[right], right - left + 1, ship))
                break
    for start, end, count, ship in sorted(hits, key=lambda h: -(h[1] - h[0]))[:8]:
        out.append(_anomaly(
            code="SERVICE_THRASH", faction=acc["name"], severity="warn",
            start=start, end=end, duration=end - start,
            title=f"ship {ship:g} re-entered service {count} times within {window:.0f} s",
            evidence={"ship": ship, "entries": count, "window_seconds": window,
                      "total_entries_for_ship": len(acc["service_entries"][ship]),
                      "service_phases": dict(acc["service_phases"].most_common(6)),
                      "service_reasons": dict(acc["service_reasons"].most_common(6))},
            cause="FLEET_SERVICE phase cycling RETURNING->UNDER_FIRE->REPAIR_REARM->READY; "
                  "the ship is being pulled out repeatedly rather than repaired once",
        ))
    series = match.series(acc["name"])
    concurrent = [s["service_max"] or 0 for s in series]
    peak = max(concurrent) if concurrent else 0
    if series and peak >= 4:
        peak_at = next((s["t"] for s in series if (s["service_max"] or 0) >= peak), series[0]["t"])
        busy = [s["t"] for s in series if (s["service_max"] or 0) >= max(2.0, peak / 2)]
        out.append(_anomaly(
            code="SERVICE_CONCENTRATION", faction=acc["name"], severity="info",
            start=busy[0] if busy else peak_at,
            end=busy[-1] if busy else peak_at,
            duration=(busy[-1] - busy[0]) if len(busy) > 1 else 0,
            title=f"up to {peak:.0f} ships in the service cycle simultaneously "
                  f"(mean {sum(concurrent) / len(concurrent):.0f}, fleet {fmt(acc['last_combatants'])})",
            evidence={"peak_simultaneous": peak,
                      "mean_simultaneous": sum(concurrent) / len(concurrent),
                      "service_phases": dict(acc["service_phases"].most_common(6)),
                      "service_reasons": dict(acc["service_reasons"].most_common(6)),
                      "sparkline": sparkline(concurrent, 60)},
            cause="most of the fleet is cycling through the station at once rather than "
                  "being repaired opportunistically; check station repair throughput",
        ))
    return out


def _friendly_fire(match, acc, limits):
    times = sorted(acc["friendly_fire_times"])
    if not times:
        return []
    gap = limits["friendly_fire_gap"]
    clusters, current = [], [times[0]]
    for time in times[1:]:
        if time - current[-1] <= gap:
            current.append(time)
        else:
            clusters.append(current)
            current = [time]
    clusters.append(current)
    clusters = [c for c in clusters if len(c) >= limits["friendly_fire_cluster"]]
    if not clusters:
        return []
    biggest = max(clusters, key=len)
    detail = ", ".join(f"{k[0]}/{k[1][:28]} x{v}" for k, v in acc["friendly_fire_detail"].most_common(2))
    return [_anomaly(
        code="FRIENDLY_FIRE_CLUSTER", faction=acc["name"], severity="warn",
        start=biggest[0], end=biggest[-1], duration=biggest[-1] - biggest[0],
        title=f"{len(biggest)} friendly-fire contacts in {biggest[-1] - biggest[0]:.0f} s "
              f"({len(clusters)} clusters in the match)",
        evidence={"total_hits": len(times), "clusters": len(clusters),
                  "cluster_windows": [[round(c[0]), round(c[-1]), len(c)] for c in clusters],
                  "sources": detail},
        cause="weapon contact recorded between same-IFF ships; resolved damage is not "
              "attributed in the FRIENDLY_HIT record, so severity is unmeasurable",
    )]


def _global_order_failures(match, limits):
    out = []
    failed = rejected = 0.0
    for time, delta in match._counter_deltas:
        failed += delta["failed"]
        rejected += delta["rejected"]
    if failed + rejected < limits["order_failure_min"]:
        return []
    return [_anomaly(
        code="ORDER_FAILURES", faction="ALL", severity="critical",
        start=match.first_time, end=match.last_time,
        duration=(match.last_time or 0) - (match.first_time or 0),
        title=f"{failed + rejected:.0f} order failures/rejections across all factions",
        evidence={"failed": failed, "rejected": rejected},
        cause="COUNTERS.orders.byResult reports non-success outcomes",
    )]


# ------------------------------------------------------------ phase timeline

def phase_timeline(match, faction):
    """Operation phase transitions, posture changes, and the latched flags, in
    one time-ordered list a maintainer can read top to bottom."""
    acc = match.factions[faction]
    rows = []
    last_phase = None
    for time, phase, reason, serial, front in acc["operation_phases"]:
        if phase and phase != last_phase:
            rows.append((time, "PHASE", phase,
                         f"serial {fmt(serial)} front {fmt(front)} reason {reason or '-'}"))
            last_phase = phase
    for time, posture in acc["posture_history"]:
        rows.append((time, "POSTURE", posture, "plan.posture"))
    for label, key in (("EMERGENCY", "emergency_first"), ("CRITICAL", "critical_first"),
                       ("URGENT", "urgent_first")):
        if acc[key] is not None:
            rows.append((acc[key], "LATCH", label, "first observed"))
    for tracker, label in ((match.defer_spans, "saving_for_desired_role"),
                           (match.no_option_spans, "no_affordable_options")):
        for span in tracker.done.get(faction, ()):
            rows.append((span["start"], "BUILD_START", label,
                         f"bank target {fmt(next(iter(span['bank_targets']), None))}"
                         if span["bank_targets"] else ""))
            rows.append((span["end"], "BUILD_END", label,
                         f"{span['n']} decisions, reasons "
                         f"{', '.join(k for k, _ in span['reasons'].most_common(2))}"))
    rows.sort(key=lambda r: (r[0], r[1]))
    return rows


# ------------------------------------------------------------------ matching

def _hull_text(state):
    """OUTCOME_CAUSE.snapshot reports stationHull as a FRACTION (0.78 = 78%),
    not the absolute hull value FACTION.stationHull carries. Same key name,
    different unit - so it is rendered here rather than through as_percent(),
    which would print a nonsensical 0.78%."""
    hull = num(state.get("stationHull"))
    if hull is None:
        return "hull=?"
    percent = 100.0 * hull
    if abs(percent) <= 100.0:
        return f"hull={percent:.1f}%"
    return f"hull={hull:,.0f} (absolute; snapshot is not a fraction)"


def termination_state(match, plan):
    """engine-result.json is absent for these runs, so the stop has to be derived
    from the telemetry plus the batch's own -max-sim-time.

    Telemetry cannot tell a cap hit from a process kill that landed short of the
    cap, so a run that stopped well before the cap is reported as an early kill
    rather than being rounded up to "simulation_cap".
    """
    cap = num((plan or {}).get("max_sim_time"))
    last = match.last_time or 0.0
    if match.outcome_causes:
        return "station_destroyed", f"OUTCOME_CAUSE at t={match.outcome_causes[0][0]:.0f}"
    if match.battle_end:
        return "mission_exit", f"BATTLE_END at t={match.battle_end[0]:.0f}"
    if cap:
        fraction = last / cap
        verdict = "simulation_cap" if fraction >= 0.9 else "killed_before_cap"
        return verdict, (f"last telemetry t={last:.0f} of -max-sim-time {cap:.0f} "
                         f"({100 * fraction:.0f}%); engine-result.json never written")
    return "truncated_or_unknown", (f"last telemetry t={last:.0f}; no cap known and no "
                                    f"terminal record")


# ------------------------------------------------------------------ rendering

def render_series(match, faction, out, width, limits):
    acc = match.factions[faction]
    series = match.series(faction)
    if not series:
        out.append(f"  (no FACTION records for {faction})")
        return
    start, end = series[0]["t"], series[-1]["t_end"]
    out.append(f"  window t={start:.0f}..{end:.0f} s over {len(series)} "
               f"{match.resolution:.0f} s buckets")
    global_series = match.series(ALL_FACTIONS)
    rows = [
        ("combatants", [s["combatants"] for s in series]),
        ("idle", [s["idle"] for s in series]),
        ("cp banked", [s["cp"] for s in series]),
        ("cp spent (cum)", [s["cum_spend"] for s in series]),
        ("cp spent / bucket", [s["spend"] for s in series]),
        ("cap util %", [s["cap_util"] for s in series]),
        ("station hull %", [s["hull_pct"] for s in series]),
        ("dmg dealt (cum)", [s["dealt"] for s in series]),
        ("dmg recv (cum)", [s["received"] for s in series]),
        ("stalled", [s["stalled"] for s in series]),
        ("unengaged s", [s["unengaged"] for s in series]),
        ("servicing", [s["servicing"] for s in series]),
        # COUNTERS carries no faction field, so reissue/switch rates are global.
        # They are shown here from the all-factions track, not per faction.
        ("reissued (global)", [s["reissued"] for s in global_series]),
    ]
    for label, values in rows:
        present = [v for v in values if v is not None]
        if not present:
            continue
        if not any(present):
            out.append(f"    {label:17} {'(all zero)':<{width}}")
            continue
        out.append(f"    {label:17} {sparkline(values, width):<{width}}  "
                   f"min {fmt(min(present)):<10} max {fmt(max(present))}")
    # posture as a letter track
    letters = [(s["posture"] or "")[:1] or "." for s in series]
    out.append(f"    {'posture':17} {_compact(letters, width)}")
    mission_totals = collections.Counter()
    for slot in series:
        for mission, count in slot["missions"].items():
            mission_totals[mission] += count
    objective_totals = collections.Counter()
    for slot in series:
        for mission, count in slot["objectives"].items():
            objective_totals[mission] += count
    if mission_totals:
        out.append("    mission mix (DECISION/CONTEST): "
                   + ", ".join(f"{k} {fmt(v)}" for k, v in mission_totals.most_common(8)))
    if objective_totals:
        out.append("    objective orders:                    "
                   + ", ".join(f"{k} {fmt(v)}" for k, v in objective_totals.most_common(8)))
    out.append(f"    interval productionSpend summed over series : {fmt(acc['cum_spend'])} CP")
    out.append(f"    PRODUCTION QUEUE_ACCEPTED cost (independent): {fmt(acc['cum_queued'])} CP")
    out.append(f"    sentry builds: {acc['sentries']} costing {fmt(acc['sentry_cost'])} CP")
    out.append(f"    fleet service labour: {fmt(acc['cp_service'])} CP")
    if acc["cp_spend_entries"]:
        drift = acc["cp_spend_ledger"] - acc["cum_spend"]
        out.append(f"    CP_SPEND ledger ({acc['cp_spend_entries']} deductions)    : "
                   f"{fmt(acc['cp_spend_ledger'])} CP   drift vs flow {drift:+.0f} CP"
                   + ("  OK" if abs(drift) <= max(1.0, acc["cum_spend"] * 0.01)
                      else "  MISMATCH - a CP movement is not reaching RecordAIEconomyFlow"))
        out.append(f"    station upgrades + faction ability (no purchase event): "
                   f"{fmt(acc['cum_spend'] - acc['cum_queued'] - acc['sentry_cost'] - acc['cp_service'])} CP")
    else:
        out.append("    no CP_SPEND ledger in this batch: station upgrades and the faction ability"
                   " cannot be attributed, only bounded")
    out.append(f"    units spawned: {acc['units_spawned']}   losses: {acc['loss_count']} "
               f"worth {fmt(acc['loss_value'])} CP")


def _compact(letters, width):
    if width and len(letters) > width:
        chunk = len(letters) / width
        out = []
        for slot in range(width):
            piece = letters[int(slot * chunk):max(int(slot * chunk) + 1, int((slot + 1) * chunk))]
            uniq = {c for c in piece if c != "."}
            out.append(next(iter(uniq)) if len(uniq) == 1 else "*")
        letters = out
    return "".join(letters)


def render_match(match, target, plan, out, width=72, limits=None, show_events=False,
                 t_from=None, t_to=None, faction_filter=None, top_per_code=3):
    state, why = termination_state(match, plan)
    out.append("=" * 100)
    out.append(f"MATCH  {target.name}   ({match.path.name})")
    out.append("=" * 100)
    out.append(f"  telemetry      : {match.records:,} records, {match.malformed} unparseable"
               + ("  <-- truncated trailing line, run was killed" if match.truncated_tail else ""))
    out.append(f"  sequence       : {fmt(match.first_seq)}..{fmt(match.last_seq)}"
               + (f"  ({match.seq_regressions} regressions)" if match.seq_regressions else ""))
    out.append(f"  sim time       : t={fmt(match.first_time, 1)}..{fmt(match.last_time, 1)} s")
    out.append(f"  termination    : {state} - {why}")
    meta = match.run_meta
    if meta:
        out.append(f"  run            : planner={meta.get('planner')} "
                   f"difficulty={fmt(meta.get('difficulty'))} factions={fmt(meta.get('factions'))} "
                   f"detailedUnit={meta.get('detailedUnitTelemetry')} "
                   f"detailedDecision={meta.get('detailedDecisionTelemetry')}")
    setup = match.setup
    if setup:
        out.append(f"  setup          : difficulty={fmt(setup.get('difficultyIndex'))} "
                   f"distance={fmt(setup.get('distanceIndex'))} "
                   f"economy={fmt(setup.get('economyIndex'))} "
                   f"duration={fmt(setup.get('durationIndex'))} "
                   f"arrangement={fmt(setup.get('arrangementDegrees'), 1)} deg")
    out.append(f"  events         : " + ", ".join(
        f"{k}={v:,}" for k, v in match.events.most_common()))

    factions = match.real_factions()
    if faction_filter:
        wanted = {f.strip().upper() for f in faction_filter.split(",") if f.strip()}
        factions = [f for f in factions if f in wanted] or factions
    for faction in factions:
        acc = match.factions[faction]
        out.append("")
        out.append(f"-- {faction} " + "-" * (96 - len(faction)))
        hull = acc["last_hull_pct"]
        out.append(f"  end state      : station hull {fmt(hull, 1)}%  combatants "
                   f"{fmt(acc['last_combatants'])}/{fmt(acc['last_fleet_cap'])}  "
                   f"fleet value {fmt(acc['last_value'])}  posture {acc['last_posture']}")
        out.append(f"  economy        : cumulative productionSpend {fmt(acc['cum_spend'])} CP  "
                   f"(interval flow, summed) | queued {fmt(acc['cum_queued'])} CP | "
                   f"income {fmt(acc['cum_income'])} bounty {fmt(acc['cum_bounty'])} "
                   f"refund {fmt(acc['cum_refund'])}")
        offense_mean = (acc["offense_sum"] / acc["offense_samples"]
                        if acc["offense_samples"] else None)
        out.append(f"                   CP still banked at end: {fmt(acc['last_cp'])} "
                   f"(peak {fmt(acc['max_cp'])})")
        out.append(f"  combat         : damage dealt {fmt(acc['cum_dealt'])}  "
                   f"(FACTION.offense is a gauge, not a flow: mean "
                   f"{fmt(offense_mean)} max {fmt(acc['offense_max'])} last "
                   f"{fmt(acc['offense_last'])} over {acc['offense_samples']} samples)  "
                   f"received {fmt(acc['cum_received'])} (cumulative field)  "
                   f"losses {acc['loss_count']} ({fmt(acc['loss_value'])} CP)")
        if acc["losses"]:
            out.append("                   lost: " + ", ".join(
                f"{k} x{int(v)}" for k, v in sorted(acc["losses"].items(),
                                                    key=lambda kv: -kv[1])[:8]))
        if acc["orders"]:
            out.append("  orders         : " + ", ".join(
                f"{m} ok={fmt(row['success'])} fail={fmt(row['failed'])} "
                f"rej={fmt(row['rejected'])}"
                for m, row in sorted(acc["orders"].items())[:8]))
        if acc["build_reasons"]:
            out.append("  build reasons  : " + ", ".join(
                f"{k}={v}" for k, v in acc["build_reasons"].most_common(6)))
        if acc["execution_modes"]:
            out.append("  execution mode : " + ", ".join(
                f"{k}={v}" for k, v in acc["execution_modes"].most_common(6)))
        if acc["execution_status"]:
            out.append("  execution stat : " + ", ".join(
                f"{k}={v}" for k, v in acc["execution_status"].most_common(6)))
        if acc["objective_status"]:
            out.append("  objective stat : " + ", ".join(
                f"{k}={v}" for k, v in acc["objective_status"].most_common(4)))

        out.append("")
        out.append(f"  TIME SERIES ({match.resolution:.0f} s buckets)")
        render_series(match, faction, out, width, limits)

        out.append("")
        out.append("  PHASE TIMELINE")
        rows = phase_timeline(match, faction)
        for time, kind, value, note in rows:
            if t_from is not None and time < t_from:
                continue
            if t_to is not None and time > t_to:
                continue
            out.append(f"    t={time:8.1f}  {kind:12} {str(value):28} {note}")

    if match.outcome_causes:
        out.append("")
        out.append("-- OUTCOME CAUSE " + "-" * 82)
        for time, data in match.outcome_causes:
            out.append(f"  t={time:.1f} {data.get('faction')} station "
                       f"{data.get('targetName')} destroyed, elapsed={fmt(data.get('elapsed'), 1)} s")
            for killer in (data.get("killers") or ())[:6]:
                out.append(f"      {str(killer.get('weapon')):14} from "
                           f"{str(killer.get('attackerFaction')):6} beam={str(killer.get('beam')):5} "
                           f"{fmt(killer.get('hullDamage')):>10} hull "
                           f"({100 * (num(killer.get('share')) or 0):.1f}%) "
                           f"{fmt(killer.get('hitCount'))} hits")
            snapshot = data.get("snapshot") if isinstance(data.get("snapshot"), dict) else {}
            if snapshot:
                out.append("      at that moment: " + "  ".join(
                    f"{k} cp={fmt((v or {}).get('commandPoints'))} {_hull_text(v or {})}"
                    for k, v in snapshot.items()))
    if match.battle_end:
        out.append(f"  BATTLE_END at t={match.battle_end[0]:.1f}: "
                   f"{json.dumps(match.battle_end[1])[:300]}")

    out.append("")
    out.append("-- BASE DAMAGE ATTRIBUTION (cumulative byWeapon, FACTION.baseDamageTelemetry) " + "-" * 20)
    if match.base_damage:
        out.append(f"   cumulative snapshot at t={fmt(match.base_elapsed, 1)} s")
        by_station = collections.defaultdict(list)
        for (station, attacker, weapon, beam), slot in match.base_damage.items():
            by_station[station].append((slot["hull"], attacker, weapon, beam, slot["hits"]))
        for station in sorted(by_station):
            rows = sorted(by_station[station], reverse=True)
            total = sum(r[0] for r in rows)
            out.append(f"   damage to the {station} station: {fmt(total)} hull total")
            for hull, attacker, weapon, beam, hits in rows[:6]:
                out.append(f"     {'BEAM' if beam else 'PROJ':5} {str(weapon):16} "
                           f"from {attacker:8} hits={fmt(hits):>8} hull={fmt(hull):>12} "
                           f"({100 * hull / total:.1f}%)" if total else
                           f"     {'BEAM' if beam else 'PROJ':5} {str(weapon):16} "
                           f"from {attacker:8} hits={fmt(hits):>8} hull={fmt(hull):>12}")
    else:
        out.append("   (no base damage telemetry reached any station in this run)")
    if match.beam_hits:
        out.append("   station beam hits: " + ", ".join(
            f"{a}->{t} x{n}" for (a, t), n in match.beam_hits.most_common(6)))

    out.append("")
    out.append("-- ANOMALIES " + "-" * 87)
    anomalies = detect_anomalies(match, limits)
    if faction_filter:
        wanted = {f.strip().upper() for f in faction_filter.split(",") if f.strip()}
        anomalies = [a for a in anomalies if a["faction"] in wanted] or anomalies
    out.append(f"   {len(anomalies)} total; grouped by code, longest {top_per_code} of each "
               f"shown here - every one is in the --json output")
    if not anomalies:
        out.append("   none detected")
    by_code = collections.defaultdict(list)
    for anomaly in anomalies:
        by_code[anomaly["code"]].append(anomaly)
    order = sorted(by_code, key=lambda code: (
        {"critical": 0, "warn": 1, "info": 2}.get(by_code[code][0]["severity"], 3),
        -max(a["duration"] for a in by_code[code])))
    for code in order:
        group = sorted(by_code[code], key=lambda a: -a["duration"])
        out.append("")
        out.append(f"   == {code} ({len(group)}) "
                   + "=" * max(0, 78 - len(code) - len(str(len(group)))))
        for anomaly in group[:top_per_code]:
            _render_anomaly(anomaly, out)
        if len(group) > top_per_code:
            hidden = group[top_per_code:]
            out.append(f"      ... {len(hidden)} more {code} "
                       f"(t={min(a['start'] for a in hidden):.0f}"
                       f"..{max(a['end'] for a in hidden):.0f}) in the JSON output")
    return anomalies


def _render_anomaly(anomaly, out):
    out.append("")
    out.append(f"   [{anomaly['severity'].upper()}] {anomaly['code']}  {anomaly['faction']}  "
               f"t={anomaly['start']:.0f}..{anomaly['end']:.0f} ({anomaly['duration']:.0f} s)")
    out.append(f"      {anomaly['title']}")
    for key, value in anomaly["evidence"].items():
        if key in ("build_reasons_total", "execution_modes", "service_phases",
                   "service_reasons", "objective_status", "sequence", "sparkline"):
            continue
        out.append(f"        {key:26} {value}")
    out.append(f"      cause: {anomaly['cause']}")
    if anomaly.get("hint"):
        out.append(f"      hint : {anomaly['hint']}")


def to_json(match, target, plan, anomalies, limits):
    state, why = termination_state(match, plan)
    factions = {}
    for name, acc in match.factions.items():
        if name == ALL_FACTIONS:
            continue
        factions[name] = {
            "end_state": {
                "station_hull_pct": acc["last_hull_pct"],
                "combatants": acc["last_combatants"],
                "fleet_cap": acc["last_fleet_cap"],
                "fleet_value": acc["last_value"],
                "posture": acc["last_posture"],
                "cp_banked": acc["last_cp"],
                "cp_banked_peak": acc["max_cp"],
            },
            "cumulative_cp_spent_from_interval_flow": acc["cum_spend"],
            "cumulative_cp_queued_from_production_events": acc["cum_queued"],
            "cumulative_cp_sentry": acc["sentry_cost"],
            "cumulative_cp_service": acc["cp_service"],
            "cp_spend_ledger": acc["cp_spend_ledger"],
            "cp_spend_ledger_drift": (acc["cp_spend_ledger"] - acc["cum_spend"]
                                      if acc["cp_spend_entries"] else None),
            "cp_spend_unattributed": (acc["cum_spend"] - acc["cum_queued"]
                                      - acc["sentry_cost"] - acc["cp_service"]),
            "station_repair_unlocked": acc["repair_unlocked"],
            "cumulative_income": acc["cum_income"],
            "cumulative_bounty": acc["cum_bounty"],
            "cumulative_refund": acc["cum_refund"],
            "damage_dealt": acc["cum_dealt"],
            # offense is the fleet value assigned to PRIMARY/ESCORT missions,
            # rebuilt from scratch each FACTION record. It is a gauge: it rises on
            # assignment and falls on release, and returns to 0 inside a match.
            "offense_assigned_fleet_value": {
                "mean": (acc["offense_sum"] / acc["offense_samples"]
                         if acc["offense_samples"] else None),
                "max": acc["offense_max"],
                "last": acc["offense_last"],
                "samples": acc["offense_samples"],
            },
            "damage_received_cumulative": acc["cum_received"],
            "losses": dict(acc["losses"]),
            "loss_value": acc["loss_value"],
            "units_spawned": acc["units_spawned"],
            "sentry_builds": acc["sentries"],
            "build_reasons": dict(acc["build_reasons"]),
            "execution_modes": dict(acc["execution_modes"]),
            "execution_status": dict(acc["execution_status"]),
            "objective_status": dict(acc["objective_status"]),
            "orders": {m: dict(row) for m, row in acc["orders"].items()},
            "service_phases": dict(acc["service_phases"]),
            "service_reasons": dict(acc["service_reasons"]),
            "unengaged_seconds": acc["unengaged"],
            "unit_seconds": acc["unit_seconds"],
            "phase_timeline": [
                {"t": t, "kind": kind, "value": value, "note": note}
                for t, kind, value, note in phase_timeline(match, name)],
            "series": [
                {k: v for k, v in slot.items() if k != "index"}
                for slot in match.series(name)],
        }
    return {
        "match": {
            "path": str(match.path),
            "name": target.name,
            "records": match.records,
            "malformed_lines": match.malformed,
            "truncated_tail": match.truncated_tail,
            "first_sequence": match.first_seq,
            "last_sequence": match.last_seq,
            "sequence_regressions": match.seq_regressions,
            "first_time": match.first_time,
            "last_time": match.last_time,
            "duration": (match.last_time or 0) - (match.first_time or 0),
            "resolution": match.resolution,
            "termination": state,
            "termination_detail": why,
            "run_meta": match.run_meta,
            "setup": match.setup,
            "event_counts": dict(match.events),
            "outcome_causes": [{"t": t, "data": d} for t, d in match.outcome_causes],
            "battle_end": {"t": match.battle_end[0], "data": match.battle_end[1]}
            if match.battle_end else None,
            "base_damage_at_elapsed_seconds": match.base_elapsed,
            "base_damage": [
                {"station": station, "attacker": attacker, "weapon": weapon,
                 "beam": beam, "hits": slot["hits"], "hull": slot["hull"]}
                for (station, attacker, weapon, beam), slot in match.base_damage.items()],
            "station_beam_hits": [{"attacker": a, "target": t, "hits": n}
                                  for (a, t), n in match.beam_hits.items()],
        },
        "factions": factions,
        "anomalies": anomalies,
        "thresholds": limits,
    }


# ------------------------------------------------------------------------ CLI

def build_limits(args):
    limits = dict(THRESHOLDS)
    for key in limits:
        value = getattr(args, key, None)
        if value is not None:
            limits[key] = float(value)
    return limits


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="ai_timeline.py", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("target", type=Path,
                        help="batch output dir (results/w/...) or a single run dir")
    parser.add_argument("--faction", help="comma separated factions, e.g. GOLD or BLUE,RED")
    parser.add_argument("--from", dest="t_from", type=float, help="hide timeline rows before t")
    parser.add_argument("--to", dest="t_to", type=float, help="hide timeline rows after t")
    parser.add_argument("--resolution", type=float, default=60.0,
                        help="time bucket width in seconds (default 60)")
    parser.add_argument("--json", type=Path, help="write the same data as JSON")
    parser.add_argument("--events", action="store_true",
                        help="also print the per-event-type census and bucket detail")
    parser.add_argument("--width", type=int, default=72, help="sparkline width")
    parser.add_argument("--quiet", action="store_true", help="suppress the terminal report")
    parser.add_argument("--top", type=int, default=3,
                        help="longest anomalies of each code to print (default 3)")
    for key in THRESHOLDS:
        parser.add_argument("--" + key.replace("_", "-"), type=float, default=None,
                            help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    target = args.target
    if not target.exists():
        raise SystemExit(f"No such path: {target}")
    files = find_telemetry(target)
    if not files:
        raise SystemExit(f"No {TELEMETRY_GLOB} under {target}")
    plan = batch_plan(target)
    limits = build_limits(args)

    out, payload = [], []
    total_anomalies = 0
    for path in files:
        match = MatchTimeline(path, args.resolution).consume()
        run_dir = path.parent.parent.parent.parent
        target_dir = target if target.is_dir() else run_dir
        if args.quiet:
            anomalies = detect_anomalies(match, limits)
            total_anomalies += len(anomalies)
            payload.append(to_json(match, target_dir, plan, anomalies, limits))
            continue
        anomalies = render_match(match, target_dir, plan, out, width=args.width,
                                 limits=limits, show_events=args.events,
                                 t_from=args.t_from, t_to=args.t_to,
                                 faction_filter=args.faction,
                                 top_per_code=args.top)
        total_anomalies += len(anomalies)
        payload.append(to_json(match, target_dir, plan, anomalies, limits))
        if args.events:
            out.append("")
            out.append("  EVENT CENSUS")
            for event, count in sorted(match.events.items(), key=lambda kv: -kv[1]):
                out.append(f"    {event:26} {count:>8,}")
    if not args.quiet:
        out.insert(0, f"AI TIMELINE  {target}\n"
                      f"{len(files)} match(es), resolution {args.resolution:.0f} s, "
                      f"{total_anomalies} anomalies\n")
        print("\n".join(out))
    if args.json:
        args.json.write_text(json.dumps(
            {"batch": str(target), "matches": payload}, indent=1, default=str),
            encoding="utf-8")
        if args.quiet:
            print(f"wrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())