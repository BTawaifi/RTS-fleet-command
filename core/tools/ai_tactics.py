"""Tactical-quality scoring for the fleet-command AI, from existing telemetry only.

Every metric here is derived from records the emitter already writes to
``rts-ai-*.jsonl``. Nothing in this file requires a new emitter field, a new
probe, or a re-run of a batch. Where a question that matters for tactics cannot
be answered from the current telemetry it is listed in ``GAPS`` rather than
approximated with a proxy that would quietly measure something else.

    python ai_tactics.py <batch-dir> [<batch-dir> ...] [--baseline <dir>]
                          [--json] [--metric <name>] [--gaps] [--verbose]

The reader streams: one file, one line, one record at a time. Per-faction state
is O(groups + ships + contest samples), never O(records), so the largest staged
batch (163 MB across 4 runs) is processed in constant memory.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from collections import Counter, defaultdict

# --------------------------------------------------------------------------
# Tunables. Thresholds in metres or seconds, stated here rather than buried in
# the metric bodies so that changing one does not silently change a meaning.
# --------------------------------------------------------------------------

GUARD_RADIUS_M = 6000.0        # what counts as "defending its own station"
LURE_WINDOW_S = 60.0           # how long a decoy has to pull the enemy
LURE_CAPTURE_M = 3000.0        # enemy must commit a target inside this radius
FAR_SHARE_M = 6000.0           # beyond this, shared targets are coincidence
STALL_FLAG_S = 30.0            # the emitter's own stall threshold
MIN_ASSAULT_PEAK = 1.0         # value below this counts as 'not at the base'
STATION_DAMAGED = 0.98         # fraction below which the home base counts as hit

HIGHER_BETTER = "higher"
LOWER_BETTER = "lower"
AMBIGUOUS = "ambiguous"

CAPITAL_ROLES = ("capital", "juggernaut")

# --------------------------------------------------------------------------
# Metric registry.
#
# `polarity` is declared from what the quantity means, not from where the
# baseline happens to sit. `diagnostic=True` marks a quantity whose direction is
# genuinely unknown - reported and explained, never scored as evidence.
# --------------------------------------------------------------------------

METRICS = {
    # -- force concentration -------------------------------------------------
    "objective_commit_ratio": dict(
        polarity=HIGHER_BETTER, family="concentration", unit="ratio",
        title="Objective commitment",
        description="Share of a faction's committed fleet value whose assigned "
                    "target is the enemy base (valueOnPrimary) rather than an "
                    "enemy group (valueOnGroups), time-averaged over CONTEST "
                    "samples in which it had any force out.",
        rationale="A base is the only thing that can be taken. Value sent at "
                  "enemy ships is value that never scores. Splitting the "
                  "difference is the arithmetic definition of not committing.",
        source="CONTEST"),
    "value_on_primary_peak": dict(
        polarity=HIGHER_BETTER, family="concentration", unit="value",
        title="Peak force on the base",
        description="Largest valueOnPrimary any faction reached in the run.",
        rationale="Committing to an objective and having enough ships to matter "
                  "on arrival are different things. A capital cannot be hurt by "
                  "three fighters, so the peak is the ceiling on what any "
                  "single push can ever accomplish.",
        source="CONTEST"),
    "commitment_duty_cycle": dict(
        polarity=HIGHER_BETTER, family="concentration", unit="fraction",
        title="Commitment duty cycle",
        description="Fraction of CONTEST samples with valueOnPrimary > 0.",
        rationale="A plan executed one time in five is not a plan. Sustained "
                  "pressure on the objective is what converts committed value "
                  "into base damage.",
        source="CONTEST"),
    "group_value_hhi": dict(
        polarity=HIGHER_BETTER, family="concentration", unit="index",
        title="Group massing (Herfindahl)",
        description="Mean Herfindahl index of group value within a COHESION "
                    "sample: 1.0 = all value in one group, 1/n = split evenly.",
        rationale="Herfindahl is scale-free. It says whether value is pooled or "
                  "scattered without caring how many groups exist, which is "
                  "exactly the mass-versus-dribble distinction.",
        source="COHESION"),
    "mean_groups_per_faction": dict(
        polarity=LOWER_BETTER, family="concentration", unit="groups",
        title="Simultaneous groups",
        description="Mean groupCount per faction across CONTEST samples.",
        rationale="The same fleet split into twice as many groups puts half the "
                  "force at every point of contact. Fewer simultaneous groups "
                  "means each engagement is a larger engagement. Read from "
                  "CONTEST so the denominator matches the stall metrics.",
        source="CONTEST"),

    # -- arrival coherence ----------------------------------------------------
    "assault_episodes_per_minute": dict(
        polarity=AMBIGUOUS, family="arrival", unit="episodes/min",
        diagnostic=True,
        title="Attack episodes per minute",
        description="Contiguous runs of CONTEST samples with valueOnPrimary > 0, "
                    "per minute of simulated time.",
        rationale="DIRECTION UNRESOLVED, and the reason is instructive. The "
                  "obvious hypothesis is that dribbling shows up as many short "
                  "episodes, so more episodes means worse. The staged data "
                  "refutes that: the broken batch records FEWER episodes than "
                  "the baseline because it barely attacks the base at all. The "
                  "count therefore measures offensive appetite at least as much "
                  "as cadence, and cannot be scored on its own.",
        source="CONTEST"),
    "assault_sustain_seconds": dict(
        polarity=HIGHER_BETTER, family="arrival", unit="seconds",
        title="Attack episode duration",
        description="Median wall-clock length of a contiguous valueOnPrimary > 0 "
                    "episode.",
        rationale="Damage to a base accumulates while someone is shooting it. "
                  "An episode that ends after one CONTEST sample means the force "
                  "arrived, did almost nothing, and left or died - which is what "
                  "attrition looks like from the defender's side.",
        source="CONTEST"),
    "value_volatility": dict(
        polarity=LOWER_BETTER, family="arrival", unit="coefficient",
        title="Commitment volatility",
        description="Coefficient of variation of valueOnPrimary across a "
                    "faction's engaged samples.",
        rationale="Steady pressure does not spike. High volatility means value "
                  "appears and vanishes at the objective, so the enemy can "
                  "choose its ground afresh every cycle. It is the volatility of "
                  "the commitment curve, not of any single group.",
        source="CONTEST"),

    # -- stall discipline -----------------------------------------------------
    "stalled_group_ratio": dict(
        polarity=LOWER_BETTER, family="stall", unit="fraction",
        title="Stalled group-time",
        description="Mean stalledGroups / groupCount over CONTEST samples.",
        rationale="Time a group spends at an objective without closing is time "
                  "the enemy chooses the terms of engagement.",
        source="CONTEST"),
    "stall_p95_seconds": dict(
        polarity=LOWER_BETTER, family="stall", unit="seconds",
        title="Worst stall, p95",
        description="95th percentile of CONTEST worstStallSeconds.",
        rationale="The mean stall hides the one group that parked in the open "
                  "for the rest of the battle. The tail is where dead fleets "
                  "come from.",
        source="CONTEST"),
    "stall_recovery_seconds": dict(
        polarity=LOWER_BETTER, family="stall", unit="seconds",
        title="Stall recovery",
        description="Median seconds from a group being flagged stalled (>30 s "
                    "without closing 150 m) to its stalledSeconds returning to "
                    "zero.",
        rationale="Detecting a stall is worthless without acting on it. The gap "
                  "between flag and recovery is the AI's reaction latency, a "
                  "property of the decision loop rather than of the fight.",
        source="CONTEST"),

    # -- depth and over-extension --------------------------------------------
    "deep_commit_fraction": dict(
        polarity=HIGHER_BETTER, family="depth", unit="fraction",
        title="Crossed the midpoint",
        description="Fraction of COHESION samples in which some group's "
                    "centroid is nearer the enemy primary than to its own "
                    "station.",
        rationale="An attacker that stops short never kills anything. This is "
                  "the willingness-to-fight term, deliberately kept separate "
                  "from the cost term so that aggression and its price are not "
                  "fused into a single number.",
        source="COHESION"),
    "near_arena_edge_fraction": dict(
        polarity=AMBIGUOUS, family="depth", unit="fraction", diagnostic=True,
        title="Near the arena edge",
        description="Fraction of COHESION samples with nearArenaEdge > 0.",
        rationale="UNKNOWN DIRECTION. Sitting at the arena boundary is either "
                  "attrition fought in the right place or ships wandering off "
                  "the map. The same number means both and the telemetry does "
                  "not separate them, so this is reported and never scored.",
        source="COHESION"),

    # -- withdrawal discipline ------------------------------------------------
    "withdrawal_per_loss": dict(
        polarity=HIGHER_BETTER, family="withdrawal", unit="per loss",
        title="Withdrawals per loss",
        description="OBJECTIVE transitions into REGROUP or RETREAT divided by "
                    "LOSS events, batch-wide.",
        rationale="A withdrawal is only worth ordering if it prevents a death. "
                  "High here with high survival is discipline; high here with "
                  "high deaths is panic. Must be read alongside loss count.",
        source="OBJECTIVE + LOSS"),
    "retreat_duty_cycle": dict(
        polarity=HIGHER_BETTER, family="withdrawal", unit="fraction",
        title="Withdrawal duty cycle",
        description="REGROUP + RETREAT share of group-time, from CONTEST "
                    "missionCounts.",
        rationale="Hull-integrity management is a standing behaviour, not an "
                  "emergency response. A faction that never spends group-time "
                  "regrouping has no withdrawal doctrine to fall back on when "
                  "one is needed.",
        source="CONTEST"),
    "order_commitment_seconds": dict(
        polarity=HIGHER_BETTER, family="withdrawal", unit="seconds",
        title="Order stickiness",
        description="Mean OBJECTIVE previousAge at order replacement.",
        rationale="previousAge is how long the outgoing order had been held. "
                  "Short ages mean the AI churns orders faster than the battle "
                  "changes, cancelling its own plan before it can produce an "
                  "effect.",
        source="OBJECTIVE"),

    # -- defensive anchoring --------------------------------------------------
    "station_guard_response": dict(
        polarity=AMBIGUOUS, family="defence", unit="pp", diagnostic=True,
        title="Station guard response",
        description="Percentage points by which the share of a faction's group "
                    "value sitting within 6 km of its own station rises when "
                    "that station is below 98% hull, versus when it is not.",
        rationale="DIRECTION UNRESOLVED, and the confound is structural. This "
                  "measures where value sits, not why. A faction that never "
                  "commits to the enemy station has all its value at home "
                  "already, so it scores a large response without defending "
                  "anything; a faction that is winning deep in enemy space "
                  "scores a negative response while winning. Both readings are "
                  "in the staged data, so this is reported, never scored.",
        source="COHESION + CONTEST"),
    "station_hull_min": dict(
        polarity=AMBIGUOUS, family="defence", unit="fraction", diagnostic=True,
        title="Deepest station damage taken",
        description="Minimum stationHull fraction any faction reached.",
        rationale="DIAGNOSTIC ONLY, direction deliberately unresolved. A low "
                  "number means the faction nearly died, but it equally means "
                  "the enemy committed. Whether that is a defensive failure "
                  "depends on who attacked, which this metric cannot see.",
        source="CONTEST"),

    # -- threat response ------------------------------------------------------
    "capital_preempt_rate": dict(
        polarity=HIGHER_BETTER, family="threat", unit="per 1k decisions",
        title="Capital-threat preemption",
        description="DECISION records with reason CAPITAL_THREAT_PREEMPTION per "
                    "1000 decisions.",
        rationale="A capital or juggernaut allowed to close is the one loss the "
                  "faction cannot replace. Answering the threat before it "
                  "arrives is the highest-leverage defensive act available.",
        source="DECISION"),
    "preempt_on_capital_rate": dict(
        polarity=HIGHER_BETTER, family="threat", unit="fraction",
        title="Preemption aimed at capital hulls",
        description="Share of CAPITAL_THREAT_PREEMPTION decisions whose target "
                    "role is capital or juggernaut.",
        rationale="The lever should be spent on the hull whose loss the enemy "
                  "cannot replace and which can break a siege on its own. An "
                  "escort is a valid target but a replaceable one, so a "
                  "preemptive bomber group sent at escorts while a capital "
                  "closes is the same reaction aimed at the wrong size of "
                  "problem.",
        source="DECISION"),

    # -- deception ------------------------------------------------------------
    "deception_duty_cycle": dict(
        polarity=AMBIGUOUS, family="deception", unit="fraction", diagnostic=True,
        title="Deception duty cycle",
        description="FEINT + LURE + TRAP share of group-time, from CONTEST "
                    "missionCounts.",
        rationale="UNKNOWN DIRECTION, for a specific reason. Nearly zero means "
                  "the AI never tries deception; a large share could mean "
                  "sophisticated bait or merely a fleet parked on the map. Only "
                  "lure_conversion can separate those two.",
        source="CONTEST"),
    "lure_conversion": dict(
        polarity=HIGHER_BETTER, family="deception", unit="fraction",
        title="Deception payoff",
        description="Fraction of FEINT/LURE/TRAP events followed within 60 s by "
                    "an enemy DECISION whose target lies within 3 km of the "
                    "decoy group's position when the tactic was declared.",
        rationale="A decoy is only worth the ships tied to it if the enemy "
                  "actually moves toward it. This measures whether the bait was "
                  "taken, which is the only part of deception that produces a "
                  "tactical benefit.",
        source="TACTIC + COHESION + DECISION"),

    # -- focus fire -----------------------------------------------------------
    "target_value_hhi": dict(
        polarity=HIGHER_BETTER, family="focusfire", unit="index",
        title="Target concentration",
        description="Mean Herfindahl index of committed group value across "
                    "distinct targetSignature values within a COHESION sample.",
        rationale="Damage concentrates on a few hulls. If every group picks a "
                  "different target, total output spreads across the enemy "
                  "fleet and nothing dies quickly enough to matter.",
        source="COHESION"),
    "coincident_share_rate": dict(
        polarity=LOWER_BETTER, family="focusfire", unit="fraction",
        title="Coincidental target sharing",
        description="Shared-target COHESION pairs whose centres are more than "
                    "6 km apart, over all shared-target pairs.",
        rationale="Two groups naming the same ship from opposite ends of the map "
                  "are not coordinating; they are both picking the "
                  "highest-value target independently. This separates real focus "
                  "fire from nominal target agreement.",
        source="COHESION"),

    # -- attrition ------------------------------------------------------------
    "damage_per_loss": dict(
        polarity=HIGHER_BETTER, family="attrition", unit="damage/ship",
        title="Damage bought per ship lost",
        description="FACTION damageDealt divided by LOSS count, averaged over "
                    "factions.",
        rationale="The exchange rate of the battle, stated ship for ship. A "
                  "faction that destroys more for every hull it spends is "
                  "fighting better regardless of what doctrine it claims to "
                  "follow.",
        source="FACTION + LOSS"),
    "damage_exchange_ratio": dict(
        polarity=AMBIGUOUS, family="attrition", unit="ratio", diagnostic=True,
        title="Damage dealt per damage taken",
        description="Hull damage inflicted divided by FACTION received, averaged "
                    "over factions.",
        rationale="DIRECTION UNRESOLVED, and the confound is arithmetic. In a "
                  "closed three-faction battle the damage one faction deals is "
                  "the damage the other two take, so this ratio is largely fixed "
                  "by how the battle is distributed and rises sharply when one "
                  "faction is winning everywhere. The broken batch scores "
                  "highest on it while losing 920 ships. Reported, never scored: "
                  "damage_per_loss is the honest exchange measure.",
        source="FACTION"),
    "friendly_fire_damage_ratio": dict(
        polarity=LOWER_BETTER, family="attrition", unit="fraction",
        title="Friendly-fire damage share",
        description="Friendly-fire hull damage divided by all hull damage "
                    "received in the same intervals.",
        rationale="Friendly fire is damage the AI inflicted on itself through "
                  "bad formation and bad target discipline. It is subtracted "
                  "from its own output before it can touch the enemy.",
        source="FACTION"),
}

FAMILIES = [
    ("concentration", "Force concentration"),
    ("arrival", "Arrival coherence"),
    ("stall", "Stall discipline"),
    ("depth", "Depth and over-extension"),
    ("withdrawal", "Withdrawal discipline"),
    ("defence", "Defensive anchoring"),
    ("threat", "Threat response"),
    ("deception", "Deception"),
    ("focusfire", "Focus fire"),
    ("attrition", "Attrition exchange"),
]

# --------------------------------------------------------------------------
# Questions the current telemetry cannot answer. Each names the emitter field
# that would close it. These are deliberately not approximated above.
# --------------------------------------------------------------------------

GAPS = [
    ("Where a ship died",
     "LOSS carries no position and no mission. A faction losing ships deep in "
     "enemy space and a faction losing them on the way home produce identical "
     "LOSS records, so the cost of over-extension cannot be attributed.",
     "LOSS.position {x,z} and LOSS.mission at kill time."),
    ("Why a group was re-tasked",
     "OBJECTIVE reports the new mission and previousMission but not the "
     "decision reason or score, so a genuine withdrawal cannot be told apart "
     "from a routine retarget.",
     "OBJECTIVE.reason and OBJECTIVE.score."),
    ("Whether ships were damaged before dying",
     "UNIT samples hull but there is no link from the final UNIT sample to the "
     "LOSS that follows it, so 'withdrew at 30% hull' and 'died at 100% hull' "
     "are the same record.",
     "LOSS.hullFractionAtDeath, or a per-ship hull series joinable to ship id."),
    ("Whether a decoy actually moved the enemy",
     "lure_conversion sees an enemy *decision* near the decoy. There is no "
     "record of enemy *movement*, so a decision that was never executed and "
     "one that was look identical.",
     "Ship positions in UNIT ({x,z}), or DECISION.result confirming the order "
     "reached the engine."),
    ("Whether the AI was outnumbered",
     "Nothing records local force balance at contact. A group that advanced "
     "into 3:1 and one that advanced into 1:3 both merely arrive.",
     "COHESION.node.localFriendlyValue and localEnemyValue, or "
     "DECISION.localRatio at decision time."),
    ("Whether a base assault converted",
     "valueOnPrimary says how much value pointed at the base. Nothing says "
     "whether that value produced base damage before the groups died, so "
     "commitment cannot be scored on outcome.",
     "A shared assault id on CONTEST.group and on BaseDamageTelemetry rows."),
    ("Group strength, not just size",
     "COHESION.node.count is a headcount. A group of 8 at full hull and a group "
     "of 8 at 20% hull contribute the same count and very different force.",
     "COHESION.node.hullFraction or meanHull."),
    ("Whether a returning group is the same group",
     "REGROUP and RETREAT are counted from mission names only; nothing "
     "distinguishes a group pulling back intact from the same group rebuilt "
     "from scratch.",
     "A stable assault or operation id on CONTEST.group and OBJECTIVE."),
]

_NEEDED = ("COHESION", "CONTEST", "OBJECTIVE", "LOSS", "TACTIC", "DECISION",
           "FACTION")


# --------------------------------------------------------------------------
# Streaming reader.
# --------------------------------------------------------------------------


def iter_records(path, events=None):
    """Yield (time, event, data) for one JSONL file without holding it in memory.

    A substring pre-filter rejects lines that cannot contain the event before
    paying for json.loads, which is what makes a 163 MB batch tractable. The
    filter matches the quoted event name only, so it is a superset of the real
    matches and cannot drop a record.
    """
    probes = tuple('"%s"' % e for e in events) if events else ()
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if probes and not any(p in line for p in probes):
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue
            event = record.get("event")
            if events and event not in events:
                continue
            data = record.get("data")
            if not isinstance(data, dict):
                data = {}
            stamp = record.get("time")
            if stamp is None:
                stamp = data.get("time")
            yield (float(stamp or 0.0), event, data)


def find_telemetry(batch_dir):
    """All rts-ai-*.jsonl under a batch directory, sorted for stable output."""
    found = []
    for base, _dirs, files in os.walk(batch_dir):
        for name in files:
            if name.startswith("rts-ai-") and name.endswith(".jsonl"):
                found.append(os.path.join(base, name))
    return sorted(found)


def _num(value, default=0.0):
    """Coerce telemetry scalars. The emitter writes floats but older batches
    hold strings, so nothing here may assume a numeric type."""
    if value is None:
        return default
    try:
        out = float(value)
    except (TypeError, ValueError):
        return default
    if out != out or out in (float("inf"), float("-inf")):
        return default
    return out


def _is_coordinate(value):
    """True only for a real numeric coordinate. Unlike _num this never invents
    a value, because a missing coordinate means 'unknown', not 'at the origin'.
    """
    if value is None or isinstance(value, str):
        return False
    try:
        out = float(value)
    except (TypeError, ValueError):
        return False
    return out == out and out not in (float("inf"), float("-inf"))


def _near(x, z, anchor_x, anchor_z, radius):
    return math.hypot(x - anchor_x, z - anchor_z) <= radius


def _median(values):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    mid = len(values) // 2
    if len(values) % 2:
        return values[mid]
    return (values[mid - 1] + values[mid]) / 2.0


def _percentile(values, pct):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    position = pct / 100.0 * (len(values) - 1)
    low = int(math.floor(position))
    high = min(low + 1, len(values) - 1)
    frac = position - low
    return values[low] * (1 - frac) + values[high] * frac


def _mean(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


# --------------------------------------------------------------------------
# Per-run accumulator.
# --------------------------------------------------------------------------


class RunAccumulator:
    """Collects every tactic metric for a single telemetry file."""

    def __init__(self):
        # CONTEST series per faction: (time, valueOnPrimary, valueOnGroups)
        self.contest = defaultdict(list)
        # (time, groupCount, stalledGroups, worstStall, mission histogram)
        self.contest_shape = defaultdict(list)
        self.station_hull = {}          # faction -> last known fraction
        self.station_hull_min = {}      # faction -> deepest damage seen
        self.group_pos = {}             # (faction, group) -> (x, z)
        self.group_hhi = defaultdict(list)
        self.target_hhi = defaultdict(list)
        self.deep_hits = Counter()
        self.sample_count = Counter()
        self.edge_hits = Counter()
        self.guard_value = defaultdict(float)
        self.guard_total = defaultdict(float)
        self.guard_value_healthy = defaultdict(float)
        self.guard_total_healthy = defaultdict(float)
        self.stall_state = defaultdict(dict)   # faction -> group -> (stalled, flagged_at)
        self.recovery_times = []
        self.withdrawals = Counter()
        self.transitions = Counter()
        self.prev_ages = []
        self.losses = Counter()
        self.decisions = Counter()
        self.preempts = Counter()
        self.preempt_capital = Counter()
        self.decoys = []                # pending (deadline, owner, x, z)
        self.decoys_total = 0
        self.decoys_converted = 0
        self.decoys_unplaced = 0
        self.damage_taken = Counter()  # faction -> combat hook hull damage received
        self.damage_received = Counter()  # faction -> FACTION.received, planner side
        self.ff_damage = defaultdict(float)
        self.ff_window_damage = Counter()
        self.shared_pairs = 0
        self.shared_pairs_far = 0
        self.run_seconds = 0.0

    # -- ingestion ------------------------------------------------------------

    def feed(self, time, event, data):
        if time > self.run_seconds:
            self.run_seconds = time
        handler = getattr(self, "_on_" + event.lower(), None)
        if handler is not None:
            handler(time, data)

    def _on_cohesion(self, time, data):
        faction = data.get("faction")
        if faction is None:
            return
        nodes = data.get("nodes") or []
        self.sample_count[faction] += 1
        if _num(data.get("nearArenaEdge")) > 0:
            self.edge_hits[faction] += 1

        # A missing coordinate must stay missing. Coercing it to 0.0 would
        # silently place the station or the objective at the arena origin and
        # turn every distance comparison into nonsense that still looks like a
        # number. _num cannot be used for this: its default is 0.0.
        raw_station = (data.get("stationX"), data.get("stationZ"))
        raw_primary = (data.get("primaryX"), data.get("primaryZ"))
        has_station = all(_is_coordinate(v) for v in raw_station)
        has_primary = all(_is_coordinate(v) for v in raw_primary)
        station_x, station_z = (_num(v) for v in raw_station)
        primary_x, primary_z = (_num(v) for v in raw_primary)
        has_geometry = has_station and has_primary

        total_value = 0.0
        guard_value = 0.0
        deep = False
        for node in nodes:
            group = node.get("group")
            raw_x = node.get("x")
            raw_z = node.get("z")
            x = _num(raw_x)
            z = _num(raw_z)
            value = max(0.0, _num(node.get("value")))
            total_value += value
            if group is None or raw_x is None or raw_z is None:
                continue
            self.group_pos[(faction, group)] = (x, z)
            if has_station and _near(x, z, station_x, station_z, GUARD_RADIUS_M):
                guard_value += value
            # The midpoint test compares distance to the objective against
            # distance to home, so both anchors must be known. With only one
            # known the comparison is meaningless and must not be attempted.
            if has_geometry and not deep:
                if math.hypot(x - primary_x, z - primary_z) < math.hypot(
                        x - station_x, z - station_z):
                    deep = True
        if deep:
            self.deep_hits[faction] += 1

        if total_value > 0:
            by_target = defaultdict(float)
            squares = 0.0
            for node in nodes:
                value = max(0.0, _num(node.get("value")))
                if value <= 0:
                    continue
                share = value / total_value
                squares += share * share
                sig = node.get("targetSignature")
                by_target[sig if sig is not None else ("#%s" % node.get("group"))] += value
            self.group_hhi[faction].append(squares)
            self.target_hhi[faction].append(
                sum((v / total_value) ** 2 for v in by_target.values()))

        for pair in data.get("pairs") or []:
            if pair.get("sharedTarget"):
                self.shared_pairs += 1
                if _num(pair.get("distance")) > FAR_SHARE_M:
                    self.shared_pairs_far += 1

        hull = self.station_hull.get(faction)
        if has_station and hull is not None:
            if hull < STATION_DAMAGED:
                self.guard_value[faction] += guard_value
                self.guard_total[faction] += total_value
            else:
                self.guard_value_healthy[faction] += guard_value
                self.guard_total_healthy[faction] += total_value

    def _on_contest(self, time, data):
        faction = data.get("faction")
        if faction is None:
            return
        primary = max(0.0, _num(data.get("valueOnPrimary")))
        groups_value = max(0.0, _num(data.get("valueOnGroups")))
        self.contest[faction].append((time, primary, groups_value))
        missions = data.get("missionCounts") or {}
        self.contest_shape[faction].append((
            time,
            max(0.0, _num(data.get("groupCount"))),
            max(0.0, _num(data.get("stalledGroups"))),
            max(0.0, _num(data.get("worstStallSeconds"))),
            dict(missions),
        ))

        hull = data.get("stationHull")
        if hull is not None:
            hull = _num(hull)
            self.station_hull[faction] = hull
            prior = self.station_hull_min.get(faction)
            if prior is None or hull < prior:
                self.station_hull_min[faction] = hull

        for group in data.get("groups") or []:
            gid = group.get("group")
            if gid is None:
                continue
            stalled = _num(group.get("stalledSeconds"))
            if stalled > STALL_FLAG_S:
                # flagged_at is when the emitter first reported this group as
                # stalled; the emitter only clears stalledSeconds once the group
                # has closed 150 m again, so a drop below the threshold is a
                # genuine recovery rather than the flag ageing out of the record.
                self.stall_state[faction].setdefault(gid, time)
            else:
                flagged_at = self.stall_state[faction].pop(gid, None)
                if flagged_at is not None and time > flagged_at:
                    self.recovery_times.append(time - flagged_at)

    def _on_objective(self, time, data):
        faction = data.get("faction")
        mission = data.get("mission")
        self.transitions[faction] += 1
        if mission in ("REGROUP", "RETREAT"):
            self.withdrawals[faction] += 1
        age = data.get("previousAge")
        if age is not None:
            self.prev_ages.append(_num(age))

    def _on_loss(self, time, data):
        self.losses[data.get("faction")] += 1

    def _on_decision(self, time, data):
        faction = data.get("faction")
        self.decisions[faction] += 1
        if data.get("reason") == "CAPITAL_THREAT_PREEMPTION":
            self.preempts[faction] += 1
            if data.get("targetRole") in CAPITAL_ROLES:
                self.preempt_capital[faction] += 1
        if self.decoys and faction is not None:
            self._resolve_decoys(time, faction, data)

    def _on_tactic(self, time, data):
        mission = data.get("mission")
        if mission not in ("FEINT", "LURE", "TRAP"):
            return
        faction = data.get("faction")
        position = self.group_pos.get((faction, data.get("group")))
        if position is None:
            # COHESION has not placed this group yet, so the decoy cannot be
            # scored. Counted separately so a batch with no placement is
            # visibly 'no data' rather than silently 0% conversion.
            self.decoys_unplaced += 1
            return
        self.decoys_total += 1
        self.decoys.append((time + LURE_WINDOW_S, faction, position[0], position[1]))

    def _on_faction(self, time, data):
        faction = data.get("faction")
        # FACTION.received is the planner's per-ship hull-loss accumulator for
        # this faction. It is the only 'damage this faction took' figure that
        # is independent of the combat hook, which matters because the hook
        # numbers are used to derive damage dealt.
        received = data.get("received")
        if isinstance(received, (int, float)) and received == received:
            self.damage_received[faction] = max(self.damage_received[faction],
                                                float(received))
        # combatDamageTelemetry.interval is keyed by TARGET faction and reset on
        # every FACTION summary, so summing it over a run gives cumulative hull
        # damage received.
        #
        # FACTION.damageDealt is deliberately NOT used. fs2rts_ai_planning.lua
        # fills it from CombatDamageTelemetry.totalByFaction[kind], and that
        # table is keyed by targetFaction (fs2rts_ai_telemetry.lua:186-188), so
        # the field carries damage the faction RECEIVED. Verified against staged
        # batches: in sentryfix-20261001 damageDealt is byte-identical to the
        # summed interval hullDamage for all three factions. Batches written
        # before the field was numeric carry the string 'unknown' instead.
        combat = (data.get("combatDamageTelemetry") or {}).get("interval") or {}
        hull = max(0.0, _num(combat.get("hullDamage")))
        self.damage_taken[faction] += hull
        self.ff_window_damage[faction] += hull
        for row in combat.get("friendlyFirePairs") or []:
            self.ff_damage[faction] += max(0.0, _num(row.get("hullDamage")))

    def _damage_dealt(self, faction):
        """Hull damage this faction inflicted.

        Derived as the damage every *other* faction received. In a closed
        three-faction battle this is exact, and it is the only derivation that
        works across all staged batches given the mislabelled damageDealt field
        documented in _on_faction.
        """
        return sum(v for f, v in self.damage_taken.items() if f != faction)

    def _resolve_decoys(self, time, faction, data):
        """Did this enemy group commit a target inside a pending decoy's radius?"""
        tx = data.get("targetX")
        tz = data.get("targetZ")
        if not (_is_coordinate(tx) and _is_coordinate(tz)):
            return
        tx = _num(tx)
        tz = _num(tz)
        kept = []
        for deadline, owner, x, z in self.decoys:
            if time > deadline:
                continue
            if faction != owner and math.hypot(tx - x, tz - z) <= LURE_CAPTURE_M:
                self.decoys_converted += 1
                continue
            kept.append((deadline, owner, x, z))
        self.decoys = kept

    # -- results --------------------------------------------------------------

    def _per_faction_mean(self, getter, factions=None):
        if factions is None:
            factions = (set(self.losses) | set(self.damage_taken)
                        | set(self.ff_window_damage) | set(self.decisions))
        values = []
        for faction in sorted(f for f in factions if f is not None):
            value = getter(faction)
            if value is not None:
                values.append(value)
        return _mean(values)

    def metrics(self):
        out = {}

        # -- concentration
        ratios = []
        peaks = defaultdict(float)
        engaged = 0
        with_primary = 0
        for series in self.contest.values():
            for _t, primary, groups_value in series:
                total = primary + groups_value
                if total <= 0:
                    continue
                engaged += 1
                ratios.append(primary / total)
                if primary > 0:
                    with_primary += 1
        for faction, series in self.contest.items():
            for _t, primary, _g in series:
                if primary > peaks[faction]:
                    peaks[faction] = primary
        out["objective_commit_ratio"] = _mean(ratios)
        out["value_on_primary_peak"] = max(peaks.values()) if peaks else None
        out["commitment_duty_cycle"] = (with_primary / engaged) if engaged else None
        out["group_value_hhi"] = _mean(
            [v for series in self.group_hhi.values() for v in series])
        out["mean_groups_per_faction"] = self._mean_group_count()

        # -- arrival coherence
        episodes = 0
        durations = []
        for series in self.contest.values():
            run_start = None
            last = None
            for time, primary, _groups in series:
                if primary > MIN_ASSAULT_PEAK:
                    if run_start is None:
                        run_start = time
                    last = time
                elif run_start is not None:
                    episodes += 1
                    durations.append(last - run_start)
                    run_start = None
            if run_start is not None:
                episodes += 1
                durations.append(last - run_start)
        minutes = self.run_seconds / 60.0 if self.run_seconds > 0 else 0.0
        out["assault_episodes_per_minute"] = (
            episodes / minutes) if minutes > 0 else None
        out["assault_sustain_seconds"] = _median(durations)
        out["value_volatility"] = self._volatility()

        # -- stall discipline
        stall_num = 0.0
        stall_den = 0.0
        worst = []
        for faction, series in self.contest_shape.items():
            for _t, group_count, stalled, worst_stall, _missions in series:
                # stalledGroups is a count, groupCount the denominator. A sample
                # with no groups has no ratio to contribute and is skipped
                # rather than counted as a clean sample.
                if group_count <= 0:
                    continue
                stall_num += stalled / group_count
                stall_den += 1.0
                worst.append(worst_stall)
        out["stalled_group_ratio"] = (stall_num / stall_den) if stall_den else None
        out["stall_p95_seconds"] = _percentile(worst, 95)
        out["stall_recovery_seconds"] = _median(self.recovery_times)

        # -- depth
        total_samples = sum(self.sample_count.values())
        out["deep_commit_fraction"] = (
            sum(self.deep_hits.values()) / total_samples) if total_samples else None
        out["near_arena_edge_fraction"] = (
            sum(self.edge_hits.values()) / total_samples) if total_samples else None

        # -- withdrawal
        total_withdrawals = sum(self.withdrawals.values())
        total_losses = sum(self.losses.values())
        out["withdrawal_per_loss"] = (
            total_withdrawals / total_losses) if total_losses else None

        regroup_time = 0.0
        group_time = 0.0
        for series in self.contest_shape.values():
            for _t, _gc, _st, _ws, missions in series:
                for mission, count in missions.items():
                    count = _num(count)
                    group_time += count
                    if mission in ("REGROUP", "RETREAT"):
                        regroup_time += count
        out["retreat_duty_cycle"] = (
            regroup_time / group_time) if group_time else None
        out["order_commitment_seconds"] = _mean(self.prev_ages)

        # -- defence
        damaged = sum(self.guard_value.values())
        damaged_all = sum(self.guard_total.values())
        healthy = sum(self.guard_value_healthy.values())
        healthy_all = sum(self.guard_total_healthy.values())
        share_damaged = (damaged / damaged_all) if damaged_all else None
        share_healthy = (healthy / healthy_all) if healthy_all else None
        out["station_guard_response"] = (
            (share_damaged - share_healthy) * 100.0
            if share_damaged is not None and share_healthy is not None else None)
        out["_guard_share_damaged"] = share_damaged
        out["_guard_share_healthy"] = share_healthy
        mins = list(self.station_hull_min.values())
        out["station_hull_min"] = min(mins) if mins else None

        # -- threat response
        total_decisions = sum(self.decisions.values())
        out["capital_preempt_rate"] = (
            1000.0 * sum(self.preempts.values()) / total_decisions
        ) if total_decisions else None
        total_preempts = sum(self.preempts.values())
        out["preempt_on_capital_rate"] = (
            sum(self.preempt_capital.values()) / total_preempts
        ) if total_preempts else None

        # -- deception
        deception_time = 0.0
        for series in self.contest_shape.values():
            for _t, _gc, _st, _ws, missions in series:
                for mission in ("FEINT", "LURE", "TRAP"):
                    deception_time += _num(missions.get(mission))
        out["deception_duty_cycle"] = (
            deception_time / group_time) if group_time else None
        out["lure_conversion"] = (
            self.decoys_converted / self.decoys_total) if self.decoys_total else None
        out["_decoys"] = self.decoys_total
        out["_decoys_unplaced"] = self.decoys_unplaced

        # -- focus fire
        out["target_value_hhi"] = _mean(
            [v for series in self.target_hhi.values() for v in series])
        out["coincident_share_rate"] = (
            self.shared_pairs_far / self.shared_pairs) if self.shared_pairs else None

        # -- attrition
        out["damage_per_loss"] = self._per_faction_mean(
            lambda f: (self._damage_dealt(f) / self.losses[f]) if self.losses[f] else None)
        # Damage taken here is FACTION.received, the planner's own per-ship hull
        # loss accumulator, which is a different measurement from the combat
        # hook totals used for _damage_dealt. Using the combat numbers on both
        # sides would force the ratio to exactly 1.0 by construction.
        out["damage_exchange_ratio"] = self._per_faction_mean(
            lambda f: (self._damage_dealt(f) / self.damage_received[f])
            if self.damage_received.get(f) else None)
        out["friendly_fire_damage_ratio"] = self._per_faction_mean(
            lambda f: (self.ff_damage[f] / self.ff_window_damage[f])
            if self.ff_window_damage[f] else None)

        out["_run_seconds"] = self.run_seconds
        out["_losses"] = total_losses
        out["_transitions"] = sum(self.transitions.values())
        out["_damage_dealt_by_faction"] = {
            f: self._damage_dealt(f) for f in sorted(self.damage_taken)}
        out["_decoys_converted"] = self.decoys_converted
        return out

    def _mean_group_count(self):
        """Mean simultaneous groups per faction.

        CONTEST is the source because it carries groupCount in the same record
        as stalledGroups and missionCounts, so the concentration and stall
        families share one denominator and one clock. COHESION also reports
        groupCount at 2 s; using both would double-count and mix cadences.
        """
        total = 0.0
        samples = 0
        for series in self.contest_shape.values():
            for _t, group_count, _stalled, _worst, _missions in series:
                total += group_count
                samples += 1
        return (total / samples) if samples else None

    def _volatility(self):
        """Coefficient of variation of committed value within each faction's
        engaged samples, averaged over factions."""
        values = []
        for series in self.contest.values():
            engaged = [primary for _t, primary, groups in series
                       if primary + groups > 0]
            if len(engaged) < 2:
                continue
            mean = sum(engaged) / len(engaged)
            if mean <= 0:
                continue
            variance = sum((v - mean) ** 2 for v in engaged) / len(engaged)
            values.append(math.sqrt(variance) / mean)
        return _mean(values)


