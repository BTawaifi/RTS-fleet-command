"""Unit tests for ai_invariants.

Two kinds of fixture:

  * SYNTHETIC records written to a temp directory, used to make each invariant
    fire and to make it stay quiet. Every invariant gets at least one of each.
  * REGRESSION shapes distilled from the two real batches, used to prove the
    linter discriminates. A linter that fires on everything is worthless, so
    ``test_regression_*`` pins BOTH directions: the known-good shape must be
    clean and the known-bad shape must fire on roster_escalation and
    cp_drift_not_persistently_negative.

Every synthetic economy CONSERVES: the bank moves by exactly what the FACTION
flow says it moved. That is not decoration -- ``production_spend_reconciles``
asserts ``|dCP - (income + bounty + refund - spend)|`` per interval against the
bank itself, so a fixture that reports income the bank never received is a leak
and is rejected. Measured on the real batches the worst deviation is 1e-4 CP
over 36 faction-matches.

Two regimes are covered for the CP spend, because real batches are in both:

  * LEDGER batches (CP_SPEND + economy.flowCumulative present, as on
    capgate-20261001) assert the conservation identity, the ledger/gauge
    reconciliation and the negative residual, and report the non-build gap as a
    measurement.
  * PRE-LEDGER batches (no CP_SPEND, as on session-fix-20260930 and
    sentryfix-20261001) cannot say whether a positive gap is a named non-build
    sink or a real leak, so that direction is reported as not-reported, never as
    a failure -- the same distinction compare_batches.py draws for
    ``cp_spend_drift``.

The real-batch regression numbers are not guesses. They are the measured values
from streaming:

  session-fix-20260930 (GOOD), per faction per match:
    capital-class builds  1 (tier 3 or tier 5) in 12 of 12 faction-matches
    cp peak               9923-13801 CP
    capital bankTarget    8600 (BLUE/GOLD) or 7700 (RED), median 12675-13825
    floorFraction         0.037-0.098
  sentryfix-20261001 (BAD), per faction per match:
    capital-class builds  0 in 12 of 12 faction-matches
    cp peak               1300-2494 CP
    capital bankTarget    8600 / 7700, median 12675-13825
    floorFraction         0.184-0.306

Run from this directory:  python -m pytest -q
"""

import io
import json
import os
import re
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ai_invariants as ai  # noqa: E402


# --------------------------------------------------------------------------
# fixture builders
# --------------------------------------------------------------------------

def rec(event, when, **data):
    return {"schema": 2.0, "sequence": 0, "time": when, "event": event, "data": data}


class MatchWriter(object):
    """Writes a synthetic match as JSON Lines, the real on-disk shape."""

    def __init__(self, path):
        self.path = path
        self._seq = 0
        self._handle = io.open(path, "w", encoding="utf-8", newline="\n")

    def write(self, event, when, **data):
        self._seq += 1
        record = rec(event, when, **data)
        record["sequence"] = self._seq
        self._handle.write(json.dumps(record) + "\n")

    def close(self):
        self._handle.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def write_match(tmp_path, records, name="a-1"):
    """Materialise a list of (event, time, data) triples as a match directory."""
    attempt = tmp_path / "results" / "w" / "worker-1" / name / "probe" / "data"
    attempt.mkdir(parents=True, exist_ok=True)
    path = str(attempt / "rts-ai-20261001-000000.jsonl")
    with MatchWriter(path) as writer:
        for event, when, data in records:
            writer.write(event, when, **data)
    return path


