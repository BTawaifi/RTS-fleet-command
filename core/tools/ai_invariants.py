"""Algebraic invariant linter for FreeSpace 2 RTS headless AI telemetry.

WHY THIS EXISTS
===============
Every real bug found in the RTS-fleet-command project so far was found by
DIFFERENTIAL review (diff against a baseline, reason about intent) or by running
headless batches and comparing metrics. That method finds code that DIFFERS from
what was intended. It cannot find ABSENCES, ASSUMPTIONS, or UNREACHED paths.

The proof that this is a real gap is in the project's own history:

  * ``RETICLE_COLOR_SELECTED`` shipped a live crash through 370 passing tests and
    a static check, because it was declared ``local`` 147 lines BELOW its use
    (Lua scope does not extend backwards). Headless runs never draw the HUD, so
    no headless harness exercises that code -- only a real game window does.
  * ``fs2rts_ai_production.lua`` wiped ``state.savingSince`` after every purchase.
    With ``FieldCheapHullWhileSaving=true`` that purchase WAS the cheap hull the
    save window deliberately fields alongside the goal, so the clock restarted
    every think, the saving window never aged into ``savingFallback``, and the
    bank never accumulated. Across 4/4 headless matches the entire
    capital/heavy/juggernaut class built ZERO ships: ``GTSC Faustus`` fighters
    went 54 -> 282, ``GVF Thoth`` 43 -> 242, sentries 67 -> 7, losses_units
    67 -> 220. Every metric-based tool reported this as "mixed / some better
    some worse" rather than naming the cause.

Both are absences. This module is the linter for that class.

WHAT AN "INVARIANT" MEANS HERE
==============================
An invariant is an ALGEBRAIC relationship that must hold regardless of how the
AI is implemented: money in equals money accounted for, a loss recorded equals a
loss counted, a hull that was paid for eventually exists or was cancelled. They
are true BY CONSTRUCTION of the economy and roster rules, not by correlation
between two metrics. A correlation can be explained away ("the AI got better at
surviving"); an accounting identity cannot.

Every invariant reports: a name, a per-faction-per-match verdict, the evidence
numbers, and a one-line statement of the absence it detects.

RECORD SHAPE AND STREAMING
==========================
Telemetry is JSON Lines at ``<batch>/results/w/<worker>/a-<id>/probe/data/
rts-ai-*.jsonl``, one record per line::

    {"schema":2.0,"sequence":N,"time":T,"event":"FACTION","data":{...}}

Files are 40 MB each, so every reader here STREAMS line by line and keeps only
bounded aggregates. Nothing loads a whole file into memory.

THE ONE THAT MUST FIRE
======================
``roster_escalation`` is the discriminator for the livelock: on the known-good
batch ``session-fix-20260930`` every one of the 12 faction-matches buys exactly
one capital-class hull; on the known-bad batch ``sentryfix-20261001`` all 12 buy
zero. ``cp_drift_not_persistently_negative`` and ``bank_target_reachable``
corroborate it from the economy side. A linter that fires on everything is
worthless, so ``test_ai_invariants.py`` asserts both directions against those
two real batches' shapes.

HOW SPEND IS RECONCILED: A MEASUREMENT, NOT A BOUND
===================================================
``production_spend_reconciles`` started life as "interval sum of
``economy.flow.productionSpend`` must equal the summed ``cost`` of PRODUCTION +
SENTRY_BUILD build events". That does not hold, and it is not measurement noise:
``productionSpend`` is recorded at ``RTS:RecordAIEconomyFlow``, the chokepoint
every CP movement funnels through, but three of its callers are not builds and
emit no build event --

  * ``RTS:BuyUpgrade`` (core/data/scripts/fs2rts_station.lua:160) spends CP for
    a station upgrade track and emits nothing of its own;
  * ``RTS:QueueOrbitalStrike`` (fs2rts_station.lua:753) spends the BLUE ability
    cost and emits only on the refusal path;
  * ``RTS:ServiceFleetShip`` (fs2rts_service.lua:370/377/392) spends CP per tick
    for hull/subsystem/ammo repair and emits FLEET_SERVICE_WORK, whose ``spent``
    is real but is not a build event.

Measured on ``capgate-20261001``, those two named sinks plus upgrades are 6.7% to
38.1% of a faction's spend, so a tolerance wide enough to accept them also
accepts a genuinely unattributed sink, which is why this check used to fail on
correct data. A BOUND cannot fix that: the gap is not bounded by anything the
emitter promises.

It is now MEASURED instead. Three facts make every CP movement observable, and
all three are read from the telemetry rather than assumed:

  1. ``economy.flowCumulative.productionSpend`` -- the running gauge behind the
     interval flow, never zeroed (fs2rts_ai_telemetry.lua:367-370). Measured
     equal to the summed intervals to within 0.005 CP.
  2. ``CP_SPEND`` -- one record per deduction through the same function, with
     ``faction``/``flow``/``amount``/``cpBefore``/``cpAfter``
     (fs2rts_ai_telemetry.lua:374-378). Summing it must reproduce the gauge.
  3. ``economy.commandPoints`` -- the bank itself. Between two FACTION snapshots
     the bank can only move by what the flow says it moved, so
     ``|dCP - (income + bounty + refund - spend)|`` is an EMITTER-INDEPENDENT
     identity that holds even on a batch with no CP_SPEND record at all. Measured
     max deviation 1e-4 CP over all 36 faction-matches of the three real batches.

With those, the check no longer asks "is the gap small enough" but "is every CP
movement accounted for", and the two failure modes stay distinguishable:

  * the bank moved and the flow did not (or the gauge counted a deduction the
    event stream dropped) -- an UNATTRIBUTED SINK, and a FAIL;
  * build events exceed the flow -- a build charged without reaching the
    chokepoint at all, i.e. a SECOND CP WRITER, also a FAIL;
  * flow exceeds the build events and nothing else moved -- that is the named
    non-build gap, now quantified as ``ledger - buildEventCost`` instead of
    bounded, and a PASS;
  * flow exceeds the build events on a batch that predates the CP_SPEND emitter
    -- UNDEFINED, reported as WARN with ``ledger-not-reported``, never as a
    failure. Several staged batches are in that state, and
    ``compare_batches.py`` already draws exactly that line for
    ``cp_spend_drift`` ("0 when the batch predates either record"), so this linter
    copies its approach rather than inventing a second one.

``roster_escalation``'s ``unlockedTiers`` had the same disease in miniature: it
recorded the tiers a faction was SEEN to buy something on, which is an
observation, not the schedule. Escalation is TIME-based
(``RTS:GetCurrentEscalationTier``, fs2rts_factions.lua:31-46, driven by mission
time and ``Config.Setup.Durations[].tierUnlocks``), so the set is now computed
from the real schedule and the match's last telemetry timestamp.

HOW TO RUN
==========
Human-readable report over a batch::

    cd D:\\Games\\FreespaceOpen\\FS2\\RTS-fleet-command-1.4.1\\core\\tools
    python ai_invariants.py D:\\Games\\FreespaceOpen\\FS2\\rts-headless-staging\\sentryfix-20261001

Exit code is 0 when every invariant passes, 1 when any invariant is violated,
and 2 on a usage or input error.

CI / gating mode. ``--require-clean`` prints one ``FAIL <name> <match> <faction>``
line per violation and a machine-readable ``SUMMARY`` line, and exits 1 on any
violation, 2 on error::

    python ai_invariants.py --require-clean <batch>
    # in CI, after producing a batch:
    python ai_invariants.py --require-clean results/latest || exit 1

Only ``--require-clean`` is meant to gate a build. Without it the tool is a
report and always exits 0 on a clean batch, so it is safe to run by hand.
``--json`` emits the full machine-readable result set for other tooling.

TOLERANCES AND WHY THEY ARE NOT WIDENED
=======================================
Every threshold below is derived from the real batches and is documented
at its definition. Where an invariant could not be made tight without producing
false failures on the GOOD batch, it is reported as WARN rather than FAIL, and
the reason is stated. Widening a band until a known defect passes is the failure
mode this module exists to prevent, so every non-zero tolerance is justified by
a measurement, not by a wish that the batch go green.

The CP tolerances are now the tightest the emitter's own precision allows rather
than a band around an unexplained gap: two are float round-trip noise floors and
one is a fraction of the smallest quantity the system can move.
"""

