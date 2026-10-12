"""Describe recorded batch metrics; gate only explicitly chosen directions.

All default metric directions are neutral. No selected criteria means
NOT_EVALUATED; empty/corrupt/one-run gated input means INSUFFICIENT_EVIDENCE.
Median/MAD separation is a heuristic, not statistical gameplay confidence.

Flows are interval values; gauges/cumulative counts are not summed as flows.
Ledger publication cutoffs, service spending and build events must be aligned.
A result-file path is presence only; completion is not inferred from silence.
Legacy repairUnlocked means ARMOR L2+, not current passive-repair availability.
Assigned offense is intent, not useful damage or a completed objective.

See docs/AI_ACCEPTANCE_AND_INVARIANTS.md before accepting a tuning change.
"""

from __future__ import annotations

import argparse
import glob
import json
import math
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path
from run_evidence import inspect_run, comparison_issues, valid_record, is_finite_number

SCHEMA = 3
SERIES_BUCKETS = 24
TAIL_TOLERANT = True

CAPITAL_ROLES = {"capital", "heavy", "juggernaut"}
# class name -> authoritative role, harvested from PRODUCTION records while a
# batch is parsed. classify_role consults this first; the faction-prefix
# heuristic below is only a fallback for classes never seen being built.
ROSTER_ROLES = {}
SPEND_ACTIONS = {"QUEUE_ACCEPTED", "BUILD_STARTED", "BUILD_QUEUED", "PURCHASED"}

# Polarity vocabulary:
#   higher  - a larger value is an improvement
#   lower   - a smaller value is an improvement
#   none    - informational, never better or worse on its own
# Override per metric on the command line with --polarity NAME=higher|lower|none.


class Metric:
    __slots__ = ("key", "label", "polarity", "group", "help")

    def __init__(self, key, label, polarity, group, help_text):
        self.key = key
        self.label = label
        self.polarity = polarity
        self.group = group
        self.help = help_text


METRICS = [
    # -- telemetry shape -------------------------------------------------
    Metric("duration_seconds", "sim seconds (median)", "none", "telemetry",
           "Max record time. Equal durations mean the sim cap, not a mission exit."),
    Metric("records", "telemetry records", "none", "telemetry",
           "JSONL records streamed per match."),
    Metric("malformed_lines", "malformed lines", "none", "telemetry",
           "Unparseable lines. A single unparseable FINAL line means a truncated write."),
    Metric("truncated_tail", "truncated tail", "none", "telemetry",
           "1 when the file's last line is a partial write. Normal for an in-flight run."),
    Metric("engine_result", "engine-result.json", "none", "telemetry",
           "Whether a native result file was available. Missing result is unknown completion, not a gameplay pass."),
    Metric("factions", "factions per match", "none", "telemetry",
           "Distinct factions seen in FACTION records."),

    # -- economy ---------------------------------------------------------
    Metric("cp_spent_flow", "CP spent (flow sum)", "none", "economy",
           "Sum of economy.flow.productionSpend over the whole FACTION series. "
           "Interval flow summed, never read off the last record."),
    Metric("cp_spent_production", "CP spent (PRODUCTION)", "none", "economy",
           "Sum of PRODUCTION event cost for unit queues. Independent cross-check "
           "of the flow sum."),
    Metric("sentry_spend", "CP spent on sentries", "none", "economy",
           "Sum of SENTRY_BUILD BUILD_STARTED cost. Station sentries are bought "
           "through a different event from unit production, so omitting this hides "
           "it inside the reconciliation gap. Polarity is deliberately open: "
           "stopping sentry production may be a deliberate doctrine change or a "
           "lost station-defence layer, and the telemetry alone cannot tell."),
    Metric("sentry_builds", "sentry builds started", "none", "economy",
           "SENTRY_BUILD BUILD_STARTED events."),
    Metric("cp_spent_events_total", "CP spent (all events)", "none", "economy",
           "Unit production, sentry construction and fleet service labour. The "
           "event-sourced total; station upgrades and the faction ability are the "
           "remaining event-free paths, sized by cp_upgrade_spend."),
    Metric("cp_spent_flow_gap", "flow/event reconciliation", "none", "economy",
           "cp_spent_events_total - cp_spent_flow. NEGATIVE by design: the station upgrade "
           "track (BuyUpgrade) and the faction ability (QueueOrbitalStrike, 750 CP) deduct CP "
           "through SpendFactionCP but publish no purchase event, so the event total cannot "
           "reach the flow. A gap near zero would instead mean one of them started emitting."),
    Metric("cp_spend_ledger", "CP ledger (per deduction)", "none", "economy",
           "Sum of CP_SPEND records, one per CP movement through RecordAIEconomyFlow. "
           "Independent of any purchase event, so it covers every sink."),
    Metric("cp_spend_drift", "ledger/flow reconciliation", "none", "economy",
           "cp_spend_ledger - cp_flow_cumulative, and 0 when the batch predates either record "
           "(nothing to compare against). THIS is the assertion that must hold: both are "
           "written by the same chokepoint, so any non-zero drift on a batch that carries "
           "CP_SPEND means a CP movement is no longer being recorded and the spend total is "
           "silently under-reporting."),
    Metric("cp_flow_cumulative", "CP spent (running total)", "none", "economy",
           "Last economy.flowCumulative.productionSpend per faction, added together. The "
           "snapshot omits spend after publication; reconciliation uses the matching ledger prefix."),
    Metric("cp_upgrade_spend", "CP spent on station upgrades", "none", "economy",
           "Cumulative upgradeSpend from the FACTION record, derived from the upgrade levels "
           "the faction actually holds. This is the bulk of the expected flow/event gap."),
    Metric("cp_spend_rate", "CP spent per sim-second", "none", "economy",
           "cp_spent_flow / duration. Normalizes matches that ran to different caps."),
    Metric("cp_income_total", "CP income (flow sum)", "none", "economy",
           "Sum of economy.flow.income. Same interval-vs-cumulative trap as spend."),
    Metric("cp_bounty_total", "CP bounty (flow sum)", "none", "economy",
           "Sum of economy.flow.bounty. Higher means the AI killed more enemy ships."),
    Metric("cp_refund_total", "CP refunded (flow sum)", "none", "economy",
           "Sum of economy.flow.refund."),
    Metric("cp_banked_final", "CP banked at end", "none", "economy",
           "Last observed economy.commandPoints. Neither high nor low is inherently "
           "good: hoarding and overspending are both failure modes."),
    Metric("cp_banked_max", "CP peak banked", "none", "economy",
           "Max observed economy.commandPoints. Exposes banking-for-a-target stalls."),
    Metric("queue_depth_mean", "queue depth (mean)", "none", "economy",
           "Mean economy.queueDepth over FACTION samples."),
    Metric("queue_blocked_samples", "queue blocked on cap", "none", "economy",
           "FACTION samples where economy.queue.waitingForCapacity was true. "
           "Non-zero means the AI wants to build past its fleet cap."),

    # -- fleet -----------------------------------------------------------
    Metric("combatants_final", "combatants at end", "none", "fleet",
           "Last observed economy.combatants, summed over factions."),
    Metric("combatants_mean", "combatants (mean sample)", "none", "fleet",
           "Mean economy.combatants over FACTION samples."),
    Metric("combatants_max", "combatants (peak)", "none", "fleet",
           "Max economy.combatants over FACTION samples."),
    Metric("fleet_cap_final", "fleet cap at end", "none", "fleet",
           "Last observed economy.fleetCap."),
    Metric("cap_utilisation_mean", "fleet cap utilisation", "none", "fleet",
           "Mean of combatants / fleetCap. Interpret alongside hull roles, values, capacity and saving state."),
    Metric("idle_mean", "idle ships (mean)", "none", "fleet",
           "Mean FACTION idle count. Idle ships are built but doing nothing."),
    Metric("idle_max", "idle ships (worst faction)", "none", "fleet",
           "Max idle count seen at any single sample in any one faction. Catches a "
           "faction that builds a fleet and then never uses it."),
    Metric("idle_fraction_mean", "idle fraction of fleet", "none", "fleet",
           "idle / max(combatants, 1), averaged over FACTION samples."),
    Metric("idle_final", "idle ships at end", "none", "fleet",
           "Last observed idle count."),
    Metric("engaged_mean", "engaged ships (mean)", "none", "fleet",
           "Mean FACTION engaged count. Engagement activity alone does not establish useful combat."),
    Metric("stalled_mean", "stalled ships (mean)", "none", "fleet",
           "Mean FACTION stalled count."),
    Metric("mismatch_max", "objective mismatches (max)", "none", "fleet",
           "Max FACTION mismatch count. Non-zero means a unit's native goal "
           "disagrees with its assigned objective."),
    Metric("unengaged_fraction", "unengaged share of unit-time", "none", "fleet",
           "unengagedSeconds / unitSeconds at end of match. Time alive and not fighting."),
    Metric("engagement_delay_mean", "first-engage delay (s)", "none", "fleet",
           "engagementDelaySum / engagementSamples."),
    Metric("replacement_value_final", "fleet value at end", "none", "fleet",
           "Last observed FACTION replacementValue, summed over factions. This is "
           "the surviving fleet, so it moves inversely with losses_value."),

    # -- losses and damage -----------------------------------------------
    Metric("losses_units", "units lost", "none", "losses",
           "Sum of the last FACTION losses dict per faction. Counts the AI's own "
           "casualties; this is an attrition measure, not a health measure."),
    Metric("losses_value", "value of units lost", "none", "losses",
           "Sum of LOSS event replacementCost. This is the value actually destroyed. "
           "Note: FACTION.replacementValueByClass is NOT this; it is the faction's "
           "surviving fleet value and sums to FACTION.replacementValue."),
    Metric("losses_capital", "capital-class units lost", "none", "losses",
           "Losses of capital/heavy/juggernaut classes. Evaluate trades and objectives before judging the loss."),
    Metric("loss_events", "LOSS events", "none", "losses",
           "Number of LOSS telemetry events (includes non-AI factions)."),
    Metric("bounty_awarded", "bounty CP awarded", "none", "losses",
           "Sum of LOSS bountyCP. Higher means the AI's kills paid out."),
    Metric("station_hull_final_frac", "station hull at end", "none", "losses",
           "Last FACTION stationHull / stationMax, mean over factions."),
    Metric("station_beam_hits", "station beam hits", "none", "losses",
           "STATION_BEAM_HIT events. Beam damage landing on stations at all."),
    Metric("station_repairs", "station repair reports", "none", "losses",
           "STATION_REPAIR telemetry reports. Station upkeep activity."),
    Metric("station_repaired_hull", "station hull restored", "none", "losses",
           "sum of STATION_REPAIR.repaired. Zero with samples present means hull never fell "
           "below the ceiling scarHull sets, or ARMOR L2 was never bought - see "
           "station_repair_unlocked_factions."),
    Metric("station_repaired_cumulative", "station hull restored (running)", "none", "none",
           "Max STATION_REPAIR.totalRepaired per faction, added across factions. This is a "
           "cumulative gauge, so it is a max, never a sum."),
    Metric("station_repair_below_ceiling", "repair-eligible reports", "none", "none",
           "STATION_REPAIR samples where hull sat below repairCeiling, i.e. damage the station "
           "was allowed to undo."),
    Metric("station_repair_unlocked_factions", "factions at ARMOR L2+", "none", "none",
           "Legacy repairUnlocked flag tracks ARMOR L2+. Current stations already repair below L2 at a lower rate."),
    Metric("station_hull_min_frac", "station hull (worst)", "none", "losses",
           "Min FACTION stationHull / stationMax. Catches a station that nearly died."),
    Metric("station_hull_mean_frac", "station hull (mean)", "none", "losses",
           "Mean FACTION stationHull / stationMax over samples."),
    Metric("damage_received_final", "damage received at end", "none", "losses",
           "Last FACTION received. Volume of incoming damage; context only, because "
           "it rises when the AI fights more, which is usually the goal."),
    Metric("damage_dealt_known", "samples with damageDealt", "none", "losses",
           "FACTION samples with numeric damageDealt. Check resolved-damage coverage and attribution before interpreting totals."),
    Metric("friendly_hits", "friendly-fire events", "none", "losses",
           "FRIENDLY_HIT events."),

    # -- order execution -------------------------------------------------
    Metric("order_attempts", "order attempts", "none", "orders",
           "COUNTERS orders.attempts (cumulative, final sample)."),
    Metric("order_success_rate", "order success rate", "none", "orders",
           "COUNTERS orders.success / orders.attempts."),
    Metric("order_failed_rate", "order failure rate", "none", "orders",
           "COUNTERS orders.failed / orders.attempts."),
    Metric("order_rejected_rate", "order rejection rate", "none", "orders",
           "COUNTERS orders.rejected / orders.attempts. Non-zero means the AI asked "
           "for something the engine refused."),
    Metric("order_unchanged_rate", "order no-op rate", "none", "orders",
           "COUNTERS orders.unchanged / orders.attempts. Orders that changed nothing."),
    Metric("order_reissue_rate", "order reissue rate", "none", "orders",
           "COUNTERS reissued / orders.attempts. Re-issuing the same order is churn "
           "but also a retry after a no-op, so polarity is left open."),
    Metric("orders_per_1000s", "orders per 1000 sim-seconds", "none", "orders",
           "COUNTERS orders.attempts normalized by duration."),
    Metric("decision_switch_rate", "objective switch rate", "none", "orders",
           "COUNTERS switches / decisions. Interpret objective progress and changing threats before judging switching."),
    Metric("decision_retain_rate", "objective retain rate", "none", "orders",
           "COUNTERS retained / decisions. The complement of switching."),
    Metric("native_change_rate", "native goal change rate", "none", "orders",
           "COUNTERS nativeChanges / decisions. Engine-side churn, not planner churn."),
    Metric("decisions_total", "DECISION events", "none", "orders",
           "Number of DECISION telemetry events."),
    Metric("can_push_rate", "canPush samples", "none", "orders",
           "FACTION samples where plan.canPush was true. Informational: the planner "
           "believing it can push is not the same as it pushing."),

    # -- build decisions -------------------------------------------------
    Metric("build_decisions", "build decisions", "none", "build",
           "AI_BUILD_DECISION events."),
    Metric("build_purchase_rate", "build purchase rate", "none", "build",
           "reason in {PURCHASE_SELECTED, EMERGENCY_DEFENSE_PURCHASE} / build decisions. "
           "The direct 'did it actually buy anything' signal."),
    Metric("build_insufficient_rate", "insufficient-CP rate", "none", "build",
           "reason == INSUFFICIENT_CP / build decisions."),
    Metric("build_saving_rate", "saving-for-role rate", "none", "build",
           "reason == SAVING_FOR_DESIRED_ROLE / build decisions. High and constant is "
           "a bank stall; contextual, so polarity is open."),
    Metric("build_affordable_mean", "affordable options (mean)", "none", "build",
           "Mean AI_BUILD_DECISION affordableOptions."),
    Metric("build_unlocked_mean", "unlocked options (mean)", "none", "build",
           "Mean AI_BUILD_DECISION unlockedOptions. Drops when a change re-locks tiers."),
    Metric("build_bank_shortfall_mean", "bank shortfall (mean CP)", "none", "build",
           "Mean max(0, bankTarget - commandPoints). Large and constant means the AI is "
           "permanently saving toward an unreachable target."),
    Metric("build_decisions_per_1000s", "build decisions per 1000s", "none", "build",
           "AI_BUILD_DECISION events normalized by duration."),
    Metric("queued_orders_total", "PRODUCTION queue events", "none", "build",
           "PRODUCTION events with a spending action."),

    # -- execution modes -------------------------------------------------
    Metric("exec_total", "EXECUTION events", "none", "execution",
           "Number of EXECUTION telemetry events."),
    Metric("exec_no_objective_rate", "no-objective rate", "none", "execution",
           "status == NO_OBJECTIVE / EXECUTION events. The ship had no job."),
    Metric("exec_idle_mode_rate", "idle-mode rate", "none", "execution",
           "mode == IDLE / EXECUTION events."),
    Metric("exec_unknown_goal_rate", "unknown-goal rate", "none", "execution",
           "goalPresent == 'unknown' / EXECUTION events. The engine had no goal to "
           "report; usually co-occurs with NO_OBJECTIVE."),
    Metric("exec_pursuit_rate", "pursuit rate", "none", "execution",
           "pursuit == true / EXECUTION events."),

    # -- service and operations -------------------------------------------
    Metric("service_events", "fleet service events", "none", "service",
           "FLEET_SERVICE events."),
    Metric("service_interrupted", "service interrupted", "none", "service",
           "FLEET_SERVICE_INTERRUPTED events. A repair that had to be abandoned."),
    Metric("service_work_events", "service work events", "none", "service",
           "FLEET_SERVICE_WORK events. Repair throughput."),
    Metric("service_spent", "service labour spent", "none", "service",
           "Sum of FLEET_SERVICE_WORK totalSpent. Higher means ships actually got "
           "repaired, not just routed to the station."),
    Metric("operation_transitions", "operation transitions", "none", "operations",
           "OPERATION events. Operation churn, no intrinsic polarity."),
    Metric("operation_withdraw_share", "operations ending WITHDRAW", "none", "operations",
           "phase == WITHDRAW / OPERATION events. Contextual: a planned withdrawal is "
           "not the same as an aborted assault, so polarity is open."),
]