def healthy_faction_records(faction="BLUE", capital=True, start_cp=5000.0,
                            interval=60.0, samples=40, end=2400.0):
    """A faction that behaves correctly: banks up, buys a capital, spends down.

    The economy CONSERVES: the bank moves by exactly what the FACTION flow says
    it moved in every interval, which is the identity
    ``production_spend_reconciles`` now asserts against the bank itself. That was
    not enforced before the check was rewritten around CP_SPEND, and the fixture
    used to add 500 CP to the bank per think while reporting 360 CP of income --
    a 140 CP lie per interval that a conservation check is right to reject. The
    reported income is now the 500 CP the bank actually receives.

    ``capital=False`` produces the livelock shape instead -- the bank is drained
    on every think so it never accumulates, which is what
    ``FieldCheapHullWhileSaving`` did in the bad batch. Its flow also spends more
    than it earns, matching the measured bad-batch net rates of -0.06 to -0.39
    CP/s against a bank pinned near the 400 CP reserve.
    """
    records = []
    cp = start_cp
    spend = 0.0
    income = 500.0
    for step in range(samples):
        when = step * interval
        spend = 0.0
        if capital:
            cp += income
            # A healthy roster is not a single hull: buy a cheap fighter every
            # few thinks and one capital-class hull, all of which must spawn.
            # Three classes and a spread, so composition is not degenerate.
            if step % 4 == 3:
                hull = ("GTF Perseus", "GVF Seth", "GTB Zeus")[step % 12 // 4]
                records.append((
                    "PRODUCTION", when,
                    dict(action="QUEUE_ACCEPTED", faction=faction, cost=1500.0,
                         count=4, tier=1, role="fighter",
                         **{"class": hull},
                         producer="AI", queuedAt=when,
                         cpBefore=cp, cpAfter=cp - 1500.0)))
                cp -= 1500.0
                records.append((
                    "PRODUCTION", when + 1.0,
                    dict(action="UNIT_SPAWNED", faction=faction, cost=1500.0,
                         tier=1, role="fighter",
                         **{"class": hull},
                         producer="AI", queuedAt=when, startedAt=when,
                         completedAt=when + 1.0,
                         requestedCount=4, spawnedCount=4)))
            if step == samples // 2:
                records.append((
                    "PRODUCTION", when,
                    dict(action="QUEUE_ACCEPTED", faction=faction, cost=8600.0,
                         count=1, tier=3, role="capital",
                         **{"class": "GTVA Colossus"},
                         producer="AI", queuedAt=when,
                         cpBefore=cp, cpAfter=cp - 8600.0)))
                cp -= 8600.0
                records.append((
                    "PRODUCTION", when + 1.0,
                    dict(action="UNIT_SPAWNED", faction=faction, cost=8600.0,
                         tier=3, role="capital",
                         **{"class": "GTVA Colossus"},
                         producer="AI", queuedAt=when, startedAt=when,
                         completedAt=when + 1.0,
                         requestedCount=1, spawnedCount=1)))
                spend += 8600.0
            records.append((
                "AI_BUILD_DECISION", when,
                dict(faction=faction, desiredRole="capital", tier=3,
                     reason=ai.SAVING_REASON, bankTarget=8600.0,
                     commandPoints=cp)))
            spend += 1500.0 if step % 4 == 3 else 0.0
        else:
            # Livelock: spend everything that arrives, on every single think, so
            # the bank never climbs. The spend exceeds income by 1 CP per think,
            # which is the real bad-batch shape (netRate -0.055 to -0.389 CP/s
            # against a bank pinned near the 400 CP reserve): the bank is drawn
            # down slowly rather than never moving at all.
            cp += income
            cp -= income + 1.0
            records.append((
                "AI_BUILD_DECISION", when,
                dict(faction=faction, desiredRole="capital", tier=3,
                     reason=ai.SAVING_REASON, bankTarget=8600.0,
                     commandPoints=cp)))
            records.append((
                "PRODUCTION", when,
                dict(action="QUEUE_ACCEPTED", faction=faction, cost=income + 1.0,
                     count=1, tier=1, role="fighter",
                     **{"class": "GTF Perseus"},
                     producer="AI", queuedAt=when,
                     cpBefore=cp + income + 1.0, cpAfter=cp)))
            records.append((
                "PRODUCTION", when,
                dict(action="UNIT_SPAWNED", faction=faction, cost=income + 1.0,
                     tier=1, role="fighter", **{"class": "GTF Perseus"},
                     producer="AI", queuedAt=when, startedAt=when,
                     completedAt=when + 1.0,
                     requestedCount=1, spawnedCount=1)))
            spend = income + 1.0
        records.append((
            "FACTION", when,
            dict(faction=faction, losses={}, economy=dict(
                commandPoints=cp,
                flow=dict(income=income, bounty=0.0, refund=0.0,
                          productionSpend=spend),
                queue=None, queueDepth=0.0))))
    return records


def losses_records(faction, count, when):
    return [("LOSS", when + i * 10.0, dict(faction=faction, ship=100 + i,
                                           **{"class": "GTF Perseus"}))
            for i in range(count)]


def run_invariants(tmp_path, records):
    path = write_match(tmp_path, records)
    result = ai.check_batch(str(tmp_path))
    return result


def statuses(result, invariant):
    return [v["status"] for m in result["matches"] for v in m["verdicts"]
            if v["invariant"] == invariant]


def verdict_for(result, invariant, faction=None):
    for m in result["matches"]:
        for v in m["verdicts"]:
            if v["invariant"] == invariant and (faction is None or v["faction"] == faction):
                return v
    raise AssertionError("no verdict for %s/%s" % (invariant, faction))


# --------------------------------------------------------------------------
# discovery
# --------------------------------------------------------------------------

def test_find_telemetry_locates_the_real_batch_layout(tmp_path):
    path = write_match(tmp_path, [("FACTION", 1.0, dict(faction="BLUE", economy={}, losses={}))])
    found = ai.find_telemetry(str(tmp_path))
    assert found == [path]


def test_find_telemetry_accepts_a_single_file(tmp_path):
    path = write_match(tmp_path, [("FACTION", 1.0, dict(faction="BLUE", economy={}, losses={}))])
    assert ai.find_telemetry(path) == [path]


def test_missing_batch_raises_valueerror(tmp_path):
    with pytest.raises(ValueError):
        ai.check_batch(str(tmp_path / "nope"))


def test_main_exits_two_on_a_missing_path(tmp_path, capsys):
    assert ai.main([str(tmp_path / "definitely-absent")]) == 2


def test_torn_final_line_is_skipped_not_fatal(tmp_path):
    """A killed run leaves a half-written last line; that must not crash."""
    path = write_match(tmp_path, healthy_faction_records())
    with io.open(path, "a", encoding="utf-8") as handle:
        handle.write('{"schema":2.0,"sequence":99,"time":99')
    result = ai.check_batch(str(tmp_path))
    assert len(result["matches"]) == 1


def test_scan_streams_without_loading_the_whole_file(tmp_path):
    """A 40 MB stream must cost the same memory as a small one: memory has to be
    bounded by the number of distinct (class, timestamp) pairs the run emits, not
    by the number of records. These asserts pin the property that keeps the 43 MB
    real files affordable: no list or dict in FactionFacts grows with record count
    beyond one entry per distinct build.
    """
    small = write_match(tmp_path, healthy_faction_records(samples=20))
    facts_small, _meta_small = ai.scan_match(small)
    many = write_match(tmp_path / "big", healthy_faction_records(samples=200))
    facts_many, _meta_many = ai.scan_match(many)

    def per_record(facts):
        queued = sum(sum(f.queued_keys.values()) for f in facts.values())
        keys = sum(len(f.queued_keys) for f in facts.values())
        return keys / float(queued)

    # 10x the records must not multiply bookkeeping by 10x per build.
    assert per_record(facts_small) == pytest.approx(per_record(facts_many), rel=0.05)
    f = facts_many["BLUE"]
    assert f.snapshot_count == 200
    assert sum(f.queued_keys.values()) == sum(f.spawned_keys.values())
    assert f.loss_events == 0


# --------------------------------------------------------------------------
# production_spend_reconciles
# --------------------------------------------------------------------------
#
# The check no longer compares the flow against build events to within a budget.
# It asserts CP CONSERVATION (the bank moves by exactly what the flow says), the
# LEDGER (CP_SPEND records sum to economy.flowCumulative), and the NEGATIVE
# residual (no build charged outside the chokepoint). The POSITIVE residual is
# the named non-build gap, reported as `nonBuildSpend`; on a batch that predates
# the CP_SPEND emitter it is undefined, so the verdict is WARN and never a
# failure.

def test_production_spend_passes_when_flow_equals_build_events(tmp_path):
    records = [
        ("FACTION", 100.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=1000.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=1600.0)))),
        ("PRODUCTION", 100.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                   cost=1600.0, count=4, tier=1, queuedAt=100.0,
                                   cpBefore=2600.0, cpAfter=1000.0)),
        # The bank then takes the interval's 500 CP of income and spends nothing:
        # the interval conserves, so the identity holds exactly.
        ("FACTION", 200.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=1500.0,
            flow=dict(income=500.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "PASS"
    assert v["evidence"]["residual"] == 0
    assert v["evidence"]["conservationViolations"] == 0


def test_production_spend_is_not_reported_when_the_batch_predates_the_ledger(tmp_path):
    """A batch with no CP_SPEND record cannot say whether its positive gap is a
    named non-build sink or a real leak, so it is UNDEFINED, not a failure.

    This is the shape of session-fix-20260930 and sentryfix-20261001: flow above
    build events, no per-deduction ledger. compare_batches.py draws exactly this
    line for cp_spend_drift ("0 when the batch predates either record"), and
    several staged batches depend on it being drawn the same way here.
    """
    records = [
        ("FACTION", 100.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=3000.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=5000.0)))),
        ("PRODUCTION", 100.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                   cost=1600.0, count=4, tier=1, queuedAt=100.0,
                                   cpBefore=4600.0, cpAfter=3000.0)),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "WARN", v
    assert v["evidence"]["direction"] == "ledger-not-reported"
    assert v["evidence"]["ledgerReported"] is False
    assert v["evidence"]["nonBuildSpend"] == "not-reported"
    # The gap is still reported, not swallowed.
    assert v["evidence"]["residual"] == pytest.approx(3400.0)