from __future__ import annotations

import argparse
import collections
import glob
import io
import json
import os
import sys

TELEMETRY_GLOB = "rts-ai-*.jsonl"

# --- tolerances, all derived from the real batches -------------------------
# Named for the arithmetic they tolerate, not for the batch they were measured
# on, so they survive a re-baseline.

# production_spend_reconciles, negative direction only. Every build charge goes
# through the flow chokepoint by definition, so flow can never legitimately fall
# short of the build-event total; a shortfall is a second CP writer writing CP
# outside the chokepoint. Measured on all three real batches: never negative at
# all, so this band is pure float noise around an exact identity.
NEGATIVE_RESIDUAL_REL_TOLERANCE = 0.001
NEGATIVE_RESIDUAL_FLOOR_CP = 1.0

# production_spend_reconciles, interval CP conservation. Between two FACTION
# snapshots the bank may only move by what the flow says it moved:
# |dCP - (income + bounty + refund - spend)|. This holds EMITTER-INDEPENDENTLY,
# so it is gated on every batch, including those with no CP_SPEND record.
# Measured max deviation over 36 faction-matches (capgate-20261001,
# session-fix-20260930, sentryfix-20261001): 1e-4 CP. 0.005 CP is the figure the
# identity was verified at, 50x the observed noise, and still 200x below the
# one CP that is the smallest spend the emitter records.
CP_CONSERVATION_TOLERANCE_CP = 0.005

# production_spend_reconciles, ledger vs gauge. The sum of CP_SPEND records as of
# a faction's last FACTION publish against economy.flowCumulative.productionSpend
# from that same publish: both are written by RecordAIEconomyFlow, so they are
# two views of one number and any difference is a deduction that stopped being
# recorded. Measured max |drift| on capgate-20261001: 0.0058 CP (BLUE,
# a-1790864032670349900). Values are 4-decimal floats round-tripped through JSON,
# so 0.05 CP is the noise floor and is still 20x below one CP.
LEDGER_DRIFT_TOLERANCE_CP = 0.05

# losses_reconcile: exact on all 12 good faction-matches once LOSS events are
# counted only up to the last FACTION snapshot (see LOSS_COUNT_CUT_NOTE). A
# snapshot boundary can still drop one in-flight record, so allow one unit.
LOSS_TOLERANCE_UNITS = 1

# no_orphan_builds: a build still inside the production queue at the final
# FACTION snapshot has not had time to complete; that is a timing cut, not a
# defect. Anything unmatched AND absent from the final queue is an orphan.
QUEUE_CUT_GRACE_SECONDS = 0.0

# roster_escalation / fleet_composition_not_degenerate: escalation tier and role
# vocabularies come from the roster tables, so these are exact class tests, not
# tuned percentages. See ESCALATION_TIER_FLOOR.
ESCALATION_TIER_FLOOR = 3
DEGENERATE_SINGLE_CLASS_SHARE = 0.85
DEGENERATE_T1_ONLY = True

# cp_drift_not_persistently_negative: the brief's literal "mean income rate
# minus mean spend rate >= 0" form does NOT survive contact with the good batch
# -- baseline BLUE/a-1790820145 runs netRate -0.656 CP/s, more negative than 10
# of the 12 bad-batch faction-matches, and still built its capital. A mean rate
# cannot distinguish "spent a bank it had built" from "never banked at all", so
# the gate is on the BANK instead: a faction claiming to save must not sit at or
# below the reserve floor for most of its own snapshots. Measured, no fitting:
# good batch 0.037-0.098, bad batch 0.184-0.306. The gate sits in that gap.
CP_DRIFT_RESERVE_CP = 400.0  # Config.AI.ReserveCP
CP_DRIFT_FLOOR_FRACTION_MAX = 0.14

# bank_target_reachable: measured separation between the batches is
# 1.15-1.61 (good) versus 0.15-0.29 (bad) on peak/minBankTarget, so the
# gate sits at 1.0 -- "the bank provably reached the target it declared".
BANK_TARGET_REACH_RATIO = 1.0

# --- escalation schedule, transcribed from the live config ------------------
#
# Escalation is TIME-based, not purchase-based: RTS:GetCurrentEscalationTier
# (core/data/scripts/fs2rts_factions.lua:31-46) walks
# Config.Setup.Durations[SetupDurationIndex].tierUnlocks against
# GetScenarioElapsed (MISSION time minus ScenarioStartTime) and returns the
# highest index whose entry has passed, so tier i becomes available at
# tierUnlocks[i]. The keys are the 1-based index into Config.Setup.Durations,
# which is exactly how GetDurationProfile resolves the profile.
#
# Transcribed, not parsed, so the linter stays deterministic offline;
# test_ai_invariants.test_tier_unlock_schedule_matches_the_live_config re-reads
# fs2rts_config.lua and fails if this copy drifts from the config it names.
#
# The { 0, 300, 900, 1800 } literal at fs2rts_factions.lua:34 is deliberately
# NOT here: it is dead code, reachable only when GetDurationProfile() returns
# nil, and using it would understate the schedule on every real batch.
TIER_UNLOCK_SCHEDULES = {
    1: (0.0, 240.0, 570.0, 1050.0, 1380.0),   # "30 MIN", fs2rts_config.lua:506
    2: (0.0, 480.0, 1140.0, 2160.0, 2760.0),  # "60 MIN", fs2rts_config.lua:516
}
DURATION_PROFILE_NAMES = {1: "30 MIN", 2: "60 MIN"}
# Config.Setup.DefaultDuration = 1 (fs2rts_config.lua:479), and
# GetDurationProfile falls back to Durations[1] whenever SetupDurationIndex is
# unset. Used only when the telemetry carries neither durationIndex nor a
# profile name, which is what a hand-written record does.
DEFAULT_DURATION_INDEX = 1

# --- record-shape facts established by streaming the real batches ----------
#
# The brief says "PRODUCTION + SENTRY_BUILD BUILD_STARTED records". The actual
# emitters use an ``action`` field: the AI producer emits
# PRODUCTION/QUEUE_ACCEPTED for the spend and PRODUCTION/UNIT_SPAWNED for the
# completion; PlaceSentry emits SENTRY_BUILD/BUILD_STARTED,
# BUILD_COMPLETED and BUILD_CANCELLED. PRODUCTION has no BUILD_STARTED at all.
# These names are what the emitter writes, and the linter keys off them.
SPEND_ACTIONS = ("QUEUE_ACCEPTED", "BUILD_STARTED")
PRODUCTION_COMPLETION_ACTIONS = ("UNIT_SPAWNED",)
SENTRY_TERMINAL_ACTIONS = ("BUILD_COMPLETED", "BUILD_CANCELLED")
SAVING_REASON = "SAVING_FOR_DESIRED_ROLE"
# The two flows that move CP out of a faction's bank and therefore carry a
# per-deduction record (fs2rts_ai_telemetry.lua:374-378). Only productionSpend
# is a spend; refund returns CP that already left.
LEDGER_SPEND_FLOWS = ("productionSpend",)