METRIC_BY_KEY = {m.key: m for m in METRICS}
METRIC_ORDER = [m.key for m in METRICS]

HISTOGRAMS = {
    "hist.build_reason": ("build reason", ("build",)),
    "hist.build_role": ("desired role", ("build",)),
    "hist.decision_mission": ("DECISION mission", ("orders",)),
    "hist.decision_reason": ("DECISION reason", ("orders",)),
    "hist.exec_status": ("EXECUTION status", ("execution",)),
    "hist.exec_mode": ("EXECUTION mode", ("execution",)),
    "hist.plan_mission": ("planner mission mix", ("orders",)),
    "hist.plan_posture": ("planner posture", ("orders",)),
    "hist.service_reason": ("service reason", ("service",)),
    "hist.service_phase": ("service phase", ("service",)),
    "hist.operation_phase": ("operation phase", ("operations",)),
    "hist.operation_reason": ("operation reason", ("operations",)),
    "hist.loss_class": ("capital losses by class", ("losses",)),
}


def num(value):
    """Telemetry encodes numbers as floats and everything else as strings."""
    return float(value) if is_finite_number(value) else None


def safe_div(numerator, denominator, default=0.0):
    if numerator is None or not denominator:
        return default
    return numerator / denominator


class Series:
    """Bounded downsample of a value over mission time.

    Samples are bucketed per whole second of mission time, which is bounded by
    the simulation cap rather than by the record count, then reduced to
    SERIES_BUCKETS equal slices when the match ends. Keeping only the buckets
    means a 26k-record match costs a few hundred floats, not 26k records.
    """

    __slots__ = ("buckets", "n")

    def __init__(self):
        self.buckets = {}
        self.n = 0

    def add(self, time_value, value):
        key = int(time_value)
        if key < 0:
            key = 0
        current = self.buckets.get(key)
        if current is None:
            self.buckets[key] = [value, 1.0]
        else:
            current[0] += value
            current[1] += 1.0
        self.n += 1

    def as_list(self):
        if not self.buckets:
            return [None] * SERIES_BUCKETS
        keys = sorted(self.buckets)
        lo, hi = keys[0], keys[-1]
        span = max(1, hi - lo)
        width = span / SERIES_BUCKETS
        buckets = [[] for _ in range(SERIES_BUCKETS)]
        for key in keys:
            index = int((key - lo) / width)
            if index >= SERIES_BUCKETS:
                index = SERIES_BUCKETS - 1
            buckets[index].append(self.buckets[key])
        result = []
        for entries in buckets:
            if not entries:
                result.append(None)
                continue
            total = sum(e[0] for e in entries)
            count = sum(e[1] for e in entries)
            result.append(total / count)
        return result


