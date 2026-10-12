"""Self-tests for compare_batches.

Covers the four failure modes that a batch comparison has to survive:

* the cumulative-vs-interval productionSpend trap, where reading the last
  FACTION record reports 0.0 for an AI that spent plenty,
* a truncated final JSONL line from a run that was killed mid-write,
* unequal match counts between baseline and candidate,
* the --fail-on exit code, in both directions and with a polarity override.

Run from the tools directory (the working directory matters for the other Lua
tests in this package):

    cd core/tools; python -m pytest -q
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parent
REPO_ROOT = TOOLS.parents[1]
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import compare_batches as cb  # noqa: E402


# ---------------------------------------------------------------------------
# synthetic fixture writer
# ---------------------------------------------------------------------------

def rec(event, time, data, sequence=0):
    return {"schema": 2, "event": event, "time": float(time),
            "sequence": float(sequence), "data": data}


def faction(name, time, cp, spend_interval, income_interval, **extra):
    """One FACTION record. spend_interval/income_interval are INTERVAL flows,
    exactly as the real telemetry reports them."""
    data = {
        "faction": name,
        "combatants": extra.get("combatants", 10.0),
        "idle": extra.get("idle", 2.0),
        "engaged": extra.get("engaged", 6.0),
        "stalled": 0.0,
        "mismatch": 0.0,
        "received": extra.get("received", 1000.0),
        "damageDealt": extra.get("damage_dealt", "unknown"),
        "unitSeconds": 100.0,
        "unengagedSeconds": extra.get("unengaged", 40.0),
        "engagementDelaySum": 5.0,
        "engagementSamples": 5.0,
        "replacementValue": 20000.0,
        "stationHull": extra.get("hull", 9000.0),
        "stationMax": 10000.0,
        "losses": extra.get("losses", {}),
        "replacementValueByClass": {},
        "composition": {},
        "objectives": {},
        "plan": {"posture": "BALANCED", "canPush": extra.get("can_push", False),
                 "missionCounts": {"PRIMARY": 3.0}, "time": time},
        "economy": {
            "commandPoints": cp,
            "queueDepth": extra.get("queue_depth", 0.0),
            "fleetCap": 64.0,
            "combatants": extra.get("combatants", 10.0),
            "committedUnits": extra.get("combatants", 10.0),
            # The interval flow. Never a running total.
            "flow": {"income": income_interval, "productionSpend": spend_interval,
                     "refund": 0.0, "bounty": 0.0},
        },
    }
    if "upgrade_spend" in extra or "repair_unlocked" in extra:
        data["economy"]["upgradeSpend"] = extra.get("upgrade_spend", 0.0)
        data["economy"]["upgradeLevels"] = {"armor": 0, "defenses": 0,
                                            "logistics": 0, "command": 0}
        data["economy"]["repairUnlocked"] = extra.get("repair_unlocked", False)
    if "flow_cumulative" in extra:
        data["economy"]["flowCumulative"] = {
            "income": 0.0, "productionSpend": extra["flow_cumulative"],
            "bounty": 0.0, "refund": 0.0}
    return rec("FACTION", time, data)


def cp_spend(name, time, amount, flow="productionSpend", cp_after=None):
    """One CP_SPEND ledger record: a single CP movement through
    RecordAIEconomyFlow, the chokepoint that writes the interval flow."""
    data = {"faction": name, "flow": flow, "amount": float(amount)}
    if cp_after is not None:
        data["cpAfter"] = float(cp_after)
        data["cpBefore"] = float(cp_after) + float(amount)
    return rec("CP_SPEND", time, data)


def service_work(name, time, spent, total_spent=None):
    """Fleet service labour. `spent` is this tick's charge out of the faction
    bank; `totalSpent` is the ship's running total and must never be summed."""
    return rec("FLEET_SERVICE_WORK", time, {
        "faction": name, "ship": 1.0, "healed": 10.0, "subsystemRepair": 0.0,
        "spent": float(spent), "totalSpent": float(
            spent if total_spent is None else total_spent),
        "hull": 900.0, "ammo": 1.0,
    })


def station_repair(name, time, repaired, total, hull=None, ceiling=None):
    data = {"faction": name, "hull": 10000.0, "maxHull": 10000.0,
            "repaired": float(repaired), "totalRepaired": float(total),
            "scarHull": 0.0, "repairCeiling": 10000.0}
    if hull is not None:
        data["hull"] = float(hull)
    if ceiling is not None:
        data["repairCeiling"] = float(ceiling)
    return rec("STATION_REPAIR", time, data)


def production(name, time, cost, action="QUEUE_ACCEPTED", cp_before=None, cp_after=None):
    return rec("PRODUCTION", time, {
        "faction": name, "action": action, "class": "GTF Ulysses", "cost": cost,
        "count": 1.0, "role": "fighter", "tier": 1.0, "producer": "AI",
        "cpBefore": cp_before, "cpAfter": cp_after,
    })


def counters(time, decisions, attempts, success, failed=0.0, rejected=0.0,
             unchanged=0.0, switches=0.0, retained=0.0, reissued=0.0,
             native_changes=0.0):
    return rec("COUNTERS", time, {
        "decisions": decisions, "nativeChanges": native_changes,
        "orders": {"attempts": attempts, "byMission": {}, "byResult": {},
                   "success": success, "failed": failed, "rejected": rejected,
                   "unchanged": unchanged},
        "reissued": reissued, "retained": retained, "switches": switches,
    })


def build_decision(name, time, reason, role="fighter", cp=1000.0, target=1400.0,
                   affordable=6.0, unlocked=8.0):
    return rec("AI_BUILD_DECISION", time, {
        "faction": name, "reason": reason, "desiredRole": role,
        "affordableOptions": affordable, "unlockedOptions": unlocked,
        "bankTarget": target, "commandPoints": cp, "slots": 6.0,
    })


def execution(name, time, status="NATIVE_TARGET_ACQUIRED", mode="APPROACHING",
              goal=True, pursuit=False):
    return rec("EXECUTION", time, {
        "faction": name, "ship": 1.0, "status": status, "mode": mode,
        "goalPresent": goal, "pursuit": pursuit,
    })