def test_production_spend_fails_on_a_negative_residual(tmp_path):
    """A build charged without passing the chokepoint is a second CP writer."""
    records = [
        ("FACTION", 100.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=1000.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
        ("PRODUCTION", 100.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                   cost=1600.0, count=4, tier=1, queuedAt=100.0,
                                   cpBefore=2600.0, cpAfter=1000.0)),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "FAIL"
    assert v["evidence"]["direction"] == "flow-below-build-events"


def test_production_spend_fails_when_a_second_cp_writer_bypasses_the_chokepoint(tmp_path):
    """The case the old 25% budget was hiding: a build charged straight off the
    bank, with a build event but no CP_SPEND record and no flow entry.

    Nothing about this looks unusual in the event stream -- the charge announces
    itself with cpBefore/cpAfter, exactly like a legitimate build -- and the old
    budget could not see it at all, because a 1600 CP shortfall sits inside a
    gap that was allowed to reach 12000 CP. It must FAIL, and the negative
    direction must stay tight enough to catch a single hull.
    """
    records = [
        ("FACTION", 100.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=13600.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
        # The bank drops 8600 (visible in the two snapshots below), the build
        # event says so, and the flow never heard of it.
        ("PRODUCTION", 150.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                   cost=8600.0, count=1, tier=3, role="capital",
                                   **{"class": "GTVA Colossus"},
                                   queuedAt=150.0, cpBefore=13600.0,
                                   cpAfter=5000.0)),
        ("FACTION", 200.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=5000.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "FAIL", v
    defects = v["evidence"]["defects"].split(",")
    # Both symptoms are present and both are reported: the flow is short of the
    # build event, and the bank moved with nothing to explain it.
    assert "flow-below-build-events" in defects
    assert "bank-moved-without-flow-record" in defects
    assert v["evidence"]["residual"] == pytest.approx(-8600.0)
    assert v["evidence"]["conservationViolations"] == 1


def test_production_spend_fails_when_the_bank_moves_without_a_flow_record(tmp_path):
    """A silent sink: CP leaves the bank, no flow entry, no event, no ledger.

    This is the unattributed sink the budget used to absorb. Nothing in the
    event stream mentions it at all -- only the bank knows -- so it is exactly
    the case a per-deduction ledger cannot be the sole answer for, and the
    conservation identity is what catches it.
    """
    records = [
        ("FACTION", 100.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=5000.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
        # A full CP_SPEND ledger that reconciles perfectly, so the emitter is
        # demonstrably healthy: the leak is in whatever did NOT report.
        ("CP_SPEND", 120.0, dict(faction="BLUE", flow="productionSpend",
                                 amount=400.0, cpBefore=5400.0, cpAfter=5000.0)),
        ("FACTION", 200.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=4600.0,
            flowCumulative=dict(productionSpend=400.0),
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "FAIL", v
    assert v["evidence"]["direction"] == "bank-moved-without-flow-record"
    assert v["evidence"]["ledgerDrift"] == pytest.approx(0.0)
    assert v["evidence"]["conservationMaxDev"] == pytest.approx(400.0)


def test_production_spend_measures_the_named_non_build_gap_with_a_ledger(tmp_path):
    """The known emitter gap, fully accounted for: upgrades, ability and service
    spend through the same chokepoint without being build events.

    Every deduction carries a CP_SPEND record and the ledger reproduces the gauge
    exactly, so the 3400 CP gap is attributable rather than merely bounded. That
    is a PASS, with the gap reported as `nonBuildSpend`.
    """
    records = [
        ("FACTION", 100.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=3000.0, upgradeSpend=3400.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=5000.0)))),
        ("FLEET_SERVICE_WORK", 50.0, dict(faction="BLUE", spent=103.0, ship=1)),
        ("PRODUCTION", 100.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                   cost=1600.0, count=4, tier=1, queuedAt=100.0,
                                   cpBefore=4600.0, cpAfter=3000.0)),
        ("CP_SPEND", 100.0, dict(faction="BLUE", flow="productionSpend",
                                 amount=1600.0, cpBefore=4600.0, cpAfter=3000.0)),
        ("CP_SPEND", 101.0, dict(faction="BLUE", flow="productionSpend",
                                 amount=3400.0, cpBefore=6600.0, cpAfter=3200.0)),
        ("FACTION", 200.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=3000.0, upgradeSpend=3400.0,
            flowCumulative=dict(productionSpend=5000.0),
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "PASS", v
    assert v["evidence"]["direction"] == "reconciled"
    assert v["evidence"]["ledgerReported"] is True
    # The residual is the named non-build gap (3400 of upgrades and service
    # against 1600 of build events) and it is now measured, not bounded.
    assert v["evidence"]["residual"] == pytest.approx(3400.0)
    assert v["evidence"]["nonBuildSpend"] == pytest.approx(3400.0)
    assert v["evidence"]["serviceSpend"] == 103.0
    assert v["evidence"]["ledgerDrift"] == pytest.approx(0.0)


def test_production_spend_fails_when_the_ledger_drift_exceeds_the_tolerance(tmp_path):
    """A deduction the gauge counted but the event stream dropped: the CP
    movement is real and the spend total is now silently under-reporting."""
    records = [
        ("FACTION", 100.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=3000.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=5000.0)))),
        ("PRODUCTION", 100.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                   cost=5000.0, count=4, tier=1, queuedAt=100.0,
                                   cpBefore=8000.0, cpAfter=3000.0)),
        # One CP_SPEND record for a 5000 CP charge that the gauge says cost
        # 5400: 400 CP of it is nowhere in the ledger.
        ("CP_SPEND", 100.0, dict(faction="BLUE", flow="productionSpend",
                                 amount=5000.0, cpBefore=8000.0, cpAfter=3000.0)),
        ("FACTION", 200.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=3000.0,
            flowCumulative=dict(productionSpend=5400.0),
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "FAIL", v
    assert v["evidence"]["direction"] == "ledger-drift-from-flow-cumulative"
    assert v["evidence"]["ledgerDrift"] == pytest.approx(400.0)
    assert v["evidence"]["ledgerDrift"] > v["evidence"]["ledgerDriftTolerance"]


def test_production_spend_accepts_float_noise_in_the_ledger(tmp_path):
    """The tolerance is a round-trip noise floor, not a band: 4-decimal floats
    through JSON must not fail, and the measured drift on capgate-20261001 peaks
    at 0.0058 CP."""
    drift = 0.004
    records = [
        ("FACTION", 100.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=3000.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=5000.0)))),
        ("PRODUCTION", 100.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                   cost=5000.0, count=4, tier=1, queuedAt=100.0,
                                   cpBefore=8000.0, cpAfter=3000.0)),
        ("CP_SPEND", 100.0, dict(faction="BLUE", flow="productionSpend",
                                 amount=5000.0, cpBefore=8000.0, cpAfter=3000.0)),
        ("FACTION", 200.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=3000.0,
            flowCumulative=dict(productionSpend=5000.0 - drift),
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "PASS", v
    assert v["evidence"]["ledgerDrift"] == pytest.approx(drift, abs=1e-6)


def test_production_spend_reports_the_tail_the_last_snapshot_never_saw(tmp_path):
    """Spend after a match's final FACTION publish is in no reported interval and
    in no gauge, so the gauge is compared AT the publish. The tail is reported
    rather than folded into the drift: measured 1225 CP on capgate-20261001
    (BLUE, a-1790864031524441400), where a purchase landed after the last
    snapshot."""
    records = [
        ("FACTION", 100.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=3000.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=1600.0)))),
        ("PRODUCTION", 100.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                   cost=1600.0, count=4, tier=1, queuedAt=100.0,
                                   cpBefore=4600.0, cpAfter=3000.0)),
        ("CP_SPEND", 100.0, dict(faction="BLUE", flow="productionSpend",
                                 amount=1600.0, cpBefore=4600.0, cpAfter=3000.0)),
        ("FACTION", 200.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=3000.0,
            flowCumulative=dict(productionSpend=1600.0),
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
        # Deduction after the final publish: no interval, no gauge update.
        ("CP_SPEND", 260.0, dict(faction="BLUE", flow="productionSpend",
                                 amount=1225.0, cpBefore=4225.0, cpAfter=3000.0)),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "PASS", v
    assert v["evidence"]["ledgerDrift"] == pytest.approx(0.0)
    assert v["evidence"]["cpSpendTailAfterPublish"] == pytest.approx(1225.0)


def test_conservation_tolerance_is_not_widened_to_cover_a_real_leak(tmp_path):
    """The conservation tolerance is a float noise floor: 0.005 CP, verified at
    that value against 36 faction-matches whose worst deviation was 1e-4 CP."""
    records = [
        ("FACTION", 100.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=5000.0,
            flow=dict(income=100.0, bounty=0.0, refund=0.0, productionSpend=0.0)))),
        # Exactly the 100.1 CP of income the flow reported.
        ("FACTION", 200.0, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=5100.1,
            flow=dict(income=100.1, bounty=0.0, refund=0.0, productionSpend=0.0)))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "PASS", v
    assert v["evidence"]["conservationViolations"] == 0

    # Same declared income, but the bank moved 100 CP less than that: 100 CP left
    # somewhere with no flow record, which is the leak.
    leaked = [r if r[0] != "FACTION" else
              ("FACTION", 200.0, dict(faction="BLUE", losses={}, economy=dict(
                  commandPoints=5200.1,
                  flow=dict(income=100.1, bounty=0.0, refund=0.0,
                            productionSpend=0.0))))
              for r in records]
    result = run_invariants(tmp_path / "leak", leaked)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "FAIL", v
    assert v["evidence"]["direction"] == "bank-moved-without-flow-record"