class FactionAcc:
    """Fixed-size per-faction state. No retained records."""

    __slots__ = (
        "name", "samples", "flow_income", "flow_spend", "flow_refund", "flow_bounty",
        "flow_spend_samples", "last_flow_spend", "cp_sum", "cp_last", "cp_max",
        "queue_sum", "queue_max", "queue_blocked", "cap_sum", "cap_last",
        "combatants_sum", "combatants_max", "combatants_last",
        "idle_sum", "idle_max", "idle_last", "engaged_sum", "stalled_sum",
        "mismatch_max", "station_hull_min", "station_hull_sum", "station_hull_last",
        "received_last", "damage_dealt_known", "unit_seconds_last",
        "unengaged_last", "engagement_delay_sum", "engagement_samples",
        "replacement_value_last", "losses_last", "losses_value_last",
        "losses_by_class", "replacement_by_class", "composition_last",
        "plan_mission_counts", "postures", "can_push", "plan_urgent",
        "objectives_last", "station_repairs", "station_repaired",
        "station_repaired_total", "station_hull_damage", "station_repair_below_ceiling",
        "repair_unlocked", "flow_cumulative_spend",
        "build", "exec", "decisions", "objectives", "contest",
        "service", "operations",         "loss_events", "friendly_hits", "loss_value", "loss_class_value",
        "cp_series", "hull_series", "idle_series", "combat_series",
    )

    def __init__(self, name):
        self.name = name
        self.samples = 0
        self.flow_income = 0.0
        self.flow_spend = 0.0
        self.flow_refund = 0.0
        self.flow_bounty = 0.0
        self.flow_spend_samples = 0
        self.last_flow_spend = 0.0
        self.cp_sum = 0.0
        self.cp_last = 0.0
        self.cp_max = 0.0
        self.queue_sum = 0.0
        self.queue_max = 0.0
        self.queue_blocked = 0
        self.cap_sum = 0.0
        self.cap_last = 0.0
        self.combatants_sum = 0.0
        self.combatants_max = 0.0
        self.combatants_last = 0.0
        self.idle_sum = 0.0
        self.idle_max = 0.0
        self.idle_last = 0.0
        self.engaged_sum = 0.0
        self.stalled_sum = 0.0
        self.mismatch_max = 0.0
        self.station_hull_min = 1.0
        self.station_hull_sum = 0.0
        self.station_hull_last = 1.0
        self.received_last = 0.0
        self.damage_dealt_known = 0
        self.unit_seconds_last = 0.0
        self.unengaged_last = 0.0
        self.engagement_delay_sum = 0.0
        self.engagement_samples = 0
        self.replacement_value_last = 0.0
        self.losses_last = 0.0
        self.losses_value_last = 0.0
        self.losses_by_class = Counter()
        self.replacement_by_class = Counter()
        self.composition_last = {}
        self.plan_mission_counts = Counter()
        self.postures = Counter()
        self.can_push = 0
        self.plan_urgent = 0
        self.objectives_last = {}
        self.station_repairs = 0
        self.station_repaired = 0.0
        self.station_repaired_total = 0.0
        self.station_hull_damage = 0.0
        self.station_repair_below_ceiling = 0
        self.repair_unlocked = False
        self.flow_cumulative_spend = 0.0
        self.build = {
            "total": 0, "purchases": 0, "insufficient": 0, "saving": 0,
            "affordable": 0.0, "unlocked": 0.0, "shortfall": 0.0, "slots": 0.0,
            "reason": Counter(), "role": Counter(),
        }
        self.exec = {
            "total": 0, "no_objective": 0, "idle_mode": 0, "unknown_goal": 0,
            "pursuit": 0, "status": Counter(), "mode": Counter(),
        }
        self.decisions = {
            "total": 0, "mission": Counter(), "reason": Counter(), "posture": Counter(),
        }
        self.objectives = {"total": 0, "status": Counter(), "mission": Counter()}
        self.contest = {
            "total": 0, "primaries": [], "primary_set": set(),
            "mission_counts": Counter(), "stale_orders_max": 0.0,
            "stalled_groups_max": 0.0, "worst_stall_max": 0.0,
        }
        self.service = {
            "total": 0, "work": 0, "interrupted": 0, "reason": Counter(),
            "phase": Counter(), "spent": 0.0,
        }
        self.operations = {"total": 0, "phase": Counter(), "reason": Counter(), "serials": set()}
        self.loss_events = 0
        self.loss_value = 0.0
        self.loss_class_value = Counter()
        self.friendly_hits = 0
        self.cp_series = Series()
        self.hull_series = Series()
        self.idle_series = Series()
        self.combat_series = Series()


def _stringify(mapping):
    if not isinstance(mapping, dict):
        return {}
    return {str(k): num(v) for k, v in mapping.items() if num(v) is not None}


def fold_faction(acc, data, time_value):
    acc.samples += 1

    flow = (data.get("economy") or {}).get("flow") or {}
    spend = num(flow.get("productionSpend"))
    if spend is not None:
        # Interval flow. Summed, never read as a running total.
        acc.flow_spend += spend
        acc.last_flow_spend = spend
        acc.flow_spend_samples += 1
    for field, attr in (("income", "flow_income"), ("refund", "flow_refund"),
                        ("bounty", "flow_bounty")):
        value = num(flow.get(field))
        if value is not None:
            setattr(acc, attr, getattr(acc, attr) + value)

    economy = data.get("economy") or {}
    cp = num(economy.get("commandPoints"))
    if cp is not None:
        acc.cp_sum += cp
        acc.cp_last = cp
        acc.cp_max = max(acc.cp_max, cp)
        acc.cp_series.add(time_value, cp)
    depth = num(economy.get("queueDepth"))
    if depth is not None:
        acc.queue_sum += depth
        acc.queue_max = max(acc.queue_max, depth)
    queue = economy.get("queue") or {}
    if queue.get("waitingForCapacity") is True:
        acc.queue_blocked += 1
    cap = num(economy.get("fleetCap"))
    if cap is not None:
        acc.cap_sum += cap
        acc.cap_last = cap
    combatants = num(economy.get("combatants"))
    if combatants is None:
        combatants = num(data.get("combatants"))
    if combatants is not None:
        acc.combatants_sum += combatants
        acc.combatants_max = max(acc.combatants_max, combatants)
        acc.combatants_last = combatants
        acc.combat_series.add(time_value, combatants)

    idle = num(data.get("idle"))
    if idle is not None:
        acc.idle_sum += idle
        acc.idle_max = max(acc.idle_max, idle)
        acc.idle_last = idle
        acc.idle_series.add(time_value, idle)
    engaged = num(data.get("engaged"))
    if engaged is not None:
        acc.engaged_sum += engaged
    stalled = num(data.get("stalled"))
    if stalled is not None:
        acc.stalled_sum += stalled
    mismatch = num(data.get("mismatch"))
    if mismatch is not None:
        acc.mismatch_max = max(acc.mismatch_max, mismatch)

    hull = num(data.get("stationHull"))
    hull_max = num(data.get("stationMax"))
    if hull is not None and hull_max:
        frac = min(1.0, max(0.0, hull / hull_max))
        acc.station_hull_min = min(acc.station_hull_min, frac)
        acc.station_hull_sum += frac
        acc.station_hull_last = frac
        acc.hull_series.add(time_value, frac)

    received = num(data.get("received"))
    if received is not None:
        acc.received_last = received
    if num(data.get("damageDealt")) is not None:
        acc.damage_dealt_known += 1
    unit_seconds = num(data.get("unitSeconds"))
    if unit_seconds is not None:
        acc.unit_seconds_last = unit_seconds
    unengaged = num(data.get("unengagedSeconds"))
    if unengaged is not None:
        acc.unengaged_last = unengaged
    delay = num(data.get("engagementDelaySum"))
    if delay is not None:
        acc.engagement_delay_sum += delay
    delay_samples = num(data.get("engagementSamples"))
    if delay_samples is not None:
        acc.engagement_samples += delay_samples

    replacement = num(data.get("replacementValue"))
    if replacement is not None:
        acc.replacement_value_last = replacement

    losses = _stringify(data.get("losses"))
    if losses:
        acc.losses_last = sum(losses.values())
        # ASSIGN, do not accumulate. FACTION.losses is AIStats.losses, a
        # per-faction CUMULATIVE counter per class (initialised once at
        # fs2rts_ai_telemetry.lua:29 and never cleared mid-mission), and this
        # handler runs on every ~30 s FACTION record. update() summed that
        # monotone counter once per snapshot, inflating losses_capital by the
        # snapshot count - measured 36-48x, which is exactly the number of
        # FACTION records per match. losses_last above assigns, which is why it
        # was right and this was wrong. The final snapshot is the truth.
        acc.losses_by_class = Counter(losses)
    loss_value = _stringify(data.get("replacementValueByClass"))
    if loss_value:
        # Tracked only to prove the FACTION field is not a loss total: it sums
        # to replacementValue, i.e. the surviving fleet. Deliberately NOT used
        # for the losses_value metric.
        acc.losses_value_last = sum(loss_value.values())
    composition = _stringify(data.get("composition"))
    if composition:
        acc.composition_last = composition

    plan = data.get("plan") or {}
    mission_counts = _stringify(plan.get("missionCounts"))
    if mission_counts:
        acc.plan_mission_counts.update(mission_counts)
    if plan.get("posture") is not None:
        acc.postures[str(plan.get("posture"))] += 1
    if plan.get("canPush") is True:
        acc.can_push += 1
    if plan.get("urgent") is True:
        acc.plan_urgent += 1

    objectives = _stringify(data.get("objectives"))
    if objectives:
        acc.objectives_last = objectives

    telemetry = data.get("baseDamageTelemetry") or {}
    cumulative = telemetry.get("cumulative") or {}
    damaged = num(cumulative.get("hullDamage"))
    if damaged is not None:
        acc.station_hull_damage = max(acc.station_hull_damage, damaged)