# --------------------------------------------------------------------------
# Batch level.
# --------------------------------------------------------------------------


def analyse_run(path):
    acc = RunAccumulator()
    for time, event, data in iter_records(path, _NEEDED):
        acc.feed(time, event, data)
    result = acc.metrics()
    result["_file"] = os.path.basename(path)
    return result


def analyse_batch(batch_dir, verbose=False):
    paths = find_telemetry(batch_dir)
    runs = []
    for path in paths:
        run = analyse_run(path)
        runs.append(run)
        if verbose:
            sys.stderr.write("  %-28s losses=%-4d seconds=%.0f\n"
                             % (run["_file"], run["_losses"], run["_run_seconds"]))
    return {"batch": os.path.basename(os.path.normpath(batch_dir)),
            "runs": runs,
            "aggregate": aggregate(runs)}


def aggregate(runs):
    out = {}
    for name in METRICS:
        values = [r.get(name) for r in runs if r.get(name) is not None]
        out[name] = {"mean": _mean(values),
                     "min": min(values) if values else None,
                     "max": max(values) if values else None,
                     "n": len(values)}
    out["_run_seconds"] = sum(_num(r.get("_run_seconds")) for r in runs)
    out["_losses"] = sum(int(_num(r.get("_losses"))) for r in runs)
    out["_transitions"] = sum(int(_num(r.get("_transitions"))) for r in runs)
    out["_runs"] = len(runs)
    return out


