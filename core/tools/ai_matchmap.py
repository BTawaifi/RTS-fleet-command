"""Match visualiser and decision-explainer for RTS-fleet-command headless runs.

A headless batch writes 20-40 MB of JSONL per match and the existing tools
reduce it to scalars (economy, production, losses, idle ships). Nothing shows
WHAT the AI did on the map or WHY it picked an objective. This tool does both,
from the same reconstruction pass, because both need the same join: the only
positions in the telemetry are group-level, so a ship's death or its shots can
only be located by joining the ship to its group and taking the group's last
known centroid.

    python ai_matchmap.py <batch> --outdir out                       # all maps
    python ai_matchmap.py <batch> --outdir out --no-png              # text only
    python ai_matchmap.py <batch> --explain GROUP=W18:bomber --from 1200 --to 1400
    python ai_matchmap.py <batch> --explain-target CLASS="GTB Zeus"
    python ai_matchmap.py <batch> --timeline
    python ai_matchmap.py <batch> --json out/summary.json

WHAT IS REAL AND WHAT IS RECONSTRUCTED -- read this before trusting a pixel.

Positions are GROUP-CENTROID RESOLUTION ONLY. DECISION carries centroidX/Z plus
the group's ship list, COHESION.nodes[] carries per-group x/z every 2 s. No
record anywhere carries a per-ship position: UNIT carries baseDistance and
enemyBaseDistance, from which a ship can be trilaterated against the two
station positions, but that is a two-solution problem with a measured median
error of 6.9 km against the group centroid (probe over 3,366 UNIT records,
p90 16.0 km). It was rejected. Every coordinate this tool prints is a group
centroid, and --json reports the staleness distribution so the reader can see
how far each point has drifted. Measured staleness at death: p50 21 s, p90
110 s, max 275 s. For EXECUTION the ship is re-placed every ~2 s, so weapon-fire
points are fresh to p50 2 s.

DAMAGE_TELEMETRY_STATUS IS NOT A DAMAGE RECORD. It is emitted once per run at
t=0.25 s and carries only hook registration state (combatDamageRegistered,
registeredTargetCount, stationBeamTrackingRegistered). It has no positions, no
damage and no timestamps, so it cannot contribute to a combat map and does not
here. Weapon-fire evidence comes from EXECUTION.hitObserved (an observed hit by
the ship, with mode, distance and effectiveRange) plus LOSS.lethalHit (the
exchange that actually killed something) and FRIENDLY_HIT.

DECISION.candidates IS ABSENT FROM EVERY STAGED BATCH. g.candidates is only
built when Config.AI.DetailedDecisionTelemetry is true (fs2rts_ai_planning.lua
:258 and :574) and fs2rts_config.lua:748 sets DetailedDecisionTelemetry = false.
A scan of all 106 telemetry files under rts-headless-staging found 0 DECISION
records carrying candidates. The per-candidate table and its probabilities are
therefore reconstructed as follows, and the tool says which of the two it did:

  * candidates present -> the real table is printed: each candidate's score,
    role multiplier, distance, ETA, force ratio, weight, telemetry.probability
    and selected flag, plus the chosen-vs-runner-up margin.
  * candidates absent -> the record still carries score, switchingCost,
    previousAge and reason, and those DO constrain the outcome. Retaining is
    gated at fs2rts_ai_planning/battle_events.lua:15 by
        age < MinimumCommitmentSeconds  OR  challenger.score < incumbent.score + switchingCost
    so for an OBJECTIVE_RETAINED record with previousAge >= MinimumCommitmentSeconds
    the challenger's score is bounded above by score + switchingCost, and for a
    record with previousAge < MinimumCommitmentSeconds the retain was inertia,
    not score, and no score bound exists. Both cases are reported as bounds with
    the arithmetic shown, never as if the challenger's score were known.

ON A RETAINED DECISION, `score` IS THE INCUMBENT'S SCORE. Line :605 rebinds
chosen=current before :611 stamps chosen.score into the record, so for an
OBJECTIVE_RETAINED record the score field belongs to the objective that was
KEPT, and the rejected challenger's score is discarded. Read naively this
inverts the explanation. Handled explicitly in the replay.

WHY THE COMMIT SHARE IS THE HEADLINE NUMBER. fs2rts_ai_planning/group_roles.lua:116 splits
each group's value into exactly one of two buckets --
    if targetSignature==primarySignature then onBase=onBase+g.value
    else onGroups=onGroups+g.value end
so valueOnPrimary and valueOnGroups are MUTUALLY EXCLUSIVE and P/(P+G) is the
true fraction of assigned combat value sitting on the enemy station. Both are
recomputed from scratch every 10 s sample, so they are gauges, not flows: the
share is computed per sample and then averaged, never derived from summed
columns, which would weight every sample by that sample's fleet size.

Memory: files are streamed line by line and only compact accumulators are kept.
Points are buffered as growable float arrays and binned once at the end, so
peak memory is dominated by the numpy arrays, not by the file.
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt          # noqa: E402
import numpy as np                       # noqa: E402

TELEMETRY_GLOB = "rts-ai-*.jsonl"
FACTION_COLOR = {"BLUE": "#46dcff", "RED": "#ff4b4b", "GOLD": "#ffbe46",
    **{f"FACTION_{i:02d}": color for i,color in enumerate((
        "#2dbeff", "#46e669", "#c373ff", "#ff822d", "#ff64c3", "#bef046",
        "#6e64ff", "#3ce1b9", "#ff735f", "#ebebeb", "#7dff32", "#ff37ff",
        "#6496ff", "#dcc83c", "#9650dc", "#50e6e6", "#ff82e6", "#6e50c8",
        "#ffaa50", "#78c84b", "#c8a0ff", "#ff5a23", "#78f0be", "#e66ea0"), start=4)},
                 "GRAY": "#9aa5ad"}
DEFAULT_CELLS = 200
DEFAULT_PAD = 4000.0
BASE_DISTANCE_FALLBACK = 18000.0
# Doctrine keys read from RUN.doctrine; defaults mirror fs2rts_config.lua so the
# tool still works if a record is missing.
DOCTRINE_DEFAULTS = {
    "MinimumCommitmentSeconds": 8.0,
    "ObjectiveSwitchCost": 25.0,
    "LocalTargetRetentionSeconds": 8.0,
    "LocalStrengthRadius": 4500.0,
    "RetargetImprovementRatio": 0.25,
    "RetreatCommitSeconds": 25.0,
}
HEAVY_ROLES = ("capital", "heavy", "juggernaut")

# Plain-language decode of every reason code the planner can emit. Each entry
# names the file:line that produces it, because a decode that cannot be traced
# to the emitter is a guess.
REASON_TEXT = {
    "OPERATION_ROLE_TARGET": "campaign planner handed this group its role target",
    "DEFEND_BASE": "target is not hostile; group is on base defence",
    "COORDINATED_APPROACH": "moving to a coordinated approach point",
    "OPERATION_ASSEMBLE": "group is assembling for a campaign operation",
    "OPERATION_WITHDRAW": "campaign planner ordered the group out",
    "BREAKTHROUGH_EXPLOIT": "pushing through to exploit the breach",
    "WEAPON_ROLE": "plain role match: this wing's weapons fit that hull",
    "TARGET_HIGH_VALUE": "high-value target: fighters prioritise bombers (x1.8)",
    "TARGET_LOW_VALUE": "low-value target: heavy role match (x0.35)",
    "TARGET_BAD_ROLE_MATCH": "weapon/role mismatch: score forced to -100",
    "TARGET_UNREACHABLE": "target cannot be reached in time: score forced to -100",
    "TARGET_OVERCOMMITTED": "more than 1.8x the target's value is already assigned",
    "PUSH_ENEMY_BASE": "PRIMARY mission bonus applied (+35)",
    "CAPITAL_THREAT_PREEMPTION": "capital suppression: defence jumped the queue",
    "INTERCEPT_IMMEDIATE_THREAT": "hostile inside the hard engage radius",
    "LOCAL_ENGAGEMENT": "group is engaging a local contact it picked itself",
    "LOCAL_INFERIORITY": "local force too weak to push; regrouping instead",
    "LOCAL_FORCE_DISADVANTAGE": "luring because the local force is outmatched",
    "RETREAT": "damaged group breaking off",
    "WEAPONS_DISABLED": "group has no loaded ordnance bank left",
    "ESCORT_HIGH_VALUE_UNIT": "support/transport unit escorting the assault",
    "ESCORT_BOMBER_STRIKE": "escorting a bomber strike",
    "SUPPORT_ASSAULT": "escorting the assault anchor",
    "FORMATION_RECOVERY": "group spread wider than the regroup distance",
    "LURE_UNDER_PRESSURE": "luring pursuers back toward friendly defences",
    "LURE_COMPLETE_REJOIN_ASSAULT": "lure window over; rejoining the assault",
    "TRAP_LURE_PURSUIT": "pursuers drawn into a trap",
    "PURSUER_LOCKED": "a specific pursuer was identified and is being baited",
    "TAUNT_DECOY": "detached as a decoy to pull the enemy off the objective",
    "TAUNT_PROBE": "probing the enemy to draw a response",
    "SIEGE_TURRET_TARGET": "sustained fire on a station subsystem",
    "SUBSYSTEM_SUPPRESSION": "suppressing one specific subsystem",
    "OBJECTIVE_RETAINED": "kept the previous objective",
    "OBJECTIVE_NO_PROGRESS": "range to the objective stopped shrinking",
    "COMMITMENT_EXPIRED": "defence commitment timer expired",
    "OUTSIDE_RELEASE_RADIUS": "outside the radius the planned task releases at",
    "CAMPAIGN_FRONT_CHANGED": "campaign front moved; objective retargeted",
    "EMERGENCY_OVERRIDE": "emergency response overrode the plan",
    "TARGET_NOT_HOSTILE": "previous objective stopped being hostile",
}
REASON_SOURCE = {
    "OPERATION_ROLE_TARGET": "fs2rts_operations.lua:277",
    "DEFEND_BASE": "fs2rts_strategy/strategic_plan.lua:243",
    "COORDINATED_APPROACH": "fs2rts_ai_planning/candidates.lua:130",
    "OPERATION_ASSEMBLE": "fs2rts_ai_planning/battle_events.lua:54",
    "OPERATION_WITHDRAW": "fs2rts_operations.lua",
    "BREAKTHROUGH_EXPLOIT": "fs2rts_operations.lua:277",
    "WEAPON_ROLE": "fs2rts_ai_planning/candidates.lua:104",
    "TARGET_HIGH_VALUE": "fs2rts_ai_planning/candidates.lua:102",
    "TARGET_LOW_VALUE": "fs2rts_ai_planning/candidates.lua:100",
    "TARGET_BAD_ROLE_MATCH": "fs2rts_ai_planning/candidates.lua:97",
    "TARGET_UNREACHABLE": "fs2rts_ai_planning/candidates.lua:133",
    "TARGET_OVERCOMMITTED": "fs2rts_ai_planning/candidates.lua:132",
    "PUSH_ENEMY_BASE": "fs2rts_ai_planning/candidates.lua:131",
    "CAPITAL_THREAT_PREEMPTION": "fs2rts_strategy/strategic_plan.lua:239",
    "INTERCEPT_IMMEDIATE_THREAT": "fs2rts_strategy/strategic_plan.lua:259",
    "LOCAL_ENGAGEMENT": "fs2rts_strategy/strategic_plan.lua:331",
    "LOCAL_INFERIORITY": "fs2rts_strategy/strategic_plan.lua:320",
    "LOCAL_FORCE_DISADVANTAGE": "fs2rts_strategy/strategic_plan.lua:277",
    "RETREAT": "fs2rts_strategy/strategic_plan.lua:309",
    "WEAPONS_DISABLED": "fs2rts_strategy/strategic_plan.lua:314",
    "ESCORT_HIGH_VALUE_UNIT": "fs2rts_strategy/strategic_plan.lua:316",
    "ESCORT_BOMBER_STRIKE": "fs2rts_strategy/strategic_plan.lua:243",
    "SUPPORT_ASSAULT": "fs2rts_strategy/strategic_plan.lua:322",
    "FORMATION_RECOVERY": "fs2rts_strategy/strategic_plan.lua:324",
    "LURE_UNDER_PRESSURE": "fs2rts_strategy/strategic_plan.lua:307",
    "TRAP_LURE_PURSUIT": "fs2rts_strategy/strategic_plan.lua:240",
    "PURSUER_LOCKED": "fs2rts_strategy/strategic_plan.lua:277",
    "TAUNT_DECOY": "fs2rts_strategy/strategic_plan.lua:242",
    "TAUNT_PROBE": "fs2rts_strategy/strategic_plan.lua:242",
    "SIEGE_TURRET_TARGET": "fs2rts_strategy.lua",
    "SUBSYSTEM_SUPPRESSION": "fs2rts_strategy.lua",
    "OBJECTIVE_RETAINED": "fs2rts_ai_planning/battle_events.lua:16",
    "OBJECTIVE_NO_PROGRESS": "fs2rts_ai_planning/battle_events.lua:19",
    "COMMITMENT_EXPIRED": "fs2rts_strategy/threats.lua:129",
    "OUTSIDE_RELEASE_RADIUS": "fs2rts_strategy/threats.lua:131",
    "CAMPAIGN_FRONT_CHANGED": "fs2rts_ai_planning/battle_events.lua:20",
}
REASON_LOCKED = {
    "CAPITAL_THREAT_PREEMPTION", "TRAP_LURE_PURSUIT", "RETREAT",
    "WEAPONS_DISABLED", "LOCAL_INFERIORITY", "FORMATION_RECOVERY", "RETREAT",
    "EMERGENCY_OVERRIDE", "LURE_COMPLETE_REJOIN_ASSAULT",
}


# ------------------------------------------------------------------ utilities

def num(value):
    """Coerce a telemetry number. The mod emits 'unknown' in places."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        value = float(value)
        return None if math.isnan(value) or math.isinf(value) else value
    return None