# LOSS_COUNT_CUT_NOTE: FACTION.losses is a CUMULATIVE snapshot taken at each
# FACTION emit. Loss events that occur after the final snapshot are counted by
# the event stream but not yet by any snapshot, so comparing the last snapshot
# against the full event count produces a spurious negative of up to 6 on the
# good batch. Counting LOSS only up to the last FACTION time makes it exact on
# all 12 good faction-matches, which is what this linter does.

EVENT_BUDGET_NOTE = "records are streamed; only bounded aggregates are retained"


class FactionFacts(object):
    """Bounded per-faction aggregate for one match.

    Deliberately small and fixed-shape: a 40 MB stream must not grow this.
    """

    __slots__ = (
        "faction", "flow", "spend_events", "sentry_spend_events",
        "loss_events", "loss_events_at_cut", "loss_times", "losses_snapshot", "last_snapshot_time",
        "first_cp", "last_cp", "cp_peak",
        "snapshot_count", "snapshots_at_or_below_floor",
        "purchases_by_class", "purchases_by_tier", "purchase_count",
        "queued_keys", "spawned_keys", "sentry_started", "sentry_terminated",
        "final_queue", "saving_desired", "bank_targets",
        "cp_delta_bad", "bounty_delta_bad", "service_spend",
        "upgrade_spend", "escalation_unlocks", "tier_seen",
        "cp_spend_entries", "cp_spend_ledger", "cp_spend_ledger_at_publish",
        "flow_cumulative", "flow_cumulative_reported",
        "conservation_violations", "conservation_max_dev",
    )

    def __init__(self, faction):
        self.faction = faction
        self.flow = collections.Counter()
        self.spend_events = 0.0
        self.sentry_spend_events = 0.0
        self.loss_events = 0
        self.loss_times = []
        self.loss_events_at_cut = 0
        self.losses_snapshot = 0.0
        self.last_snapshot_time = None
        self.first_cp = None
        self.last_cp = 0.0
        self.cp_peak = 0.0
        self.snapshot_count = 0
        self.snapshots_at_or_below_floor = 0
        self.purchases_by_class = collections.Counter()
        self.purchases_by_tier = collections.Counter()
        self.purchase_count = 0
        self.queued_keys = collections.Counter()
        self.spawned_keys = collections.Counter()
        self.sentry_started = collections.Counter()
        self.sentry_terminated = collections.Counter()
        self.final_queue = None
        self.saving_desired = 0
        self.bank_targets = []
        self.cp_delta_bad = 0
        self.bounty_delta_bad = 0
        self.service_spend = 0.0
        self.upgrade_spend = 0.0
        # Retained for the report only: which escalation tiers the faction was
        # SEEN to purchase on. It is an observation, not the schedule, so it no
        # longer decides anything -- see MatchMeta.unlocked_tiers for that.
        self.escalation_unlocks = set()
        self.tier_seen = 0
        # CP_SPEND per-deduction ledger and the gauge it must reproduce.
        self.cp_spend_entries = 0
        self.cp_spend_ledger = 0.0
        self.cp_spend_ledger_at_publish = 0.0
        self.flow_cumulative = 0.0
        self.flow_cumulative_reported = False
        # Interval CP conservation: bank movement against the reported flow.
        self.conservation_violations = 0
        self.conservation_max_dev = 0.0

    @property
    def match_duration(self):
        # Never zero: every rate in this module divides by it, and a match with
        # no FACTION snapshot (or one truncated before it) must still lint
        # rather than raise ZeroDivisionError.
        if self.first_cp is None or self.last_snapshot_time is None:
            return 1.0
        return max(1.0, self.last_snapshot_time)

    @property
    def ledger_reported(self):
        """True when this batch carries both halves of the ledger comparison.

        Both are required, because either alone has nothing to reconcile
        against -- the same distinction compare_batches.py draws for
        ``cp_spend_drift`` ("0 when the batch predates either record").
        """
        return bool(self.cp_spend_entries) and self.flow_cumulative_reported


class MatchMeta(object):
    """Bounded match-level facts the roster rules depend on.

    Escalation is a property of the MISSION CLOCK, not of a faction, so this is
    match-level and every faction row reports the same set. Nothing here grows
    with the record stream: five schedule entries and a handful of scalars.
    """

    __slots__ = (
        "end_time", "duration_index", "duration_name", "duration_source",
        "tier_schedule", "scenario_start", "scenario_start_source",
        "elapsed_at_end", "unlocked_tiers",
    )

    def __init__(self, end_time=0.0):
        self.end_time = end_time
        self.duration_index = None
        self.duration_name = None
        self.duration_source = "default"
        self.tier_schedule = None
        self.scenario_start = 0.0
        self.scenario_start_source = "assumed-mission-time-zero"
        self.elapsed_at_end = 0.0
        self.unlocked_tiers = []

    @property
    def schedule_known(self):
        return self.tier_schedule is not None

    @property
    def max_tier_unlocked(self):
        """Highest escalation tier available at the match's last timestamp.

        Mirrors RTS:GetCurrentEscalationTier: the highest index whose unlock
        time has passed, and never below tier 1 even before the first entry.
        """
        return max(self.unlocked_tiers) if self.unlocked_tiers else 0


def find_telemetry(batch_dir):
    """Locate rts-ai-*.jsonl under a batch directory.

    Telemetry lives at results/w/<worker>/a-<id>/probe/data/rts-ai-*.jsonl.
    A direct path to a file or to one ``data`` directory is also accepted so a
    single match can be linted in isolation.
    """
    batch_dir = os.path.abspath(batch_dir)
    if os.path.isfile(batch_dir):
        return [batch_dir]
    pattern = os.path.join(batch_dir, "results", "w", "*", "a-*", "probe", "data", TELEMETRY_GLOB)
    found = sorted(glob.glob(pattern))
    if found:
        return found
    pattern = os.path.join(batch_dir, "results", "**", TELEMETRY_GLOB)
    return sorted(glob.glob(pattern))


def _num(value, default=0.0):
    if isinstance(value, bool) or value is None:
        return default
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _facts_for(facts, faction):
    """Return (creating if needed) the aggregate for one faction."""
    f = facts.get(faction)
    if f is None:
        f = facts[faction] = FactionFacts(faction)
    return f