def separation(metric, good_runs, other_runs):
    """Did every run in `other_runs` land strictly on the wrong side of every
    run in `good_runs`?

    Returns (verdict, ratio, strength).

    `ratio` is expressed so that 1.0 means no difference and a value below 1.0
    always means the compared batch is worse, whichever direction the metric
    runs in. `strength` is the plain relative gap in the metric's own units.

    'insufficient' means a run produced no value at all, which is a data gap
    and must never be read as a pass.
    """
    spec = METRICS[metric]
    if spec["polarity"] == AMBIGUOUS:
        return ("ambiguous", None, None)
    good = [r[metric] for r in good_runs if r.get(metric) is not None]
    other = [r[metric] for r in other_runs if r.get(metric) is not None]
    if not good or not other:
        return ("insufficient", None, None)
    g_lo, g_hi = min(good), max(good)
    o_lo, o_hi = min(other), max(other)
    g_mean = sum(good) / len(good)
    o_mean = sum(other) / len(other)
    # Always express the ratio as a degradation factor: above 1.0 means the
    # compared batch is worse, regardless of which way the metric runs. A
    # report column mixing 'x4 better' and 'x0.25 better' is unreadable.
    if spec["polarity"] == HIGHER_BETTER:
        ok = o_hi < g_lo
        ratio = g_mean / o_mean if o_mean else None
    else:
        ok = o_lo > g_hi
        ratio = o_mean / g_mean if g_mean else None
    strength = abs(g_mean - o_mean) / abs(g_mean) if g_mean else None
    return ("separates" if ok else "overlaps", ratio, strength)