def stream_match(path, workers=1, until=None):
    """Stream one telemetry file into a compact match accumulator.

    Tolerates a truncated final line: a run that was killed mid-write leaves a
    partial last line, and that is reported rather than raised.
    """
    factions = {}
    events = Counter()
    duration = 0.0
    records = 0
    malformed = 0
    malformed_positions = []
    truncated_tail = False
    last_line_had_newline = True
    cp_spent_production = 0.0
    production_events = 0
    cp_spent_service = 0.0
    cp_spend_ledger = 0.0
    cp_spend_entries = 0
    flow_spend_total = 0.0
    upgrade_spend_last = {}
    sentry_spend = 0.0
    sentry_builds = 0
    station_beam_hits = 0
    first_time = None
    latest_counters = {}
    observed = Counter()
    event_samples = Counter()
    sequence_valid = True
    previous_sequence = None
    previous_time = None
    ledger_at_publish = {}
    ledger_by_faction = defaultdict(float)
    global_result = None

    def observe(event, value, prefix=''):
        if value is not None:
            observed[(event, '@' + prefix)] += 1
        if isinstance(value, dict):
            for key, child in value.items():
                observe(event, child, prefix + '.' + str(key) if prefix else str(key))
        elif isinstance(value,bool):
            observed[(event, '?' + prefix)] += 1
        elif num(value) is not None:
            observed[(event, prefix)] += 1
            if (num(value) or 0) > 0:
                observed[(event, '+' + prefix)] += 1

    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if not line.endswith("\n"):
                last_line_had_newline = False
            stripped = line.strip()
            if not stripped:
                continue
            try:
                record = json.loads(stripped)
            except (json.JSONDecodeError, ValueError):
                malformed += 1
                if len(malformed_positions) < 5:
                    malformed_positions.append(records + 1)
                continue
            if not valid_record(record):
                malformed += 1
                continue
            time_value = num(record.get('time'))
            if time_value is None:
                malformed += 1
                continue
            sequence = num(record.get('sequence'))
            if sequence is None or sequence != int(sequence) or (previous_sequence is None and sequence != 1) or (previous_sequence is not None and sequence != previous_sequence + 1):
                sequence_valid = False
            previous_sequence = sequence
            if previous_time is not None and time_value < previous_time:
                sequence_valid = False
            previous_time = time_value
            if until is not None and time_value > until:
                continue
            last_line_had_newline = True
            records += 1
            event = record.get("event")
            events[event] += 1
            time_value = num(record.get("time")) or 0.0
            if first_time is None:
                first_time = time_value
            if time_value > duration:
                duration = time_value
            data = record.get("data")
            if not isinstance(data, dict):
                data = {}
            event_samples[event] += 1
            observe(event, data)
            if event == 'BATTLE_END' and data.get('globalResolved') is True:
                global_result = data.get('victorFaction')

            if event == "FACTION":
                name = data.get("faction")
                if name is None:
                    name = "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                fold_faction(acc, data, time_value)
                ledger_at_publish[str(name)] = ledger_by_faction.get(str(name), 0.0)
                # The interval flow for THIS record, before fold_faction folded
                # it into the faction running total.
                flow_spend_total += num(((data.get("economy") or {}).get("flow") or {}).get("productionSpend")) or 0.0
                # flowCumulative is a running gauge; keep the last snapshot.
                running = num(((data.get("economy") or {}).get("flowCumulative") or {}).get("productionSpend"))
                if running is not None:
                    acc.flow_cumulative_spend = running
                # upgradeSpend is a cumulative gauge; keep the last snapshot.
                upgrade = num((data.get("economy") or {}).get("upgradeSpend"))
                if upgrade is not None:
                    upgrade_spend_last[str(name)] = upgrade
                if (data.get("economy") or {}).get("repairUnlocked") is True:
                    acc.repair_unlocked = True
            elif event == "PRODUCTION":
                action = data.get("action")
                # Authoritative class->role map, harvested from the batch itself.
                # classify_role()'s faction-prefix heuristic calls every GTCv/GVCv/
                # GVOS hull a capital, but fs2rts_config.lua:386 has GTC Aeolus as
                # role="escort" and :1039 GVC Aten as role="escort", so escorts
                # and bombers were being counted as capital losses.
                _cls = data.get("class")
                _role = data.get("role")
                if _cls and _role and _role in CAPITAL_ROLES:
                    ROSTER_ROLES[str(_cls)] = str(_role)
                if action in SPEND_ACTIONS:
                    cost = num(data.get("cost"))
                    if cost is not None:
                        cp_spent_production += cost
                    production_events += 1
            elif event == "AI_BUILD_DECISION":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                build = acc.build
                build["total"] += 1
                reason = str(data.get("reason"))
                build["reason"][reason] += 1
                if reason in ("PURCHASE_SELECTED", "EMERGENCY_DEFENSE_PURCHASE"):
                    build["purchases"] += 1
                elif reason == "INSUFFICIENT_CP":
                    build["insufficient"] += 1
                elif reason == "SAVING_FOR_DESIRED_ROLE":
                    build["saving"] += 1
                build["role"][str(data.get("desiredRole"))] += 1
                affordable = num(data.get("affordableOptions"))
                if affordable is not None:
                    build["affordable"] += affordable
                unlocked = num(data.get("unlockedOptions"))
                if unlocked is not None:
                    build["unlocked"] += unlocked
                slots = num(data.get("slots"))
                if slots is not None:
                    build["slots"] += slots
                target = num(data.get("bankTarget"))
                points = num(data.get("commandPoints"))
                if target is not None and points is not None:
                    build["shortfall"] += max(0.0, target - points)
            elif event == "EXECUTION":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                execution = acc.exec
                execution["total"] += 1
                status = str(data.get("status"))
                mode = str(data.get("mode"))
                execution["status"][status] += 1
                execution["mode"][mode] += 1
                if status == "NO_OBJECTIVE":
                    execution["no_objective"] += 1
                if mode == "IDLE":
                    execution["idle_mode"] += 1
                if str(data.get("goalPresent")) == "unknown":
                    execution["unknown_goal"] += 1
                if data.get("pursuit") is True:
                    execution["pursuit"] += 1
            elif event == "DECISION":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                decisions = acc.decisions
                decisions["total"] += 1
                decisions["mission"][str(data.get("mission"))] += 1
                decisions["reason"][str(data.get("reason"))] += 1
                decisions["posture"][str(data.get("posture"))] += 1
            elif event == "OBJECTIVE":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                acc.objectives["total"] += 1
                acc.objectives["status"][str(data.get("status"))] += 1
                acc.objectives["mission"][str(data.get("mission"))] += 1
            elif event == "CONTEST":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                contest = acc.contest
                contest["total"] += 1
                primary = data.get("primaryName")
                if primary is not None and primary not in contest["primary_set"]:
                    contest["primary_set"].add(primary)
                    contest["primaries"].append(str(primary))
                for key, value in _stringify(data.get("missionCounts")).items():
                    contest["mission_counts"][key] = value
                for key, attr in (("staleOrders", "stale_orders_max"),
                                  ("stalledGroups", "stalled_groups_max"),
                                  ("worstStallSeconds", "worst_stall_max")):
                    value = num(data.get(key))
                    if value is not None:
                        contest[attr] = max(contest[attr], value)
            elif event == "FLEET_SERVICE":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                acc.service["total"] += 1
                acc.service["reason"][str(data.get("reason"))] += 1
                acc.service["phase"][str(data.get("phase"))] += 1
            elif event == "FLEET_SERVICE_WORK":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                acc.service["work"] += 1
                # `spent` is this tick's CP out of the faction bank and is the
                # only spend-side field; `totalSpent` is a running per-ship
                # total, so summing it would multiply the spend by the tick
                # count. It also belongs in the event spend total, because this
                # CP lands in economy.flow.productionSpend like everything else.
                spent = num(data.get("spent"))
                if spent is not None:
                    acc.service["spent"] += spent
                    cp_spent_service += spent
            elif event == "CP_SPEND":
                # Per-deduction ledger from RecordAIEconomyFlow, the chokepoint
                # that writes the interval flow. Summing it must reproduce
                # productionSpend exactly; the drift between the two is the
                # regression guard for a CP movement that stops being recorded.
                if data.get("flow") == "productionSpend":
                    amount = num(data.get("amount"))
                    if amount is not None:
                        cp_spend_ledger += amount
                        ledger_by_faction[str(data.get('faction'))] += amount
                        cp_spend_entries += 1
            elif event == "FLEET_SERVICE_INTERRUPTED":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                acc.service["interrupted"] += 1
            elif event == "OPERATION":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                operations = acc.operations
                operations["total"] += 1
                operations["phase"][str(data.get("phase"))] += 1
                operations["reason"][str(data.get("reason"))] += 1
                serial = num(data.get("serial"))
                if serial is not None:
                    operations["serials"].add(serial)
            elif event == "LOSS":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                acc.loss_events += 1
                # replacementCost is the value actually destroyed by this loss.
                cost = num(data.get("replacementCost"))
                if cost is None:
                    cost = num(data.get("baseUnitCost"))
                if cost is not None:
                    acc.loss_value += cost
                class_name = data.get("class")
                if class_name is not None:
                    acc.loss_class_value[str(class_name)] += cost or 0.0
            elif event == "FRIENDLY_HIT":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                acc.friendly_hits += 1
            elif event == "STATION_REPAIR":
                name = data.get("faction") or "UNKNOWN"
                acc = factions.get(name)
                if acc is None:
                    acc = factions[name] = FactionAcc(str(name))
                acc.station_repairs += 1
                # `repaired` is this report's increment and `totalRepaired` the
                # station's running hull restored, so the running total is the
                # max, never a sum. Zero means the ARMOR L2 gate was not met or
                # hull never sat below the ceiling; `repair_unlocked` and the
                # ceiling gap say which, so a zero is readable rather than blank.
                repaired = num(data.get("repaired"))
                if repaired is not None:
                    acc.station_repaired += repaired
                total = num(data.get("totalRepaired"))
                if total is not None:
                    acc.station_repaired_total = max(acc.station_repaired_total, total)
                hull = num(data.get("hull"))
                ceiling = num(data.get("repairCeiling"))
                if hull is not None and ceiling is not None and hull < ceiling:
                    acc.station_repair_below_ceiling += 1
            elif event == "STATION_BEAM_HIT":
                station_beam_hits += 1
            elif event == "SENTRY_BUILD":
                if data.get("action") == "BUILD_STARTED":
                    cost = num(data.get("cost"))
                    if cost is not None:
                        sentry_spend += cost
                    sentry_builds += 1
            elif event == "COUNTERS":
                # COUNTERS is emitted periodically and every record carries the
                # full cumulative state, so only the last one is kept.
                latest_counters = data

    if not last_line_had_newline and malformed:
        truncated_tail = True

    return {
        "path": str(path),
        "duration": duration,
        "first_time": first_time,
        "records": records,
        "malformed": malformed,
        "malformed_positions": malformed_positions,
        "truncated_tail": truncated_tail,
        "factions": factions,
        "events": events,
        "cp_spent_production": cp_spent_production,
        "production_events": production_events,
        "cp_spent_service": cp_spent_service,
        "cp_spend_ledger": cp_spend_ledger,
        "cp_spend_entries": cp_spend_entries,
        "flow_spend_total": flow_spend_total,
        "flow_cumulative_total": sum(a.flow_cumulative_spend for a in factions.values()),
        "upgrade_spend_last": upgrade_spend_last,
        "sentry_spend": sentry_spend,
        "sentry_builds": sentry_builds,
        "station_beam_hits": station_beam_hits,
        "counters": latest_counters,
        "observed": observed, "event_samples": event_samples,
        "sequence_valid": sequence_valid and records > 0,
        "ledger_at_publish": sum(ledger_at_publish.values()),
        "global_result": global_result,
    }