def test_sentry_spend_counts_toward_reconciliation(tmp_path):
    """SENTRY_BUILD/BUILD_STARTED is a second spend path; ignoring it produced a
    false -1.27e4 gap in the baseline batch."""
    records = [
        ("FACTION", 100.0, dict(faction="RED", losses={}, economy=dict(
            commandPoints=1000.0,
            flow=dict(income=0.0, bounty=0.0, refund=0.0, productionSpend=1975.0)))),
        ("SENTRY_BUILD", 100.0, dict(action="BUILD_STARTED", faction="RED",
                                      cost=375.0, startedAt=100.0, finishAt=120.0)),
        ("SENTRY_BUILD", 101.0, dict(action="BUILD_STARTED", faction="RED",
                                      cost=1600.0, startedAt=101.0, finishAt=121.0)),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "production_spend_reconciles")
    assert v["status"] == "PASS"
    assert v["evidence"]["sentryEvents"] == 1975.0
    assert v["evidence"]["residual"] == pytest.approx(0.0)


# --------------------------------------------------------------------------
# losses_reconcile
# --------------------------------------------------------------------------

def test_losses_reconcile_passes_on_an_exact_count(tmp_path):
    records = losses_records("BLUE", 3, 100.0) + [
        ("FACTION", 200.0, dict(faction="BLUE", losses={"GTF Perseus": 3.0},
                                economy=dict(commandPoints=100.0, flow={}))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "losses_reconcile")
    assert v["status"] == "PASS"
    assert v["evidence"]["diff"] == 0


def test_losses_reconcile_fails_when_the_snapshot_undercounts(tmp_path):
    records = losses_records("BLUE", 5, 100.0) + [
        ("FACTION", 200.0, dict(faction="BLUE", losses={"GTF Perseus": 3.0},
                                economy=dict(commandPoints=100.0, flow={}))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "losses_reconcile")
    assert v["status"] == "FAIL"
    assert v["evidence"]["diff"] == -2


def test_losses_reconcile_ignores_losses_after_the_final_snapshot(tmp_path):
    """The tail cut. Without it the GOOD batch showed spurious negatives up to
    -6; with it, all 12 good faction-matches reconcile exactly."""
    records = losses_records("BLUE", 3, 100.0) + [
        ("FACTION", 200.0, dict(faction="BLUE", losses={"GTF Perseus": 3.0},
                                economy=dict(commandPoints=100.0, flow={}))),
    ] + losses_records("BLUE", 4, 300.0)  # all after the last snapshot
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "losses_reconcile")
    assert v["status"] == "PASS"
    assert v["evidence"]["lossEventsTotal"] == 7
    assert v["evidence"]["lossEventsAtSnapshot"] == 3


# --------------------------------------------------------------------------
# no_orphan_builds
# --------------------------------------------------------------------------

def test_no_orphans_passes_when_every_build_spawns(tmp_path):
    records = [
        ("PRODUCTION", 100.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                   cost=1600.0, count=4, tier=1, queuedAt=100.0,
                                   cpBefore=2600.0, cpAfter=1000.0)),
        ("PRODUCTION", 120.0, dict(action="UNIT_SPAWNED", faction="BLUE",
                                   cost=1600.0, tier=1, queuedAt=100.0,
                                   startedAt=100.0, completedAt=120.0)),
        ("FACTION", 200.0, dict(faction="BLUE", losses={},
                                economy=dict(commandPoints=1000.0, flow={}))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "no_orphan_builds")
    assert v["status"] == "PASS"
    assert v["evidence"]["orphanBuilds"] == 0


def test_no_orphans_fails_when_a_paid_build_never_spawns(tmp_path):
    records = [
        ("PRODUCTION", 100.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                   cost=8600.0, count=1, tier=5,
                                   **{"class": "GTVA Colossus"},
                                   queuedAt=100.0, cpBefore=9600.0, cpAfter=1000.0)),
        ("FACTION", 500.0, dict(faction="BLUE", losses={},
                                economy=dict(commandPoints=1000.0, flow={}))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "no_orphan_builds")
    assert v["status"] == "FAIL"
    assert v["evidence"]["orphanBuilds"] == 1
    assert "GTVA Colossus@100.0" == v["evidence"]["orphanSample"]


def test_no_orphans_allows_a_build_still_in_the_final_queue(tmp_path):
    """A hull still building at the final snapshot is a timing cut, not a bug.
    Observed on the GOOD batch: GTVA Colossus queued t=2641.2, finishAt=2876.0,
    final snapshot t=2812.9."""
    records = [
        ("PRODUCTION", 2641.155, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                      cost=8600.0, count=1, tier=5,
                                      queuedAt=2641.155, cpBefore=9600.0, cpAfter=1000.0)),
        ("FACTION", 2812.9, dict(faction="BLUE", losses={}, economy=dict(
            commandPoints=1000.0, flow={},
            queue=dict(cls="GTVA Colossus", queuedAt=2641.155, cost=8600.0)))),
    ]
    result = run_invariants(tmp_path, records)
    assert verdict_for(result, "no_orphan_builds")["status"] == "PASS"