def write_match(batch: Path, index: int, records, truncate_last: bool = False,
                match_count_hint: int = 1) -> Path:
    """Write one match's telemetry into a batch layout that mirrors the real
    harvest: results/w/<worker>/a-<id>/probe/data/rts-ai-*.jsonl."""
    run = (batch / "results" / "w" / f"worker{index:02d}" / f"a-1000{index}"
           / "probe" / "data")
    run.mkdir(parents=True, exist_ok=True)
    path = run / f"rts-ai-20260930-{index:06d}.jsonl"
    records = [dict(record, sequence=i+1) for i, record in enumerate(records)]
    text = "".join(json.dumps(r) + "\n" for r in records)
    if truncate_last:
        # Drop the newline AND most of the final record, the way a killed
        # process leaves a partial write.
        text = text[: text.rfind("\n") + 1] + '{"schema":2,"event":"FACTION","ti'
    path.write_text(text, encoding="utf-8")
    from test_run_evidence import freeze_fixture
    freeze_fixture(batch, sorted({p.parent.parent.parent for p in batch.rglob('rts-ai-*.jsonl')}))
    return path


# ---------------------------------------------------------------------------
# 1. the cumulative-vs-interval productionSpend trap
# ---------------------------------------------------------------------------

def test_interval_flow_spend_is_summed_not_read_off_the_last_record(tmp_path):
    """The trap: the last FACTION record's productionSpend is 0.0 while the AI
    spent plenty over the match. Summing the interval is the only correct read."""
    records = []
    interval = 500.0
    for step in range(1, 11):
        # The FINAL sample deliberately spends nothing, which is what makes the
        # naive last-record read report 0.0.
        spend = 0.0 if step == 10 else interval
        records.append(faction("BLUE", step * 10.0, 1000.0, spend, 100.0))
    batch = tmp_path / "trap"
    path = write_match(batch, 0, records)

    match = cb.stream_match(path)
    vec = cb._match_vector(match)

    acc = match["factions"]["BLUE"]
    assert acc.last_flow_spend == 0.0, (
        "fixture must reproduce the trap: the last interval is 0.0")
    assert vec["cp_spent_flow"] == pytest.approx(9 * interval)
    assert vec["cp_spent_flow"] > 0.0

    # PRODUCTION events are summed independently and must agree with the flow.
    records = records + [production("BLUE", 10.0, 500.0, cp_before=1000.0,
                                    cp_after=500.0) for _ in range(9)]
    path = write_match(batch, 0, records)
    match = cb.stream_match(path)
    vec = cb._match_vector(match)
    assert vec["cp_spent_production"] == pytest.approx(9 * interval)
    assert vec["cp_spent_flow_gap"] == pytest.approx(0.0), (
        "flow sum and PRODUCTION sum must reconcile; a gap means one of them "
        "was read as a running total instead of an interval")


def test_single_last_record_read_would_have_reported_zero(tmp_path):
    """Directly assert the wrong answer is zero, so the test fails loudly if a
    future change makes the fixture stop exercising the trap."""
    records = [faction("BLUE", 10.0, 1000.0, 0.0, 100.0),
               faction("BLUE", 20.0, 1000.0, 750.0, 100.0),
               faction("BLUE", 30.0, 1000.0, 0.0, 100.0)]
    path = write_match(tmp_path / "trap2", 0, records)
    match = cb.stream_match(path)
    acc = match["factions"]["BLUE"]

    naive_last_record = acc.last_flow_spend
    assert naive_last_record == 0.0
    assert acc.flow_spend == pytest.approx(750.0)
    assert cb._match_vector(match)["cp_spent_flow"] == pytest.approx(750.0)


def test_engine_result_absence_is_not_a_failure(tmp_path):
    """These batches end on the simulation cap, so engine-result.json is never
    written. That must be reportable state, never a crash or a failure."""
    records = [faction("BLUE", 10.0, 500.0, 100.0, 50.0),
               faction("BLUE", 20.0, 400.0, 0.0, 50.0)]
    batch = tmp_path / "noengine"
    write_match(batch, 0, records)
    for result in batch.rglob('engine-result.json'):
        result.unlink()
    loaded = cb.load_batch(batch, "baseline")

    assert len(loaded) == 1
    assert loaded[0]["engine_result_path"] is None
    assert loaded[0]["termination"] == "telemetry-only (termination unverified)"
    assert loaded[0]["vector"]["engine_result"] == 0.0
    assert loaded[0]["vector"]["records"] == 2


# ---------------------------------------------------------------------------
# 2. a truncated final line
# ---------------------------------------------------------------------------

def test_truncated_final_line_is_tolerated_and_reported(tmp_path):
    records = [faction("BLUE", 10.0, 1000.0, 200.0, 50.0),
               production("BLUE", 10.0, 200.0),
               faction("BLUE", 20.0, 800.0, 0.0, 50.0),
               counters(20.0, 40.0, 10.0, 10.0)]
    batch = tmp_path / "trunc"
    path = write_match(batch, 0, records, truncate_last=True)

    loaded = cb.load_batch(batch, "baseline")  # must not raise
    vec = loaded[0]["vector"]
    assert vec["truncated_tail"] == 1.0
    assert vec["malformed_lines"] == 1.0
    assert vec["records"] == 4, "the three good records must still be counted"
    assert vec["cp_spent_flow"] == pytest.approx(200.0)
    assert vec["order_attempts"] == 10.0


def test_malformed_line_in_the_middle_is_tolerated(tmp_path):
    batch = tmp_path / "midbad"
    run = (batch / "results" / "w" / "w0" / "a-1" / "probe" / "data")
    run.mkdir(parents=True)
    path = run / "rts-ai-20260930-000000.jsonl"
    path.write_text(
        json.dumps(faction("BLUE", 10.0, 1000.0, 100.0, 10.0)) + "\n"
        + "this is not json at all\n"
        + json.dumps(faction("BLUE", 20.0, 900.0, 50.0, 10.0)) + "\n",
        encoding="utf-8")
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["malformed_lines"] == 1.0
    assert vec["records"] == 2
    assert vec["cp_spent_flow"] == pytest.approx(150.0)


# ---------------------------------------------------------------------------
# 3. unequal match counts
# ---------------------------------------------------------------------------

def make_two_spends(tmp_path, name, count, spend_per_match):
    """count matches, each spending spend_per_match CP via interval flow."""
    batch = tmp_path / name
    for index in range(count):
        records = [faction("BLUE", 10.0, 1000.0, spend_per_match, 10.0),
                   faction("BLUE", 20.0, 900.0, 0.0, 10.0),
                   counters(20.0, 20.0, 5.0, 5.0)]
        write_match(batch, index, records)
    return batch