def _match_vector(match):
    """Reduce one match's per-faction accumulators to the metric vector."""
    factions = match["factions"]
    samples = sum(acc.samples for acc in factions.values()) or 1
    duration = match["duration"] or 1.0
    vec = {}

    def total(fn):
        return sum(fn(acc) for acc in factions.values())

    def mean(fn):
        return total(fn) / samples

    cp_spent_flow = total(lambda a: a.flow_spend)
    cp_spent_production = match["cp_spent_production"]
    cp_spent_events = cp_spent_production + match["sentry_spend"] + match["cp_spent_service"]

    orders = match["counters"].get("orders") or {}
    decisions_total = num(match["counters"].get("decisions")) or 0.0
    attempts = num(orders.get("attempts")) or 0.0
    switches = num(match["counters"].get("switches")) or 0.0
    retained = num(match["counters"].get("retained")) or 0.0
    native_changes = num(match["counters"].get("nativeChanges")) or 0.0
    reissued = num(match["counters"].get("reissued")) or 0.0

    build_total = total(lambda a: a.build["total"])
    exec_total = total(lambda a: a.exec["total"])
    op_total = total(lambda a: a.operations["total"])
    service_total = total(lambda a: a.service["total"])
    decision_events = total(lambda a: a.decisions["total"])
    engagement_samples = total(lambda a: a.engagement_samples)
    engagement_delay = total(lambda a: a.engagement_delay_sum)

    capital_losses = total(
        lambda a: sum(v for k, v in a.losses_by_class.items() if classify_role(k)))

    vec["duration_seconds"] = duration
    vec["records"] = float(match["records"])
    vec["malformed_lines"] = float(match["malformed"])
    vec["truncated_tail"] = 1.0 if match["truncated_tail"] else 0.0
    vec["engine_result"] = 0.0
    vec["factions"] = float(len(factions))

    vec["cp_spent_flow"] = cp_spent_flow
    vec["cp_spent_production"] = cp_spent_production
    vec["sentry_spend"] = match["sentry_spend"]
    vec["sentry_builds"] = float(match["sentry_builds"])
    vec["cp_spent_events_total"] = cp_spent_events
    # Negative by design: station upgrades and the faction ability deduct CP
    # through the same chokepoint but publish no purchase event, so the event
    # total cannot reach the flow. cp_upgrade_spend is the size of that gap.
    vec["cp_spent_flow_gap"] = cp_spent_events - cp_spent_flow
    vec["cp_spend_rate"] = cp_spent_flow / duration
    vec["cp_income_total"] = total(lambda a: a.flow_income)
    vec["cp_bounty_total"] = total(lambda a: a.flow_bounty)
    vec["cp_refund_total"] = total(lambda a: a.flow_refund)
    vec["cp_banked_final"] = total(lambda a: a.cp_last)
    vec["cp_banked_max"] = total(lambda a: a.cp_max)
    vec["queue_depth_mean"] = mean(lambda a: a.queue_sum)
    vec["queue_blocked_samples"] = float(total(lambda a: a.queue_blocked))

    vec["combatants_final"] = total(lambda a: a.combatants_last)
    vec["combatants_mean"] = mean(lambda a: a.combatants_sum)
    vec["combatants_max"] = total(lambda a: a.combatants_max)
    vec["fleet_cap_final"] = total(lambda a: a.cap_last)
    # cap_sum and combatants_sum are both sums over the same FACTION samples,
    # so their ratio is already a per-faction mean utilisation. Averaging that
    # across factions keeps the value a fraction in 0..1.
    vec["cap_utilisation_mean"] = (
        sum(safe_div(a.combatants_sum, a.cap_sum, 0.0) for a in factions.values())
        / len(factions)) if factions else 0.0
    vec["idle_mean"] = mean(lambda a: a.idle_sum)
    vec["idle_max"] = total(lambda a: a.idle_max)
    vec["idle_fraction_mean"] = mean(
        lambda a: safe_div(a.idle_sum, max(a.combatants_sum, 1.0), 0.0))
    vec["idle_final"] = total(lambda a: a.idle_last)
    vec["engaged_mean"] = mean(lambda a: a.engaged_sum)
    vec["stalled_mean"] = mean(lambda a: a.stalled_sum)
    vec["mismatch_max"] = total(lambda a: a.mismatch_max)
    vec["unengaged_fraction"] = safe_div(
        total(lambda a: a.unengaged_last), total(lambda a: a.unit_seconds_last), 0.0)
    vec["engagement_delay_mean"] = safe_div(engagement_delay, engagement_samples, 0.0)
    vec["replacement_value_final"] = total(lambda a: a.replacement_value_last)

    vec["losses_units"] = total(lambda a: a.losses_last)
    vec["losses_value"] = total(lambda a: a.loss_value)
    vec["losses_capital"] = capital_losses
    vec["loss_events"] = float(total(lambda a: a.loss_events))
    vec["bounty_awarded"] = total(lambda a: a.flow_bounty)
    vec["station_hull_final_frac"] = (
        total(lambda a: a.station_hull_last) / len(factions)) if factions else 0.0
    vec["station_hull_min_frac"] = min(
        (a.station_hull_min for a in factions.values()), default=1.0)
    vec["station_hull_mean_frac"] = (
        total(lambda a: a.station_hull_sum) / samples)
    vec["damage_received_final"] = total(lambda a: a.received_last)
    vec["damage_dealt_known"] = float(total(lambda a: a.damage_dealt_known))
    vec["friendly_hits"] = float(total(lambda a: a.friendly_hits))
    vec["station_beam_hits"] = float(match["station_beam_hits"])

    vec["order_attempts"] = attempts
    vec["order_success_rate"] = safe_div(num(orders.get("success")), attempts)
    vec["order_failed_rate"] = safe_div(num(orders.get("failed")), attempts)
    vec["order_rejected_rate"] = safe_div(num(orders.get("rejected")), attempts)
    vec["order_unchanged_rate"] = safe_div(num(orders.get("unchanged")), attempts)
    vec["order_reissue_rate"] = safe_div(reissued, attempts)
    vec["orders_per_1000s"] = attempts / duration * 1000.0
    vec["decision_switch_rate"] = safe_div(switches, decisions_total)
    vec["decision_retain_rate"] = safe_div(retained, decisions_total)
    vec["native_change_rate"] = safe_div(native_changes, decisions_total)
    vec["decisions_total"] = decision_events
    vec["can_push_rate"] = total(lambda a: a.can_push) / samples

    vec["build_decisions"] = float(build_total)
    vec["build_purchase_rate"] = safe_div(total(lambda a: a.build["purchases"]), build_total)
    vec["build_insufficient_rate"] = safe_div(
        total(lambda a: a.build["insufficient"]), build_total)
    vec["build_saving_rate"] = safe_div(total(lambda a: a.build["saving"]), build_total)
    vec["build_affordable_mean"] = safe_div(
        total(lambda a: a.build["affordable"]), build_total)
    vec["build_unlocked_mean"] = safe_div(
        total(lambda a: a.build["unlocked"]), build_total)
    vec["build_bank_shortfall_mean"] = safe_div(
        total(lambda a: a.build["shortfall"]), build_total)
    vec["build_decisions_per_1000s"] = build_total / duration * 1000.0
    vec["queued_orders_total"] = float(match["production_events"])

    vec["exec_total"] = float(exec_total)
    vec["exec_no_objective_rate"] = safe_div(
        total(lambda a: a.exec["no_objective"]), exec_total)
    vec["exec_idle_mode_rate"] = safe_div(total(lambda a: a.exec["idle_mode"]), exec_total)
    vec["exec_unknown_goal_rate"] = safe_div(
        total(lambda a: a.exec["unknown_goal"]), exec_total)
    vec["exec_pursuit_rate"] = safe_div(total(lambda a: a.exec["pursuit"]), exec_total)

    vec["service_events"] = float(service_total)
    vec["service_interrupted"] = float(total(lambda a: a.service["interrupted"]))
    vec["service_work_events"] = float(total(lambda a: a.service["work"]))
    vec["service_spent"] = total(lambda a: a.service["spent"])
    vec["operation_transitions"] = float(op_total)
    vec["operation_withdraw_share"] = safe_div(
        total(lambda a: a.operations["phase"].get("WITHDRAW", 0)), op_total)
    vec["station_repairs"] = float(total(lambda a: a.station_repairs))
    vec["station_repaired_hull"] = total(lambda a: a.station_repaired)
    vec["station_repaired_cumulative"] = total(lambda a: a.station_repaired_total)
    vec["station_repair_below_ceiling"] = float(total(lambda a: a.station_repair_below_ceiling))
    vec["station_repair_unlocked_factions"] = float(
        sum(1 for a in factions.values() if a.repair_unlocked))
    # CP reconciliation. cp_spent_flow_gap is the event-carried total minus the
    # interval flow and is EXPECTED to be negative: station upgrades and the
    # faction ability spend CP with no purchase event of their own.
    # cp_spend_drift is the per-deduction ledger against the same flow and must be
    # ~0; non-zero means a CP movement stopped being recorded.
    vec["cp_spend_ledger"] = match["cp_spend_ledger"]
    # Compared against economy.flowCumulative, the running total behind the
    # interval flow: the interval is zeroed when FACTION publishes it, so spend
    # made after a match's last FACTION record is in no published interval.
    # Undefined, not zero, on a batch that predates either record: there is no
    # second view to compare against, and reporting the raw -flow would dress
    # every legacy batch up as a catastrophic reconciliation failure.
    vec["cp_spend_drift"] = (match["ledger_at_publish"] - match["flow_cumulative_total"]
                             if match["cp_spend_entries"] and match["flow_cumulative_total"] else 0.0)
    vec["cp_flow_cumulative"] = match["flow_cumulative_total"]
    vec["cp_upgrade_spend"] = float(sum(match["upgrade_spend_last"].values()))

    return vec


# Capital and heavy ship prefixes as they appear in the observed class names.
# Only used for the losses_capital metric, so a conservative prefix test is
# enough: an unrecognised class counts as non-capital.
CAPITAL_PREFIXES = frozenset({
    "gtc", "gvc", "gvd", "gtd", "gtl", "sd", "sj",
})


def classify_role(class_name):
    """True when the class is a capital-class hull.

    Resolution order:
      1. ROSTER_ROLES - the role the batch's own PRODUCTION records declare.
         Authoritative: fs2rts_config.lua is the single source of truth for a
         hull's role and it does NOT follow the faction prefix. GTC Aeolus and
         GVC Aten are role="escort" (config.lua:386, :1039) while GTCv Deimos is
         role="capital", and all three share the "gtc"/"gvc" prefix.
      2. The faction-prefix heuristic, for classes never observed being built in
         this batch. Deliberately last: it was the ONLY rule before, which made
         every GTCv/GVCv escort and bomber count as a capital loss.
    """
    known = ROSTER_ROLES.get(str(class_name))
    if known is not None:
        return known in CAPITAL_ROLES
    name = str(class_name).lower()
    head, _, tail = name.partition(" ")
    if not tail:
        return False
    prefix = re.sub(r"v$", "", head)
    if prefix in CAPITAL_PREFIXES:
        return True
    # Role words appear in the middle: "GTD Orion", "GTCv Deimos", "SJ Sathanas".
    for word in tail.split():
        if word in CAPITAL_ROLES:
            return True
    return False


def match_histograms(match):
    hist = {key: Counter() for key in HISTOGRAMS}
    for acc in match["factions"].values():
        hist["hist.build_reason"].update(acc.build["reason"])
        hist["hist.build_role"].update(acc.build["role"])
        hist["hist.decision_mission"].update(acc.decisions["mission"])
        hist["hist.decision_reason"].update(acc.decisions["reason"])
        hist["hist.exec_status"].update(acc.exec["status"])
        hist["hist.exec_mode"].update(acc.exec["mode"])
        hist["hist.plan_mission"].update(acc.plan_mission_counts)
        hist["hist.plan_posture"].update(acc.postures)
        hist["hist.service_reason"].update(acc.service["reason"])
        hist["hist.service_phase"].update(acc.service["phase"])
        hist["hist.operation_phase"].update(acc.operations["phase"])
        hist["hist.operation_reason"].update(acc.operations["reason"])
        capital = Counter()
        for class_name, value in acc.losses_by_class.items():
            if classify_role(class_name):
                capital[class_name] += value
        hist["hist.loss_class"].update(capital)
    return {k: dict(v) for k, v in hist.items()}