def test_no_orphans_allows_a_build_queued_after_the_final_snapshot(tmp_path):
    """Baseline GOLD queued GVF Thoth at t=2569.7 with the last snapshot at
    t=2569.0, so no snapshot could have reported it."""
    records = [
        ("FACTION", 2569.0, dict(faction="GOLD", losses={},
                                 economy=dict(commandPoints=1000.0, flow={}))),
        ("PRODUCTION", 2569.6726, dict(action="QUEUE_ACCEPTED", faction="GOLD",
                                       cost=1600.0, count=4, tier=1,
                                       queuedAt=2569.6726,
                                       cpBefore=2600.0, cpAfter=1000.0)),
    ]
    result = run_invariants(tmp_path, records)
    assert verdict_for(result, "no_orphan_builds")["status"] == "PASS"


def test_no_orphans_fails_on_an_unterminated_sentry_build(tmp_path):
    records = [
        ("SENTRY_BUILD", 100.0, dict(action="BUILD_STARTED", faction="BLUE",
                                      cost=375.0, startedAt=100.0, finishAt=120.0)),
        ("FACTION", 500.0, dict(faction="BLUE", losses={},
                                economy=dict(commandPoints=1000.0, flow={}))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "no_orphan_builds")
    assert v["status"] == "FAIL"
    assert v["evidence"]["sentryBuildsOpen"] == 1


def test_sentry_cancel_closes_the_build(tmp_path):
    records = [
        ("SENTRY_BUILD", 100.0, dict(action="BUILD_STARTED", faction="RED",
                                      cost=375.0, startedAt=100.0, finishAt=120.0)),
        ("SENTRY_BUILD", 101.0, dict(action="BUILD_CANCELLED", faction="RED",
                                      cost=375.0, reason="Enemy contact at build site")),
        ("FACTION", 500.0, dict(faction="RED", losses={},
                                economy=dict(commandPoints=1000.0, flow={}))),
    ]
    result = run_invariants(tmp_path, records)
    assert verdict_for(result, "no_orphan_builds")["status"] == "PASS"

# --------------------------------------------------------------------------
# cp_drift_not_persistently_negative
# --------------------------------------------------------------------------

def test_cp_drift_passes_for_a_faction_whose_bank_accumulates(tmp_path):
    records = healthy_faction_records(capital=True, start_cp=9000.0)
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "cp_drift_not_persistently_negative")
    assert v["status"] == "PASS"
    assert v["evidence"]["floorFraction"] <= ai.CP_DRIFT_FLOOR_FRACTION_MAX


def test_cp_drift_fails_for_a_saving_faction_pinned_at_the_floor(tmp_path):
    """The livelock: claims to save, bank never leaves the reserve floor."""
    records = healthy_faction_records(capital=False, start_cp=200.0)
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "cp_drift_not_persistently_negative")
    assert v["status"] == "FAIL"
    assert v["evidence"]["mechanism"] == "saving-claim-but-bank-pinned-at-floor"
    assert v["evidence"]["savingDecisions"] > 0


def test_cp_drift_passes_when_the_faction_never_claims_to_save(tmp_path):
    """No saving claim means no assertion about accumulation to falsify.

    The faction spends more than it earns, exactly like the bad batch, so the
    only thing separating the two shapes is the saving claim. The bank declines
    by precisely what the flow says it does, so this fixture stays consistent
    with the CP conservation identity.
    """
    records = []
    cp = 20000.0
    for step in range(40):
        cp += 360.0
        cp -= 400.0
        records.append((
            "FACTION", step * 60.0,
            dict(faction="BLUE", losses={}, economy=dict(
                commandPoints=cp,
                flow=dict(income=360.0, bounty=0.0, refund=0.0,
                          productionSpend=400.0)))))
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "cp_drift_not_persistently_negative")
    assert v["status"] == "PASS"
    assert v["evidence"]["mechanism"] == "no-saving-claim"
    assert v["evidence"]["netRate"] < 0.0


def test_cp_drift_allows_a_negative_rate_when_the_bank_is_healthy(tmp_path):
    """Baseline BLUE/a-1790820145 ran netRate -0.656 CP/s and still built its
    capital. A mean-rate gate would false-fire here; the bank-based gate must not.
    This is the test that keeps the brief's literal form from creeping back in."""
    records = healthy_faction_records(capital=True, start_cp=9900.0)
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "cp_drift_not_persistently_negative")
    # The fixture must actually be net-negative: it banks hard, then spends the
    # bank down on the capital hull, so the whole-match mean is negative while
    # the peak clears the target. Nothing is faked in the flow to achieve that.
    assert v["evidence"]["netRate"] < 0.0, "fixture must actually be net-negative"
    assert v["evidence"]["cpPeak"] > 8600.0
    assert v["status"] == "PASS"
    assert verdict_for(result, "production_spend_reconciles")["status"] == "PASS"


# --------------------------------------------------------------------------
# roster_escalation -- THE discriminator
# --------------------------------------------------------------------------

def test_roster_escalation_passes_with_one_capital_class_build(tmp_path):
    records = healthy_faction_records(capital=True)
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "roster_escalation")
    assert v["status"] == "PASS"
    assert v["evidence"]["capitalClassBuilds"] >= 1


def test_roster_escalation_passes_on_a_tier5_juggernaut(tmp_path):
    # Tier 5 unlocks at 1380 s on the 30 MIN profile, so the purchase and the
    # snapshot that reports it are placed after it. A fixture that bought one at
    # t=100 described an impossible match.
    records = [
        ("PRODUCTION", 1400.0, dict(action="QUEUE_ACCEPTED", faction="BLUE",
                                     cost=29375.0, count=1, tier=5,
                                     role="juggernaut", queuedAt=1400.0,
                                     cpBefore=30375.0, cpAfter=1000.0)),
        ("FACTION", 1500.0, dict(faction="BLUE", losses={},
                                 economy=dict(commandPoints=1000.0, flow={}))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "roster_escalation")
    assert v["status"] == "PASS"
    assert v["evidence"]["maxTierBuilt"] == 5


def test_roster_escalation_passes_on_a_tier4_heavy(tmp_path):
    records = [
        ("PRODUCTION", 1100.0, dict(action="QUEUE_ACCEPTED", faction="GOLD",
                                     cost=8000.0, count=1, tier=4, role="heavy",
                                     queuedAt=1100.0,
                                     cpBefore=9000.0, cpAfter=1000.0)),
        ("FACTION", 1500.0, dict(faction="GOLD", losses={},
                                 economy=dict(commandPoints=1000.0, flow={}))),
    ]
    result = run_invariants(tmp_path, records)
    assert verdict_for(result, "roster_escalation")["status"] == "PASS"


def test_roster_escalation_fails_when_only_t1_and_t2_are_built(tmp_path):
    """Exactly the known-bad shape: 48 cheap hulls, no capital class at all."""
    records = []
    for step in range(20):
        records.append((
            "PRODUCTION", step * 60.0,
            dict(action="QUEUE_ACCEPTED", faction="RED", cost=1500.0, count=4,
                 tier=1 if step % 2 else 2, role="fighter", queuedAt=step * 60.0,
                 cpBefore=2500.0, cpAfter=1000.0)))
        records.append((
            "FACTION", step * 60.0,
            dict(faction="RED", losses={}, economy=dict(
                commandPoints=1000.0, flow={}))))
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "roster_escalation")
    assert v["status"] == "FAIL"
    assert v["evidence"]["capitalClassBuilds"] == 0
    assert v["evidence"]["maxTierBuilt"] == 2
    assert v["evidence"]["totalBuilds"] == 80
    assert v["evidence"]["mechanism"] == "capital-class-available-but-never-built"