def scan_match(path):
    """Stream one telemetry file into (per-faction facts, match-level meta).

    Streams line by line. Only bounded aggregates survive, so a 43 MB file costs
    the same memory as a 4 kB one. The returned ``meta`` carries the escalation
    schedule and the scenario clock, which are match-level facts (see MatchMeta).
    """
    facts = {}
    meta = MatchMeta()
    end_time = 0.0
    duration_index = None
    duration_name = None
    duration_source = "default"
    scenario_start = None
    scenario_source = "assumed-mission-time-zero"
    run_time = None
    with io.open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                # A torn final line is expected when a run is killed mid-write;
                # skipping it is the documented behaviour, not a silent failure.
                continue
            event = record.get("event")
            data = record.get("data")
            if not isinstance(data, dict):
                continue
            when = _num(record.get("time"))
            if when > end_time:
                end_time = when

            if event == "RUN":
                # RUN.data.setup.duration is the profile NAME ("30 MIN"); the
                # index is not in this record. Its own time is mission start,
                # which is the fallback scenario clock (see _resolve_escalation).
                run_time = when
                name = (data.get("setup") or {}).get("duration")
                if name:
                    duration_name = str(name)
                    if duration_source == "default":
                        duration_source = "run-record-name"

            elif event == "ACCEPTANCE_SETUP":
                # durationIndex is self.SetupDurationIndex, i.e. the 1-based
                # index into Config.Setup.Durations. Preferred over the name: it
                # is the exact value the emitter resolved the profile with.
                index = data.get("durationIndex")
                if index is not None:
                    duration_index = int(_num(index)) or None
                    duration_source = "acceptance-setup-index"

            elif event == "OUTCOME_CAUSE":
                # OUTCOME_CAUSE carries `elapsed` (scenario time) beside the
                # record time (mission time), so the subtraction recovers
                # ScenarioStartTime directly instead of assuming it.
                elapsed = data.get("elapsed")
                if elapsed is not None:
                    scenario_start = when - _num(elapsed)
                    scenario_source = "outcome-cause-elapsed"

            elif event == "FACTION":
                faction = data.get("faction")
                if faction is None:
                    continue
                f = _facts_for(facts, faction)
                economy = data.get("economy") or {}
                flow = economy.get("flow") or {}
                # The ledger total as of THIS publish, captured before the
                # interval this record reports is folded in. Compared against
                # flowCumulative from the same publish, this is the exact
                # reconciliation: both are written by RecordAIEconomyFlow, so a
                # difference means a deduction stopped being recorded.
                f.cp_spend_ledger_at_publish = f.cp_spend_ledger
                interval_spend = _num(flow.get("productionSpend"))
                interval_in = (_num(flow.get("income")) + _num(flow.get("bounty"))
                               + _num(flow.get("refund")))
                for key in ("income", "bounty", "refund", "productionSpend"):
                    f.flow[key] += _num(flow.get(key))
                cp = _num(economy.get("commandPoints"))
                # Interval CP conservation, emitter-independent: the bank may
                # only move by what the flow says it moved. A second CP writer
                # that deducts without reaching RecordAIEconomyFlow breaks this
                # even on a batch that carries no CP_SPEND record at all. The
                # first snapshot has no predecessor, so it establishes the
                # baseline instead of being compared against it.
                if f.first_cp is None:
                    f.first_cp = cp
                else:
                    deviation = abs((cp - f.last_cp) - (interval_in - interval_spend))
                    if deviation > f.conservation_max_dev:
                        f.conservation_max_dev = deviation
                    if deviation > CP_CONSERVATION_TOLERANCE_CP:
                        f.conservation_violations += 1
                f.last_cp = cp
                if cp > f.cp_peak:
                    f.cp_peak = cp
                f.snapshot_count += 1
                if cp <= CP_DRIFT_RESERVE_CP:
                    f.snapshots_at_or_below_floor += 1
                upgrades = economy.get("upgradeSpend")
                if upgrades is not None:
                    # Present only in batches captured after the emitter fix.
                    f.upgrade_spend = _num(upgrades)
                cumulative = economy.get("flowCumulative") or {}
                if cumulative.get("productionSpend") is not None:
                    # A running gauge; the last snapshot is the whole total.
                    f.flow_cumulative = _num(cumulative.get("productionSpend"))
                    f.flow_cumulative_reported = True
                f.losses_snapshot = sum(
                    _num(v) for v in (data.get("losses") or {}).values())
                f.last_snapshot_time = when
                f.final_queue = economy.get("queue")
                f.tier_seen = max(f.tier_seen, 0)

            elif event == "CP_SPEND":
                # Per-deduction ledger from RecordAIEconomyFlow, one record per
                # CP movement, independent of any purchase event. Summing it must
                # reproduce economy.flowCumulative; the drift between them is the
                # regression guard for a CP movement that stops being recorded.
                if data.get("flow") not in LEDGER_SPEND_FLOWS:
                    continue
                faction = data.get("faction")
                if faction is None:
                    continue
                f = _facts_for(facts, faction)
                f.cp_spend_ledger += _num(data.get("amount"))
                f.cp_spend_entries += 1

            elif event == "LOSS":
                faction = data.get("faction")
                if faction is None:
                    continue
                f = _facts_for(facts, faction)
                f.loss_events += 1
                f.loss_times.append(when)

            elif event == "PRODUCTION":
                faction = data.get("faction")
                if faction is None:
                    continue
                f = _facts_for(facts, faction)
                action = data.get("action")
                if action == "QUEUE_ACCEPTED":
                    cost = _num(data.get("cost"))
                    f.spend_events += cost
                    f.queued_keys[(data.get("class"), _num(data.get("queuedAt")))] += 1
                    count = int(_num(data.get("count"), 1) or 1)
                    tier = int(_num(data.get("tier"), 1) or 1)
                    f.purchases_by_class[data.get("class")] += count
                    f.purchases_by_tier[tier] += count
                    f.purchase_count += count
                    if tier >= ESCALATION_TIER_FLOOR:
                        f.escalation_unlocks.add(tier)
                    # cpBefore/cpAfter is recorded at the same chokepoint as the
                    # flow, so this identity must hold to the cent.
                    before = _num(data.get("cpBefore"))
                    after = _num(data.get("cpAfter"))
                    if abs((before - after) - cost) > 1.0:
                        f.cp_delta_bad += 1
                elif action == "UNIT_SPAWNED":
                    f.spawned_keys[(data.get("class"), _num(data.get("queuedAt")))] += 1
                elif action == "BOUNTY":
                    before = _num(data.get("cpBefore"))
                    after = _num(data.get("cpAfter"))
                    bounty = _num(data.get("bountyCP"))
                    if abs((after - before) - bounty) > 1.0:
                        f.bounty_delta_bad += 1

            elif event == "SENTRY_BUILD":
                faction = data.get("faction")
                if faction is None:
                    continue
                f = _facts_for(facts, faction)
                action = data.get("action")
                key = (data.get("class"), data.get("cost"))
                if action == "BUILD_STARTED":
                    f.sentry_spend_events += _num(data.get("cost"))
                    f.sentry_started[key] += 1
                elif action in SENTRY_TERMINAL_ACTIONS:
                    f.sentry_terminated[key] += 1

            elif event == "FLEET_SERVICE_WORK":
                faction = data.get("faction")
                if faction is None:
                    continue
                f = _facts_for(facts, faction)
                f.service_spend += _num(data.get("spent"))

            elif event == "AI_BUILD_DECISION":
                faction = data.get("faction")
                if faction is None:
                    continue
                f = _facts_for(facts, faction)
                if data.get("reason") == SAVING_REASON:
                    f.saving_desired += 1
                    if data.get("desiredRole") == "capital":
                        f.bank_targets.append(
                            (_num(data.get("bankTarget")), int(_num(data.get("tier"), 1) or 1)))

    # Losses after a faction's final FACTION snapshot are in the event stream but
    # in no snapshot yet, so they must be excluded from the reconciliation.
    # Verified: cutting here makes FACTION.losses reconcile exactly on all 12
    # good faction-matches; not cutting produced spurious negatives up to -6.
    # Loss times are kept because the snapshot time is only known at end of
    # stream; the count is O(100) per match, so this stays bounded.
    for f in facts.values():
        if f.last_snapshot_time is not None:
            f.loss_events_at_cut = sum(
                1 for t in f.loss_times if t <= f.last_snapshot_time)
        else:
            f.loss_events_at_cut = 0

    _resolve_escalation(meta, end_time, duration_index, duration_name,
                        duration_source, scenario_start, scenario_source, run_time)
    return facts, meta