def discover_matches(batch_dir):
    """Find every match's telemetry under a batch directory.

    A match is a runner attempt directory. Two of these can collide in the
    same batch when runners overlap, so a batch is not assumed to hold a clean
    N matches: the count is reported as found, per match, and the comparison
    says so explicitly when the two batches differ.
    """
    batch = Path(batch_dir).resolve()
    if not batch.is_dir():
        raise SystemExit(f"compare_batches: not a directory: {batch}")

    found = []
    seen = set()
    for pattern in (
        str(batch / "results" / "*" / "*" / "*" / "probe" / "data" / "rts-ai-*.jsonl"),
        str(batch / "results" / "*" / "*" / "*" / "rts-ai-*.jsonl"),
        str(batch / "results" / "*" / "*" / "rts-ai-*.jsonl"),
        str(batch / "rts-ai-*.jsonl"),
    ):
        for path_string in sorted(glob.glob(pattern)):
            path = Path(path_string)
            if path in seen:
                continue
            seen.add(path)
            found.append(path)

    matches = []
    for path in found:
        run_dir = _run_dir_for(path)
        engine_result = run_dir / "engine-result.json" if run_dir else None
        matches.append({
            "path": path,
            "run_dir": run_dir,
            "worker": _worker_for(path),
            "attempt": _attempt_for(path),
            "engine_result": engine_result if engine_result and engine_result.is_file() else None,
        })
    return matches


def _run_dir_for(path):
    for parent in path.parents:
        if parent.name.startswith("a-"):
            return parent
    return path.parent


def _worker_for(path):
    for parent in path.parents:
        if parent.parent.name == "w":
            return parent.name
    return "?"


def _attempt_for(path):
    for parent in path.parents:
        if parent.name.startswith("a-"):
            return parent.name
    return "?"


def load_batch(batch_dir, label, until=None):
    matches = discover_matches(batch_dir)
    loaded = []
    for info in matches:
        match = stream_match(info["path"], until=until)
        vec = _match_vector(match)
        # engine-result.json is optional. Its absence is the normal state for a
        # batch that ended on the simulation cap, and must not be reported as
        # a crash or a failure.
        vec["engine_result"] = 1.0 if info["engine_result"] else 0.0
        loaded.append({
            "evidence": inspect_run(info['run_dir']),
            "coverage": metric_coverage(match, vec),
            "sequence_valid": match['sequence_valid'], "until": until,
            "global_result": match['global_result'],
            "label": label,
            "batch": str(Path(batch_dir).resolve()),
            "worker": info["worker"],
            "attempt": info["attempt"],
            "path": str(info["path"]),
            "engine_result_path": (str(info["engine_result"]) if info["engine_result"] else None),
            "termination": ("result file present (completion unverified)" if info["engine_result"]
                            else "telemetry-only (termination unverified)"),
            "vector": vec,
            "histograms": match_histograms(match),
            "events": dict(match["events"]),
            "malformed_positions": match["malformed_positions"],
            "factions": {
                name: {
                    "samples": acc.samples,
                    "cp_spent_flow": acc.flow_spend,
                    "last_flow_spend": acc.last_flow_spend,
                    "flow_spend_samples": acc.flow_spend_samples,
                    "cp_income": acc.flow_income,
                    "combatants_final": acc.combatants_last,
                    "combatants_mean": acc.combatants_sum / acc.samples if acc.samples else 0.0,
                    "idle_mean": acc.idle_sum / acc.samples if acc.samples else 0.0,
                    "idle_final": acc.idle_last,
                    "engaged_mean": acc.engaged_sum / acc.samples if acc.samples else 0.0,
                    "station_hull_final_frac": acc.station_hull_last,
                    "station_hull_min_frac": acc.station_hull_min,
                    "losses": dict(acc.losses_by_class),
                    "replacement_value": acc.replacement_value_last,
                    "build_purchases": acc.build["purchases"],
                    "build_total": acc.build["total"],
                    "exec_total": acc.exec["total"],
                    "exec_no_objective": acc.exec["no_objective"],
                    "cp_series": acc.cp_series.as_list(),
                    "hull_series": acc.hull_series.as_list(),
                    "idle_series": acc.idle_series.as_list(),
                    "combat_series": acc.combat_series.as_list(),
                }
                for name, acc in sorted(match["factions"].items())
            },
        })
    return loaded



def metric_coverage(match, vector):
    """Only observed fields support a metric; absent events do not prove zero."""
    observed, samples = match['observed'], match['event_samples']
    def fields(event, *paths):
        return samples[event] > 0 and all(observed[(event, p)] == samples[event] for p in paths)
    result = {key: False for key in vector}
    for key in ('duration_seconds', 'records', 'malformed_lines', 'truncated_tail', 'engine_result'):
        result[key] = True
    requirements = {
    "cp_spent_flow": "economy.flow.productionSpend",
    "cp_spend_rate": "economy.flow.productionSpend",
    "cp_income_total": "economy.flow.income",
    "cp_bounty_total": "economy.flow.bounty",
    "bounty_awarded": "economy.flow.bounty",
    "cp_refund_total": "economy.flow.refund",
    "cp_banked_final": "economy.commandPoints",
    "cp_banked_max": "economy.commandPoints",
    "queue_depth_mean": "economy.queueDepth",
    "fleet_cap_final": "economy.fleetCap",
    "combatants_final": "economy.combatants",
    "combatants_mean": "economy.combatants",
    "combatants_max": "economy.combatants",
    "idle_mean": "idle",
    "idle_max": "idle",
    "idle_final": "idle",
    "engaged_mean": "engaged",
    "stalled_mean": "stalled",
    "mismatch_max": "mismatch",
    "replacement_value_final": "replacementValue",
    "damage_received_final": "received",
    "cp_flow_cumulative": "economy.flowCumulative.productionSpend",
    "cp_upgrade_spend": "economy.upgradeSpend",
    "can_push_rate": "?plan.canPush"
}
    for key, path in requirements.items():
        result[key] = fields('FACTION', path)
    result['factions'] = samples['FACTION'] > 0
    for key in ('station_hull_final_frac', 'station_hull_min_frac', 'station_hull_mean_frac'):
        result[key] = fields('FACTION', 'stationHull', '+stationMax')
    result['cap_utilisation_mean'] = fields('FACTION', 'economy.combatants', 'economy.fleetCap') and all(a.cap_sum > 0 for a in match['factions'].values())
    result['idle_fraction_mean'] = fields('FACTION', 'idle', 'economy.combatants') and all(a.combatants_sum > 0 for a in match['factions'].values())
    result['engagement_delay_mean'] = fields('FACTION', 'engagementDelaySum', 'engagementSamples') and sum(a.engagement_samples for a in match['factions'].values()) > 0
    result['unengaged_fraction'] = fields('FACTION', 'unitSeconds', 'unengagedSeconds') and sum(a.unit_seconds_last for a in match['factions'].values()) > 0
    result['order_attempts'] = fields('COUNTERS', 'orders.attempts')
    for key, path in {'order_success_rate':'orders.success', 'order_failed_rate':'orders.failed',
                      'order_rejected_rate':'orders.rejected', 'order_unchanged_rate':'orders.unchanged',
                      'order_reissue_rate':'reissued'}.items():
        result[key] = fields('COUNTERS', path, 'orders.attempts') and vector['order_attempts'] > 0
    result['orders_per_1000s'] = result['order_attempts'] and match['duration'] > 0
    for key, path in {'decision_switch_rate':'switches', 'decision_retain_rate':'retained', 'native_change_rate':'nativeChanges'}.items():
        result[key] = fields('COUNTERS', path, 'decisions') and (num(match['counters'].get('decisions')) or 0) > 0
    result['cp_spend_ledger'] = fields('CP_SPEND', 'amount')
    result['cp_spend_drift'] = result['cp_flow_cumulative'] and result['cp_spend_ledger'] and match['sequence_valid']
    result['queue_blocked_samples'] = fields('FACTION', '?economy.queue.waitingForCapacity')
    result['losses_units'] = fields('FACTION', '@losses')
    result['losses_capital'] = result['losses_units'] and fields('PRODUCTION', '@role', '@class')
    result['losses_value'] = fields('LOSS', 'replacementCost')
    result['damage_dealt_known'] = fields('FACTION', 'damageDealt')
    result['cp_spent_production'] = fields('PRODUCTION', 'cost', '@action')
    result['queued_orders_total'] = fields('PRODUCTION', '@action')
    result['sentry_spend'] = fields('SENTRY_BUILD', 'cost', '@action')
    result['sentry_builds'] = fields('SENTRY_BUILD', '@action')
    result['service_spent'] = fields('FLEET_SERVICE_WORK', 'spent')
    result['cp_spent_events_total'] = all(result[k] for k in ('cp_spent_production','sentry_spend','service_spent'))
    result['cp_spent_flow_gap'] = result['cp_spent_events_total'] and result['cp_spent_flow']
    result['decisions_total'] = samples['DECISION'] > 0
    for key in ('build_purchase_rate','build_insufficient_rate','build_saving_rate'):
        result[key] = fields('AI_BUILD_DECISION', '@reason')
    for key, path in {'build_affordable_mean':'affordableOptions', 'build_unlocked_mean':'unlockedOptions',
                      'build_bank_shortfall_mean':'bankTarget'}.items():
        result[key] = fields('AI_BUILD_DECISION', path, 'commandPoints')
    result['build_decisions_per_1000s'] = samples['AI_BUILD_DECISION'] > 0 and match['duration'] > 0
    for key, path in {'exec_no_objective_rate':'@status', 'exec_idle_mode_rate':'@mode',
                      'exec_unknown_goal_rate':'@goalPresent', 'exec_pursuit_rate':'?pursuit'}.items():
        result[key] = fields('EXECUTION', path)
    result['operation_withdraw_share'] = fields('OPERATION', '@phase')
    result['station_repaired_hull'] = fields('STATION_REPAIR', 'repaired')
    result['station_repaired_cumulative'] = fields('STATION_REPAIR', 'totalRepaired')
    result['station_repair_below_ceiling'] = fields('STATION_REPAIR', 'hull', 'repairCeiling')
    result['station_repair_unlocked_factions'] = fields('FACTION', '?economy.repairUnlocked')
    for key, event in {'exec_total':'EXECUTION', 'build_decisions':'AI_BUILD_DECISION',
                       'service_events':'FLEET_SERVICE', 'service_interrupted':'FLEET_SERVICE_INTERRUPTED',
                       'service_work_events':'FLEET_SERVICE_WORK', 'operation_transitions':'OPERATION',
                       'loss_events':'LOSS', 'station_beam_hits':'STATION_BEAM_HIT',
                       'friendly_hits':'FRIENDLY_HIT', 'station_repairs':'STATION_REPAIR'}.items():
        result[key] = samples[event] > 0
    return result

def median(values):
    if not values:
        return 0.0
    return statistics.median(values)


def mad(values, centre=None):
    """Median absolute deviation: a spread that a single outlier cannot inflate
    the way a standard deviation can. Used to decide whether two batches'
    per-match values actually separate."""
    if not values:
        return 0.0
    if centre is None:
        centre = median(values)
    return median([abs(v - centre) for v in values])


def _quantiles(values):
    if not values:
        return 0.0, 0.0, 0.0
    ordered = sorted(values)
    return ordered[0], median(ordered), ordered[-1]


def _duration_clusters(durations, ratio=1.5):
    """Group match lengths into bands separated by more than `ratio`.

    A single batch can contain full-length matches and matches that were cut
    short. Sorting the durations and splitting where the step exceeds the ratio
    finds those bands without assuming anything about how many there are."""
    ordered = sorted(durations)
    if not ordered:
        return []
    clusters = [[ordered[0]]]
    for value in ordered[1:]:
        if value > clusters[-1][-1] * ratio:
            clusters.append([value])
        else:
            clusters[-1].append(value)
    return clusters