def as_int(value):
    got = num(value)
    return None if got is None else int(got)


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


def pct(part, whole, digits=1):
    if part is None or whole in (None, 0):
        return "-"
    return f"{100.0 * part / whole:.{digits}f}"


def dist(ax, az, bx, bz):
    return math.hypot(ax - bx, az - bz)


def quantile(sorted_values, q):
    if not sorted_values:
        return None
    idx = int(len(sorted_values) * q)
    if idx >= len(sorted_values):
        idx = len(sorted_values) - 1
    return sorted_values[idx]


def median(sorted_values):
    return quantile(sorted_values, 0.5)


def sget(stats, key):
    """defaultdict.get() returns None for an unwritten key; every caller here
    wants the counter default, not a missing value."""
    try:
        return stats[key]
    except (KeyError, TypeError):
        return 0.0


def counters(stats, prefix):
    """Slice a prefix-tagged counter family out of a faction's stats dict."""
    return {k[len(prefix):]: v for k, v in stats.items() if k.startswith(prefix)}


def rows(container):
    """The mod emits a JSON table either as a dict or as a list depending on
    the Lua side. Both shapes show up in the same field across records."""
    if isinstance(container, dict):
        return [row for row in container.values() if isinstance(row, dict)]
    if isinstance(container, list):
        return [row for row in container if isinstance(row, dict)]
    return []


def table(mapping, key="count", reverse=True, limit=12):
    return ", ".join("%s=%s" % (k, fmt(v)) for k, v in
                     sorted(mapping.items(), key=lambda kv: (-kv[1] if reverse else kv[0],
                                                            str(kv[0])))[:limit])


# --------------------------------------------------------------- run discovery

def find_telemetry(target: Path):
    """Telemetry lives at results/w/<worker>/a-<id>/probe/data/rts-ai-*.jsonl.
    Prefer results/ so the multi-gigabyte base/ workspace is never walked.
    A single file path is accepted so one match can be iterated on."""
    if target.is_file():
        return [target] if target.match(TELEMETRY_GLOB) else []
    roots = [target / "results", target] if (target / "results").is_dir() else [target]
    for root in roots:
        found = sorted(root.rglob(TELEMETRY_GLOB))
        if found:
            return found
    return []