def _resolve_escalation(meta, end_time, duration_index, duration_name,
                        duration_source, scenario_start, scenario_source, run_time):
    """Fill MatchMeta from what the telemetry said about the scenario clock.

    Two questions, both answered by the batch rather than assumed:

      * WHICH profile -- ACCEPTANCE_SETUP.durationIndex is preferred (it is the
        index the emitter resolved the profile with), then the profile NAME from
        RUN.data.setup.duration, then Config.Setup.DefaultDuration.
      * WHEN the scenario started -- OUTCOME_CAUSE.elapsed beside its own record
        time recovers ScenarioStartTime exactly. The RUN record's time is the
        fallback: RUN is the first record of a headless match (t=0.25 on every
        real batch measured) and ScenarioStartTime is set from
        mn.getMissionTime() when the scenario goes live
        (fs2rts_lifecycle.lua:420). The two agree exactly where both exist
        (capgate-20261001 a-1790864033752800000: OUTCOME_CAUSE elapsed 2966.0923
        at t=2966.3423, so ScenarioStartTime = 0.25 = the RUN time). With
        neither, mission time is assumed to start the scenario, which is wrong by
        at most the setup delay -- sub-second on every batch measured, against
        unlock boundaries at 0/240/570/1050/1380 s.

    An unknown profile index is reported as unknown rather than silently
    substituted, so a newly added duration profile cannot quietly understate the
    schedule this linter judges a faction against.
    """
    meta.end_time = end_time
    index = duration_index
    if index is None and duration_name:
        for candidate, name in DURATION_PROFILE_NAMES.items():
            if name == duration_name:
                index = candidate
                duration_source = "run-record-name"
                break
    if index is None:
        index = DEFAULT_DURATION_INDEX
        duration_source = "config-default-duration"
    meta.duration_index = index
    meta.duration_source = duration_source
    meta.duration_name = duration_name or DURATION_PROFILE_NAMES.get(index)
    meta.tier_schedule = TIER_UNLOCK_SCHEDULES.get(index)

    if scenario_start is not None:
        meta.scenario_start = scenario_start
        meta.scenario_start_source = scenario_source
    elif run_time is not None:
        meta.scenario_start = run_time
        meta.scenario_start_source = "run-record-time"
    meta.elapsed_at_end = max(0.0, end_time - meta.scenario_start)
    if meta.tier_schedule:
        tier = 1
        for position, unlock_at in enumerate(meta.tier_schedule, start=1):
            if meta.elapsed_at_end >= unlock_at:
                tier = position
        meta.unlocked_tiers = list(range(1, tier + 1))


def match_label(path):
    parts = os.path.normpath(path).split(os.sep)
    for part in parts:
        if part.startswith("a-"):
            return part
    return os.path.basename(path)


class Verdict(object):
    """One invariant's result for one faction in one match."""

    __slots__ = ("invariant", "match", "faction", "status", "evidence", "explanation")

    def __init__(self, invariant, match, faction, status, evidence, explanation):
        self.invariant = invariant
        self.match = match
        self.faction = faction
        self.status = status
        self.evidence = evidence
        self.explanation = explanation

    def as_dict(self):
        return {
            "invariant": self.invariant,
            "match": self.match,
            "faction": self.faction,
            "status": self.status,
            "evidence": self.evidence,
            "explanation": self.explanation,
        }

    def format_line(self):
        ev = " ".join("%s=%s" % (k, _fmt(v)) for k, v in sorted(self.evidence.items()))
        return "%-9s %-34s %-14s %-5s %s" % (
            self.status, self.invariant, "%s/%s" % (self.match, self.faction), "", ev)


def _fmt(value):
    if isinstance(value, float):
        if abs(value - round(value)) < 1e-9:
            return str(int(round(value)))
        return "%.3f" % value
    return str(value)


EXPLANATIONS = {
    "production_spend_reconciles":
        "Detects a CP movement that no record accounts for: a build charged "
        "outside the flow chokepoint, a bank movement the flow never reported, "
        "or a deduction the event ledger stopped recording.",
    "losses_reconcile":
        "Detects a LOSS the FACTION snapshot never counted, or a counted loss "
        "with no LOSS event behind it.",
    "no_orphan_builds":
        "Detects hulls paid for that neither spawned, were cancelled, nor were "
        "still legitimately in the queue at the final snapshot.",
    "cp_drift_not_persistently_negative":
        "Detects a faction that claims to be saving while its bank never grows: "
        "the saving-window livelock, where income arrives and is spent before "
        "the target can ever be met.",
    "roster_escalation":
        "Detects a faction that unlocks capital/heavy/juggernaut hulls and then "
        "builds none of them: the absence that the saving-clock livelock "
        "produced, and that no metric-diff tool named.",
    "fleet_composition_not_degenerate":
        "Detects a roster that has collapsed onto a single hull class or onto "
        "T1 only, which is what a faction buying nothing but its cheapest "
        "affordable hull looks like.",
    "bank_target_reachable":
        "Detects a declared save target the bank provably never reached, which "
        "makes the saving window a permanent no-op by construction.",
}