def compare_metric(key, base_values, cand_values, rel_tol, abs_tol):
    base_median = median(base_values)
    cand_median = median(cand_values)
    delta = cand_median - base_median
    if base_median:
        rel_delta = delta / abs(base_median)
    else:
        rel_delta = float("inf") if delta else 0.0
    base_min, _, base_max = _quantiles(base_values)
    cand_min, _, cand_max = _quantiles(cand_values)

    spread = mad(base_values, base_median) + mad(cand_values, cand_median)
    threshold = max(abs_tol, rel_tol * abs(base_median))
    separated = abs(delta) > spread and abs(delta) > threshold

    if abs(delta) <= threshold or not separated:
        direction = "neutral"
    else:
        direction = "delta"

    return {
        "metric": key,
        "baseline_median": base_median,
        "candidate_median": cand_median,
        "delta": delta,
        "rel_delta": None if rel_delta in (float("inf"), float("-inf")) else rel_delta,
        "baseline_min": base_min,
        "baseline_max": base_max,
        "candidate_min": cand_min,
        "candidate_max": cand_max,
        "baseline_spread_mad": mad(base_values, base_median),
        "candidate_spread_mad": mad(cand_values, cand_median),
        "baseline_matches": len(base_values),
        "candidate_matches": len(cand_values),
        "separated": separated,
        "raw_direction": direction,
        "threshold": threshold,
    }


def build_report(base_matches, cand_matches, base_dir, cand_dir,
                 rel_tol=0.05, abs_tol=1e-9, polarity_overrides=None, fail_on=None):
    polarity_overrides = polarity_overrides or {}
    fail_on = fail_on or []
    for key,direction in polarity_overrides.items():
        if key not in METRIC_BY_KEY or direction not in ('higher','lower','none'):
            raise ValueError(f'Invalid metric direction: {key}={direction}')

    rows = []
    if not math.isfinite(rel_tol) or rel_tol < 0 or not math.isfinite(abs_tol) or abs_tol < 0:
        raise ValueError('Tolerances must be finite and nonnegative')
    if any(key not in METRIC_BY_KEY for key in fail_on):
        raise ValueError('Unknown gated metric')
    for spec in METRICS:
        key = spec.key
        base_values = [m["vector"].get(key, 0.0) for m in base_matches]
        cand_values = [m["vector"].get(key, 0.0) for m in cand_matches]
        row = compare_metric(key, base_values, cand_values, rel_tol, abs_tol)
        coverage = all(m.get('coverage', {}).get(key, False) for m in base_matches + cand_matches)
        row['coverage_complete'] = coverage
        if not coverage:
            row.update(baseline_median=None, candidate_median=None, delta=None, rel_delta=None,
                       separated=False, raw_direction='unknown')
        row["label"] = spec.label
        row["group"] = spec.group
        row["help"] = spec.help
        polarity = polarity_overrides.get(key, spec.polarity)
        row["declared_polarity"] = spec.polarity
        row["polarity"] = polarity
        row["polarity_overridden"] = key in polarity_overrides
        if key in fail_on:
            row["gated"] = True
            row["verdict"] = verdict_for(row, polarity)
        else:
            row["gated"] = False
            row["verdict"] = "not_evaluated"
        row["display"] = _display(row, polarity)
        rows.append(row)

    hist_rows = []
    for key, (label, group) in HISTOGRAMS.items():
        base = Counter()
        cand = Counter()
        for m in base_matches:
            base.update(m["histograms"].get(key, {}))
        for m in cand_matches:
            cand.update(m["histograms"].get(key, {}))
        base_total = sum(base.values())
        cand_total = sum(cand.values())
        for category in sorted(set(base) | set(cand)):
            b_count = base.get(category, 0)
            c_count = cand.get(category, 0)
            b_rate = safe_div(b_count, base_total)
            c_rate = safe_div(c_count, cand_total)
            hist_rows.append({
                "histogram": key,
                "label": label,
                "group": group,
                "category": category,
                "baseline_count": b_count,
                "candidate_count": c_count,
                "baseline_share": b_rate,
                "candidate_share": c_rate,
                "share_delta": c_rate - b_rate,
            })

    gated = [r for r in rows if r["gated"]]
    failures = [r for r in gated if r["verdict"] == "fail"]
    warnings = []
    if len(base_matches) != len(cand_matches):
        warnings.append(
            f"UNEQUAL MATCH COUNTS: baseline has {len(base_matches)} match(es), "
            f"candidate has {len(cand_matches)}. Aggregates are per-match medians, "
            f"so the comparison is like-for-like, but the batches are not balanced. "
            f"A batch can also hold more match directories than it has distinct "
            f"scenarios when two runners overlapped and claimed the same slots; "
            f"check the worker/attempt columns before reading a delta as a change "
            f"in behaviour rather than a change in sample.")

    # A batch is not necessarily a clean set of equal-length matches. A run that
    # was killed early, or a second runner that started while the first was still
    # going, produces matches of very different length, and every unnormalized
    # total then differs by sample size rather than by behaviour.
    for side, label in ((base_matches, "baseline"), (cand_matches, "candidate")):
        for cluster in _duration_clusters([m["vector"]["duration_seconds"] for m in side]):
            if len(cluster) < 2 or len(cluster) == len(side):
                continue
            warnings.append(
                f"{label.upper()} DURATION SPLIT: {len(cluster)} of {len(side)} "
                f"matches are in one length band and {len(side) - len(cluster)} in "
                f"another ({', '.join(f'{v:.0f}s' for v in sorted(cluster))} vs "
                f"the rest). Totals that scale with match length (CP spent, CP "
                f"income, order attempts, fleet value, service labour) are "
                f"confounded by duration. Rates are context, not a correction for "
                f"all phase/survivor bias; compare matched windows or actual outcomes.")
    if base_matches and cand_matches:
        base_durations = [m["vector"]["duration_seconds"] for m in base_matches]
        cand_durations = [m["vector"]["duration_seconds"] for m in cand_matches]
        if min(base_durations) > max(cand_durations) or min(cand_durations) > max(base_durations):
            warnings.append(
                f"DISJOINT DURATION RANGES: baseline spans "
                f"{min(base_durations):.0f}-{max(base_durations):.0f}s, candidate "
                f"spans {min(cand_durations):.0f}-{max(cand_durations):.0f}s. "
                f"The two batches did not run the same amount of simulated time, "
                f"so unnormalized totals cannot be compared at all.")
    if not base_matches:
        warnings.append("baseline batch has no telemetry files")
    if not cand_matches:
        warnings.append("candidate batch has no telemetry files")

    truncated = [m for m in base_matches + cand_matches if m["vector"]["truncated_tail"]]
    if truncated:
        warnings.append(
            f"{len(truncated)} match(es) end in a truncated partial line "
            f"(tolerated, counted, and the totals are slightly low): "
            + ", ".join(f"{m['label']}/{m['attempt']}" for m in truncated[:6]))
    malformed = [(m, m["vector"]["malformed_lines"]) for m in base_matches + cand_matches
                 if m["vector"]["malformed_lines"]]
    if malformed and not truncated:
        warnings.append(
            f"{len(malformed)} match(es) contain unparseable lines that are not a "
            f"truncated tail.")

    invalid = not base_matches or not cand_matches or bool(truncated or malformed)
    if gated:
        evidence_issues = comparison_issues(base_matches, cand_matches)
        warnings.extend(evidence_issues)
        if evidence_issues or any(not row['coverage_complete'] for row in gated):
            invalid = True
            warnings.append('Acceptance requires complete selected-metric coverage and matched frozen runs.')
    if any(row['verdict']=='not_evaluated' for row in gated):
        invalid=True
        warnings.append('Selected metrics require an explicit direction; no acceptance decision was made.')
    if gated and (len(base_matches)<2 or len(cand_matches)<2):
        invalid=True
        warnings.append('A one-run comparison cannot estimate variation; acceptance is not evaluated.')
    if invalid:
        overall='insufficient_evidence'
    elif not gated:
        overall='not_evaluated'
    elif failures:
        overall='fail'
    elif any(row['verdict']=='inconclusive' for row in gated):
        overall='inconclusive'
    else:
        overall='pass'

    return {
        "schema": SCHEMA,
        "vector_semantics": "legacy arithmetic; coverage=false means unknown, never observed zero; metric rows use null",
        "tool": "compare_batches",
        "baseline": {
            "dir": str(Path(base_dir).resolve()),
            "matches": len(base_matches),
            "per_match": [
                {"worker": m["worker"], "attempt": m["attempt"], "path": m["path"],
                 "termination": m["termination"],
                 "evidence": m.get('evidence'), "coverage": m.get('coverage'),
                 "global_result": m.get('global_result'), "until": m.get('until'),
                 "engine_result": m["vector"]["engine_result"] == 1.0,
                 "records": m["vector"]["records"],
                 "malformed_lines": m["vector"]["malformed_lines"],
                 "truncated_tail": m["vector"]["truncated_tail"] == 1.0,
                 "duration_seconds": m["vector"]["duration_seconds"],
                 "vector": m["vector"], "histograms": m["histograms"],
                 "events": m["events"], "factions": m["factions"]}
                for m in base_matches],
        },
        "candidate": {
            "dir": str(Path(cand_dir).resolve()),
            "matches": len(cand_matches),
            "per_match": [
                {"worker": m["worker"], "attempt": m["attempt"], "path": m["path"],
                 "termination": m["termination"],
                 "evidence": m.get('evidence'), "coverage": m.get('coverage'),
                 "global_result": m.get('global_result'), "until": m.get('until'),
                 "engine_result": m["vector"]["engine_result"] == 1.0,
                 "records": m["vector"]["records"],
                 "malformed_lines": m["vector"]["malformed_lines"],
                 "truncated_tail": m["vector"]["truncated_tail"] == 1.0,
                 "duration_seconds": m["vector"]["duration_seconds"],
                 "vector": m["vector"], "histograms": m["histograms"],
                 "events": m["events"], "factions": m["factions"]}
                for m in cand_matches],
        },
        "tolerance": {"rel": rel_tol, "abs": abs_tol},
        "metric_rows": rows,
        "histogram_rows": hist_rows,
        "warnings": warnings,
        "verdict": {
            "overall": overall,
            "scope": "selected recorded metrics only; median/MAD heuristic, not statistical gameplay acceptance",
            "gated_metrics": [r["metric"] for r in gated],
            "failures": [{"metric": r["metric"], "verdict": r["verdict"],
                          "baseline_median": r["baseline_median"],
                          "candidate_median": r["candidate_median"],
                          "delta": r["delta"], "polarity": r["polarity"]}
                         for r in failures],
            "gated_inconclusive": [r["metric"] for r in gated
                                   if r["verdict"] == "inconclusive"],
        },
    }