# --------------------------------------------------------------------------
# Reporting.
# --------------------------------------------------------------------------


def format_value(spec, value):
    if value is None:
        return "n/a"
    unit = spec.get("unit", "")
    if unit == "ratio":
        return "%.3f" % value
    if unit == "fraction":
        return "%.1f%%" % (value * 100.0)
    if unit == "pp":
        return "%+.1fpp" % value
    if unit == "index":
        return "%.3f" % value
    if unit == "seconds":
        return "%.1fs" % value
    if unit == "per 1k decisions":
        return "%.2f" % value
    if unit == "per loss":
        return "%.2f" % value
    if unit == "coefficient":
        return "%.2f" % value
    if unit == "episodes/min":
        return "%.2f" % value
    if unit == "groups":
        return "%.1f" % value
    if unit in ("value", "damage/ship"):
        return "%.0f" % value
    return "%.2f" % value


def report(batches, baseline=None):
    names = [b["batch"] for b in batches]
    # Accept a full path for --baseline; batches are keyed by directory name.
    base_name = os.path.basename(os.path.normpath(baseline)) if baseline else names[0]
    if base_name not in names:
        base_name = names[0]
    base_idx = names.index(base_name)
    # Comparison is PAIRWISE against the baseline. Pooling every other batch
    # into one 'others' group hides a metric that cleanly separates the baseline
    # from one batch but not from another, which is the whole question being
    # asked.
    comparisons = [(i, n) for i, n in enumerate(names) if i != base_idx]

    lines = []
    lines.append("AI TACTICAL QUALITY - derived from existing telemetry only")
    lines.append("=" * 116)
    for batch in batches:
        agg = batch["aggregate"]
        lines.append("%-26s runs=%-3d sim-seconds=%-7.0f losses=%-5d "
                     "order-transitions=%d"
                     % (batch["batch"], agg["_runs"], agg["_run_seconds"],
                        agg["_losses"], agg["_transitions"]))
    lines.append("")
    lines.append("baseline: %s     each other batch is compared to it separately"
                 % base_name)
    lines.append("")
    lines.append("separation test: every run of the compared batch lands strictly on the")
    lines.append("wrong side of every baseline run. 'overlaps' means the run ranges")
    lines.append("intersect, so the metric is not evidence either way.")
    lines.append("")

    width = 20
    header = "metric".ljust(26) + "polarity".ljust(10)
    for name in names:
        header += name[:width].rjust(width)
    for _i, n in comparisons:
        header += ("vs " + n[:width - 3]).rjust(width + 2)
    lines.append(header)
    lines.append("-" * 116)

    verdicts = {n: {} for _i, n in comparisons}
    ambiguous = []
    for family, label in FAMILIES:
        lines.append("")
        lines.append(label)
        for name, spec in METRICS.items():
            if spec["family"] != family:
                continue
            row = spec["title"][:24].ljust(26)
            row += (spec["polarity"][:8] if spec["polarity"] != AMBIGUOUS
                    else "ambig").ljust(10)
            for batch in batches:
                row += format_value(spec, batch["aggregate"][name]["mean"]).rjust(width)
            if spec["polarity"] == AMBIGUOUS:
                ambiguous.append(name)
                row += "  diagnostic".rjust(width + 2)
            else:
                for idx, other_name in comparisons:
                    verdict, ratio, _strength = separation(
                        name, batches[base_idx]["runs"], batches[idx]["runs"])
                    verdicts[other_name][name] = (verdict, ratio)
                    if verdict == "separates":
                        cell = ("WORSE x%.2f" % ratio) if ratio else "SEPARATES"
                    elif verdict == "overlaps":
                        cell = "overlaps"
                    else:
                        cell = "NO DATA"
                    row += cell.rjust(width + 2)
            lines.append(row)

    lines.append("")
    lines.append("=" * 116)
    for _idx, other_name in comparisons:
        table = verdicts[other_name]
        sep = sorted((n for n, (v, _) in table.items() if v == "separates"),
                     key=lambda n: -(table[n][1] or 0))
        over = sorted(n for n, (v, _) in table.items() if v == "overlaps")
        nodata = sorted(n for n, (v, _) in table.items() if v == "insufficient")
        lines.append("vs %s" % other_name)
        lines.append("  WORSE (%d, with degradation factor): %s"
                     % (len(sep), ", ".join(
                         "%s x%.2f" % (n, table[n][1]) for n in sep if table[n][1])
                      or "none"))
        lines.append("  OVERLAPS (%d): %s" % (len(over), ", ".join(over) or "none"))
        lines.append("  NO DATA  (%d): %s" % (len(nodata), ", ".join(nodata) or "none"))
    lines.append("DIAGNOSTIC (%d, direction unresolved): %s"
                 % (len(ambiguous), ", ".join(ambiguous) or "none"))
    return "\n".join(lines), verdicts, ambiguous