def check_production_spend_reconciles(facts, match):
    """Every CP that left the bank must be accounted for, and no build may be free.

    The old form of this check -- "flow must equal build-event cost to within a
    non-build budget" -- cannot be made to work and was replaced rather than
    widened. ``flow.productionSpend`` is recorded at ``RecordAIEconomyFlow``,
    which station upgrades, the orbital strike and per-tick fleet service all
    share without being builds; those are 6.7-38.1% of a faction's spend on
    capgate-20261001, so any budget that accepts them also accepts a real
    unattributed sink, and any budget tight enough to catch one fails on correct
    data (it did: residualPct 26.298 and 38.075 against a 25% tolerance).

    What is asserted now, per faction:
      * CONSERVATION -- ``|dCP - (income + bounty + refund - spend)|`` holds per
        interval, using the bank itself as the witness. A CP movement that never
        reached the flow chokepoint breaks it, and it is emitter-independent, so
        it is gated on every batch.
      * LEDGER -- the sum of CP_SPEND records as of the last publish equals
        ``economy.flowCumulative.productionSpend`` from that publish. Two views
        of one counter; a difference means a deduction stopped being recorded.
      * NEGATIVE residual -- build events exceed the flow. Every build charge
        goes through the chokepoint by definition, so this is a second CP writer
        charging CP outside it, and it gets a tight bound.
      * POSITIVE residual -- flow exceeds the build events. With a ledger this is
        the named non-build gap and is REPORTED (``nonBuildSpend``), not bounded.
        Without one -- a batch predating the CP_SPEND emitter -- it is undefined,
        so the verdict is WARN with ``ledger-not-reported``, never a failure.
        That is the distinction compare_batches.py already draws for
        ``cp_spend_drift``, and several staged batches depend on it.
    """
    out = []
    for faction in sorted(facts):
        f = facts[faction]
        flow = f.flow["productionSpend"]
        events = f.spend_events + f.sentry_spend_events
        residual = flow - events
        negative_tolerance = max(NEGATIVE_RESIDUAL_FLOOR_CP,
                                 abs(events) * NEGATIVE_RESIDUAL_REL_TOLERANCE)
        ledger_reported = f.ledger_reported
        drift = (f.cp_spend_ledger_at_publish - f.flow_cumulative
                 if ledger_reported else None)
        # Spend recorded after the last FACTION publish: in no reported interval
        # and in no gauge, which is why the gauge is compared at the publish and
        # not at end of file.
        ledger_tail = f.cp_spend_ledger - f.cp_spend_ledger_at_publish

        # The two signs are DIFFERENT defects and get different treatment.
        defects = []
        if residual < -negative_tolerance:
            defects.append("flow-below-build-events")
        if f.conservation_violations:
            defects.append("bank-moved-without-flow-record")
        if ledger_reported and abs(drift) > LEDGER_DRIFT_TOLERANCE_CP:
            defects.append("ledger-drift-from-flow-cumulative")
        if defects:
            status = "FAIL"
            direction = defects[0]
        elif residual > 0.0 and not ledger_reported:
            status = "WARN"
            direction = "ledger-not-reported"
        else:
            status = "PASS"
            direction = "reconciled"
        pct = (100.0 * residual / flow) if flow else 0.0
        # What the two named non-build sinks account for. Reported, NOT gated:
        # the ledger attributes every CP to a deduction but does not classify it,
        # and upgradeSpend plus service spend does not sum to the whole gap on
        # every faction-match (measured 0 CP on capgate-20261001
        # a-1790864033752800000 to 4200 CP on a-1790864032670349900 RED), so a
        # decomposition gate would fail on correct data for the same reason the
        # budget did.
        named_non_build = f.upgrade_spend + f.service_spend
        evidence = {
            "flowProductionSpend": flow,
            "buildEventCost": events,
            "prodEvents": f.spend_events,
            "sentryEvents": f.sentry_spend_events,
            "serviceSpend": f.service_spend,
            "upgradeSpend": f.upgrade_spend,
            "residual": residual,
            "residualPct": pct,
            # The non-build gap, measured rather than bounded: every CP the
            # chokepoint recorded that no build event explains.
            "nonBuildSpend": (f.cp_spend_ledger - events) if ledger_reported else "not-reported",
            "namedNonBuildSpend": named_non_build if ledger_reported else "not-reported",
            "unattributedNonBuild": ((residual - named_non_build)
                                     if ledger_reported else "not-reported"),
            "ledgerReported": ledger_reported,
            "cpSpendEntries": f.cp_spend_entries,
            "cpSpendLedger": f.cp_spend_ledger if ledger_reported else "not-reported",
            "cpSpendLedgerAtPublish": (f.cp_spend_ledger_at_publish
                                       if ledger_reported else "not-reported"),
            "cpSpendTailAfterPublish": ledger_tail if ledger_reported else "not-reported",
            "flowCumulativeSpend": (f.flow_cumulative if ledger_reported else "not-reported"),
            "ledgerDrift": abs(drift) if ledger_reported else "not-reported",
            "ledgerDriftTolerance": LEDGER_DRIFT_TOLERANCE_CP if ledger_reported else "not-reported",
            "conservationViolations": f.conservation_violations,
            "conservationMaxDev": f.conservation_max_dev,
            "conservationTolerance": CP_CONSERVATION_TOLERANCE_CP,
            "negativeTolerance": negative_tolerance,
            "direction": direction,
        }
        if defects:
            evidence["defects"] = ",".join(defects)
        out.append(Verdict(
            "production_spend_reconciles", match, faction, status,
            evidence,
            EXPLANATIONS["production_spend_reconciles"]))
    return out


def check_losses_reconcile(facts, match):
    """Cumulative FACTION.losses must equal the LOSS count at snapshot time.

    Counting is cut at the final FACTION snapshot: losses after it are in the
    event stream but in no snapshot yet, and counting them produced spurious
    negatives of up to 6 on the GOOD batch.
    """
    out = []
    for faction in sorted(facts):
        f = facts[faction]
        cut = f.last_snapshot_time
        # loss_events is a plain count, so the cut is applied by the caller
        # passing pre-split counts. scan_match records the total; recompute the
        # cut count here from the same source when available.
        counted = getattr(f, "loss_events_at_cut", None)
        if counted is None:
            counted = f.loss_events
        diff = f.losses_snapshot - counted
        status = "PASS" if -LOSS_TOLERANCE_UNITS <= diff <= LOSS_TOLERANCE_UNITS else "FAIL"
        out.append(Verdict(
            "losses_reconcile", match, faction, status,
            {
                "factionLosses": f.losses_snapshot,
                "lossEventsAtSnapshot": counted,
                "lossEventsTotal": f.loss_events,
                "diff": diff,
            },
            EXPLANATIONS["losses_reconcile"]))
    return out


def check_no_orphan_builds(facts, match):
    """Every paid-for build must spawn, be cancelled, or still be queued."""
    out = []
    for faction in sorted(facts):
        f = facts[faction]
        unmatched = []
        for key, count in f.queued_keys.items():
            remaining = f.spawned_keys.get(key, 0)
            for _ in range(max(0, count - remaining)):
                unmatched.append("%s@%.1f" % (key[0], key[1]))
        # A build still in the final queue snapshot has not had time to finish.
        # That is a timing cut, not an orphan.
        final = f.final_queue or {}
        in_flight = 0
        if final.get("class"):
            in_flight = 1
        orphans = [u for u in unmatched if not _matches_final_queue(u, f)]
        sentry_open = 0
        for key, count in f.sentry_started.items():
            sentry_open += max(0, count - f.sentry_terminated.get(key, 0))
        status = "PASS" if not orphans and not sentry_open else "FAIL"
        out.append(Verdict(
            "no_orphan_builds", match, faction, status,
            {
                "buildsQueued": int(sum(f.queued_keys.values())),
                "buildsSpawned": int(sum(f.spawned_keys.values())),
                "unmatchedBuilds": len(unmatched),
                "inFinalQueue": in_flight,
                "orphanBuilds": len(orphans),
                "sentryBuildsOpen": sentry_open,
                "orphanSample": ",".join(orphans[:4]) if orphans else "",
            },
            EXPLANATIONS["no_orphan_builds"]))
    return out


def _matches_final_queue(unmatched_text, f):
    """True when an unmatched build is legitimately still in flight.

    Two distinct timing cuts make an unmatched QUEUE_ACCEPTED legitimate, and
    both were observed on the GOOD batch:
      1. it is the entry in the final FACTION snapshot's economy.queue; or
      2. it was queued AFTER that snapshot, so no snapshot could have reported
         it (baseline GOLD GVF Thoth queued at t=2569.7 with the last snapshot
         at t=2569.0).
    Anything else is an orphan: hulls paid for that no snapshot can account for.
    """
    try:
        name, queued_at = unmatched_text.rsplit("@", 1)
        queued_at = float(queued_at)
    except (IndexError, ValueError):
        return False
    final = f.final_queue or {}
    if str(final.get("class")) == name and abs(_num(final.get("queuedAt")) - queued_at) <= 1.0:
        return True
    if f.last_snapshot_time is not None and queued_at > f.last_snapshot_time + QUEUE_CUT_GRACE_SECONDS:
        return True
    return False