def verdict_for(row, polarity):
    if polarity == "none":
        return "not_evaluated"
    if not row["separated"]:
        return "inconclusive"
    delta = row["delta"]
    if delta == 0:
        return "pass"
    if polarity == "higher":
        return "pass" if delta > 0 else "fail"
    if polarity == "lower":
        return "pass" if delta < 0 else "fail"
    return "pass"


def _display(row, polarity):
    if row['delta'] is None:
        return 'unknown'
    if polarity == "higher":
        return "better" if row["delta"] > 0 else ("worse" if row["delta"] < 0 else "flat")
    if polarity == "lower":
        return "better" if row["delta"] < 0 else ("worse" if row["delta"] > 0 else "flat")
    return "info"


HEADLINE_METRICS = [
    "cp_spent_flow", "cp_spent_events_total", "cp_spent_flow_gap", "cp_spend_rate",
    "cp_spend_ledger", "cp_spend_drift", "cp_flow_cumulative", "cp_upgrade_spend",
    "sentry_spend", "combatants_final", "idle_fraction_mean", "engaged_mean",
    "cap_utilisation_mean", "station_hull_final_frac", "losses_units",
    "order_success_rate", "order_rejected_rate", "decision_switch_rate",
    "build_purchase_rate", "build_insufficient_rate",
    "exec_no_objective_rate", "unengaged_fraction",
]


def fmt(value):
    if value is None:
        return "-"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if abs(value) >= 1000 or (value != 0 and abs(value) < 0.01):
        return f"{value:.3g}"
    if value == int(value) and abs(value) < 1e15:
        return str(int(value))
    return f"{value:.4g}"


def print_report(report, show_per_match=True, show_histograms=True,
                 only_groups=None, quiet=False):
    base = report["baseline"]
    cand = report["candidate"]
    out = []

    out.append("=" * 118)
    out.append(f"compare_batches  baseline: {base['dir']}  ({base['matches']} match(es))")
    out.append(f"                 candidate: {cand['dir']}  ({cand['matches']} match(es))")
    out.append("=" * 118)

    for warning in report["warnings"]:
        out.append("  ! " + warning)
    if report["warnings"]:
        out.append("")

    if not quiet:
        out.append("MATCHES")
        out.append(f"  {'batch':<10} {'worker':<26} {'attempt':<24} {'term':<34} "
                   f"{'records':>9} {'bad':>4} {'sec':>8}")
        for side in (base, cand):
            for m in side["per_match"]:
                out.append(
                    f"  {'base' if side is base else 'cand':<10} {m['worker']:<26} "
                    f"{m['attempt']:<24} {m['termination']:<34} "
                    f"{int(m['records']):>9} {int(m['malformed_lines']):>4} "
                    f"{m['duration_seconds']:>8.1f}")
        out.append("")

    rows = report["metric_rows"]
    if only_groups:
        rows = [r for r in rows if r["group"] in only_groups]

    current_group = None
    header = (f"  {'metric':<26} {'baseline':>12} {'candidate':>12} {'delta':>12} "
              f"{'rel':>8} {'spread':>10} {'dir':<8} {'verdict':<12} metric")
    for row in rows:
        if row["group"] != current_group:
            current_group = row["group"]
            out.append(f"[{current_group}]")
            out.append(header)
        rel = "-" if row["rel_delta"] is None else f"{row['rel_delta']:+.1%}"
        spread = f"{row['baseline_spread_mad'] + row['candidate_spread_mad']:.4g}"
        out.append(
            f"  {row['metric']:<26} {fmt(row['baseline_median']):>12} "
            f"{fmt(row['candidate_median']):>12} {fmt(row['delta']):>12} {rel:>8} "
            f"{spread:>10} {row['display']:<8} {row['verdict']:<12} {row['label']}")
    out.append("")
    out.append("  spread = baseline MAD + candidate MAD. dir/verdict are 'neutral'/"
               "'inconclusive' when the")
    out.append("  median delta is inside that spread, i.e. when a single match could "
               "have produced it.")
    out.append("  polarity column in --list-metrics states the expected direction "
               "for every metric.")
    out.append("")

    if show_per_match:
        out.append("PER-MATCH VALUES (stochastic: one match proves nothing)")
        width = 34
        out.append(f"  {'metric':<26} {'baseline per match':<{width}} "
                   f"{'candidate per match':<{width}}")
        for key in HEADLINE_METRICS:
            base_values = [m["vector"].get(key, 0.0) for m in base["per_match"]]
            cand_values = [m["vector"].get(key, 0.0) for m in cand["per_match"]]
            if not base_values and not cand_values:
                continue
            base_text = " ".join(fmt(v) for v in base_values) or "-"
            cand_text = " ".join(fmt(v) for v in cand_values) or "-"
            out.append(f"  {key:<26} {base_text:<{width}} {cand_text:<{width}}")
        out.append("")

    if show_histograms:
        out.append("HISTOGRAM SHARES (count and share of all events in the histogram)")
        current = None
        for row in report["histogram_rows"]:
            if row["histogram"] != current:
                current = row["histogram"]
                out.append(f"[{row['label']}]")
                out.append(f"  {'category':<32} {'base n':>9} {'base %':>8} "
                           f"{'cand n':>9} {'cand %':>8} {'share delta':>12}")
            out.append(
                f"  {row['category'][:32]:<32} {row['baseline_count']:>9} "
                f"{row['baseline_share']:>7.2%} {row['candidate_count']:>9} "
                f"{row['candidate_share']:>7.2%} {row['share_delta']:>+11.2%}")
        out.append("")

    verdict = report["verdict"]
    out.append("VERDICT")
    out.append(f"  overall: {verdict['overall'].upper()}")
    out.append(f"  scope: {verdict['scope']}")
    if verdict["gated_metrics"]:
        out.append(f"  gated on: {', '.join(verdict['gated_metrics'])}")
    else:
        out.append("  gated on: (nothing; --fail-on not used, this run is report-only)")
    for failure in verdict["failures"]:
        out.append(f"  FAIL {failure['metric']}: {fmt(failure['baseline_median'])} -> "
                   f"{fmt(failure['candidate_median'])} "
                   f"(delta {fmt(failure['delta'])}, expects {failure['polarity']})")
    for metric in verdict["gated_inconclusive"]:
        row = next(r for r in report["metric_rows"] if r["metric"] == metric)
        out.append(f"  INCONCLUSIVE {metric}: per-match spread overlaps across the "
                   f"two batches; needs more matches to call")
    out.append("")
    return "\n".join(out)


def list_metrics():
    out = ["metric                     declared  direction        group       "
           "meaning"]
    for spec in METRICS:
        out.append(f"{spec.key:<26} {spec.polarity:<9} {spec.label:<16} "
                   f"{spec.group:<11} {spec.help}")
    out.append("")
    out.append("Override any direction with --polarity NAME=higher|lower|none.")
    return "\n".join(out)


def parse_polarity(values):
    overrides = {}
    for item in values or []:
        if "=" not in item:
            raise SystemExit(f"compare_batches: --polarity expects NAME=higher|lower|none, "
                             f"got {item!r}")
        name, polarity = item.split("=", 1)
        name = name.strip()
        polarity = polarity.strip()
        if name not in METRIC_BY_KEY:
            raise SystemExit(f"compare_batches: unknown metric {name!r}; "
                             f"use --list-metrics")
        if polarity not in ("higher", "lower", "none"):
            raise SystemExit(f"compare_batches: polarity for {name!r} must be "
                             f"higher, lower or none; got {polarity!r}")
        overrides[name] = polarity
    return overrides


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="compare_batches",
        description="Compare two headless RTS batches and flag AI regressions.")
    parser.add_argument("baseline", nargs="?", help="baseline batch directory")
    parser.add_argument("candidate", nargs="?", help="candidate batch directory")
    parser.add_argument("--json", dest="json_path",
                        help="write the full machine-readable report here")
    parser.add_argument("--fail-on", action="append", default=[], metavar="METRIC",
                        help="gate on this metric; exit 1 when it regresses "
                             "against its declared polarity. Repeatable.")
    parser.add_argument("--polarity", action="append", default=[], metavar="NAME=DIR",
                        help="override a metric's direction: higher, lower or none")
    parser.add_argument("--rel-tol", type=float, default=0.05,
                        help="relative delta below which a metric is called "
                             "neutral (default 0.05)")
    parser.add_argument("--abs-tol", type=float, default=1e-9,
                        help="absolute delta below which a metric is called neutral")
    parser.add_argument('--until', type=float, help='common mission-time cutoff for metric gates')
    parser.add_argument("--list-metrics", action="store_true",
                        help="print every metric, its declared polarity and its meaning")
    parser.add_argument("--no-per-match", action="store_true",
                        help="skip the per-match value table")
    parser.add_argument("--no-histograms", action="store_true",
                        help="skip the histogram share table")
    parser.add_argument("--group", action="append", default=[], metavar="GROUP",
                        help="only show these metric groups (telemetry, economy, "
                             "fleet, losses, orders, build, execution, service, "
                             "operations)")
    parser.add_argument("--quiet", action="store_true",
                        help="print only warnings and the verdict")
    args = parser.parse_args(argv)

    if args.list_metrics:
        print(list_metrics())
        return 0

    if not args.baseline or not args.candidate:
        parser.error("baseline and candidate batch directories are required "
                     "(or use --list-metrics)")

    for name in args.fail_on:
        if name not in METRIC_BY_KEY:
            raise SystemExit(f"compare_batches: unknown metric {name!r} for --fail-on; "
                             f"use --list-metrics to see the names")

    overrides = parse_polarity(args.polarity)
    unspecified=[key for key in args.fail_on if overrides.get(key,METRIC_BY_KEY[key].polarity)=='none']
    if unspecified:
        parser.error('gating requires an explicit direction: '+', '.join(unspecified)+'; use --polarity NAME=higher|lower')

    if args.until is not None and (not math.isfinite(args.until) or args.until <= 0):
        parser.error('--until must be finite and positive')
    base_matches = load_batch(args.baseline, "baseline", until=args.until)
    cand_matches = load_batch(args.candidate, "candidate", until=args.until)

    report = build_report(
        base_matches, cand_matches, args.baseline, args.candidate,
        rel_tol=args.rel_tol, abs_tol=args.abs_tol,
        polarity_overrides=overrides, fail_on=args.fail_on)

    print(print_report(report,
                       show_per_match=not (args.no_per_match or args.quiet),
                       show_histograms=not (args.no_histograms or args.quiet),
                       only_groups=set(args.group) or None,
                       quiet=args.quiet))

    if args.json_path:
        out = Path(args.json_path)
        if out.parent and str(out.parent) not in ("", "."):
            out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2, sort_keys=True,
                                  default=str), encoding="utf-8")
        print(f"wrote {out}")

    verdict=report["verdict"]["overall"]
    return 1 if verdict=='fail' else 2 if verdict in ('insufficient_evidence','inconclusive') else 0


if __name__ == "__main__":
    sys.exit(main())