def batch_plan(target: Path):
    for candidate in [target, *target.parents]:
        plan = candidate / "batch.plan.json"
        if plan.is_file():
            try:
                return json.loads(plan.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return {}
    return {}


# --------------------------------------------------------------------- fields

class Field:
    """Growable buffer of weighted (x, z) samples, binned only when rendered."""

    __slots__ = ("name", "xs", "zs", "ws", "meta")

    def __init__(self, name):
        self.name = name
        self.xs = []
        self.zs = []
        self.ws = []
        self.meta = {}

    def add(self, x, z, weight=1.0):
        if x is None or z is None:
            return False
        self.xs.append(x)
        self.zs.append(z)
        self.ws.append(weight)
        return True

    def extend_meta(self, key, value):
        if value is None:
            return
        self.meta[key] = value

    def __len__(self):
        return len(self.xs)

    def total(self):
        return sum(self.ws) if self.ws else 0.0

    def arrays(self):
        return (np.asarray(self.xs, dtype=np.float64),
                np.asarray(self.zs, dtype=np.float64),
                np.asarray(self.ws, dtype=np.float64))

    def bin(self, bounds, cells):
        """Return (grid, samples) with grid[i, j] summing weights.

        grid[i, j] -> (x in [i, i+1), z in [j, j+1)) so imshow(origin='lower')
        lines up with extent [x0, x1, z0, z1]. `samples` is the (xs, zs, ws)
        triple, or None when the field is empty, for callers that want the raw
        points as well as the grid.
        """
        grid = np.zeros((cells, cells), dtype=np.float64)
        if not self.xs:
            return grid, None
        xs, zs, ws = self.arrays()
        ix = np.floor((xs - bounds[0]) / bounds[2]).astype(np.int64)
        iz = np.floor((zs - bounds[1]) / bounds[2]).astype(np.int64)
        keep = (ix >= 0) & (ix < cells) & (iz >= 0) & (iz < cells)
        np.add.at(grid, (ix[keep], iz[keep]), ws[keep])
        return grid, (xs, zs, ws)


def bounds_of(points, pad=DEFAULT_PAD, cells=DEFAULT_CELLS):
    """Square bounds covering every sample, snapped to a cell grid."""
    xs = [p[0] for p in points if p[0] is not None]
    zs = [p[1] for p in points if p[1] is not None]
    if not xs or not zs:
        return (0.0, 0.0, 1.0)
    lo_x, hi_x = min(xs) - pad, max(xs) + pad
    lo_z, hi_z = min(zs) - pad, max(zs) + pad
    span = max(hi_x - lo_x, hi_z - lo_z)
    cx, cz = (lo_x + hi_x) / 2.0, (lo_z + hi_z) / 2.0
    lo_x, lo_z = cx - span / 2.0, cz - span / 2.0
    size = span / float(cells)
    return (math.floor(lo_x / size) * size, math.floor(lo_z / size) * size, size)


def concentration(grid, share=0.10):
    """Fraction of total weight inside the busiest `share` of OCCUPIED cells.

    Measured over all cells instead, a sparse death map trivially scores 1.0
    because 63 deaths occupy fewer cells than the 10% cutoff."""
    total = float(grid.sum())
    if total <= 0:
        return 0.0
    flat = np.sort(grid.ravel())[::-1]
    occupied = int((flat > 0).sum())
    take = max(1, int(occupied * share))
    return float(flat[:take].sum()) / total


def robust_max(grid, quantile=0.99):
    """Cell count that a map should saturate at.

    A raw max lets three outlier cells flatten the rest of the map to
    background, which is exactly the wrong failure for a density plot.
    """
    if grid is None or not grid.any():
        return None
    nonzero = np.sort(grid[grid > 0].ravel())
    if not len(nonzero):
        return None
    return float(nonzero[min(len(nonzero) - 1, int(len(nonzero) * quantile))]) or 1.0


def peak_cell(grid, bounds):
    if not grid.any():
        return None
    idx = int(np.argmax(grid))
    i, j = divmod(idx, grid.shape[1])
    return (bounds[0] + (i + 0.5) * bounds[2], bounds[1] + (j + 0.5) * bounds[2],
            float(grid[i, j]))
# ------------------------------------------------------------------ accumulator

class MatchMap:
    """One match, one streaming pass. Every on_* method keeps O(1) state."""

    def __init__(self, path, cells=DEFAULT_CELLS):
        self.path = Path(path)
        self.cells = cells
        run_dir = self.path.parent.parent.parent.parent
        self.run_dir = run_dir
        worker = run_dir.name
        self.match_name = ("%s.%s" % (worker, self.path.stem)) if worker else self.path.stem
        self.end_time = 0.0
        self.events = collections.Counter()
        self.bad_lines = 0
        self.stations = {}              # faction -> (x, z)
        self.base_distance = BASE_DISTANCE_FALLBACK
        self.doctrine = dict(DOCTRINE_DEFAULTS)
        self.roster = {}                # class -> {"role":..,"tier":..}
        self.factions = []              # stable display order
        self.detailed_decisions = False

        # spatial fields, keyed by name
        self.fire = Field("combat_fire")            # EXECUTION hitObserved
        self.fire_hull = Field("combat_fire_hull")  # EXECUTION hitObserved + hullLoss
        self.losses = Field("losses")                # LOSS, positioned
        self.friendly = Field("friendly_fire")       # FRIENDLY_HIT, positioned
        self.dwell = {}                              # faction -> Field
        self.dwell_heavy = {}                        # faction -> Field, heavy roles
        self.stall = {}                              # faction -> Field
        self.deaths_by_class = {}                    # class -> Field
        self.deaths_heavy = Field("deaths_heavy")

        self.sentries = []                           # (t, faction, action, x, z)
        self.commit = collections.defaultdict(list)  # faction -> [(t, onPrimary, onGroups)]
        self.faction_stats = collections.defaultdict(_new_faction_stats)
        self.timelines = {}                          # (faction, group) -> timeline state
        self.decision_census = collections.Counter()
        self.reasons = collections.Counter()
        self.missions = collections.Counter()
        self.stale_orders = 0
        self.counters = {}
        self.outcomes = []
        self.tactics = []
        self.loss_rows = []
        self.staleness = []                          # seconds between a ship's
        self.fire_staleness = []                     # position and its use
        self.positioned_losses = 0
        self.unpositioned_losses = 0

        # ship index, rebuilt continuously: only the last known position matters
        self.ship_pos = {}      # ship -> (t, x, z, group, faction)
        self.ship_class = {}    # ship -> class name
        self.group_pos = {}     # (faction, group) -> (t, x, z)

        # optional decision capture for --explain
        self.decision_filter = None
        self.decisions = []

    # ---------------------------------------------------------------- streaming

    def consume(self):
        with self.path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    self.bad_lines += 1
                    continue
                data = record.get("data")
                if not isinstance(data, dict):
                    continue
                event = record.get("event")
                self.events[event] += 1
                self.end_time = num(record.get("time")) or self.end_time
                handler = _HANDLERS.get(event)
                if handler is not None:
                    handler(self, num(record.get("time")) or 0.0, record, data)
                self._capture(record, data)
        self._finish()
        return self

    def _capture(self, record, data):
        """Buffer DECISION records that --explain asked for."""
        if self.decision_filter is None or record.get("event") != "DECISION":
            return
        limit = self.decision_filter.limit
        if len(self.decisions) >= limit:
            return
        if not self.decision_filter.wants(record.get("time") or 0.0, data):
            return
        self.decisions.append((record.get("time"), data))

    def _finish(self):
        self.decisions.sort(key=lambda item: item[0])
        self.staleness.sort()
        self.fire_staleness.sort()
        for key, timeline in self.timelines.items():
            timeline["segments"].sort(key=lambda seg: seg["start"])

    # ------------------------------------------------------------------ handlers

    def on_run(self, time, record, data):
        self.detailed_decisions = data.get("detailedDecisionTelemetry") is True
        doctrine = data.get("doctrine")
        if isinstance(doctrine, dict):
            for key, fallback in DOCTRINE_DEFAULTS.items():
                self.doctrine[key] = first_num(doctrine, key) if num(doctrine.get(key)) is not None else fallback
            self.doctrine = {**doctrine, **{k: v for k, v in self.doctrine.items()}}
        balance = data.get("balance")
        rosters = (balance or {}).get("aiRosters")
        if isinstance(rosters, dict):
            for rows in rosters.values():
                for row in rows or []:
                    cls = row.get("class")
                    if cls:
                        self.roster[cls] = {"role": row.get("role"), "tier": num(row.get("tier"))}
        setup = data.get("setup")
        if isinstance(setup, dict):
            distance = first_num(setup, "baseDistanceUnits")
            if distance:
                self.base_distance = distance

    def on_setup(self, time, record, data):
        for faction, pos in (data.get("stationPositions") or {}).items():
            if isinstance(pos, dict) and num(pos.get("x")) is not None:
                self.stations[faction] = (pos["x"], pos["z"])
                self._add_faction(faction)
        distance = first_num(data, "baseDistanceUnits")
        if distance:
            self.base_distance = distance

    def _add_faction(self, faction):
        if faction and faction not in self.factions:
            self.factions.append(faction)

    def on_decision(self, time, record, data):
        faction = data.get("faction")
        group = data.get("group")
        self._add_faction(faction)
        self.reasons[data.get("reason")] += 1
        self.missions[data.get("mission")] += 1
        stats = self.faction_stats[faction]
        stats["decisions"] += 1
        stats["reason:" + str(data.get("reason"))] += 1
        stats["mission:" + str(data.get("mission"))] += 1
        stats["score_sum"] += num(data.get("score")) or 0.0
        stats["target:" + str(data.get("targetClass"))] += 1
        cx, cz = num(data.get("centroidX")), num(data.get("centroidZ"))
        if cx is None or cz is None:
            return
        stats["positioned"] += 1
        field = self.dwell.setdefault(faction, Field("dwell:" + str(faction)))
        field.add(cx, cz, 1.0)
        if data.get("role") in HEAVY_ROLES:
            self.dwell_heavy.setdefault(
                faction, Field("dwell_heavy:" + str(faction))).add(cx, cz, 1.0)
        key = (faction, group)
        self.group_pos[key] = (time, cx, cz)
        for ship in data.get("ships") or []:
            sid = as_int(ship)
            if sid is not None:
                self.ship_pos[sid] = (time, cx, cz, group, faction)
        timeline = self.timelines.setdefault(key, {"segments": [], "last": None,
                                                   "switches": 0, "first": time,
                                                   "group": group, "faction": faction})
        entry = (data.get("mission"), data.get("targetClass"), data.get("reason"))
        if timeline["last"] != entry:
            if timeline["last"] is not None:
                timeline["switches"] += 1
            timeline["segments"].append({
                "start": time, "mission": entry[0], "targetClass": entry[1],
                "reason": entry[2], "score": num(data.get("score")),
                "target": data.get("target"),
            })
            timeline["last"] = entry
        timeline["last_time"] = time

    def on_cohesion(self, time, record, data):
        faction = data.get("faction")
        for node in rows(data.get("nodes")):
            x, z = num(node.get("x")), num(node.get("z"))
            group = node.get("group")
            if x is None or z is None:
                continue
            self.group_pos[(faction, group)] = (time, x, z)
            if node.get("role") in HEAVY_ROLES:
                # COHESION samples every 2 s against the DECISION cadence, so it
                # is the denser source for where capital groups actually go.
                self.dwell_heavy.setdefault(
                    faction, Field("dwell_heavy:" + str(faction))).add(x, z, 1.0)
            stats = self.faction_stats[faction]
            stats["cohesion_nodes"] += 1
            stats["near_edge_samples"] += 1 if num(data.get("nearArenaEdge")) else 0
            pair_rows = rows(data.get("pairs"))
            if pair_rows:
                stats["cohesion_pairs"] += len(pair_rows)
                stats["shared_target_pairs"] += sum(
                    1 for pair in pair_rows if pair.get("sharedTarget") is True)

    def on_contest(self, time, record, data):
        faction = data.get("faction")
        self._add_faction(faction)
        on_primary = num(data.get("valueOnPrimary")) or 0.0
        on_groups = num(data.get("valueOnGroups")) or 0.0
        self.commit[faction].append((time, on_primary, on_groups))
        stats = self.faction_stats[faction]
        stats["contest_samples"] += 1
        total = on_primary + on_groups
        stats["share_sum"] += (on_primary / total) if total > 0 else 0.0
        if on_primary > 0:
            stats["samples_with_commit"] += 1
        else:
            stats["samples_without_commit"] += 1
        stats["peak_on_primary"] = max(stats["peak_on_primary"], on_primary)
        stats["sum_on_groups"] += on_groups
        stats["sum_on_primary"] += on_primary
        stats["stalled_groups"] += as_int(data.get("stalledGroups")) or 0
        stats["worst_stall"] = max(stats["worst_stall"],
                                   num(data.get("worstStallSeconds")) or 0.0)
        self.stale_orders += as_int(data.get("staleOrders")) or 0
        counts = data.get("missionCounts")
        if isinstance(counts, dict):
            for mission, value in counts.items():
                stats["group_mission:" + str(mission)] += as_int(value) or 0
        for node in rows(data.get("groups")):
                stalled = num(node.get("stalledSeconds")) or 0.0
                if stalled <= 0.0:
                    continue
                key = (faction, node.get("group"))
                stats["stall_records"] += 1
                stats["stall_seconds"] += stalled
                if node.get("targetIsStation") is True:
                    stats["stall_on_station_records"] += 1
                position = self.group_pos.get(key)
                if position and position[0] <= time:
                    self.stall.setdefault(faction, Field("stall:" + str(faction))).add(
                        position[1], position[2], stalled)
                    stats["stall_positioned"] += 1

    def on_execution(self, time, record, data):
        if not data.get("hitObserved"):
            return
        stats = self.faction_stats[data.get("faction")]
        stats["fire_events"] += 1
        stats["fire:" + str(data.get("mode"))] += 1
        hull = num(data.get("hullLoss")) or 0.0
        if hull > 0:
            stats["fire_hull_events"] += 1
            stats["fire_hull_damage"] += hull
        sid = as_int(data.get("ship"))
        position = self.ship_pos.get(sid) if sid is not None else None
        if position and position[0] <= time:
            self.fire.add(position[1], position[2], 1.0)
            if hull > 0:
                self.fire_hull.add(position[1], position[2], hull)
            self.fire_staleness.append(time - position[0])
            stats["fire_positioned"] += 1

    def on_friendly_hit(self, time, record, data):
        sid = as_int(data.get("ship"))
        position = self.ship_pos.get(sid) if sid is not None else None
        if position and position[0] <= time:
            self.friendly.add(position[1], position[2], 1.0)

    def on_loss(self, time, record, data):
        faction = data.get("faction")
        self._add_faction(faction)
        stats = self.faction_stats[faction]
        stats["losses"] += 1
        cls = data.get("class") or self.ship_class.get(as_int(data.get("ship")))
        if cls:
            self.ship_class[as_int(data.get("ship"))] = cls
        role = (self.roster.get(cls) or {}).get("role")
        lethal = data.get("lethalHit") or {}
        sid = as_int(data.get("ship"))
        position = self.ship_pos.get(sid) if sid is not None else None
        own = self.stations.get(faction)
        row = {
            "time": time, "faction": faction, "class": cls, "role": role,
            "ship": sid, "attackerFaction": lethal.get("attackerFaction"),
            "attackerClass": lethal.get("attackerClass"),
            "weaponClass": lethal.get("weaponClass"),
            "damageType": lethal.get("damageType"),
            "replacementCost": num(data.get("replacementCost")),
            "mission": (data.get("objective") or {}).get("mission"),
            "group": self.ship_pos.get(sid, (0, 0, 0, None, None))[3] if sid is not None else None,
            "x": None, "z": None, "distHome": None, "fracHome": None, "stale": None,
        }
        if position and position[0] <= time:
            x, z = position[1], position[2]
            row["x"], row["z"] = x, z
            row["stale"] = time - position[0]
            row["group"] = position[3]
            self.staleness.append(row["stale"])
            self.losses.add(x, z, 1.0)
            if own:
                d = dist(x, z, own[0], own[1])
                row["distHome"] = d
                row["fracHome"] = d / self.base_distance if self.base_distance else None
            self.positioned_losses += 1
            stats["positioned_losses"] += 1
            if cls:
                self.deaths_by_class.setdefault(cls, Field("death:" + cls)).add(x, z, 1.0)
            if role in HEAVY_ROLES:
                self.deaths_heavy.add(x, z, 1.0)
                stats["heavy_losses"] += 1
                stats["heavy_loss_cost"] += num(data.get("replacementCost")) or 0.0
                if lethal.get("attackerFaction") and lethal.get("attackerFaction") != faction:
                    stats["heavy_loss_to_%s" % lethal["attackerFaction"]] += 1
        else:
            self.unpositioned_losses += 1
            stats["unpositioned_losses"] += 1
        if role:
            stats["loss_role:" + role] += 1
        if row["mission"]:
            stats["loss_mission:" + str(row["mission"])] += 1
        else:
            # LOSS.objective is the order state as of death and is frequently
            # absent, so the coverage of this join has to be reported.
            stats["loss_mission_unknown"] += 1
        if lethal.get("attackerFaction") and lethal.get("attackerFaction") != faction:
            stats["killed_by:%s" % lethal["attackerFaction"]] += 1
        self.loss_rows.append(row)

    def on_sentry(self, time, record, data):
        pos = data.get("position")
        if not isinstance(pos, dict):
            return
        x, z = num(pos.get("x")), num(pos.get("z"))
        if x is None:
            return
        faction = data.get("faction")
        stats = self.faction_stats[faction]
        stats["sentry_" + str(data.get("action")).lower()] += 1
        if data.get("action") == "BUILD_COMPLETED":
            stats["sentries"] += 1
            self.sentries.append((time, faction, x, z))

    def on_objective(self, time, record, data):
        stats = self.faction_stats[data.get("faction")]
        stats["objective_transitions"] += 1
        stats["objective_status:" + str(data.get("status"))] += 1
        previous = data.get("previous")
        previous_mission = data.get("previousMission")
        if previous is not None:
            if previous_mission == data.get("mission"):
                stats["retarget_same_mission"] += 1
            else:
                stats["objective_mission_switches"] += 1
                stats["switch:%s->%s" % (previous_mission, data.get("mission"))] += 1
        age = num(data.get("previousAge"))
        if age is not None:
            stats["objective_age_sum"] += age
            stats["objective_age_n"] += 1

    def on_unit(self, time, record, data):
        sid = as_int(data.get("ship"))
        if sid is not None and data.get("class"):
            self.ship_class[sid] = data["class"]

    def on_faction(self, time, record, data):
        stats = self.faction_stats[data.get("faction")]
        plan = data.get("plan")
        if isinstance(plan, dict):
            stats["posture:" + str(plan.get("posture"))] += 1
            stats["can_push_samples"] += 1 if plan.get("canPush") else 0
            stats["urgent_samples"] += 1 if plan.get("urgent") else 0
        losses = data.get("losses")
        if isinstance(losses, dict):
            stats["faction_samples"] += 1
            for key, value in losses.items():
                seen = as_int(value) or 0
                tag = "loss_cum_max:" + str(key)
                if seen > sget(stats, tag):
                    stats[tag] = seen
        telemetry = data.get("combatDamageTelemetry")
        interval = (telemetry or {}).get("interval") if isinstance(telemetry, dict) else None
        if isinstance(interval, dict):
            stats["combat_hull_damage"] += num(interval.get("hullDamage")) or 0.0
            stats["combat_hits"] += as_int(interval.get("hitCount")) or 0
            stats["combat_lethal_hits"] += as_int(interval.get("lethalHits")) or 0

    def on_tactic(self, time, record, data):
        self.tactics.append({"time": time, "faction": data.get("faction"),
                             "group": data.get("group"), "mission": data.get("mission"),
                             "reason": data.get("reason"),
                             "targetClass": data.get("targetClass"),
                             "targetDistance": num(data.get("targetDistance")),
                             "forceRatio": num(data.get("forceRatio"))})
        stats = self.faction_stats[data.get("faction")]
        stats["tactics"] += 1
        stats["tactic:" + str(data.get("mission"))] += 1

    def on_production(self, time, record, data):
        cls = data.get("class")
        if not cls:
            return
        action = data.get("action") or "UNKNOWN"
        role = (self.roster.get(cls) or {}).get("role") or "unknown"
        stats = self.faction_stats[data.get("faction")]
        count = num(data.get("count")) or 0.0
        if count <= 0:
            count = 1.0
        stats["production_" + action] += 1
        if action == "QUEUE_ACCEPTED":
            stats["ordered_" + str(role)] += count
            stats["ordered_cost"] += (num(data.get("cost")) or 0.0) * count
            return
        if action != "UNIT_SPAWNED":
            return
        stats["built_" + str(role)] += count
        stats["built_cost"] += (num(data.get("cost")) or 0.0) * count
        stats["built_class:" + str(cls)] += count

    def on_counters(self, time, record, data):
        for key, value in (data or {}).items():
            if num(value) is not None:
                self.counters[key] = num(value)
            elif isinstance(value, dict):
                self.counters[key] = value

    def on_outcome(self, time, record, data):
        self.outcomes.append({"faction": data.get("faction"),
                              "time": num(data.get("elapsed")),
                              "attributed": num(data.get("totalAttributedHullDamage"))})
        stats = self.faction_stats[data.get("faction")]
        stats["station_destroyed"] += 1
        stats["station_damage_attributed"] += num(data.get("totalAttributedHullDamage")) or 0.0


def _new_faction_stats():
    return collections.defaultdict(float)


_HANDLERS = {
    "RUN": MatchMap.on_run,
    "ACCEPTANCE_SETUP": MatchMap.on_setup,
    "DECISION": MatchMap.on_decision,
    "COHESION": MatchMap.on_cohesion,
    "CONTEST": MatchMap.on_contest,
    "EXECUTION": MatchMap.on_execution,
    "FRIENDLY_HIT": MatchMap.on_friendly_hit,
    "LOSS": MatchMap.on_loss,
    "SENTRY_BUILD": MatchMap.on_sentry,
    "OBJECTIVE": MatchMap.on_objective,
    "UNIT": MatchMap.on_unit,
    "FACTION": MatchMap.on_faction,
    "TACTIC": MatchMap.on_tactic,
    "PRODUCTION": MatchMap.on_production,
    "COUNTERS": MatchMap.on_counters,
    "OUTCOME_CAUSE": MatchMap.on_outcome,
}

# ------------------------------------------------------------------- analysis

class DecisionFilter:
    """--explain / --explain-target selection, applied during the stream."""

    def __init__(self, groups=None, classes=None, roles=None, missions=None,
                 reasons=None, t_from=None, t_to=None, limit=200):
        self.groups = {g.lower() for g in (groups or [])}
        self.classes = {c.lower() for c in (classes or [])}
        self.roles = {r.lower() for r in (roles or [])}
        self.missions = {m.upper() for m in (missions or [])}
        self.reasons = {r.upper() for r in (reasons or [])}
        self.t_from = t_from
        self.t_to = t_to
        self.limit = max(1, int(limit))

    def wants(self, time, data):
        if self.t_from is not None and time < self.t_from:
            return False
        if self.t_to is not None and time > self.t_to:
            return False
        if self.groups and str(data.get("group") or "").lower() not in self.groups:
            return False
        if self.classes and str(data.get("targetClass") or "").lower() not in self.classes:
            return False
        if self.roles and str(data.get("targetRole") or "").lower() not in self.roles:
            return False
        if self.missions and str(data.get("mission") or "").upper() not in self.missions:
            return False
        if self.reasons and str(data.get("reason") or "").upper() not in self.reasons:
            return False
        return True

    def describe(self):
        bits = []
        if self.groups:
            bits.append("group in %s" % ",".join(sorted(self.groups)))
        if self.classes:
            bits.append("target class in %s" % ",".join(sorted(self.classes)))
        if self.roles:
            bits.append("target role in %s" % ",".join(sorted(self.roles)))
        if self.missions:
            bits.append("mission in %s" % ",".join(sorted(self.missions)))
        if self.reasons:
            bits.append("reason in %s" % ",".join(sorted(self.reasons)))
        window = []
        if self.t_from is not None:
            window.append("from %s" % fmt(self.t_from))
        if self.t_to is not None:
            window.append("to %s" % fmt(self.t_to))
        if window:
            bits.append(" ".join(window))
        return "; ".join(bits) if bits else "no filter (first %d decisions)" % self.limit


def candidate_rows(raw):
    """Normalise whatever shape the candidate list arrived in.

    Two shapes exist in this codebase and both are handled:
      * objective candidates from ScoreAIObjective -- target/mission/score/
        reason/factors{distance,coverage,superiority}/distance/eta/ratio
        (fs2rts_ai_planning/candidates.lua:136)
      * roster candidates from the production picker -- entry.class /
        entry.tier / entry.role / weight / telemetry.selectionWeight /
        telemetry.probability / telemetry.selected
        (fs2rts_ai_production.lua:128 and :310)
    """
    rows = []
    if isinstance(raw, dict):
        iterable = list(raw.values())
    elif isinstance(raw, list):
        iterable = list(raw)
    else:
        return rows
    for item in iterable:
        if not isinstance(item, dict):
            continue
        entry = item.get("entry") if isinstance(item.get("entry"), dict) else {}
        telemetry = item.get("telemetry") if isinstance(item.get("telemetry"), dict) else {}
        factors = item.get("factors") if isinstance(item.get("factors"), dict) else {}
        rows.append({
            "target": item.get("target", item.get("targetSignature")),
            "class": entry.get("class") or item.get("class"),
            "tier": entry.get("tier") or item.get("tier"),
            "role": entry.get("role") or item.get("role"),
            "mission": item.get("mission"),
            "score": num(item.get("score")),
            "weight": num(telemetry.get("selectionWeight", item.get("weight"))),
            "probability": num(telemetry.get("probability")),
            "selected": bool(telemetry.get("selected", item.get("selected"))),
            "reason": item.get("reason"),
            "distance": first_num(item, "distance"),
            "eta": first_num(item, "eta"),
            "ratio": first_num(item, "ratio"),
            "factors": {k: num(v) for k, v in factors.items()},
        })
    return rows


def explain_decision(time, data, doctrine):
    """Turn one DECISION record into a claim about why it chose what it chose.

    `basis` names where each number came from:
      CANDIDATES     the real per-candidate table was in the record
      RETAIN_BOUND   no candidate list; the retain gate at
                     fs2rts_ai_planning/battle_events.lua:15 bounds the rejected challenger
      INERTIA        no candidate list; the retain was the age gate, so the
                     rejected challenger is unconstrained by score
      SCORE_ONLY     no candidate list and no retain; only the winner's score
                     survives, so no margin can be stated at all
    """
    score = num(data.get("score"))
    switching_cost = num(data.get("switchingCost"))
    if switching_cost is None:
        switching_cost = num(doctrine.get("ObjectiveSwitchCost"))
    age = num(data.get("previousAge"))
    min_commit = num(doctrine.get("MinimumCommitmentSeconds"))
    reason = data.get("reason")
    rows = candidate_rows(data.get("candidates"))
    chosen_score = score
    runner_up = None
    margin = None
    probabilities = []
    basis = "SCORE_ONLY"

    if rows:
        basis = "CANDIDATES"
        for row in rows:
            if num(row["probability"]) is not None:
                probabilities.append(row["probability"])
        if not any(row["selected"] for row in rows):
            # The emitter appends the chosen candidate last
            # (fs2rts_ai_planning/battle_events.lua:23); trust `selected` when present,
            # otherwise fall back to the highest score.
            best = max(rows, key=lambda r: (num(r["score"]) is not None, num(r["score"]) or 0.0))
            best["selected"] = True
        selected = [r for r in rows if r["selected"]]
        rejected = sorted((r for r in rows if not r["selected"]),
                          key=lambda r: -(num(r["score"]) if num(r["score"]) is not None else -1e18))
        if rejected:
            runner_up = rejected[0]
            margin = ((num(selected[0]["score"]) - num(runner_up["score"]))
                      if selected and num(selected[0]["score"]) is not None
                      and num(runner_up["score"]) is not None else None)
    elif reason == "OBJECTIVE_RETAINED":
        if age is not None and min_commit is not None and age < min_commit:
            basis = "INERTIA"
        else:
            basis = "RETAIN_BOUND"
            if score is not None and switching_cost is not None:
                # lua:604 retained when challenger.score < incumbent.score + switchingCost
                runner_up = {"score": None, "class": None, "mission": None,
                             "upperBound": score + switching_cost}
    view = {
        "time": time, "faction": data.get("faction"), "group": data.get("group"),
        "role": data.get("role"), "posture": data.get("posture"),
        "ships": len(data.get("ships") or []),
        "mission": data.get("mission"), "target": data.get("target"),
        "targetName": data.get("targetName"), "targetClass": data.get("targetClass"),
        "targetRole": data.get("targetRole"), "targetFaction": data.get("targetFaction"),
        "reason": reason, "score": score, "switchingCost": switching_cost,
        "previousAge": age, "basis": basis,
        "candidates": rows, "runnerUp": runner_up, "margin": margin,
        "probabilities": probabilities,
        "emergency": data.get("emergency"),
        "operation": data.get("operation"), "operationPhase": data.get("operationPhase"),
        "localThreatDistance": num(data.get("localThreatDistance")),
        "hardLocalThreat": data.get("hardLocalThreat"),
        "assaultReserved": data.get("assaultReserved"),
        "spread": num(data.get("spread")),
"centroid": (num(data.get("centroidX")), num(data.get("centroidZ"))),
        "results": data.get("results") or {},
        "minCommit": min_commit,
    }
    view["plain"] = plain_explanation(view)
    return view


def plain_explanation(view):
    """One line a maintainer can read without opening the JSON."""
    reason = view["reason"]
    text = REASON_TEXT.get(reason, "reason code %s" % reason)
    who = "%s %s" % (view["faction"], view["group"])
    what = "put %s (%s) on %s" % (
        view["mission"], view["targetClass"] or view["targetName"] or "unknown",
        view["targetFaction"] or "unknown")
    bits = [text]
    if view["score"] is not None:
        bits.append("score %s" % fmt(view["score"], 1))
    if view["basis"] == "CANDIDATES":
        if view["margin"] is not None:
            bits.append("beat the runner-up %s by %s" % (
                view["runnerUp"].get("class") or view["runnerUp"].get("target"),
                fmt(view["margin"], 1)))
        if view["probabilities"]:
            bits.append("candidate probabilities %s" % ", ".join(
"%.3f" % p for p in sorted(view["probabilities"], reverse=True)[:4]))
    elif view["basis"] == "RETAIN_BOUND":
        bits.append("kept the old objective; the rejected challenger scored below %s "
                    "(incumbent %s + switching cost %s), and the age gate was already past "
                    "(previousAge %s s >= %s s)"
                    % (fmt(view["runnerUp"]["upperBound"], 1), fmt(view["score"], 1),
                       fmt(view["switchingCost"], 1), fmt(view["previousAge"], 1),
                       fmt(view["minCommit"], 1)))
    elif view["basis"] == "INERTIA":
        bits.append("kept the old objective on the age gate alone (previousAge %s s), "
                    "so no score margin applies" % fmt(view["previousAge"], 1))
    else:
        bits.append("no candidate list in this run, so no margin can be stated")
    return "%s: %s because %s." % (who, what, "; ".join(bits))


def format_decision(view, doctrine, out):
    out.append("")
    out.append("  t=%s %s %s role=%s posture=%s ships=%d"
               % (fmt(view["time"], 1), view["faction"], view["group"],
                  view["role"], view["posture"], view["ships"]))
    out.append("    chose      %s -> %s (%s, %s)"
               % (view["mission"], view["targetName"] or "?",
                  view["targetClass"] or "?", view["targetFaction"] or "?"))
    out.append("    reason     %s  [%s]"
               % (view["reason"], REASON_SOURCE.get(view["reason"], "source not mapped")))
    if view["basis"] == "CANDIDATES":
        out.append("    basis      recorded candidate table (%d candidates)"
                   % len(view["candidates"]))
        chosen = [r for r in view["candidates"] if r["selected"]]
        rejected = sorted((r for r in view["candidates"] if not r["selected"]),
                          key=lambda r: -(num(r["score"]) if num(r["score"]) is not None else -1e18))
        out.append("      %-22s %-10s %8s %8s %7s %7s  %s"
                   % ("candidate", "mission", "score", "weight", "prob", "margin", "pick"))
        for row in chosen + rejected:
            mark = "CHOSEN" if row["selected"] else "rejected"
            gap = ""
            if row["selected"] and view["margin"] is not None:
                gap = "%+.1f" % view["margin"]
            out.append("      %-22s %-10s %8s %8s %7s %7s  %s"
                       % (str(row.get("class") or row.get("target")), row.get("mission"),
                          fmt(row.get("score"), 1), fmt(row.get("weight"), 2),
                          fmt(row.get("probability"), 3) if row.get("probability") is not None else "-",
                          gap or "-", mark))
    elif view["basis"] == "RETAIN_BOUND":
        out.append("    basis      no candidate list (DetailedDecisionTelemetry=false); "
                   "bound from fs2rts_ai_planning/battle_events.lua:15")
        out.append("      incumbent score %s, switching cost %s -> challenger < %s"
                   % (fmt(view["score"], 1), fmt(view["switchingCost"], 1),
                      fmt(view["runnerUp"]["upperBound"], 1)))
        out.append("      previousAge %s s vs MinimumCommitmentSeconds %s s"
                   % (fmt(view["previousAge"], 1),
                      fmt(doctrine.get("MinimumCommitmentSeconds"), 1)))
    elif view["basis"] == "INERTIA":
        out.append("    basis      no candidate list; retained on the age gate "
                   "(previousAge %s s < MinimumCommitmentSeconds %s s)"
                   % (fmt(view["previousAge"], 1),
                      fmt(doctrine.get("MinimumCommitmentSeconds"), 1)))
    else:
        out.append("    basis      no candidate list; only the winner's score survives")
    orders = collections.Counter(view["results"].values())
    if orders:
        out.append("    orders     %s" % dict(orders))
    if view["centroid"][0] is not None:
        out.append("    position   (%s, %s)  GROUP CENTROID, not the ship"
                   % (fmt(view["centroid"][0]), fmt(view["centroid"][1])))


def group_timeline_rows(match):
    """Per-group mission segments: who was sent where, for how long, switching rate."""
    rows = []
    for (faction, group), state in match.timelines.items():
        segments = state["segments"]
        if not segments:
            continue
        spans = []
        for index, seg in enumerate(segments):
            end = (segments[index + 1]["start"] if index + 1 < len(segments)
                   else state.get("last_time", seg["start"]))
            spans.append(max(0.0, end - seg["start"]))
        total = sum(spans) or 1e-9
        by_mission = collections.Counter()
        for seg, span in zip(segments, spans):
            by_mission[seg["mission"]] += span
        held = state.get("last_time", segments[0]["start"]) - segments[0]["start"]
        rows.append({
            "faction": faction, "group": group, "segments": len(segments),
            "switches": state["switches"], "firstSeen": segments[0]["start"],
            "tracked": total, "switchRate": state["switches"] / max(1e-9, total / 60.0),
            "meanHold": total / len(segments),
            "longestHold": max(spans),
            "missions": dict(by_mission),
            "dominantMission": by_mission.most_common(1)[0][0],
            "lastMission": segments[-1]["mission"],
            "lastTargetClass": segments[-1]["targetClass"],
        })
    rows.sort(key=lambda r: (-r["tracked"], r["faction"], str(r["group"])))
    return rows


def sentry_coverage(match, radius=4000.0):
    """How much of a faction's damage output landed inside its own sentry rings.

    A kill counts when this faction's weapons destroyed a hostile hull inside
    `radius` of a sentry this faction had already completed. Kills by other
    factions are deliberately excluded: the question is whether the sentry
    grid is where the fighting actually gets decided, not who is winning.
    """
    per_faction = {}
    for time, faction, x, z in match.sentries:
        per_faction.setdefault(faction, []).append((time, x, z))
    out = {}
    for faction in match.faction_stats:
        mine = per_faction.get(faction, [])
        kills = 0
        kills_in_ring = 0
        for row in match.loss_rows:
            if row["x"] is None or not row["attackerFaction"]:
                continue
            if row["attackerFaction"] != faction or row["faction"] == faction:
                continue
            kills += 1
            if any(row["time"] >= placed and dist(row["x"], row["z"], sx, sz) <= radius
                   for placed, sx, sz in mine):
                kills_in_ring += 1
        out[faction] = {"sentries": len(mine), "killsByThisFaction": kills,
                        "killsInsideSentryRadius": kills_in_ring,
                        "radius": radius,
                        "share": (kills_in_ring / kills) if kills else None}
    return out

# ------------------------------------------------------------------ rendering

def _panel(ax, grid, bounds, title, stations=None, markers=None, cmap="inferno",
           vmax=None, label="", cells=DEFAULT_CELLS):
    extent = [bounds[0], bounds[0] + bounds[2] * cells,
              bounds[1], bounds[1] + bounds[2] * cells]
    if grid is None or not grid.any():
        ax.set_facecolor("#12161a")
        ax.text(0.5, 0.5, "no samples", ha="center", va="center",
                transform=ax.transAxes, color="#8b949c", fontsize=9)
    else:
        ax.imshow(grid.T, origin="lower", extent=extent, cmap=cmap,
                  vmin=0, vmax=vmax or robust_max(grid) or 1.0, aspect="equal",
                  interpolation="nearest")
    for faction, (sx, sz) in (stations or {}).items():
        ax.plot(sx, sz, marker="*", markersize=13, linestyle="none",
                color=FACTION_COLOR.get(faction, "#ffffff"),
                markeredgecolor="#10141a", markeredgewidth=0.8)
        ax.annotate(faction, (sx, sz), textcoords="offset points", xytext=(7, 7),
                    color=FACTION_COLOR.get(faction, "#ffffff"), fontsize=8, weight="bold")
    for (mx, mz, colour, size) in (markers or []):
        ax.plot(mx, mz, marker="o", markersize=size, linestyle="none",
                color=colour, markeredgecolor="#0b0e12", markeredgewidth=0.4, alpha=0.9)
    ax.set_xlim(extent[0], extent[1])
    ax.set_ylim(extent[2], extent[3])
    ax.set_title(title, fontsize=9, color="#e6edf3", loc="left")
    ax.set_xlabel("x", fontsize=7, color="#8b949c")
    ax.set_ylabel("z", fontsize=7, color="#8b949c")
    ax.tick_params(labelsize=6, colors="#8b949c")
    if label:
        ax.text(0.99, 0.02, label, transform=ax.transAxes, ha="right", va="bottom",
                fontsize=7, color="#e6edf3",
                bbox=dict(boxstyle="round,pad=0.25", facecolor="#10141a", alpha=0.75))


def _sparse_panel(ax, field, bounds, title, stations, cells, colour="#ff9f6b"):
    """Too few points to fill a grid: plot them, do not pretend they are a heat map."""
    extent = [bounds[0], bounds[0] + bounds[2] * cells,
              bounds[1], bounds[1] + bounds[2] * cells]
    ax.set_facecolor("#12161a")
    ax.plot(field.xs, field.zs, linestyle="none", marker="o", markersize=5,
            color=colour, markeredgecolor="#0b0e12", markeredgewidth=0.3, alpha=0.95)
    for faction, (sx, sz) in (stations or {}).items():
        ax.plot(sx, sz, marker="*", markersize=12, linestyle="none",
                color=FACTION_COLOR.get(faction, "#ffffff"),
                markeredgecolor="#10141a", markeredgewidth=0.7)
        ax.annotate(faction, (sx, sz), textcoords="offset points", xytext=(6, 6),
                    color=FACTION_COLOR.get(faction, "#ffffff"), fontsize=7, weight="bold")
    ax.set_xlim(extent[0], extent[1])
    ax.set_ylim(extent[2], extent[3])
    ax.set_title(title, fontsize=9, color="#e6edf3", loc="left")
    ax.set_xlabel("x", fontsize=7, color="#8b949c")
    ax.set_ylabel("z", fontsize=7, color="#8b949c")
    ax.tick_params(labelsize=6, colors="#8b949c")
    ax.text(0.99, 0.02, "n=%d  too sparse for a density map" % len(field),
            transform=ax.transAxes, ha="right", va="bottom", fontsize=7,
            color="#e6edf3", bbox=dict(boxstyle="round,pad=0.25", facecolor="#10141a",
                                       alpha=0.75))


def _save(fig, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=110, bbox_inches="tight", facecolor="#0d1117")
    plt.close(fig)
    return path


def map_bounds(match, cells):
    points = []
    for faction, (x, z) in match.stations.items():
        points.append((x, z))
    fields = [match.fire, match.fire_hull, match.losses, match.friendly,
              match.deaths_heavy] + list(match.dwell.values()) \
        + list(match.dwell_heavy.values()) + list(match.stall.values())
    for field in fields:
        points.extend(zip(field.xs, field.zs))
    return bounds_of(points, cells=cells)


def render_combat_density(match, outdir, cells):
    bounds = map_bounds(match, cells)
    factions = match.factions or sorted(match.faction_stats)
    fig, axes = plt.subplots(1, max(1, len(factions)),
                             figsize=(5.2 * max(1, len(factions)), 5.4), squeeze=False)
    for index, faction in enumerate(factions):
        ax = axes[0][index]
        grid, _ = match.fire.bin(bounds, cells)
        grid_h, _ = match.fire_hull.bin(bounds, cells)
        _panel(axes[0][index], grid, bounds, "weapon fire observed - %s" % faction,
               stations=match.stations, cmap="magma",
               label="hits=%d  hull-loss hits=%d" % (len(match.fire), len(match.fire_hull)),
               cells=cells)
        if grid_h.any():
            ax.contour(grid_h.T, levels=[grid_h.max() * 0.5], colors=["#66d9ef"],
                       linewidths=0.6, alpha=0.5,
                       extent=[bounds[0], bounds[0] + bounds[2] * cells,
                               bounds[1], bounds[1] + bounds[2] * cells])
        ax.set_xlim(bounds[0], bounds[0] + bounds[2] * cells)
        ax.set_ylim(bounds[1], bounds[1] + bounds[2] * cells)
    fig.suptitle("COMBAT DENSITY  %s   sqrt(hit observations), cyan contour = hull-loss hits"
                 % match.match_name, fontsize=11, color="#e6edf3")
    return _save(fig, outdir / ("combat_density_%s.png" % match.match_name))


def render_deaths(match, outdir, cells):
    bounds = map_bounds(match, cells)
    factions = match.factions or sorted(match.faction_stats)
    by_class = sorted(match.deaths_by_class.items(), key=lambda kv: -len(kv[1]))[:6]
    fig, axes = plt.subplots(2, max(2, max(len(factions), len(by_class))),
                             figsize=(4.6 * max(2, max(len(factions), len(by_class))), 9.0),
                             squeeze=False)
    grid, _ = match.losses.bin(bounds, cells)
    top = robust_max(grid) or 0.0
    for index, faction in enumerate(factions):
        row = []
        marker = [(r["x"], r["z"], FACTION_COLOR.get(faction, "#fff"), 5)
                  for r in match.loss_rows
                  if r["faction"] == faction and r["x"] is not None]
        ax = axes[0][index]
        _panel(ax, grid / top if top else grid, bounds, "all deaths - %s" % faction,
               stations=match.stations, cmap="magma",
               vmax=1.0 if top else None,
               label="%d deaths" % sum(1 for r in match.loss_rows if r["faction"] == faction),
               cells=cells)
        if marker:
            ax.plot([m[0] for m in marker], [m[1] for m in marker], linestyle="none",
                    marker="o", markersize=2.5, color="#ffffff", alpha=0.35)
        del row
    for index, (cls, field) in enumerate(by_class):
        if len(field) < 12:
            _sparse_panel(axes[1][index], field, bounds, "dead: %s" % cls,
                          match.stations, cells)
            continue
        grid_c, _ = field.bin(bounds, cells)
        _panel(axes[1][index], grid_c, bounds, "dead: %s" % cls,
               stations=match.stations, cmap="magma",
               label="n=%d" % len(field), cells=cells)
    for index in range(len(by_class), axes.shape[1]):
        axes[1][index].axis("off")
    for index in range(len(factions), axes.shape[1]):
        axes[0][index].axis("off")
    fig.suptitle("DEATH LOCATIONS  %s   every point is the DEAD SHIP'S GROUP CENTROID\n"
                 "staleness at death: p50=%s s p90=%s s max=%s s; %d of %d deaths positioned"
                 % (match.match_name, fmt(median(match.staleness), 0),
                    fmt(quantile(match.staleness, 0.9), 0),
                    fmt(match.staleness[-1] if match.staleness else None, 0),
                    match.positioned_losses,
                    match.positioned_losses + match.unpositioned_losses),
                 fontsize=11, color="#e6edf3")
    return _save(fig, outdir / ("deaths_%s.png" % match.match_name))


def render_dwell(match, outdir, cells):
    bounds = map_bounds(match, cells)
    factions = match.factions or sorted(match.faction_stats)
    fig, axes = plt.subplots(2, max(1, len(factions)),
                             figsize=(5.2 * max(1, len(factions)), 10.4), squeeze=False)
    for index, faction in enumerate(factions):
        field = match.dwell.get(faction)
        grid, _ = field.bin(bounds, cells) if field else (None, None)
        own = match.stations.get(faction)
        share = None
        if field is not None and own:
            share = 0
            total = len(field)
            if total:
                share = sum(1 for x, z in zip(field.xs, field.zs)
                            if dist(x, z, own[0], own[1]) <= match.base_distance / 2.0) / total
        _panel(axes[0][index], grid, bounds, "all groups - %s" % faction,
               stations=match.stations, cmap="viridis",
               label="samples=%d%s" % (len(field) if field else 0,
                                      ("  own-half=%.0f%%" % (100 * share)) if share is not None else ""),
               cells=cells)
        heavy = match.dwell_heavy.get(faction)
        hgrid, _ = heavy.bin(bounds, cells) if heavy else (None, None)
        hshare = None
        if heavy is not None and own and len(heavy):
            hshare = sum(1 for x, z in zip(heavy.xs, heavy.zs)
                         if dist(x, z, own[0], own[1]) <= match.base_distance / 2.0) / len(heavy)
        _panel(axes[1][index], hgrid, bounds, "capital/heavy/juggernaut groups - %s" % faction,
               stations=match.stations, cmap="plasma",
               label="samples=%d%s" % (len(heavy) if heavy else 0,
                                      ("  own-half=%.0f%%" % (100 * hshare)) if hshare is not None else ""),
               cells=cells)
    fig.suptitle("OBJECTIVE DWELL  %s   group centroids, 1 sample per think\n"
                 "bottom row: only capital/heavy/juggernaut groups. If they never leave "
                 "their own half the heavies are decoration."
                 % match.match_name, fontsize=11, color="#e6edf3")
    return _save(fig, outdir / ("dwell_%s.png" % match.match_name))


def render_stalls(match, outdir, cells):
    bounds = map_bounds(match, cells)
    factions = [f for f in (match.factions or sorted(match.faction_stats))
                if f in match.stall]
    if not factions:
        factions = match.factions or sorted(match.faction_stats)
    fig, axes = plt.subplots(1, max(1, len(factions)),
                             figsize=(5.2 * max(1, len(factions)), 5.4), squeeze=False)
    for index, faction in enumerate(factions):
        field = match.stall.get(faction)
        grid, _ = field.bin(bounds, cells) if field else (None, None)
        stats = match.faction_stats[faction]
        _panel(axes[0][index], grid, bounds, "stall regions - %s" % faction,
               stations=match.stations, cmap="cividis",
               label="stall-seconds=%d worst=%s s records=%d"
                     % (stats.get("stall_seconds", 0), fmt(stats.get("worst_stall")),
                        stats.get("stall_records", 0)),
               cells=cells)
    fig.suptitle("STALL REGIONS  %s   CONTEST group stalledSeconds, placed at the group's\n"
                 "last known COHESION position" % match.match_name,
                 fontsize=11, color="#e6edf3")
    return _save(fig, outdir / ("stalls_%s.png" % match.match_name))


def render_commit_curve(match, outdir):
    factions = sorted(match.commit)
    if not factions:
        fig, ax = plt.subplots(figsize=(6, 4))
        ax.text(0.5, 0.5, "no CONTEST records", ha="center", transform=ax.transAxes)
        ax.axis("off")
        fig.suptitle("FORCE COMMIT  %s" % match.match_name, color="#e6edf3")
        return _save(fig, outdir / ("commit_%s.png" % match.match_name))
    fig, axes = plt.subplots(1, 2, figsize=(13.0, 4.8),
                             gridspec_kw={"width_ratios": [2, 1]})
    for faction in factions:
        series = sorted(match.commit[faction])
        times = [s[0] for s in series]
        primary = [s[1] for s in series]
        others = [s[2] for s in series]
        share = [(p / (p + o)) if (p + o) > 0 else 0.0 for p, o in zip(primary, others)]
        color = FACTION_COLOR.get(faction, "#ffffff")
        axes[0].plot(times, primary, color=color, linewidth=1.1, label="%s on primary" % faction)
        axes[0].plot(times, others, color=color, linewidth=0.8, linestyle="--", alpha=0.55,
                     label="%s on other targets" % faction)
        axes[1].plot(times, share, color=color, linewidth=1.1, label=faction)
        stats = match.faction_stats[faction]
        axes[0].annotate("%s peak %.0f" % (faction, stats.get("peak_on_primary", 0.0)),
                         (times[int(len(times) * 0.02)] if times else 0,
                          stats.get("peak_on_primary", 0.0)), color=color, fontsize=7)
    axes[0].set_title("fleet value assigned per 10 s CONTEST sample", fontsize=9, color="#e6edf3")
    axes[0].set_xlabel("mission seconds", fontsize=8, color="#8b949c")
    axes[0].set_ylabel("combat value", fontsize=8, color="#8b949c")
    axes[1].set_title("share of value on the enemy station", fontsize=9, color="#e6edf3")
    axes[1].set_xlabel("mission seconds", fontsize=8, color="#8b949c")
    axes[1].set_ylabel("share on primary", fontsize=8, color="#8b949c")
    axes[1].set_ylim(-0.02, 1.02)
    for ax in axes:
        ax.legend(fontsize=7, ncol=2, facecolor="#10141a", edgecolor="#30363d",
                  labelcolor="#e6edf3")
        ax.grid(alpha=0.15, color="#8b949c")
        ax.tick_params(labelsize=7, colors="#8b949c")
    fig.suptitle("FORCE COMMIT CURVE  %s   flat zero = this faction never put a ship "
                 "on the enemy station" % match.match_name, fontsize=11, color="#e6edf3")
    return _save(fig, outdir / ("commit_%s.png" % match.match_name))


def render_sentry_coverage(match, outdir, cells, radius=4000.0):
    bounds = map_bounds(match, cells)
    coverage = sentry_coverage(match, radius)
    factions = match.factions or sorted(match.faction_stats)
    fig, axes = plt.subplots(1, max(1, len(factions)),
                             figsize=(5.2 * max(1, len(factions)), 5.4), squeeze=False)
    for index, faction in enumerate(factions):
        grid, _ = match.losses.bin(bounds, cells)
        sentries = [(x, z, "#ffa657", 6) for _, f, x, z in match.sentries if f == faction]
        sentry_xy = [(sx, sz) for sx, sz, _, _ in sentries]
        attackers = [(r["x"], r["z"]) for r in match.loss_rows
                     if r["x"] is not None and r["attackerFaction"] == faction
                     and r["faction"] != faction]
        _panel(axes[0][index], grid, bounds, "sentry cover vs attacker deaths - %s" % faction,
               stations=match.stations, cmap="bone",
               markers=sentries, cells=cells)
        if attackers:
            axes[0][index].plot([a[0] for a in attackers], [a[1] for a in attackers],
                                linestyle="none", marker="x", markersize=4,
                                color="#ff6b6b", alpha=0.85)
        for sx, sz in sentry_xy:
            axes[0][index].add_patch(plt.Circle((sx, sz), radius, fill=False,
                                                edgecolor="#58a6ff", linewidth=0.5,
                                                alpha=0.45))
        stats = coverage.get(faction, {})
        axes[0][index].text(0.99, 0.02,
                            "sentries=%d  kills by this faction=%d  inside %s m ring=%s"
                            % (stats.get("sentries", 0), stats.get("killsByThisFaction", 0),
                               fmt(radius), stats.get("killsInsideSentryRadius", 0)),
                            transform=axes[0][index].transAxes, ha="right", va="bottom",
                            fontsize=7, color="#e6edf3",
                            bbox=dict(boxstyle="round,pad=0.25", facecolor="#10141a", alpha=0.75))
    fig.suptitle("SENTRY COVERAGE vs THREAT  %s   orange = completed sentry, ring = %s m "
                 "radius, red x = where this faction's attackers died\n"
                 "deaths plotted at the dead ship's GROUP CENTROID"
                 % (match.match_name, fmt(radius)), fontsize=11, color="#e6edf3")
    return _save(fig, outdir / ("sentry_%s.png" % match.match_name))

# ---------------------------------------------------------------- text report

def faction_report(match, faction, out):
    stats = match.faction_stats[faction]
    series = sorted(match.commit.get(faction, []))
    samples = len(series)
    share = (stats.get("share_sum", 0.0) / samples) if samples else None
    out.append("")
    out.append("  [%s]  decisions=%s  reasons: %s"
               % (faction, fmt(stats.get("decisions")),
                  table(counters(stats, "reason:"))))
    out.append("       missions(groups): %s"
               % table(counters(stats, "group_mission:")))
    out.append("COMMIT faction=%s share_on_primary=%s mean_on_primary=%s "
               "samples_with_commit=%d/%d peak_on_primary=%s"
               % (faction,
                  ("%.4f" % share) if share is not None else "-",
                  fmt((stats.get("sum_on_primary", 0.0) / samples) if samples else None),
                  as_int(stats.get("samples_with_commit", 0)), samples,
                  fmt(stats.get("peak_on_primary"))))
    out.append("       samples_never_on_primary=%d  canPush=%d/%s  urgent=%d"
               % (as_int(stats.get("samples_without_commit", 0)) or 0,
                  as_int(stats.get("can_push_samples", 0)) or 0,
                  fmt(as_int(stats.get("contest_samples", 0))),
                  as_int(stats.get("urgent_samples", 0)) or 0))
    out.append("STALL faction=%s records=%d stall_seconds=%s worst_stall_s=%s "
               "on_station_records=%d positioned=%d"
               % (faction, as_int(sget(stats, "stall_records")),
                  fmt(sget(stats, "stall_seconds")), fmt(sget(stats, "worst_stall")),
                  as_int(sget(stats, "stall_on_station_records")),
                  as_int(sget(stats, "stall_positioned"))))
    fire = as_int(stats.get("fire_events", 0)) or 0
    out.append("COMBAT faction=%s fire_observations=%d positioned=%d hull_loss_hits=%d "
               "hull_damage=%s stale_p50=%s"
               % (faction, fire, as_int(stats.get("fire_positioned", 0)) or 0,
                  as_int(stats.get("fire_hull_events", 0)) or 0,
                  fmt(stats.get("fire_hull_damage")), fmt(median(match.fire_staleness))))
    losses = as_int(stats.get("losses", 0)) or 0
    out.append("LOSS faction=%s total=%d positioned=%d unpositioned=%d heavy=%d heavy_cost=%s"
               % (faction, losses, as_int(stats.get("positioned_losses", 0)) or 0,
                  as_int(stats.get("unpositioned_losses", 0)) or 0,
                  as_int(stats.get("heavy_losses", 0)) or 0,
                  fmt(stats.get("heavy_loss_cost"))))
    out.append("       by role: %s"
               % table(counters(stats, "loss_role:"), limit=6))
    unknown = as_int(sget(stats, "loss_mission_unknown")) or 0
    out.append("       by mission at death: %s  [mission not recorded on %d of %d]"
               % (table(counters(stats, "loss_mission:"), limit=6), unknown, losses))
    heavy_rows = [r for r in match.loss_rows if r["faction"] == faction and r["role"] in HEAVY_ROLES]
    if heavy_rows:
        fracs = sorted(r["fracHome"] for r in heavy_rows if r["fracHome"] is not None)
        mid = median(fracs) if fracs else None
        out.append("HEAVY_DEATH faction=%s n=%d positioned=%d dist_home_p50=%s "
                   "frac_of_way=%s killed_by=%s"
                   % (faction, len(heavy_rows), len(fracs),
                      fmt(mid * match.base_distance) if mid is not None else "-",
                      ("%.2f" % mid) if mid is not None else "-",
                      table(counters(stats, "heavy_loss_to_")) or "n/a"))
        for row in sorted(heavy_rows, key=lambda r: r["time"]):
            out.append("HEAVY_DEATH_DETAIL faction=%s t=%s class=%s role=%s group=%s "
                       "mission=%s killed_by=%s/%s at=%s,%s dist_home=%s (%.0f%% of way) "
                       "position_stale=%.0fs"
                       % (faction, fmt(row["time"], 1), row["class"], row["role"],
                          row["group"], row["mission"], row["attackerFaction"],
                          row["attackerClass"],
                          fmt(row["x"]) if row["x"] is not None else "-",
                          fmt(row["z"]) if row["z"] is not None else "-",
                          fmt(row["distHome"]),
                          100.0 * row["fracHome"] if row["fracHome"] is not None else -1.0,
                          row["stale"] if row["stale"] is not None else -1.0))
    coverage = sentry_coverage(match).get(faction)
    if coverage and coverage["sentries"]:
        out.append("SENTRY faction=%s completed=%d kills_by_this_faction=%d "
                   "kills_inside_sentry_ring=%s"
                   % (faction, coverage["sentries"], coverage["killsByThisFaction"],
                      coverage["killsInsideSentryRadius"]))
    out.append("BUILD faction=%s spawned_capital=%s spawned_heavy=%s spawned_juggernaut=%s "
               "spawned_cost=%s ordered_capital=%s"
               % (faction, fmt(sget(stats, "built_capital"), 0),
                  fmt(sget(stats, "built_heavy"), 0), fmt(sget(stats, "built_juggernaut"), 0),
                  fmt(sget(stats, "built_cost")), fmt(sget(stats, "ordered_capital"), 0)))
    heavy_classes = {k[len("built_class:"):]: v
                     for k, v in stats.items() if k.startswith("built_class:")}
    if heavy_classes:
        out.append("       spawned hulls: %s" % table(heavy_classes, limit=10))
    heavy_field = match.dwell_heavy.get(faction)
    own = match.stations.get(faction)
    if heavy_field is not None and len(heavy_field):
        radii = ([dist(x, z, own[0], own[1]) for x, z in zip(heavy_field.xs, heavy_field.zs)]
                 if own else [])
        if radii:
            radii_sorted = sorted(radii)
            home = sum(1 for r in radii_sorted
                       if r <= match.base_distance / 2.0) / len(radii_sorted)
            out.append("HEAVY_DWELL faction=%s samples=%d own_half=%.3f "
                       "mean_dist_from_own=%s p90=%s max=%s (base distance %s)"
                       % (faction, len(heavy_field), home,
                          fmt(sum(radii_sorted) / len(radii_sorted)),
                          fmt(radii_sorted[int(len(radii_sorted) * 0.9)]),
                          fmt(radii_sorted[-1]), fmt(match.base_distance)))
    else:
        out.append("HEAVY_DWELL faction=%s samples=0 no capital/heavy/juggernaut "
                   "group was ever reported" % faction)


def match_summary(match, cells=DEFAULT_CELLS):
    out = []
    out.append("MATCHMAP match=%s file=%s end_time=%.0fs records=%d bad_lines=%d "
               "detailed_decision_telemetry=%s"
               % (match.match_name, match.path.name, match.end_time,
                  sum(match.events.values()), match.bad_lines, match.detailed_decisions))
    out.append("  stations %s  base_distance=%s arena events %s"
               % ({f: (round(x), round(z)) for f, (x, z) in match.stations.items()},
                  fmt(match.base_distance),
                  table(match.events, limit=8)))
    bounds = map_bounds(match, cells)
    grid, _ = match.losses.bin(bounds, cells)
    fire_grid, _ = match.fire.bin(bounds, cells)
    peak = peak_cell(grid, bounds)
    fire_peak = peak_cell(fire_grid, bounds)
    out.append("DEATHS total=%d positioned=%d unpositioned=%d peak_cell=%s "
               "concentration_top10pct=%.3f  [every coordinate is the dead ship's "
               "GROUP CENTROID, not the ship: no record carries a per-ship position]"
               % (match.positioned_losses + match.unpositioned_losses,
                  match.positioned_losses, match.unpositioned_losses,
                  "(%s,%s)" % (fmt(peak[0]), fmt(peak[1])) if peak else "-",
                  concentration(grid)))
    out.append("       staleness_s p50=%s p90=%s max=%s  classes: %s"
               % (fmt(median(match.staleness)), fmt(quantile(match.staleness, 0.9)),
                  fmt(match.staleness[-1] if match.staleness else None),
                  table({cls: len(f) for cls, f in match.deaths_by_class.items()})))
    out.append("COMBAT fire_observations=%d peak_cell=%s concentration_top10pct=%.3f "
               "friendly_fire_points=%d"
               % (len(match.fire),
                  "(%s,%s)" % (fmt(fire_peak[0]), fmt(fire_peak[1])) if fire_peak else "-",
                  concentration(fire_grid), len(match.friendly)))
    out.append("       fire staleness_s p50=%s p90=%s max=%s"
               % (fmt(median(match.fire_staleness)),
                  fmt(quantile(match.fire_staleness, 0.9)),
                  fmt(match.fire_staleness[-1] if match.fire_staleness else None)))
    for faction in (match.factions or sorted(match.faction_stats)):
        field = match.dwell.get(faction)
        if field is not None:
            own = match.stations.get(faction)
            share = None
            mean_radius = None
            if own and len(field):
                radii = [dist(x, z, own[0], own[1]) for x, z in zip(field.xs, field.zs)]
                mean_radius = sum(radii) / len(radii)
                share = sum(1 for r in radii
                            if r <= match.base_distance / 2.0) / len(field)
            out.append("DWELL faction=%s samples=%d own_half=%.3f mean_dist_from_own=%s"
                       % (faction, len(field), share if share is not None else -1.0,
                          fmt(mean_radius)))
    for faction in match.faction_stats:
        faction_report(match, faction, out)
    if match.outcomes:
        out.append("OUTCOME " + " ".join("faction=%s at=%s attributed=%.0f"
                                         % (o["faction"], fmt(o["time"], 1),
                                            o["attributed"] or 0.0)
                                         for o in match.outcomes))
    if match.counters:
        out.append("COUNTERS " + json.dumps({k: v for k, v in match.counters.items()
                                             if k in ("decisions", "retained", "switches",
                                                      "reissued", "nativeChanges")},
                                            default=str))
    return out


def timeline_report(match, limit=40):
    out = ["GROUP MISSION TIMELINE  match=%s  groups=%d"
           % (match.match_name, len(match.timelines))]
    rows = group_timeline_rows(match)
    out.append("  %-5s %-14s %5s %5s %8s %8s %-12s %s"
               % ("fac", "group", "seg", "sw", "meanHold", "maxHold", "dominant", "missions(s)"))
    for row in rows[:limit]:
        out.append("  %-5s %-14s %5d %5d %8.1f %8.1f %-12s %s"
                   % (row["faction"], str(row["group"]), row["segments"], row["switches"],
                      row["meanHold"], row["longestHold"], row["dominantMission"],
                      table(row["missions"], limit=5)))
    if len(rows) > limit:
        out.append("  ... %d more groups" % (len(rows) - limit))
    for (faction, group), state in sorted(match.timelines.items()):
        for seg in state["segments"]:
            out.append("TIMELINE faction=%s group=%s start=%s mission=%s target_class=%s "
                       "reason=%s score=%s"
                       % (faction, group, fmt(seg["start"], 1), seg["mission"],
                          seg["targetClass"], seg["reason"], fmt(seg["score"], 1)))
    return out


def to_json(match, cells=DEFAULT_CELLS):
    bounds = map_bounds(match, cells)
    grid, _ = match.losses.bin(bounds, cells)
    fire_grid, _ = match.fire.bin(bounds, cells)
    peak = peak_cell(grid, bounds)
    fire_peak = peak_cell(fire_grid, bounds)
    factions = {}
    for faction in (match.factions or sorted(match.faction_stats)):
        stats = {k: v for k, v in match.faction_stats[faction].items()}
        samples = len(match.commit.get(faction, []))
        series = sorted(match.commit.get(faction, []))
        factions[faction] = {
            "stats": stats,
            "commitSamples": samples,
            "meanShareOnPrimary": (stats.get("share_sum", 0.0) / samples) if samples else None,
            "commitSeries": [{"t": t, "onPrimary": p, "onGroups": g} for t, p, g in series],
            "sentryCoverage": sentry_coverage(match).get(faction),
        }
    return {
        "match": match.match_name,
        "path": str(match.path),
        "endTime": match.end_time,
        "events": dict(match.events),
        "badLines": match.bad_lines,
        "detailedDecisionTelemetry": match.detailed_decisions,
        "doctrine": {k: match.doctrine.get(k) for k in DOCTRINE_DEFAULTS},
        "stations": {f: {"x": x, "z": z} for f, (x, z) in match.stations.items()},
        "baseDistance": match.base_distance,
        "factions": factions,
        "deaths": {"positioned": match.positioned_losses,
                   "unpositioned": match.unpositioned_losses,
                   "peakCell": list(peak) if peak else None,
                   "concentrationTop10pct": concentration(grid),
                   "stalenessSeconds": {"p50": median(match.staleness),
                                       "p90": quantile(match.staleness, 0.9),
                                       "max": match.staleness[-1] if match.staleness else None},
                   "byClass": {cls: len(f) for cls, f in match.deaths_by_class.items()},
                   "rows": match.loss_rows},
        "combat": {"fireObservations": len(match.fire),
                   "peakCell": list(fire_peak) if fire_peak else None,
                   "concentrationTop10pct": concentration(fire_grid),
                   "friendlyFirePoints": len(match.friendly),
                   "stalenessSeconds": {"p50": median(match.fire_staleness),
                                        "p90": quantile(match.fire_staleness, 0.9),
                                        "max": (match.fire_staleness[-1]
                                                if match.fire_staleness else None)}},
        "dwell": {f: {"samples": len(fld), "xs": fld.xs, "zs": fld.zs}
                  for f, fld in match.dwell.items()},
        "dwellHeavy": {f: {"samples": len(fld), "xs": fld.xs, "zs": fld.zs}
                       for f, fld in match.dwell_heavy.items()},
        "stalls": {f: {"samples": len(fld), "xs": fld.xs, "zs": fld.zs, "weights": fld.ws}
                   for f, fld in match.stall.items()},
        "sentries": [{"t": t, "faction": f, "x": x, "z": z}
                     for t, f, x, z in match.sentries],
        "groupTimelines": group_timeline_rows(match),
        "tactics": match.tactics,
        "outcomes": match.outcomes,
        "counters": match.counters,
    }


# ------------------------------------------------------------------------ CLI

def _split_list(value):
    if not value:
        return []
    return [part.strip() for part in value.split(",") if part.strip()]


def render_all(match, outdir, cells, radius):
    outdir.mkdir(parents=True, exist_ok=True)
    written = []
    for renderer in (render_combat_density, render_deaths, render_dwell, render_stalls):
        written.append(renderer(match, outdir, cells))
    written.append(render_commit_curve(match, outdir))
    written.append(render_sentry_coverage(match, outdir, cells, radius))
    return written


def build_parser():
    parser = argparse.ArgumentParser(
        prog="ai_matchmap.py", description="Match visualiser and decision-explainer "
                                            "for RTS-fleet-command headless telemetry.")
    parser.add_argument("target", type=Path, help="batch output dir or a single run dir")
    parser.add_argument("--outdir", type=Path, help="directory for PNG maps")
    parser.add_argument("--no-png", action="store_true", help="text summary only")
    parser.add_argument("--json", type=Path, help="write the full reconstruction as JSON")
    parser.add_argument("--cells", type=int, default=DEFAULT_CELLS,
                        help="heat map grid resolution (default %d)" % DEFAULT_CELLS)
    parser.add_argument("--sentry-radius", type=float, default=4000.0,
                        help="sentry threat radius in units (default 4000)")
    parser.add_argument("--faction", help="limit the faction breakdown to this faction")
    parser.add_argument("--explain", action="store_true",
                        help="replay decisions matching GROUP/CLASS/ROLE/MISSION/REASON")
    parser.add_argument("--explain-target", action="store_true",
                        help="same as --explain; the flag exists to read clearly when only "
                             "a target CLASS is given")
    parser.add_argument("--group", action="append", default=[],
                        help="group id to explain, e.g. W18:bomber (repeatable)")
    parser.add_argument("--class", dest="classes", action="append", default=[],
                        help="target class to explain, e.g. 'GTB Zeus' (repeatable)")
    parser.add_argument("--role", action="append", default=[], help="target role to explain")
    parser.add_argument("--mission", action="append", default=[], help="mission to explain")
    parser.add_argument("--reason-code", dest="reasons", action="append", default=[],
                        help="reason code to explain, e.g. OBJECTIVE_RETAINED")
    parser.add_argument("--from", dest="t_from", type=float, help="explain from t")
    parser.add_argument("--to", dest="t_to", type=float, help="explain to t")
    parser.add_argument("--limit", type=int, default=20,
                        help="max decisions to print per match (default 20)")
    parser.add_argument("--timeline", action="store_true",
                        help="print the per-group mission timeline")
    parser.add_argument("--quiet", action="store_true", help="suppress the text summary")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    target = args.target
    if not target.exists():
        raise SystemExit("No such path: %s" % target)
    files = find_telemetry(target)
    if not files:
        raise SystemExit("No %s under %s" % (TELEMETRY_GLOB, target))
    plan = batch_plan(target)

    wants_explain = args.explain or args.explain_target or any(
        [args.group, args.classes, args.role, args.mission, args.reasons,
         args.t_from is not None, args.t_to is not None])
    decision_filter = None
    if wants_explain:
        decision_filter = DecisionFilter(groups=args.group, classes=args.classes,
                                         roles=args.role, missions=args.mission,
                                         reasons=args.reasons, t_from=args.t_from,
                                         t_to=args.t_to, limit=args.limit)

    outdir = args.outdir
    if outdir is not None and not args.no_png:
        outdir.mkdir(parents=True, exist_ok=True)

    out = []
    payloads = []
    for path in files:
        match = MatchMap(path, cells=args.cells)
        match.decision_filter = decision_filter
        match.consume()
        payloads.append(to_json(match, args.cells))
        if match.faction_stats and args.faction:
            keep = args.faction
            match.faction_stats = {keep: match.faction_stats.get(
                keep, collections.defaultdict(float))}
            match.factions = [f for f in match.factions if f == keep]
        if not args.quiet:
            out.extend(match_summary(match, args.cells))
        # --timeline and --explain are queries in their own right, so --quiet
        # suppresses the summary but never silences an explicit request.
        if args.timeline:
            out.extend(timeline_report(match))
        if wants_explain:
            out.append("")
            out.append("DECISION REPLAY  match=%s  filter: %s"
                       % (match.match_name, decision_filter.describe()))
            if not match.decisions:
                out.append("  no DECISION record matched. Note that this batch carries "
                           "no per-candidate tables (DetailedDecisionTelemetry=%s), so a "
                           "replay can bound the rejected option but cannot print it."
                           % match.detailed_decisions)
            for time, data in match.decisions:
                view = explain_decision(time, data, match.doctrine)
                out.append("DECISION t=%s faction=%s group=%s mission=%s "
                           "target_class=%s reason=%s score=%s basis=%s"
                           % (fmt(time, 1), view["faction"], view["group"],
                              view["mission"], view["targetClass"], view["reason"],
                              fmt(view["score"], 1), view["basis"]))
                out.append("EXPLAIN %s" % view["plain"])
                format_decision(view, match.doctrine, out)
        if outdir is not None and not args.no_png:
            render_all(match, outdir, args.cells, args.sentry_radius)

    if out:
        out.insert(0, "AI MATCHMAP  %s\n%d match(es), grid %dx%d, max_sim_time %s\n"
                   % (target, len(files), args.cells, args.cells,
                      plan.get("max_sim_time", "?")))
        print("\n".join(out))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps({"batch": str(target), "matches": payloads},
                                        indent=1, default=str), encoding="utf-8")
        print("wrote %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