# -- unlockedTiers: the SCHEDULE, not what the faction happened to build ----

def test_unlocked_tiers_comes_from_the_schedule_not_from_purchases(tmp_path):
    """The defect this replaces: unlockedTiers was the set of tiers a faction was
    SEEN to buy on, so it read [] for a faction that bought 80 T1/T2 hulls and
    [5] for one that bought a single juggernaut -- while both matches ran past
    the 1380 s unlock with all five tiers available.

    Measured on capgate-20261001 before the fix: GOLD/BLUEnlockedTiers=[] and
    RED unlockedTiers=[5] on the same match. Now it is the schedule applied to
    the match's last telemetry timestamp, and it is the same for every faction
    because the escalation clock is mission-global.
    """
    records = []
    for step in range(50):
        when = step * 60.0
        records.append((
            "PRODUCTION", when,
            dict(action="QUEUE_ACCEPTED", faction="BLUE", cost=1500.0, count=4,
                 tier=1 if step % 2 else 2, role="fighter", queuedAt=when,
                 cpBefore=2500.0, cpAfter=1000.0)))
        records.append((
            "FACTION", when,
            dict(faction="BLUE", losses={}, economy=dict(
                commandPoints=1000.0, flow={}))))
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "roster_escalation")
    # Match ends at t=2940, past every entry of {0, 240, 570, 1050, 1380}.
    assert v["evidence"]["unlockedTiers"] == [1, 2, 3, 4, 5]
    assert v["evidence"]["maxTierUnlocked"] == 5
    assert v["evidence"]["tierSchedule"] == list(ai.TIER_UNLOCK_SCHEDULES[1])
    assert v["evidence"]["scenarioElapsedSeconds"] == pytest.approx(2940.0)
    # What it actually built on is still reported, and is still empty: the two
    # facts are different and conflating them was the defect.
    assert v["evidence"]["tiersBuiltOn"] == []
    assert v["evidence"]["capitalClassBuilds"] == 0
    assert v["status"] == "FAIL"


def test_unlocked_tiers_tracks_the_schedule_across_the_match(tmp_path):
    """One unlock boundary, checked against the schedule rather than the clock's
    tick: at t=300 the 30 MIN profile has tiers 1-2, at t=600 it has 1-3."""
    def tiers_at(last_step):
        records = []
        for step in range(last_step + 1):
            when = step * 60.0
            records.append((
                "FACTION", when,
                dict(faction="BLUE", losses={}, economy=dict(
                    commandPoints=1000.0, flow={}))))
        return verdict_for(run_invariants(tmp_path / ("t%d" % last_step), records),
                           "roster_escalation")["evidence"]["unlockedTiers"]

    assert tiers_at(5) == [1, 2]      # t=300, capital unlocks at 570
    assert tiers_at(9) == [1, 2]      # t=540
    assert tiers_at(10) == [1, 2, 3]  # t=600
    assert tiers_at(17) == [1, 2, 3]  # t=1020, heavy unlocks at 1050
    assert tiers_at(18) == [1, 2, 3, 4]
    assert tiers_at(22) == [1, 2, 3, 4]       # t=1320
    assert tiers_at(23) == [1, 2, 3, 4, 5]    # t=1380 exactly


def test_escalation_profile_is_read_from_the_batch_not_assumed(tmp_path):
    """The 60 MIN profile is roughly twice as slow to escalate, so a linter that
    assumed the 30 MIN schedule would judge the same match differently. The
    batch says which profile ran, via ACCEPTANCE_SETUP.durationIndex."""
    records = [("ACCEPTANCE_SETUP", 0.25, dict(durationIndex=2, economyIndex=2,
                                              difficultyIndex=2, distanceIndex=2))]
    for step in range(25):
        records.append((
            "FACTION", step * 60.0,
            dict(faction="BLUE", losses={}, economy=dict(
                commandPoints=1000.0, flow={}))))
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "roster_escalation")
    # t=1440 on {0, 480, 1140, 2160, 2760}: tier 3 only. The 30 MIN schedule
    # would have said tier 5.
    assert v["evidence"]["unlockedTiers"] == [1, 2, 3]
    assert v["evidence"]["tierSchedule"] == list(ai.TIER_UNLOCK_SCHEDULES[2])
    assert v["evidence"]["durationProfile"] == "60 MIN"


def test_scenario_start_is_recovered_from_the_telemetry_not_assumed(tmp_path):
    """OUTCOME_CAUSE carries scenario `elapsed` beside its own record time, so
    ScenarioStartTime is a measurement. Measured agreement on capgate-20261001
    a-1790864033752800000: elapsed 2966.0923 at t=2966.3423 gives a scenario
    start of 0.25, exactly the RUN record's time."""
    records = [
        ("RUN", 0.25, dict(setup=dict(duration="30 MIN"), factions=3)),
        ("OUTCOME_CAUSE", 2966.3423, dict(faction="BLUE", elapsed=2966.0923)),
        ("FACTION", 2966.0, dict(faction="BLUE", losses={},
                                 economy=dict(commandPoints=1000.0, flow={}))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "roster_escalation")
    assert v["evidence"]["scenarioStartSource"] == "outcome-cause-elapsed"
    assert v["evidence"]["scenarioStartSeconds"] == pytest.approx(0.25)
    # The match's last telemetry record is the OUTCOME_CAUSE at t=2966.3423, so
    # the elapsed scenario time is exactly the value that record published.
    assert v["evidence"]["scenarioElapsedSeconds"] == pytest.approx(2966.0923)
    assert v["evidence"]["unlockedTiers"] == [1, 2, 3, 4, 5]


def test_escalation_profile_falls_back_to_the_run_record_name(tmp_path):
    """A batch with no ACCEPTANCE_SETUP record still names its profile."""
    records = [
        ("RUN", 0.25, dict(setup=dict(duration="60 MIN"))),
        ("FACTION", 1160.0, dict(faction="BLUE", losses={},
                                 economy=dict(commandPoints=1000.0, flow={}))),
    ]
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "roster_escalation")
    assert v["evidence"]["durationProfile"] == "60 MIN"
    assert v["evidence"]["unlockedTiers"] == [1, 2, 3]