def test_unequal_match_counts_are_reported_not_fatal(tmp_path):
    base = make_two_spends(tmp_path, "b", 2, 300.0)
    cand = make_two_spends(tmp_path, "c", 5, 300.0)

    base_matches = cb.load_batch(base, "baseline")
    cand_matches = cb.load_batch(cand, "candidate")
    assert (len(base_matches), len(cand_matches)) == (2, 5)

    report = cb.build_report(base_matches, cand_matches, base, cand)
    assert any("UNEQUAL MATCH COUNTS" in w for w in report["warnings"])
    assert report["verdict"]["overall"] == "not_evaluated"

    row = next(r for r in report["metric_rows"] if r["metric"] == "cp_spent_flow")
    assert row["baseline_matches"] == 2
    assert row["candidate_matches"] == 5
    assert row["delta"] == pytest.approx(0.0)


def test_more_matches_on_one_side_does_not_change_the_median(tmp_path):
    base = make_two_spends(tmp_path, "b2", 2, 300.0)
    cand = make_two_spends(tmp_path, "c2", 6, 300.0)
    report = cb.build_report(cb.load_batch(base, "baseline"),
                             cb.load_batch(cand, "candidate"), base, cand)
    row = next(r for r in report["metric_rows"] if r["metric"] == "cp_spent_flow")
    assert row["baseline_median"] == row["candidate_median"] == pytest.approx(300.0)


# ---------------------------------------------------------------------------
# 4. --fail-on exit code
# ---------------------------------------------------------------------------

def run_cli(*argv):
    """Run the CLI as a subprocess from the repo root, proving the paths work
    from there as well as from the tools directory."""
    return subprocess.run(
        [sys.executable, str(TOOLS / "compare_batches.py"), '--until', '20', *[str(a) for a in argv]],
        cwd=str(REPO_ROOT), capture_output=True, text=True)


def test_fail_on_exits_nonzero_when_metric_regresses(tmp_path):
    base = make_two_spends(tmp_path, "b3", 4, 900.0)
    cand = make_two_spends(tmp_path, "c3", 4, 200.0)

    out = tmp_path / "regress.json"
    result = run_cli(base, cand, "--json", out, "--no-per-match", "--no-histograms",
                     "--fail-on", "cp_spent_flow", "--polarity", "cp_spent_flow=higher")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "FAIL cp_spent_flow" in result.stdout

    payload = json.loads(out.read_text(encoding="utf-8"))
    assert payload["verdict"]["overall"] == "fail"
    assert [f["metric"] for f in payload["verdict"]["failures"]] == ["cp_spent_flow"]
    assert payload["verdict"]["failures"][0]["delta"] < 0


def test_fail_on_exits_zero_when_metric_improves(tmp_path):
    base = make_two_spends(tmp_path, "b4", 4, 200.0)
    cand = make_two_spends(tmp_path, "c4", 4, 900.0)

    result = run_cli(base, cand, "--no-per-match", "--no-histograms",
                     "--fail-on", "cp_spent_flow", "--polarity", "cp_spent_flow=higher")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "overall: PASS" in result.stdout


def test_polarity_override_flips_the_verdict(tmp_path):
    """Explicit experiment goals can request either direction; counts alone have none."""
    base = make_two_spends(tmp_path, "b5", 4, 900.0)
    cand = make_two_spends(tmp_path, "c5", 4, 200.0)

    normal = run_cli(base, cand, "--no-per-match", "--no-histograms",
                     "--fail-on", "cp_spent_flow", "--polarity", "cp_spent_flow=higher")
    assert normal.returncode == 1

    flipped = run_cli(base, cand, "--no-per-match", "--no-histograms",
                      "--fail-on", "cp_spent_flow", "--polarity", "cp_spent_flow=lower")
    assert flipped.returncode == 0, flipped.stdout + flipped.stderr
    assert "better" in flipped.stdout


def test_polarity_none_cannot_silently_disable_a_gate(tmp_path):
    base = make_two_spends(tmp_path, "b6", 4, 900.0)
    cand = make_two_spends(tmp_path, "c6", 4, 200.0)
    result = run_cli(base, cand, "--no-per-match", "--no-histograms",
                     "--fail-on", "cp_spent_flow", "--polarity", "cp_spent_flow=none")
    assert result.returncode == 2, result.stdout + result.stderr
    assert 'explicit direction' in result.stderr


def test_inconclusive_metric_cannot_pass_the_gate(tmp_path):
    """Four matches per side, but every match has the same value, so a changed
    value on the candidate side is a real separation. Give both sides huge
    spread instead: a small median shift inside the spread must not fail."""
    base = tmp_path / "b7"
    cand = tmp_path / "c7"
    for index, spend in enumerate((100.0, 5000.0, 200.0, 4800.0)):
        write_match(base, index, [faction("BLUE", 10.0, 1000.0, spend, 10.0),
                                  faction("BLUE", 20.0, 900.0, 0.0, 10.0)])
    for index, spend in enumerate((110.0, 5100.0, 210.0, 4900.0)):
        write_match(cand, index, [faction("BLUE", 10.0, 1000.0, spend, 10.0),
                                  faction("BLUE", 20.0, 900.0, 0.0, 10.0)])

    result = run_cli(base, cand, "--no-per-match", "--no-histograms",
                     "--fail-on", "cp_spent_flow", "--polarity", "cp_spent_flow=higher")
    assert result.returncode == 2, result.stdout + result.stderr
    assert "INCONCLUSIVE cp_spent_flow" in result.stdout


def test_unknown_metric_and_bad_polarity_are_usage_errors(tmp_path):
    base = make_two_spends(tmp_path, "b8", 1, 100.0)
    bad_metric = run_cli(base, base, "--fail-on", "not_a_metric")
    assert bad_metric.returncode != 0
    assert "unknown metric" in (bad_metric.stdout + bad_metric.stderr)

    bad_polarity = run_cli(base, base, "--polarity", "cp_spent_flow=sideways")
    assert bad_polarity.returncode != 0
    assert "higher, lower or none" in (bad_polarity.stdout + bad_polarity.stderr)