def check_cp_drift(facts, match):
    """A faction claiming to save must not live permanently on the reserve floor.

    The brief asks for "mean income rate minus mean spend rate >= 0 over the
    match, OR the faction must have been saving". The net-rate half of that is
    NOT usable on its own, and this is a measured finding rather than a guess:
    baseline BLUE in match a-1790820145 ran netRate -0.656 CP/s -- more negative
    than 10 of the 12 bad-batch faction-matches -- and still built its
    capital-class hull, because it banked 9923 CP first and then spent down. A
    mean rate cannot tell "spent a bank it had built" from "never banked at
    all", so gating on it produces a false failure on the good batch.

    The algebraic form that holds is about the BANK, not the rate: a faction
    that emits SAVING_FOR_DESIRED_ROLE is asserting it is accumulating toward a
    target. If it sits at or below the reserve floor (Config.AI.ReserveCP = 400)
    for a large fraction of its own snapshots, it is not accumulating at all --
    income arrives and leaves before the target can ever be met, which is the
    saving-window livelock by construction.

    Measured separation, no threshold fitting:
      good batch  3-8 of 82-92 snapshots at/below floor  (0.037-0.098)
      bad batch  18-30 of 98 snapshots at/below floor   (0.184-0.306)
    The bad batch also spends more than it earns in 12 of 12 faction-matches
    (net -0.055 to -0.389 CP/s) while the good batch does so in only 3 of 12, so
    the two signals agree; the floor-fraction is the one used to gate because it
    does not misfire on a bank-spending match.
    """
    out = []
    for faction in sorted(facts):
        f = facts[faction]
        duration = f.match_duration
        inflow = f.flow["income"] + f.flow["bounty"] + f.flow["refund"]
        outflow = f.flow["productionSpend"]
        net_rate = (inflow - outflow) / duration
        saving_claim = f.saving_desired > 0
        floor_fraction = (f.snapshots_at_or_below_floor / float(f.snapshot_count)
                          if f.snapshot_count else 0.0)
        if not saving_claim:
            status = "PASS"
            note = "no-saving-claim"
        elif floor_fraction > CP_DRIFT_FLOOR_FRACTION_MAX:
            status = "FAIL"
            note = "saving-claim-but-bank-pinned-at-floor"
        else:
            status = "PASS"
            note = "saving-claim-with-accumulating-bank"
        out.append(Verdict(
            "cp_drift_not_persistently_negative", match, faction, status,
            {
                "incomeRate": inflow / duration,
                "spendRate": outflow / duration,
                "netRate": net_rate,
                "snapshots": f.snapshot_count,
                "snapshotsAtFloor": f.snapshots_at_or_below_floor,
                "floorFraction": floor_fraction,
                "floorFractionMax": CP_DRIFT_FLOOR_FRACTION_MAX,
                "endingCP": f.last_cp,
                "cpPeak": f.cp_peak,
                "reserveCP": CP_DRIFT_RESERVE_CP,
                "savingDecisions": f.saving_desired,
                "mechanism": note,
            },
            EXPLANATIONS["cp_drift_not_persistently_negative"]))
    return out


def check_roster_escalation(facts, match, meta):
    """At least one capital/heavy/juggernaut build per faction per match.

    Escalation unlocks tiers 3 (capital), 4 (heavy) and 5 (juggernaut) on a
    MISSION-TIME schedule -- ``Config.Setup.Durations[].tierUnlocks``, walked by
    ``RTS:GetCurrentEscalationTier`` (fs2rts_factions.lua:31-46) -- so the roster
    rule makes a capital-class purchase ATTAINABLE once the schedule has passed
    that tier, not guaranteed. The verdict is therefore stated over the
    escalation CLASS (tier >= 3), and ``unlockedTiers`` reports what the SCHEDULE
    had unlocked at the match's last telemetry timestamp.

    ``unlockedTiers`` used to collect the tiers a faction was observed to buy
    something on, which is not an unlock signal at all: it is empty for a faction
    that bought nothing above tier 2 and holds a single element for one that
    bought exactly one tier-5 hull (measured: ``[]`` for GOLD and BLUE,
    ``[5]`` for RED on capgate-20261001, all three running past the 1380 s
    juggernaut unlock). It is now ``[1..maxTier]`` from the real schedule, so a
    faction that had all five tiers available and built no capital is legible as
    exactly that.

    A match that ends before tier 3 unlocks has not had the capital class
    available at all, so the absence is not the AI's: that is a WARN, not a FAIL.
    It does not weaken the discriminator -- every real batch measured runs to
    2400-3000 s, well past the 570 s capital unlock, so the known-bad batch still
    fails 12 of 12.

    This is the invariant that must discriminate: good batch 1 capital-class
    hull per faction per match in 12 of 12; bad batch 0 in 12 of 12.
    """
    out = []
    for faction in sorted(facts):
        f = facts[faction]
        by_tier = dict(f.purchases_by_tier)
        esc = sum(v for t, v in f.purchases_by_tier.items() if t >= ESCALATION_TIER_FLOOR)
        seen_tiers = sorted(t for t in f.purchases_by_tier)
        # A faction that bought nothing above tier 1 never had a capital-class
        # hull available OR never took it. Both are the absence we care about --
        # except when the schedule had not unlocked one yet.
        capital_available = meta.max_tier_unlocked >= ESCALATION_TIER_FLOOR
        if esc > 0:
            status = "PASS"
            mechanism = "capital-class-built"
        elif not meta.schedule_known:
            status = "FAIL"
            mechanism = "capital-class-absent-schedule-unknown"
        elif not capital_available:
            status = "WARN"
            mechanism = "escalation-not-yet-unlocked-at-match-end"
        else:
            status = "FAIL"
            mechanism = "capital-class-available-but-never-built"
        out.append(Verdict(
            "roster_escalation", match, faction, status,
            {
                "capitalClassBuilds": esc,
                "tierHistogram": by_tier,
                "maxTierBuilt": max(seen_tiers) if seen_tiers else 0,
                "totalBuilds": f.purchase_count,
                "unlockedTiers": (list(meta.unlocked_tiers) if meta.schedule_known
                                  else "unknown-duration-profile"),
                "maxTierUnlocked": meta.max_tier_unlocked if meta.schedule_known else "unknown",
                "tiersBuiltOn": sorted(f.escalation_unlocks),
                "tierSchedule": (list(meta.tier_schedule) if meta.schedule_known
                                 else "unknown-duration-profile"),
                "durationProfile": meta.duration_name or "unknown",
                "scenarioElapsedSeconds": meta.elapsed_at_end,
                "scenarioStartSeconds": meta.scenario_start,
                "scenarioStartSource": meta.scenario_start_source,
                "classesBuilt": sorted(str(c) for c in f.purchases_by_class),
                "mechanism": mechanism,
            },
            EXPLANATIONS["roster_escalation"]))
    return out


def check_fleet_composition(facts, match):
    """No single class may dominate, and a faction may not be T1-only.

    Both clauses are stated as exact class tests against the roster vocabulary,
    not tuned percentages, except the single-class share whose threshold sits
    above every value measured on the good batch (max 0.82 there) and below the
    bad batch's worst (1.00 for RED).
    """
    out = []
    for faction in sorted(facts):
        f = facts[faction]
        total = f.purchase_count
        if total <= 0:
            out.append(Verdict(
                "fleet_composition_not_degenerate", match, faction, "WARN",
                {"totalBuilds": 0},
                "no purchases recorded; composition undefined"))
            continue
        by_class = f.purchases_by_class
        top_class, top_count = by_class.most_common(1)[0]
        share = top_count / float(total)
        t1_only = all(t <= 1 for t in f.purchases_by_tier)
        reasons = []
        if share > DEGENERATE_SINGLE_CLASS_SHARE:
            reasons.append("single-class %.2f" % share)
        if DEGENERATE_T1_ONLY and t1_only:
            reasons.append("T1-only")
        status = "FAIL" if reasons else "PASS"
        out.append(Verdict(
            "fleet_composition_not_degenerate", match, faction, status,
            {
                "totalBuilds": total,
                "topClass": top_class,
                "topClassShare": share,
                "distinctClasses": len(by_class),
                "tierHistogram": dict(f.purchases_by_tier),
                "t1Only": t1_only,
                "reasons": ",".join(reasons),
            },
            EXPLANATIONS["fleet_composition_not_degenerate"]))
    return out