def gaps_report():
    lines = ["", "=" * 104,
             "GAPS - tactical questions the current telemetry cannot answer"]
    for question, why, field in GAPS:
        lines.append("")
        lines.append("* %s" % question)
        lines.append("    why:   %s" % why)
        lines.append("    field: %s" % field)
    return "\n".join(lines)


def metric_help(name):
    spec = METRICS[name]
    return "\n".join([
        "%s  (%s)" % (name, spec["title"]),
        "  polarity: %s%s" % (spec["polarity"],
                              "  [diagnostic, never scored]" if spec.get("diagnostic") else ""),
        "  family:   %s" % spec["family"],
        "  unit:     %s" % spec["unit"],
        "  source:   %s" % spec["source"],
        "  measures: %s" % spec["description"],
        "  why %s is %s: %s" % (
            "higher" if spec["polarity"] == HIGHER_BETTER else
            "lower" if spec["polarity"] == LOWER_BETTER else "ambiguous",
            spec["polarity"],
            spec["rationale"]),
    ])


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Score AI tactical quality from staged headless telemetry.")
    parser.add_argument("batches", nargs="*",
                        help="batch directories holding results/**/rts-ai-*.jsonl")
    parser.add_argument("--baseline", default=None,
                        help="batch used as the 'good' reference for separation")
    parser.add_argument("--json", action="store_true", dest="as_json")
    parser.add_argument("--metric", default=None,
                        help="explain one metric and exit")
    parser.add_argument("--gaps", action="store_true", help="print the gap list and exit")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    if args.gaps:
        print(gaps_report())
        return 0
    if args.metric:
        if args.metric not in METRICS:
            parser.error("unknown metric %r" % args.metric)
        print(metric_help(args.metric))
        return 0
    if not args.batches:
        parser.error("at least one batch directory is required")

    results = []
    for batch_dir in args.batches:
        if args.verbose:
            sys.stderr.write("scanning %s\n" % batch_dir)
        results.append(analyse_batch(batch_dir, verbose=args.verbose))

    if args.as_json:
        print(json.dumps({
            "batches": [{"batch": b["batch"], "aggregate": b["aggregate"],
                         "runs": b["runs"]} for b in results],
            "polarity": {k: v["polarity"] for k, v in METRICS.items()},
            "gaps": [{"question": q, "why": w, "field": f} for q, w, f in GAPS],
        }, indent=2, sort_keys=True))
        return 0

    table, *_ = report(results, args.baseline)
    print(table)
    print(gaps_report())
    return 0


if __name__ == "__main__":
    sys.exit(main())