def test_cli_runs_from_the_tools_directory(tmp_path):
    """The other tests in this package need the tools directory as cwd, so the
    tool has to work from there too."""
    base = make_two_spends(tmp_path, "b9", 2, 400.0)
    cand = make_two_spends(tmp_path, "c9", 2, 400.0)
    result = subprocess.run(
        [sys.executable, str(TOOLS / "compare_batches.py"), str(base), str(cand),
         "--no-per-match", "--no-histograms"],
        cwd=str(TOOLS), capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "overall: NOT_EVALUATED" in result.stdout


# ---------------------------------------------------------------------------
# metric extraction
# ---------------------------------------------------------------------------

def test_order_counters_and_rates(tmp_path):
    records = [
        faction("BLUE", 10.0, 1000.0, 100.0, 10.0),
        counters(10.0, decisions=100.0, attempts=10.0, success=7.0, failed=1.0,
                 rejected=1.0, unchanged=1.0, switches=20.0, retained=70.0,
                 reissued=3.0, native_changes=9.0),
    ]
    path = write_match(tmp_path / "orders", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["order_attempts"] == 10.0
    assert vec["order_success_rate"] == pytest.approx(0.7)
    assert vec["order_failed_rate"] == pytest.approx(0.1)
    assert vec["order_rejected_rate"] == pytest.approx(0.1)
    assert vec["order_unchanged_rate"] == pytest.approx(0.1)
    assert vec["order_reissue_rate"] == pytest.approx(0.3)
    assert vec["decision_switch_rate"] == pytest.approx(0.2)
    assert vec["decision_retain_rate"] == pytest.approx(0.7)
    assert vec["native_change_rate"] == pytest.approx(0.09)


def test_build_decision_reasons_and_bank_shortfall(tmp_path):
    records = [
        build_decision("BLUE", 10.0, "PURCHASE_SELECTED", cp=2000.0, target=1400.0),
        build_decision("BLUE", 11.0, "INSUFFICIENT_CP", cp=500.0, target=1400.0),
        build_decision("BLUE", 12.0, "INSUFFICIENT_CP", cp=600.0, target=1400.0),
        build_decision("BLUE", 13.0, "SAVING_FOR_DESIRED_ROLE", role="capital",
                       cp=1000.0, target=1400.0),
    ]
    path = write_match(tmp_path / "build", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["build_decisions"] == 4.0
    assert vec["build_purchase_rate"] == pytest.approx(0.25)
    assert vec["build_insufficient_rate"] == pytest.approx(0.5)
    assert vec["build_saving_rate"] == pytest.approx(0.25)
    assert vec["build_bank_shortfall_mean"] == pytest.approx((0.0 + 900.0 + 800.0 + 400.0) / 4)
    hist = cb.match_histograms(cb.stream_match(path))
    assert hist["hist.build_reason"]["INSUFFICIENT_CP"] == 2
    assert hist["hist.build_role"]["capital"] == 1


def test_execution_histograms_and_rates(tmp_path):
    records = [
        execution("BLUE", 10.0, status="NO_OBJECTIVE", mode="IDLE", goal="unknown"),
        execution("BLUE", 11.0, status="NATIVE_TARGET_ACQUIRED", mode="ENGAGED"),
        execution("BLUE", 12.0, status="NATIVE_TARGET_ACQUIRED", mode="APPROACHING",
                  pursuit=True),
        execution("BLUE", 13.0, status="NATIVE_TARGET_ACQUIRED", mode="APPROACHING"),
    ]
    path = write_match(tmp_path / "exec", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["exec_total"] == 4.0
    assert vec["exec_no_objective_rate"] == pytest.approx(0.25)
    assert vec["exec_idle_mode_rate"] == pytest.approx(0.25)
    assert vec["exec_unknown_goal_rate"] == pytest.approx(0.25)
    assert vec["exec_pursuit_rate"] == pytest.approx(0.25)


def sentry(time, cost, action="BUILD_STARTED"):
    return rec("SENTRY_BUILD", time, {"faction": "RED", "action": action,
                                      "class": "SSG Trident", "cost": cost,
                                      "startedAt": time, "finishAt": time + 20.0})


def test_sentry_spend_is_counted_and_closes_the_reconciliation(tmp_path):
    """Sentries are bought through SENTRY_BUILD, not PRODUCTION. Leaving that out
    hides the whole sentry budget inside the flow reconciliation gap."""
    records = [
        faction("BLUE", 10.0, 1000.0, 300.0, 10.0),
        production("BLUE", 10.0, 300.0),
        sentry(11.0, 375.0),
        sentry(12.0, 375.0),
        sentry(13.0, 375.0, action="BUILD_CANCELLED"),
    ]
    path = write_match(tmp_path / "sentry", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["sentry_builds"] == 2.0, "only BUILD_STARTED spends CP"
    assert vec["sentry_spend"] == pytest.approx(750.0)
    assert vec["cp_spent_events_total"] == pytest.approx(300.0 + 750.0)
    assert vec["cp_spent_flow_gap"] == pytest.approx(1050.0 - 300.0)


def test_reconciliation_gap_is_near_zero_when_totals_agree(tmp_path):
    """The real batches reconcile to within ~0.2% once sentries are included,
    which is the proof that the interval flow is being summed and not read off
    the last record."""
    spend = 1000.0
    records = []
    for step in range(1, 8):
        records.append(faction("BLUE", step * 10.0, 500.0,
                               spend if step < 7 else 0.0, 10.0))
        if step < 7:
            records.append(production("BLUE", step * 10.0, spend))
    path = write_match(tmp_path / "recon", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["cp_spent_flow"] == pytest.approx(6 * spend)
    assert vec["cp_spent_events_total"] == pytest.approx(6 * spend)
    assert vec["cp_spent_flow_gap"] == pytest.approx(0.0)


def test_cp_spend_ledger_reconciles_against_the_interval_flow(tmp_path):
    """CP_SPEND is one record per CP movement through RecordAIEconomyFlow, the
    same chokepoint that writes economy.flow.productionSpend. Two views of one
    number, so they must agree exactly. This is the assertion that catches a
    CP movement silently ceasing to be recorded, which used to surface only as
    a slowly growing gap between the flow and the purchase events."""
    records = [
        cp_spend("BLUE", 10.0, 300.0),
        faction("BLUE", 10.0, 1000.0, 300.0, 10.0, flow_cumulative=300.0),
        cp_spend("BLUE", 40.0, 625.0),
        faction("BLUE", 40.0, 700.0, 625.0, 10.0, flow_cumulative=925.0),   # upgrade
        cp_spend("GOLD", 40.0, 750.0),
        faction("GOLD", 40.0, 900.0, 750.0, 10.0, flow_cumulative=750.0),   # ability
    ]
    path = write_match(tmp_path / "ledger", 0, records)
    match = cb.stream_match(path)
    vec = cb._match_vector(match)
    assert match["cp_spend_ledger"] == pytest.approx(1675.0)
    assert match["flow_cumulative_total"] == pytest.approx(1675.0)
    assert vec["cp_spend_ledger"] == pytest.approx(1675.0)
    assert vec["cp_flow_cumulative"] == pytest.approx(1675.0)
    assert vec["cp_spend_drift"] == pytest.approx(0.0)
    # No purchase event exists for any of it, so the flow/event gap is the whole
    # total. That is expected, not a defect: cp_upgrade_spend explains it.
    assert vec["cp_spent_flow_gap"] == pytest.approx(-1675.0)


def test_flow_cumulative_covers_spend_after_the_last_faction_record(tmp_path):
    """economy.flow is zeroed the moment FACTION publishes it, so spend made
    after a match's final FACTION record lands in an interval nobody reports and
    the summed intervals come up short. flowCumulative is the running total that
    does not have that hole, and it is a gauge: last snapshot, never a sum."""
    records = [
        faction("BLUE", 10.0, 1000.0, 300.0, 10.0, flow_cumulative=300.0),
        faction("BLUE", 40.0, 700.0, 400.0, 10.0, flow_cumulative=700.0),
    ]
    path = write_match(tmp_path / "tail", 0, records)
    match = cb.stream_match(path)
    vec = cb._match_vector(match)
    assert vec["cp_spent_flow"] == pytest.approx(700.0), "intervals only"
    assert vec["cp_flow_cumulative"] == pytest.approx(700.0), "the last snapshot"
    assert match["flow_cumulative_total"] == pytest.approx(700.0), \
        "summing the gauge would give 1000.0"


def test_cp_spend_drift_is_nonzero_when_a_deduction_is_unrecorded(tmp_path):
    """The regression this metric exists for: a CP movement that stops reaching
    RecordAIEconomyFlow leaves the ledger short of the flow, which is exactly
    the failure that made ~10% of spend unattributable in the first place."""
    records = [
        faction("BLUE", 10.0, 1000.0, 300.0, 10.0, flow_cumulative=300.0),
        cp_spend("BLUE", 10.0, 300.0),
        faction("BLUE", 40.0, 700.0, 700.0, 10.0, flow_cumulative=1000.0),
    ]
    path = write_match(tmp_path / "drift", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["cp_spent_flow"] == pytest.approx(1000.0)
    assert vec["cp_flow_cumulative"] == pytest.approx(1000.0)
    assert vec["cp_spend_ledger"] == pytest.approx(300.0)
    assert vec["cp_spend_drift"] == pytest.approx(-700.0)


def test_cp_spend_drift_is_undefined_not_alarming_on_a_batch_without_the_ledger(tmp_path):
    """A batch predating CP_SPEND has no second view of the spend, so drift is
    undefined. Reporting the raw -flow there would present every legacy batch as
    a catastrophic reconciliation failure."""
    records = [faction("BLUE", 10.0, 1000.0, 1000.0, 10.0)]
    path = write_match(tmp_path / "legacy", 0, records)
    match = cb.stream_match(path)
    vec = cb._match_vector(match)
    assert match["cp_spend_entries"] == 0
    assert vec["cp_spent_flow"] == pytest.approx(1000.0)
    assert vec["cp_spend_drift"] == pytest.approx(0.0)


def test_fleet_service_labour_is_counted_as_a_spend_path(tmp_path):
    """FLEET_SERVICE_WORK.spent is CP out of the same bank and lands in the same
    interval flow, so the event-sourced total has to include it. Its sibling
    totalSpent is a per-ship running total: summing that instead would multiply
    the charge by the tick count, which is why it is not read."""
    records = [
        faction("BLUE", 10.0, 1000.0, 500.0, 10.0),
        service_work("BLUE", 11.0, 50.0),
        service_work("BLUE", 13.0, 50.0, total_spent=100.0),
        service_work("BLUE", 15.0, 50.0, total_spent=150.0),
        production("BLUE", 16.0, 300.0),
    ]
    path = write_match(tmp_path / "service", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["service_spent"] == pytest.approx(150.0), "spent is per tick, not the running total"
    assert vec["cp_spent_events_total"] == pytest.approx(300.0 + 150.0)
    assert vec["cp_spent_flow_gap"] == pytest.approx(-50.0)


def test_station_repair_zero_is_attributed_to_the_armor_gate(tmp_path):
    """STATION_REPAIR reporting zero hull restored is normally the ARMOR L2 gate
    or a station that never sat below its ceiling. Both are now visible, so a
    zero reads as a gate instead of as a broken emitter. Before this, the metric
    was indistinguishable from dead telemetry."""
    locked = [
        faction("BLUE", 10.0, 1000.0, 0.0, 10.0, repair_unlocked=False),
        station_repair("BLUE", 400.0, 0.0, 0.0, hull=10000.0, ceiling=10000.0),
    ]
    vec = cb._match_vector(cb.stream_match(write_match(tmp_path / "locked", 0, locked)))
    assert vec["station_repairs"] == 1.0
    assert vec["station_repaired_hull"] == pytest.approx(0.0)
    assert vec["station_repair_below_ceiling"] == 0.0
    assert vec["station_repair_unlocked_factions"] == 0.0, \
        "no faction reached ARMOR L2, so the zero is the gate"
    assert vec["station_repaired_cumulative"] == pytest.approx(0.0)

    unlocked = [
        faction("BLUE", 10.0, 1000.0, 0.0, 10.0, repair_unlocked=True),
        station_repair("BLUE", 400.0, 2500.0, 9000.0, hull=7000.0, ceiling=9500.0),
        station_repair("BLUE", 430.0, 1500.0, 10500.0, hull=7500.0, ceiling=9500.0),
    ]
    vec = cb._match_vector(cb.stream_match(write_match(tmp_path / "unlocked", 0, unlocked)))
    assert vec["station_repaired_hull"] == pytest.approx(4000.0), "summed increments"
    assert vec["station_repaired_cumulative"] == pytest.approx(10500.0), \
        "cumulative is a max per faction, never a sum of running totals"
    assert vec["station_repair_below_ceiling"] == 2.0
    assert vec["station_repair_unlocked_factions"] == 1.0


def test_upgrade_spend_is_read_as_a_cumulative_gauge(tmp_path):
    """economy.upgradeSpend only ever rises as tracks are bought, so it is a
    running total: the last snapshot is the value, and summing the series would
    multiply it by the sample count."""
    records = [
        faction("BLUE", 10.0, 1000.0, 0.0, 10.0, upgrade_spend=0.0),
        faction("BLUE", 40.0, 1000.0, 0.0, 10.0, upgrade_spend=625.0),
        faction("BLUE", 70.0, 1000.0, 0.0, 10.0, upgrade_spend=625.0),
        faction("GOLD", 70.0, 1000.0, 0.0, 10.0, upgrade_spend=1875.0),
    ]
    path = write_match(tmp_path / "upgrades", 0, records)
    match = cb.stream_match(path)
    assert match["upgrade_spend_last"] == {"BLUE": 625.0, "GOLD": 1875.0}
    vec = cb._match_vector(match)
    assert vec["cp_upgrade_spend"] == pytest.approx(2500.0)


def test_capital_class_detection():
    # FALLBACK behaviour only. classify_role consults ROSTER_ROLES first - the
    # role the batch's own PRODUCTION records declare, which is authoritative.
    # These prefixes are what is left for a class never observed being built.
    # fs2rts_config.lua does NOT align roles to prefixes: GTC Fenris, GTC
    # Leviathan and GVC Mentu are all role="escort" (config.lua:952-955) while
    # GTCv Deimos is role="capital", and all four share a prefix. So do not read
    # this list as ground truth about roles - see
    # test_classify_role_prefers_roster_over_prefix below.
    for name in ("GTCv Deimos", "GTC Fenris", "GTC Leviathan", "GVD Typhon",
                 "GTD Orion", "SJ Sathanas", "SD Lucifer", "GVC Mentu"):
        assert cb.classify_role(name), name
    for name in ("GTF Perseus", "GTB Zeus", "GVF Tauret", "GTSG Cerberus",
                 "GTSG Watchdog", "SSG Trident", "GTF Hercules Mark II"):
        assert not cb.classify_role(name), name


def test_classify_role_prefers_roster_over_prefix():
    # The bug this locks: GTC/GVC prefixes were the ONLY rule, so every escort
    # and bomber sharing one was counted as a capital loss. Measured on
    # capgate-20261001: 9 of 10 "capital" losses were escort-class GVC Aten and
    # GTC Aeolus. Ground truth from that batch's own PRODUCTION records: 9
    # capital-role hulls spawned, 1 died.
    saved = dict(cb.ROSTER_ROLES)
    try:
        cb.ROSTER_ROLES.clear()
        # No roster known: the prefix fallback still mislabels these, which is
        # why it must never be the primary rule.
        assert cb.classify_role("GTC Aeolus"), "prefix fallback is what we are fixing"
        cb.ROSTER_ROLES.update({
            "GTC Aeolus": "escort",    # config.lua:386 role="escort"
            "GVC Aten": "escort",      # config.lua:1039 role="escort"
            "GVB Bakha": "escort",
            "GTCv Deimos": "capital",  # config.lua:956 role="capital"
            "GTVA Colossus": "juggernaut",
            "GTD Hecate": "heavy",
        })
        for escort in ("GTC Aeolus", "GVC Aten", "GVB Bakha"):
            assert not cb.classify_role(escort), escort
        for capital in ("GTCv Deimos", "GTVA Colossus", "GTD Hecate"):
            assert cb.classify_role(capital), capital
    finally:
        cb.ROSTER_ROLES.clear()
        cb.ROSTER_ROLES.update(saved)


def test_losses_by_class_is_not_accumulated_across_snapshots(tmp_path):
    # The bug this locks: FACTION.losses is AIStats.losses, a per-faction
    # CUMULATIVE counter (initialised once at fs2rts_ai_telemetry.lua:29, never
    # cleared). The handler ran on every ~30 s FACTION record and did
    # acc.losses_by_class.update(losses), summing a monotone counter once per
    # snapshot. Measured inflation was 36-48x, i.e. the snapshot count, which
    # made losses_capital read 30.5 where the truth was 1.5.
    records = []
    for i in range(5):
        records.append(faction("BLUE", 10.0, 1000.0, 0.0, 10.0,
                               hull=5000.0, idle=0.0,
                               losses={"GTCv Deimos": 1.0}))
    path = write_match(tmp_path / "losses_accum", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    # Five identical cumulative snapshots of one capital death must read ONE.
    assert vec["losses_capital"] == 1.0, (
        "losses_capital accumulated across %d snapshots: %s" % (len(records), vec["losses_capital"]))
    assert vec["losses_units"] == 1.0


def test_losses_and_station_hull(tmp_path):
    # FACTION.losses is a CUMULATIVE snapshot, verified against the real
    # telemetry: the last snapshot summed over factions equals the LOSS event
    # count exactly. So the metric reads the last snapshot, not a running sum.
    records = [
        faction("BLUE", 10.0, 1000.0, 0.0, 10.0, hull=5000.0, idle=4.0,
                losses={"GTF Perseus": 1.0}),
        faction("BLUE", 20.0, 900.0, 0.0, 10.0, hull=10000.0, idle=0.0,
                losses={"GTF Perseus": 3.0, "GTCv Deimos": 1.0}),
    ]
    path = write_match(tmp_path / "losses", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["losses_units"] == 4.0, "last cumulative snapshot, not 1 + 4"
    assert vec["losses_capital"] == 1.0
    assert vec["station_hull_final_frac"] == pytest.approx(1.0)
    assert vec["station_hull_min_frac"] == pytest.approx(0.5)
    assert vec["station_hull_mean_frac"] == pytest.approx(0.75)


def test_losses_metric_does_not_double_count(tmp_path):
    """A running sum over a cumulative field would report 5 for 1 + 4."""
    records = [
        faction("BLUE", 10.0, 1000.0, 0.0, 10.0, losses={"GTF Perseus": 1.0}),
        faction("BLUE", 20.0, 900.0, 0.0, 10.0, losses={"GTF Perseus": 3.0}),
    ]
    path = write_match(tmp_path / "losses2", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["losses_units"] == 3.0


def test_damage_dealt_string_is_counted_as_unknown(tmp_path):
    records = [faction("BLUE", 10.0, 10.0, 0.0, 1.0),
               faction("BLUE", 20.0, 10.0, 0.0, 1.0, damage_dealt=123.0)]
    path = write_match(tmp_path / "dmg", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["damage_dealt_known"] == 1.0, (
        "the string 'unknown' must not be counted as a measurement")


def test_series_are_bounded_and_none_padded(tmp_path):
    records = [faction("BLUE", 100.0, 1000.0, 1.0, 1.0),
               faction("BLUE", 2500.0, 500.0, 1.0, 1.0)]
    path = write_match(tmp_path / "series", 0, records)
    match = cb.stream_match(path)
    series = match["factions"]["BLUE"].cp_series.as_list()
    assert len(series) == cb.SERIES_BUCKETS
    assert series[0] == pytest.approx(1000.0)
    assert series[-1] == pytest.approx(500.0)
    assert sum(1 for v in series if v is None) == cb.SERIES_BUCKETS - 2


def test_losses_value_comes_from_loss_events_not_surviving_fleet(tmp_path):
    """FACTION.replacementValueByClass sums to FACTION.replacementValue: it is
    the SURVIVING fleet, not what was lost. losses_value must come from LOSS
    event replacementCost instead."""
    records = [
        faction("BLUE", 10.0, 1000.0, 0.0, 10.0, hull=10000.0,
                losses={"GTF Perseus": 2.0}),
        rec("LOSS", 12.0, {"faction": "BLUE", "class": "GTF Perseus",
                           "baseUnitCost": 400.0, "replacementCost": 400.0,
                           "bountyCP": 96.0}),
        rec("LOSS", 14.0, {"faction": "BLUE", "class": "GTB Zeus",
                           "baseUnitCost": 650.0, "bountyCP": 156.0}),
    ]
    path = write_match(tmp_path / "lossval", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["loss_events"] == 2.0
    # Second LOSS has no replacementCost, so it falls back to baseUnitCost.
    assert vec["losses_value"] == pytest.approx(400.0 + 650.0)
    assert vec["losses_units"] == 2.0


def test_cap_utilisation_is_a_fraction_between_zero_and_one(tmp_path):
    """Regression guard: an extra samples factor once made this 2.9e-05."""
    records = [
        faction("BLUE", 10.0, 1000.0, 0.0, 10.0, combatants=32.0),
        faction("BLUE", 20.0, 1000.0, 0.0, 10.0, combatants=32.0),
    ]
    path = write_match(tmp_path / "cap", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["cap_utilisation_mean"] == pytest.approx(0.5)
    assert 0.0 <= vec["cap_utilisation_mean"] <= 1.0


def test_cap_utilisation_averages_ratios_across_factions(tmp_path):
    records = [
        faction("BLUE", 10.0, 1000.0, 0.0, 10.0, combatants=64.0),   # 1.0
        faction("BLUE", 20.0, 1000.0, 0.0, 10.0, combatants=64.0),
        faction("RED", 10.0, 1000.0, 0.0, 10.0, combatants=0.0),     # 0.0
        faction("RED", 20.0, 1000.0, 0.0, 10.0, combatants=0.0),
    ]
    path = write_match(tmp_path / "cap2", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    assert vec["cap_utilisation_mean"] == pytest.approx(0.5)


def test_duration_split_and_disjoint_ranges_are_warned_about(tmp_path):
    """A batch holding both full-length and cut-short matches must say so, or a
    sample-size difference reads as an AI behaviour change."""
    base = tmp_path / "dbase"
    cand = tmp_path / "dcand"
    for index, seconds in enumerate((2600.0, 2600.0, 2700.0)):
        write_match(base, index, [faction("BLUE", seconds / 2, 1000.0, 500.0, 50.0),
                                  faction("BLUE", seconds, 900.0, 0.0, 50.0)])
    for index, seconds in enumerate((500.0, 2100.0, 2150.0, 2200.0)):
        write_match(cand, index, [faction("BLUE", seconds / 2, 1000.0, 500.0, 50.0),
                                  faction("BLUE", seconds, 900.0, 0.0, 50.0)])
    report = cb.build_report(cb.load_batch(base, "baseline"),
                             cb.load_batch(cand, "candidate"), base, cand)
    joined = " ".join(report["warnings"])
    assert "DURATION SPLIT" in joined
    assert "DISJOINT DURATION RANGES" in joined


def test_equal_length_batches_produce_no_duration_warning(tmp_path):
    base = make_two_spends(tmp_path, "sbase", 3, 100.0)
    cand = make_two_spends(tmp_path, "scand", 3, 100.0)
    report = cb.build_report(cb.load_batch(base, "baseline"),
                             cb.load_batch(cand, "candidate"), base, cand)
    joined = " ".join(report["warnings"])
    assert "DURATION" not in joined
    assert "UNEQUAL" not in joined


def test_every_declared_metric_is_produced_by_the_vector(tmp_path):
    """A metric in the registry that the vector never fills would silently
    report 0.0 and read as a real regression."""
    records = [faction("BLUE", 10.0, 1000.0, 100.0, 10.0),
               faction("BLUE", 20.0, 900.0, 50.0, 10.0),
               production("BLUE", 10.0, 100.0),
               counters(20.0, 50.0, 10.0, 9.0),
               build_decision("BLUE", 20.0, "PURCHASE_SELECTED"),
               execution("BLUE", 20.0),
               rec("FLEET_SERVICE", 20.0, {"faction": "BLUE", "reason": "HULL_LOW",
                                          "phase": "RETURNING", "ship": 1.0}),
               rec("FLEET_SERVICE_WORK", 21.0, {"faction": "BLUE", "totalSpent": 0.1}),
               rec("FLEET_SERVICE_INTERRUPTED", 22.0, {"faction": "BLUE", "spent": 5.0}),
               rec("OPERATION", 20.0, {"faction": "BLUE", "phase": "ASSEMBLE",
                                        "reason": "NEW_OPERATION", "serial": 0.0}),
               rec("OPERATION", 25.0, {"faction": "BLUE", "phase": "WITHDRAW",
                                        "reason": "RECOVERY_DEADLINE", "serial": 0.0}),
               rec("LOSS", 20.0, {"faction": "BLUE", "class": "GTF Perseus",
                                   "bountyCP": 96.0}),
               rec("FRIENDLY_HIT", 20.0, {"faction": "BLUE", "ship": 1.0}),
               rec("DECISION", 20.0, {"faction": "BLUE", "mission": "PRIMARY",
                                      "reason": "DEFEND_BASE", "posture": "OFFENSIVE"}),
               rec("OBJECTIVE", 20.0, {"faction": "BLUE", "status": "ORDER_ACCEPTED",
                                       "mission": "PRIMARY", "ship": 1.0}),
               rec("CONTEST", 20.0, {"faction": "BLUE", "primaryName": "RTS Red Station",
                                     "missionCounts": {"PRIMARY": 2.0},
                                     "staleOrders": 1.0, "stalledGroups": 0.0,
                                     "worstStallSeconds": 3.0}),
               rec("STATION_BEAM_HIT", 20.0, {"targetFaction": "BLUE"}),
               rec("STATION_REPAIR", 20.0, {"faction": "BLUE", "totalRepaired": 1.0})]
    path = write_match(tmp_path / "coverage", 0, records)
    vec = cb._match_vector(cb.stream_match(path))
    missing = [m.key for m in cb.METRICS if m.key not in vec]
    assert not missing, f"metrics never produced: {missing}"
    extra = sorted(k for k in vec if k not in cb.METRIC_BY_KEY)
    assert not extra, f"vector keys with no declared metric: {extra}"


def test_quiet_suppresses_per_match_and_histograms(tmp_path):
    base = make_two_spends(tmp_path, "qb", 3, 300.0)
    cand = make_two_spends(tmp_path, "qc", 3, 900.0)
    loud = run_cli(base, cand)
    quiet = run_cli(base, cand, "--quiet")
    assert quiet.returncode == 0, quiet.stdout + quiet.stderr
    assert "PER-MATCH VALUES" not in quiet.stdout
    assert "HISTOGRAM SHARES" not in quiet.stdout
    assert "MATCHES" not in quiet.stdout
    assert "PER-MATCH VALUES" in loud.stdout
    assert "HISTOGRAM SHARES" in loud.stdout
    assert len(quiet.stdout) < len(loud.stdout)
    # The metric table and the verdict survive, which is the point of the mode.
    assert "cp_spent_flow" in quiet.stdout
    assert "overall: NOT_EVALUATED" in quiet.stdout


def test_json_report_is_complete_and_machine_readable(tmp_path):
    base = make_two_spends(tmp_path, "jb", 2, 300.0)
    cand = make_two_spends(tmp_path, "jc", 3, 900.0)
    out = tmp_path / "nested" / "report.json"
    result = run_cli(base, cand, "--json", out, "--quiet")
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(out.read_text(encoding="utf-8"))
    assert payload["tool"] == "compare_batches"
    assert payload["baseline"]["matches"] == 2
    assert payload["candidate"]["matches"] == 3
    assert len(payload["metric_rows"]) == len(cb.METRICS)
    for row in payload["metric_rows"]:
        assert row["verdict"] == "not_evaluated"
        assert row["polarity"] in ("higher", "lower", "none")
        assert "baseline_median" in row and "candidate_median" in row
    assert payload["verdict"]["overall"] == "not_evaluated"
    assert payload["verdict"]["gated_metrics"] == []
    first = payload["baseline"]["per_match"][0]
    for key in ("worker", "attempt", "path", "termination", "engine_result",
                "records", "vector", "histograms", "events", "factions"):
        assert key in first
    assert first["engine_result"] is True
    assert first['evidence']['verified']


def test_polarity_override_is_recorded_in_the_json(tmp_path):
    base = make_two_spends(tmp_path, "ob", 4, 900.0)
    cand = make_two_spends(tmp_path, "oc", 4, 200.0)
    out = tmp_path / "pol.json"
    result = run_cli(base, cand, "--json", out, "--quiet",
                     "--fail-on", "cp_spent_flow", "--polarity", "cp_spent_flow=lower")
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(out.read_text(encoding="utf-8"))
    row = next(r for r in payload["metric_rows"] if r["metric"] == "cp_spent_flow")
    assert row["polarity"] == "lower"
    assert row["polarity_overridden"] is True
    assert row["declared_polarity"] == "none"


def test_list_metrics_runs_without_batches():
    result = subprocess.run(
        [sys.executable, str(TOOLS / "compare_batches.py"), "--list-metrics"],
        cwd=str(REPO_ROOT), capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    for spec in cb.METRICS:
        assert spec.key in result.stdout


def test_list_metrics_documents_every_polarity():
    text = cb.list_metrics()
    for spec in cb.METRICS:
        assert spec.key in text
        assert spec.polarity in ("higher", "lower", "none")


def test_empty_batch_is_reported_not_crashed(tmp_path):
    empty = tmp_path / "empty"
    (empty / "results").mkdir(parents=True)
    small = make_two_spends(tmp_path, "small", 1, 100.0)
    loaded = cb.load_batch(empty, "baseline")
    assert loaded == []
    report = cb.build_report(loaded, cb.load_batch(small, "candidate"), empty, small)
    assert any("no telemetry files" in w for w in report["warnings"])
    assert report["verdict"]["overall"] == "insufficient_evidence"


def test_report_without_acceptance_criteria_cannot_claim_pass(tmp_path):
    base=make_two_spends(tmp_path,'report-only',2,300)
    result=run_cli(base,base,'--quiet')
    assert result.returncode==0
    assert 'overall: NOT_EVALUATED' in result.stdout and 'overall: PASS' not in result.stdout


def test_one_run_cannot_pass_a_comparison_gate(tmp_path):
    base=make_two_spends(tmp_path,'one-base',1,100)
    candidate=make_two_spends(tmp_path,'one-candidate',1,1000)
    result=run_cli(base,candidate,'--fail-on','cp_spent_flow','--polarity','cp_spent_flow=higher','--quiet')
    assert result.returncode==2
    assert 'overall: INSUFFICIENT_EVIDENCE' in result.stdout


def test_none_direction_cannot_be_a_gate(tmp_path):
    base=make_two_spends(tmp_path,'no-direction',2,300)
    result=run_cli(base,base,'--fail-on','sentry_builds','--quiet')
    assert result.returncode==2
    assert 'explicit direction' in result.stderr


def test_context_metrics_do_not_encode_gameplay_preferences():
    assert all(spec.polarity=='none' for spec in cb.METRICS), 'diagnostic counts still pretend to be universal quality targets'


def test_programmatic_gate_without_direction_cannot_claim_pass(tmp_path):
    base=make_two_spends(tmp_path,'programmatic',2,300)
    matches=cb.load_batch(base,'baseline')
    report=cb.build_report(matches,matches,base,base,fail_on=['sentry_builds'])
    assert report['verdict']['overall']=='insufficient_evidence'


def test_corrupt_telemetry_cannot_pass_an_explicit_gate(tmp_path):
    base=make_two_spends(tmp_path,'clean',2,100)
    candidate=make_two_spends(tmp_path,'corrupt',2,1000)
    path=next(candidate.rglob('rts-ai-*.jsonl'))
    path.write_text(path.read_text()+'broken record\n',encoding='utf-8')
    result=run_cli(base,candidate,'--fail-on','cp_spent_flow','--polarity','cp_spent_flow=higher','--quiet')
    assert result.returncode==2 and 'overall: INSUFFICIENT_EVIDENCE' in result.stdout


def test_missing_directory_is_a_clean_error(tmp_path):
    with pytest.raises(SystemExit) as excinfo:
        cb.discover_matches(tmp_path / "does-not-exist")
    assert "not a directory" in str(excinfo.value)