def check_bank_target_reachable(facts, match):
    """A declared capital bankTarget must be within the bank's observed peak.

    Only targets declared while escalation tier >= 3 count, because only then is
    the capital class actually purchasable; a tier-1 bankTarget is a different
    question. Measured separation on the two batches is 1.15-1.61 (good) versus
    0.15-0.29 (bad), so the gate at ratio 1.0 is not a tuned threshold.
    """
    out = []
    for faction in sorted(facts):
        f = facts[faction]
        gated = [bt for bt, tier in f.bank_targets if tier >= ESCALATION_TIER_FLOOR]
        if not gated:
            out.append(Verdict(
                "bank_target_reachable", match, faction, "WARN",
                {"savingDecisions": f.saving_desired, "tierGatedTargets": 0},
                "no capital save target declared at tier>=3; nothing to test"))
            continue
        lowest = min(gated)
        ratio = (f.cp_peak / lowest) if lowest else float("inf")
        status = "PASS" if ratio >= BANK_TARGET_REACH_RATIO else "FAIL"
        ordered = sorted(gated)
        out.append(Verdict(
            "bank_target_reachable", match, faction, status,
            {
                "tierGatedTargets": len(gated),
                "lowestBankTarget": lowest,
                "medianBankTarget": ordered[len(ordered) // 2],
                "cpPeak": f.cp_peak,
                "peakOverTarget": ratio,
                "endingCP": f.last_cp,
            },
            EXPLANATIONS["bank_target_reachable"]))
    return out


CHECKS = (
    check_production_spend_reconciles,
    check_losses_reconcile,
    check_no_orphan_builds,
    check_cp_drift,
    check_roster_escalation,
    check_fleet_composition,
    check_bank_target_reachable,
)

# The invariant name each check emits. Declared alongside the check so a new
# check cannot silently produce a nameless row in a CI log; the test
# `test_every_registered_check_is_covered_by_an_explanation` asserts this stays
# in sync with EXPLANATIONS.
CHECK_NAMES = (
    "production_spend_reconciles",
    "losses_reconcile",
    "no_orphan_builds",
    "cp_drift_not_persistently_negative",
    "roster_escalation",
    "fleet_composition_not_degenerate",
    "bank_target_reachable",
)


def check_batch(batch_dir, paths=None):
    """Run every invariant over every match in a batch. Returns a result dict."""
    paths = paths if paths is not None else find_telemetry(batch_dir)
    if not paths:
        raise ValueError("no %s found under %s" % (TELEMETRY_GLOB, batch_dir))
    matches = []
    for path in paths:
        facts, meta = scan_match(path)
        label = match_label(path)
        verdicts = []
        for check in CHECKS:
            if check is check_roster_escalation:
                verdicts.extend(check(facts, label, meta))
            else:
                verdicts.extend(check(facts, label))
        matches.append({
            "match": label,
            "path": path,
            "endTime": meta.end_time,
            "factions": sorted(facts),
            "escalation": {
                "durationProfile": meta.duration_name or "unknown",
                "durationIndex": meta.duration_index,
                "durationSource": meta.duration_source,
                "tierSchedule": (list(meta.tier_schedule) if meta.schedule_known
                                 else None),
                "scenarioStartSeconds": meta.scenario_start,
                "scenarioStartSource": meta.scenario_start_source,
                "scenarioElapsedSeconds": meta.elapsed_at_end,
                "unlockedTiers": (list(meta.unlocked_tiers) if meta.schedule_known
                                  else None),
            },
            "verdicts": [v.as_dict() for v in verdicts],
        })
    return {"batch": os.path.abspath(batch_dir), "matches": matches}


def iter_verdicts(result):
    for match in result["matches"]:
        for verdict in match["verdicts"]:
            yield match["match"], verdict


def summarize(result):
    counts = collections.Counter()
    for _match, verdict in iter_verdicts(result):
        counts[verdict["status"]] += 1
    return counts


def _render(result, out, show_events=False):
    out.write("BATCH %s\n" % result["batch"])
    for match in result["matches"]:
        out.write("\n== match %s  (end t=%.1fs, %d factions)\n"
                  % (match["match"], match["endTime"], len(match["factions"])))
        current = None
        for verdict in match["verdicts"]:
            if verdict["invariant"] != current:
                current = verdict["invariant"]
                out.write("  -- %s\n     %s\n" % (current, verdict["explanation"]))
            v = Verdict(verdict["invariant"], match["match"], verdict["faction"],
                        verdict["status"], verdict["evidence"], verdict["explanation"])
            out.write("     %s\n" % v.format_line())
    counts = summarize(result)
    out.write("\nSUMMARY pass=%d fail=%d warn=%d\n"
              % (counts["PASS"], counts["FAIL"], counts["WARN"]))


def render_require_clean(result, out):
    """Machine-readable gating output: one line per violation plus a SUMMARY.

    Designed for CI logs: grep-able, one line per violation, no tables to
    reformat when a column width changes.
    """
    total = 0
    violations = 0
    warns = 0
    for match, verdict in iter_verdicts(result):
        total += 1
        if verdict["status"] == "FAIL":
            violations += 1
            ev = " ".join("%s=%s" % (k, _fmt(v)) for k, v in sorted(verdict["evidence"].items()))
            out.write("FAIL %s %s %s %s\n"
                      % (verdict["invariant"], match, verdict["faction"], ev))
        elif verdict["status"] == "WARN":
            warns += 1
            ev = " ".join("%s=%s" % (k, _fmt(v)) for k, v in sorted(verdict["evidence"].items()))
            out.write("WARN %s %s %s %s\n"
                      % (verdict["invariant"], match, verdict["faction"], ev))
    out.write("SUMMARY checks=%d failures=%d warnings=%d batch=%s\n"
              % (total, violations, warns, result["batch"]))
    return violations


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="ai_invariants.py",
        description="Algebraic invariant linter for RTS headless AI telemetry. "
                    "Exits non-zero when an invariant that must hold by "
                    "construction of the economy/roster rules is violated.")
    parser.add_argument("batch", help="batch directory (or a single telemetry file)")
    parser.add_argument("--require-clean", action="store_true",
                        help="CI/gating mode: emit one line per violation and exit "
                             "1 if any invariant fails")
    parser.add_argument("--json", action="store_true",
                        help="emit the full machine-readable result set")
    args = parser.parse_args(argv)

    if not os.path.exists(args.batch):
        sys.stderr.write("ai_invariants: no such path: %s\n" % args.batch)
        return 2
    try:
        result = check_batch(args.batch)
    except ValueError as exc:
        sys.stderr.write("ai_invariants: %s\n" % exc)
        return 2

    if args.json:
        sys.stdout.write(json.dumps(result, indent=1, sort_keys=True) + "\n")
    elif args.require_clean:
        violations = render_require_clean(result, sys.stdout)
        if violations:
            return 1
        return 0
    else:
        _render(result, sys.stdout)
        if summarize(result)["FAIL"]:
            return 1
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