def test_roster_escalation_is_not_judged_before_capital_unlocks(tmp_path):
    """A match that ends before the capital tier unlocks has not had the class
    available at all, so the absence is not the AI's to be blamed for. This is a
    WARN, and it must not become a way for the real absence to hide: every batch
    this linter discriminates runs to 2400-3000 s."""
    records = [("PRODUCTION", step * 30.0,
                dict(action="QUEUE_ACCEPTED", faction="BLUE", cost=1500.0,
                     count=4, tier=1, role="fighter", queuedAt=step * 30.0,
                     cpBefore=2500.0, cpAfter=1000.0))
               for step in range(10)]
    records.append(("FACTION", 300.0, dict(faction="BLUE", losses={},
                                           economy=dict(commandPoints=1000.0,
                                                        flow={}))))
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "roster_escalation")
    assert v["evidence"]["unlockedTiers"] == [1, 2]
    assert v["evidence"]["maxTierUnlocked"] == 2
    assert v["status"] == "WARN"
    assert v["evidence"]["mechanism"] == "escalation-not-yet-unlocked-at-match-end"


def test_tier_unlock_schedule_matches_the_live_config():
    """The schedule is transcribed into this module so the linter stays offline
    and deterministic. That copy can only be allowed to exist if something
    checks it against the file it claims to mirror, so this test re-reads
    fs2rts_config.lua: a new duration profile, a retuned schedule or a changed
    default must fail here rather than silently judging factions against a
    schedule the game no longer runs."""
    config = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "..", "data", "scripts", "fs2rts_config.lua")
    if not os.path.exists(config):
        pytest.skip("fs2rts_config.lua not present beside this checkout")
    with io.open(config, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    schedules = re.findall(r"tierUnlocks\s*=\s*\{([^}]*)\}", text)
    assert schedules, "no tierUnlocks table found in %s" % config
    parsed = []
    for body in schedules:
        values = [float(v) for v in re.findall(r"[-0-9.]+", body)]
        parsed.append(tuple(values))
    assert set(parsed) == set(ai.TIER_UNLOCK_SCHEDULES.values()), (
        "transcribed schedule drifted from fs2rts_config.lua: live=%s module=%s"
        % (parsed, ai.TIER_UNLOCK_SCHEDULES))
    names = re.findall(r'name\s*=\s*"([^"]+)"[^}]*?targetSeconds', text)
    for name in ai.DURATION_PROFILE_NAMES.values():
        assert name in names, "profile name %r not in the live Durations table" % name
    default = re.search(r"DefaultDuration\s*=\s*(\d+)", text)
    if default:
        assert ai.DEFAULT_DURATION_INDEX == int(default.group(1))


def test_the_dead_factions_fallback_schedule_is_not_used():
    """fs2rts_factions.lua:34 carries { 0, 300, 900, 1800 }, reachable only when
    GetDurationProfile() returns nil. Using it would understate the real schedule
    on every batch, so it must not be in the module at all."""
    dead = (0.0, 300.0, 900.0, 1800.0)
    assert dead not in ai.TIER_UNLOCK_SCHEDULES.values()
    for schedule in ai.TIER_UNLOCK_SCHEDULES.values():
        assert schedule != dead


# --------------------------------------------------------------------------
# fleet_composition_not_degenerate
# --------------------------------------------------------------------------

def test_composition_passes_on_a_spread_fleet(tmp_path):
    records = healthy_faction_records(capital=True)
    for step, cls in enumerate(("GTF Perseus", "GVF Seth", "GTB Zeus", "GTSC Faustus")):
        records.append((
            "PRODUCTION", step * 100.0,
            dict(action="QUEUE_ACCEPTED", faction="BLUE", cost=1000.0, count=4,
                 tier=1, role="fighter", queuedAt=step * 100.0,
                 cpBefore=2000.0, cpAfter=1000.0)))
    result = run_invariants(tmp_path, records)
    assert verdict_for(result, "fleet_composition_not_degenerate")["status"] == "PASS"


def test_composition_fails_on_a_single_class_fleet(tmp_path):
    records = []
    for step in range(20):
        records.append((
            "PRODUCTION", step * 60.0,
            dict(action="QUEUE_ACCEPTED", faction="GOLD", cost=1600.0, count=4,
                 tier=1, role="fighter", queuedAt=step * 60.0,
                 cpBefore=2600.0, cpAfter=1000.0)))
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "fleet_composition_not_degenerate")
    assert v["status"] == "FAIL"
    assert v["evidence"]["topClassShare"] == 1.0
    assert "single-class" in v["evidence"]["reasons"]


def test_composition_fails_on_a_t1_only_fleet(tmp_path):
    """The BAD batch's RED faction: 132 hulls, every one of them tier 1."""
    records = []
    for step in range(33):
        for cls in ("SF Dragon", "SF Manticore", "SF Mara"):
            records.append((
                "PRODUCTION", step * 60.0,
                dict(action="QUEUE_ACCEPTED", faction="RED", cost=1500.0, count=4,
                     tier=1, role="fighter", queuedAt=step * 60.0,
                     cpBefore=2500.0, cpAfter=1000.0)))
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "fleet_composition_not_degenerate")
    assert v["status"] == "FAIL"
    assert v["evidence"]["t1Only"] is True
    assert "T1-only" in v["evidence"]["reasons"]


def test_composition_warns_when_there_is_nothing_to_judge(tmp_path):
    records = [("FACTION", 100.0, dict(faction="BLUE", losses={},
                                       economy=dict(commandPoints=1.0, flow={})))]
    result = run_invariants(tmp_path, records)
    assert verdict_for(result, "fleet_composition_not_degenerate")["status"] == "WARN"


# --------------------------------------------------------------------------
# bank_target_reachable
# --------------------------------------------------------------------------

def test_bank_target_passes_when_the_peak_reached_it(tmp_path):
    records = healthy_faction_records(capital=True, start_cp=12000.0)
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "bank_target_reachable")
    assert v["status"] == "PASS"
    assert v["evidence"]["peakOverTarget"] >= ai.BANK_TARGET_REACH_RATIO


def test_bank_target_fails_when_the_peak_never_reached_it(tmp_path):
    """BAD-batch signature: bankTarget 8600 against a 1314 CP peak (ratio 0.15)."""
    records = healthy_faction_records(capital=False, start_cp=200.0)
    result = run_invariants(tmp_path, records)
    v = verdict_for(result, "bank_target_reachable")
    assert v["status"] == "FAIL"
    assert v["evidence"]["lowestBankTarget"] == 8600.0
    assert v["evidence"]["peakOverTarget"] < 0.5


def test_bank_target_ignores_targets_declared_before_tier3(tmp_path):
    """A tier-1 bankTarget is a different question; only tier>=3 gates."""
    records = []
    for step in range(20):
        records.append((
            "AI_BUILD_DECISION", step * 60.0,
            dict(faction="BLUE", desiredRole="fighter", tier=1,
                 reason=ai.SAVING_REASON, bankTarget=1400.0,
                 commandPoints=300.0)))
        records.append((
            "FACTION", step * 60.0, dict(faction="BLUE", losses={}, economy=dict(
                commandPoints=300.0, flow={}))))
    result = run_invariants(tmp_path, records)
    assert verdict_for(result, "bank_target_reachable")["status"] == "WARN"


# --------------------------------------------------------------------------
# regression: the known-good and known-bad shapes
# --------------------------------------------------------------------------

def _three_faction_batch(tmp_path, capital):
    """Three factions in one match, healthy or livelocked.

    Reproduces the per-faction numbers measured in the real batches so both
    regression tests below are driven by the same fixture.
    """
    records = []
    for faction, peak in (("BLUE", 11482.0), ("RED", 12270.0), ("GOLD", 13801.0)):
        bank_target = 7700.0 if faction == "RED" else 8600.0
        if capital:
            records.extend(healthy_faction_records(faction, True, start_cp=peak - 600.0))
        else:
            records.extend(healthy_faction_records(faction, False, start_cp=200.0))
        # every capital save decision in the real batches was tier-gated
        for _ in range(3):
            records.append((
                "AI_BUILD_DECISION", 100.0,
                dict(faction=faction, desiredRole="capital", tier=3,
                     reason=ai.SAVING_REASON, bankTarget=bank_target,
                     commandPoints=peak if capital else 200.0)))
    return records


def test_regression_known_good_shape_is_clean(tmp_path):
    """session-fix-20260930: 1 capital-class hull per faction per match,
    bank peaks 9.9k-13.8k against 7.7k-8.6k targets. Nothing may fire."""
    result = run_invariants(tmp_path, _three_faction_batch(tmp_path, capital=True))
    failures = [(m["match"], v["invariant"], v["faction"])
                for m in result["matches"] for v in m["verdicts"]
                if v["status"] == "FAIL"]
    assert failures == [], "known-good shape must be clean, got %s" % failures


def test_regression_roster_escalation_fires_on_the_known_bad_shape(tmp_path):
    """sentryfix-20261001: capital/heavy/juggernaut builds are ZERO in 12 of 12
    faction-matches. This is the regression the whole module exists for, and it
    is the shape every metric-based tool reported as merely 'mixed'."""
    result = run_invariants(tmp_path, _three_faction_batch(tmp_path, capital=False))
    verdicts = [v for m in result["matches"] for v in m["verdicts"]
                if v["invariant"] == "roster_escalation"]
    assert len(verdicts) == 3
    for v in verdicts:
        assert v["status"] == "FAIL", v
        assert v["evidence"]["capitalClassBuilds"] == 0
        assert v["evidence"]["maxTierBuilt"] <= 2


def test_regression_cp_drift_names_the_livelock_on_the_known_bad_shape(tmp_path):
    result = run_invariants(tmp_path, _three_faction_batch(tmp_path, capital=False))
    verdicts = [v for m in result["matches"] for v in m["verdicts"]
                if v["invariant"] == "cp_drift_not_persistently_negative"]
    assert len(verdicts) == 3
    for v in verdicts:
        assert v["status"] == "FAIL", v
        assert v["evidence"]["mechanism"] == "saving-claim-but-bank-pinned-at-floor"
        assert v["evidence"]["netRate"] < 0.0
        assert v["evidence"]["savingDecisions"] > 0


def test_regression_bank_reachability_names_the_livelock_too(tmp_path):
    result = run_invariants(tmp_path, _three_faction_batch(tmp_path, capital=False))
    verdicts = [v for m in result["matches"] for v in m["verdicts"]
                if v["invariant"] == "bank_target_reachable"]
    assert len(verdicts) == 3
    for v in verdicts:
        assert v["status"] == "FAIL", v
        assert v["evidence"]["peakOverTarget"] < ai.BANK_TARGET_REACH_RATIO


def test_regression_the_two_batches_differ_on_exactly_the_escalation_signal(tmp_path):
    """A linter that fires on everything is worthless. Pinned here so a future
    tolerance change that collapses the two batches together is caught."""
    good = run_invariants(tmp_path, _three_faction_batch(tmp_path, capital=True))
    bad_dir = tmp_path / "bad"
    bad_dir.mkdir()
    bad = run_invariants(bad_dir, _three_faction_batch(bad_dir, capital=False))

    def fired(result, invariant):
        return any(v["status"] == "FAIL"
                   for m in result["matches"] for v in m["verdicts"]
                   if v["invariant"] == invariant)

    for invariant in ("roster_escalation",
                      "cp_drift_not_persistently_negative",
                      "bank_target_reachable"):
        assert not fired(good, invariant), "%s must not fire on the good shape" % invariant
        assert fired(bad, invariant), "%s must fire on the bad shape" % invariant

    # The accounting invariants stay quiet on BOTH shapes: they are about
    # consistency, not about winning, and must not become proxies for quality.
    for invariant in ("production_spend_reconciles", "losses_reconcile",
                      "no_orphan_builds"):
        assert not fired(good, invariant), invariant
        assert not fired(bad, invariant), invariant


# --------------------------------------------------------------------------
# CLI / gating
# --------------------------------------------------------------------------

def test_main_requires_clean_exits_one_on_violation(tmp_path, capsys):
    write_match(tmp_path, _three_faction_batch(tmp_path, capital=False))
    assert ai.main(["--require-clean", str(tmp_path)]) == 1
    out = capsys.readouterr().out
    assert "FAIL roster_escalation" in out
    assert "SUMMARY checks=" in out
    assert "failures=" in out


def test_main_requires_clean_exits_zero_on_a_clean_batch(tmp_path, capsys):
    write_match(tmp_path, _three_faction_batch(tmp_path, capital=True))
    assert ai.main(["--require-clean", str(tmp_path)]) == 0
    out = capsys.readouterr().out
    assert "failures=0" in out


def test_main_report_mode_exits_one_when_an_invariant_fails(tmp_path, capsys):
    write_match(tmp_path, _three_faction_batch(tmp_path, capital=False))
    assert ai.main([str(tmp_path)]) == 1
    out = capsys.readouterr().out
    assert "SUMMARY" in out and "fail=" in out


def test_main_json_mode_is_machine_readable(tmp_path, capsys):
    write_match(tmp_path, _three_faction_batch(tmp_path, capital=True))
    assert ai.main(["--json", str(tmp_path)]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["matches"]
    first = payload["matches"][0]["verdicts"][0]
    assert set(first) == {"invariant", "match", "faction", "status",
                          "evidence", "explanation"}


def test_every_invariant_reports_a_mechanism_explanation(tmp_path):
    """Requirement 3: every invariant reports name, verdict, evidence numbers
    and a one-line explanation of the mechanism it detects."""
    result = run_invariants(tmp_path, _three_faction_batch(tmp_path, capital=False))
    seen = set()
    for match in result["matches"]:
        for v in match["verdicts"]:
            seen.add(v["invariant"])
            assert v["status"] in ("PASS", "FAIL", "WARN"), v
            assert v["explanation"], v
            assert v["evidence"], v
            assert v["faction"] and v["match"]
    assert seen == set(ai.EXPLANATIONS), (seen, set(ai.EXPLANATIONS))
    for name, text in ai.EXPLANATIONS.items():
        assert len(text) > 40, name


def test_every_registered_check_is_covered_by_an_explanation():
    assert set(ai.EXPLANATIONS) == set(ai.CHECK_NAMES)


def test_no_check_leaves_the_invariant_unnamed(tmp_path):
    """A new check added without an explanation must fail here rather than
    silently producing a nameless row in a CI log."""
    assert len(ai.CHECKS) == len(ai.CHECK_NAMES)
