"""Tests for ai_timeline: bucketing, interval-vs-cumulative flows, phase
derivation, anomaly detection both ways, and a killed run's truncated tail.

All fixtures are written to a temp dir and shaped like the real telemetry:
{"schema":2,"event":..,"time":..,"sequence":..,"data":{..}}. Field names and
value shapes come from the real session-fix-20260930 runs, including the fact
that economy.flow.productionSpend is an INTERVAL and FACTION.received is
cumulative.
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ai_timeline as ait


# ------------------------------------------------------------------ fixtures

def rec(event, time, data, sequence=None):
    return {"schema": 2, "event": event, "time": float(time),
            "sequence": sequence if sequence is not None else int(time * 10) + 1,
            "data": data}


def faction_rec(time, faction, cp, spend, received, offense, **kw):
    plan = {"posture": kw.get("posture", "BALANCED"),
            "missionCounts": kw.get("mission_counts", {"PRIMARY": 2})}
    data = {
        "faction": faction,
        "combatants": kw.get("combatants", 10),
        "idle": kw.get("idle", 0),
        "servicing": kw.get("servicing", 0),
        "stalled": kw.get("stalled", 0),
        "value": kw.get("value", 5000),
        "received": received,
        "offense": offense,
        "damageDealt": "unknown",
        "stationHull": kw.get("hull", 132600),
        "stationMax": 132600,
        "unengagedSeconds": kw.get("unengaged", 0),
        "unitSeconds": kw.get("unit_seconds", 0),
        "plan": plan,
        "economy": {
            "commandPoints": cp,
            "queueDepth": kw.get("queue_depth", 0),
            "fleetCap": kw.get("fleet_cap", 64),
            "combatants": kw.get("combatants", 10),
            "flow": {"income": kw.get("income", 300),
                     "productionSpend": spend, "bounty": 0, "refund": 0},
        },
        "combatDamageTelemetry": {"interval": {"hullDamage": kw.get("dealt", 0)}},
    }
    return rec("FACTION", time, data)


def build_rec(time, faction, reason, cp, affordable, bank_target=8600,
              tier=3, role="capital", slots=50):
    return rec("AI_BUILD_DECISION", time, {
        "faction": faction, "reason": reason, "commandPoints": cp,
        "bankTarget": bank_target, "tier": tier, "desiredRole": role,
        "slots": slots, "affordableOptions": affordable,
        "unlockedOptions": affordable, "fleetFitOptions": affordable,
        "currentTierDesiredCost": bank_target,
        "deficits": {"capital": 0.34}, "unitCounts": {}, "unitValues": {},
        "tacticalDemand": {}, "compositionTargets": {"capital": 0.34},
        "options": [{"class": "X", "cost": bank_target, "affordable": affordable > 0,
                     "tier": tier, "role": role}],
    })


def write_run(directory, name, records, trailing=b""):
    run = Path(directory) / "results" / "w" / "worker0" / "a-1" / "probe" / "data"
    run.mkdir(parents=True, exist_ok=True)
    path = run / f"rts-ai-{name}.jsonl"
    with path.open("wb") as stream:
        for index, record in enumerate(records, start=1):
            record["sequence"] = index
            stream.write((json.dumps(record) + "\n").encode("utf-8"))
        if trailing:
            stream.write(trailing)
    return Path(directory)


def load(directory, resolution=60.0):
    files = ait.find_telemetry(Path(directory))
    assert files, "fixture produced no telemetry"
    return ait.MatchTimeline(files[0], resolution).consume()


def by_code(anomalies, code, faction=None):
    return [a for a in anomalies
            if a["code"] == code and (faction is None or a["faction"] == faction)]


# --------------------------------------------------------------------- tests

class BucketingTests(unittest.TestCase):
    def test_records_land_in_the_right_bucket_and_gauges_take_the_last_value(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "bucket", [
                faction_rec(0, "BLUE", 100, 0, 0, 0, combatants=4),
                faction_rec(30, "BLUE", 200, 0, 0, 0, combatants=6),
                faction_rec(61, "BLUE", 300, 0, 0, 0, combatants=8),
                faction_rec(125, "BLUE", 400, 0, 0, 0, combatants=10),
            ])
            match = load(tmp, resolution=60)
            series = match.series("BLUE")
            self.assertEqual([s["index"] for s in series], [0, 1, 2])
            # gauge: last observation inside the bucket wins
            self.assertEqual(series[0]["combatants"], 6)
            self.assertEqual(series[0]["cp"], 200)
            # bucket 1 covers t=60..119 and holds the t=61 record
            self.assertEqual(series[1]["combatants"], 8)
            self.assertEqual(series[1]["cp"], 300)
            self.assertEqual(series[2]["combatants"], 10)

    def test_resolution_changes_the_bucket_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "res", [faction_rec(t, "BLUE", 10, 0, 0, 0)
                                   for t in range(0, 300, 30)])
            coarse = load(tmp, resolution=60)
            fine = load(tmp, resolution=30)
            self.assertEqual(len(coarse.series("BLUE")), 5)
            self.assertEqual(len(fine.series("BLUE")), 10)

    def test_cap_util_and_hull_percent(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "util", [faction_rec(0, "BLUE", 10, 0, 0, 0,
                                                 combatants=32, fleet_cap=64, hull=66300)])
            acc = load(tmp).factions["BLUE"]
            self.assertAlmostEqual(acc["last_hull_pct"], 50.0)
            slot = acc["buckets"][0]
            self.assertAlmostEqual(slot["cap_util"], 50.0)


class FlowAggregationTests(unittest.TestCase):
    """The trap: productionSpend is an INTERVAL. Summing the series is the only
    correct reading; the final record alone reads 0.0."""

    def test_interval_production_spend_is_summed_not_read_from_the_last_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            # the mod zeroes the flow right after each emit, so the final record
            # legitimately reports 0.0 no matter how much was built
            records = [faction_rec(0, "BLUE", 500, 1600, 0, 0),
                       faction_rec(30, "BLUE", 500, 0, 0, 0),
                       faction_rec(60, "BLUE", 500, 1400, 0, 0),
                       faction_rec(90, "BLUE", 500, 0, 0, 0)]
            write_run(tmp, "flow", records)
            acc = load(tmp).factions["BLUE"]
            self.assertEqual(acc["cum_spend"], 3000.0)
            # the naive read that produces the wrong answer
            self.assertEqual(records[-1]["data"]["economy"]["flow"]["productionSpend"], 0)

    def test_per_bucket_spend_sums_and_cumulative_series_is_monotonic(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "perbucket", [
                faction_rec(0, "BLUE", 500, 1000, 0, 0),
                faction_rec(30, "BLUE", 500, 0, 0, 0),
                faction_rec(60, "BLUE", 500, 2000, 0, 0),
                faction_rec(90, "BLUE", 500, 0, 0, 0),
            ])
            series = load(tmp).series("BLUE")
            # four records at t=0/30/60/90 fall into two 60 s buckets
            self.assertEqual(len(series), 2)
            self.assertEqual(series[0]["spend"], 1000.0)
            self.assertEqual(series[1]["spend"], 2000.0)
            cumulative = [s["cum_spend"] for s in series]
            self.assertEqual(cumulative, [1000.0, 3000.0])
            self.assertEqual(cumulative, sorted(cumulative))

    def test_received_is_cumulative_and_offense_is_a_gauge_not_a_flow(self):
        # This test previously asserted the opposite for `offense`, on the
        # reasoning that "resets to 0 each window" means interval. That
        # reasoning is wrong: ai_planning.lua rebuilds offense from scratch on
        # every FACTION record (`offense=0` then adding each PRIMARY/ESCORT
        # group's value), so it is the fleet value CURRENTLY ASSIGNED to those
        # missions. It rises when missions are assigned and falls when groups
        # are released. A real BLUE series from session-fix-20260930 runs
        # 0, 1264, 1264, 2423, 0, 1231, 2044, 3417, 2860, 1353, 3304, 0 - it
        # returns to zero inside a single match. Summing it produced a number
        # that scales with the sample count and measures neither damage nor
        # spend; it is now reported as a gauge.
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "damage", [
                faction_rec(0, "BLUE", 0, 0, received=100, offense=40, dealt=40),
                faction_rec(30, "BLUE", 0, 0, received=250, offense=0, dealt=0),
                faction_rec(60, "BLUE", 0, 0, received=400, offense=15, dealt=15),
            ])
            acc = load(tmp).factions["BLUE"]
            # received never decreases -> take the running maximum, not the sum
            self.assertEqual(acc["cum_received"], 400)
            # offense is a gauge: mean/max/last, and the sum is kept only to
            # derive the mean, never published as a total.
            self.assertEqual(acc["offense_samples"], 3)
            self.assertEqual(acc["offense_max"], 40)
            self.assertEqual(acc["offense_last"], 15)
            self.assertAlmostEqual(acc["offense_sum"] / acc["offense_samples"], 55.0 / 3)
            self.assertNotIn("cum_offense", acc)
            # dealt IS an interval and is summed.
            self.assertEqual(acc["cum_dealt"], 55.0)

    def test_offense_gauge_is_not_summed_into_a_total(self):
        # Doubling the sample count with the same gauge values must not double
        # any published total. A summed gauge would.
        with tempfile.TemporaryDirectory() as tmp:
            records = []
            for i in range(2):
                for k in range(10):
                    records.append(faction_rec(i * 300 + k * 30, "BLUE", 0, 0, 0,
                                                1000))
            write_run(tmp, "gauge", records)
            acc = load(tmp).factions["BLUE"]
            self.assertEqual(acc["offense_samples"], 20)
            self.assertEqual(acc["offense_max"], 1000)
            self.assertEqual(acc["offense_last"], 1000)
            self.assertAlmostEqual(acc["offense_sum"] / acc["offense_samples"], 1000.0)

    def test_income_bounty_refund_are_summed(self):
        with tempfile.TemporaryDirectory() as tmp:
            record = faction_rec(0, "BLUE", 0, 0, 0, 0)
            record["data"]["economy"]["flow"].update(
                {"income": 300, "bounty": 25, "refund": 10})
            record2 = faction_rec(30, "BLUE", 0, 0, 0, 0)
            record2["data"]["economy"]["flow"].update(
                {"income": 320, "bounty": 0, "refund": 0})
            write_run(tmp, "flows", [record, record2])
            acc = load(tmp).factions["BLUE"]
            self.assertEqual(acc["cum_income"], 620.0)
            self.assertEqual(acc["cum_bounty"], 25.0)
            self.assertEqual(acc["cum_refund"], 10.0)


class PhaseTimelineTests(unittest.TestCase):
    def test_operation_phases_become_transitions_and_repeats_are_suppressed(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "phase", [
                faction_rec(0, "BLUE", 0, 0, 0, 0),
                rec("OPERATION", 10, {"faction": "BLUE", "phase": "ASSEMBLE",
                                      "reason": "NEW_OPERATION", "serial": 0, "front": 1}),
                rec("OPERATION", 20, {"faction": "BLUE", "phase": "ASSEMBLE",
                                      "reason": "STILL_ASSEMBLING", "serial": 0, "front": 1}),
                rec("OPERATION", 30, {"faction": "BLUE", "phase": "APPROACH",
                                      "reason": "ASSEMBLY_RELEASE", "serial": 1, "front": 1}),
                rec("OPERATION", 40, {"faction": "BLUE", "phase": "ENGAGE",
                                      "reason": "CONTACT_OR_APPROACH_DEADLINE",
                                      "serial": 1, "front": 1}),
                rec("OPERATION", 50, {"faction": "BLUE", "phase": "ENGAGE",
                                      "reason": "HOLD", "serial": 1, "front": 1}),
                rec("OPERATION", 60, {"faction": "BLUE", "phase": "EXPLOIT",
                                      "reason": "DEFENSE_BROKEN", "serial": 1, "front": 1}),
                rec("OPERATION", 70, {"faction": "BLUE", "phase": "WITHDRAW",
                                      "reason": "STRIKE_FORCE_LOST", "serial": 1, "front": 1}),
            ])
            match = load(tmp)
            phases = [(t, value) for t, kind, value, _ in ait.phase_timeline(match, "BLUE")
                      if kind == "PHASE"]
            self.assertEqual(phases, [(10, "ASSEMBLE"), (30, "APPROACH"),
                                      (40, "ENGAGE"), (60, "EXPLOIT"),
                                      (70, "WITHDRAW")])

    def test_posture_changes_and_flag_latches_appear_in_the_timeline(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "posture", [
                faction_rec(0, "BLUE", 0, 0, 0, 0, posture="BALANCED"),
                faction_rec(30, "BLUE", 0, 0, 0, 0, posture="OFFENSIVE"),
                faction_rec(60, "BLUE", 0, 0, 0, 0, posture="OFFENSIVE"),
                faction_rec(90, "BLUE", 0, 0, 0, 0, posture="DEFENSIVE"),
            ])
            match = load(tmp)
            postures = [value for _, kind, value, _ in ait.phase_timeline(match, "BLUE")
                        if kind == "POSTURE"]
            self.assertEqual(postures, ["BALANCED", "OFFENSIVE", "DEFENSIVE"])

    def test_emergency_latch_time_is_the_first_true_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = []
            for index, time in enumerate((0, 30, 60, 90)):
                record = faction_rec(time, "GOLD", 0, 0, 0, 0)
                if index >= 2:
                    record["data"]["plan"]["emergency"] = True
                records.append(record)
            write_run(tmp, "emergency", records)
            match = load(tmp)
            self.assertEqual(match.factions["GOLD"]["emergency_first"], 60.0)
            latches = [value for _, kind, value, _ in ait.phase_timeline(match, "GOLD")
                       if kind == "LATCH"]
            self.assertIn("EMERGENCY", latches)

    def test_saving_and_no_option_spans_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "spans", [
                build_rec(0, "GOLD", "SAVING_FOR_DESIRED_ROLE", 100, 12),
                build_rec(20, "GOLD", "SAVING_FOR_DESIRED_ROLE", 200, 12),
                build_rec(40, "GOLD", "INSUFFICIENT_CP", 50, 0),
                build_rec(60, "GOLD", "INSUFFICIENT_CP", 80, 0),
                build_rec(80, "GOLD", "PURCHASE_SELECTED", 900, 3),
            ])
            match = load(tmp)
            kinds = {(kind, value) for _, kind, value, _ in ait.phase_timeline(match, "GOLD")
                     if kind.startswith("BUILD")}
            self.assertIn(("BUILD_START", "saving_for_desired_role"), kinds)
            self.assertIn(("BUILD_END", "saving_for_desired_role"), kinds)
            self.assertIn(("BUILD_START", "no_affordable_options"), kinds)


class AnomalyPositiveTests(unittest.TestCase):
    def test_production_blackout_is_detected_with_its_window_and_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = []
            # 20 deferral decisions over 200 s with 12-15 options affordable and
            # the bank climbing, then a purchase that closes the window.
            for step in range(10):
                time = step * 20
                cp = 1000 + step * 300
                records.append(build_rec(time, "BLUE", "SAVING_FOR_DESIRED_ROLE",
                                         cp, 12 + step % 4))
                records.append(faction_rec(time + 10, "BLUE", cp, 0, 0, 0,
                                           idle=3, unengaged=900, unit_seconds=1000))
            records.append(rec("PRODUCTION", 200, {"faction": "BLUE",
                                                   "action": "QUEUE_ACCEPTED", "cost": 8600}))
            records.append(faction_rec(210, "BLUE", 200, 0, 0, 0))
            records.append(build_rec(220, "BLUE", "PURCHASE_SELECTED", 8600, 14))
            write_run(tmp, "blackout", records)
            match = load(tmp)
            found = by_code(ait.detect_anomalies(match), "PRODUCTION_BLACKOUT", "BLUE")
            self.assertEqual(len(found), 1)
            anomaly = found[0]
            self.assertAlmostEqual(anomaly["start"], 0.0)
            # the span ends at the last DECLINED decision (t=180), not at the
            # closing purchase decision that archives it
            self.assertAlmostEqual(anomaly["end"], 180.0)
            self.assertGreaterEqual(anomaly["duration"], 90)
            self.assertEqual(anomaly["evidence"]["build_decisions_in_window"], 10)
            self.assertEqual(anomaly["evidence"]["max_affordable_options"], 15)
            self.assertEqual(anomaly["evidence"]["purchases_in_window"], 0)
            self.assertEqual(anomaly["evidence"]["unit_purchase_spend_in_window"], 0.0)
            self.assertGreater(anomaly["evidence"]["cp_banked_growth"], 2000)
            self.assertTrue(anomaly["cause"])

    def test_blackout_that_met_its_bank_target_is_critical(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [build_rec(step * 20, "RED", "SAVING_FOR_DESIRED_ROLE",
                                 9000 + step * 100, 15, bank_target=8600, tier=3)
                       for step in range(10)]
            records.append(build_rec(200, "RED", "PURCHASE_SELECTED", 10000, 15))
            write_run(tmp, "met", records)
            anomaly = by_code(ait.detect_anomalies(load(tmp)),
                              "PRODUCTION_BLACKOUT", "RED")[0]
            self.assertEqual(anomaly["severity"], "critical")
            self.assertTrue(anomaly["evidence"]["bank_target_met"])
            self.assertIn("not releasing", anomaly["cause"])

    def test_deferral_containing_a_purchase_is_not_labelled_a_blackout(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = []
            for step in range(10):
                records.append(build_rec(step * 20, "BLUE", "SAVING_FOR_DESIRED_ROLE",
                                         500 + step * 100, 12))
                if step == 5:
                    records.append(rec("PRODUCTION", 105, {
                        "faction": "BLUE", "action": "QUEUE_ACCEPTED", "cost": 1400}))
            records.append(build_rec(200, "BLUE", "PURCHASE_SELECTED", 900, 12))
            write_run(tmp, "deferral", records)
            codes = [a["code"] for a in ait.detect_anomalies(load(tmp))]
            self.assertIn("PRODUCTION_DEFERRAL", codes)
            self.assertNotIn("PRODUCTION_BLACKOUT", codes)

    def test_stuck_build_reason_needs_one_reason_and_a_long_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [build_rec(step * 20, "BLUE", "SAVING_FOR_DESIRED_ROLE",
                                 500 + step * 50, 9) for step in range(10)]
            records.append(build_rec(200, "BLUE", "INSUFFICIENT_CP", 10, 0))
            write_run(tmp, "stuck", records)
            match = load(tmp)
            stuck = by_code(ait.detect_anomalies(match), "STUCK_BUILD_REASON", "BLUE")
            self.assertTrue(stuck)
            self.assertEqual(stuck[0]["evidence"]["reason"], "SAVING_FOR_DESIRED_ROLE")

    def test_sustained_idle(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "GOLD", 100, 0, 0, 0, idle=4)
                       for step in range(10)]
            write_run(tmp, "idle", records)
            found = by_code(ait.detect_anomalies(load(tmp)), "SUSTAINED_IDLE", "GOLD")
            self.assertTrue(found)
            self.assertGreaterEqual(found[0]["duration"], 90)
            self.assertGreaterEqual(found[0]["evidence"]["peak_idle"], 4)

    def test_stalled_groups(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "RED", 100, 0, 0, 0, stalled=2)
                       for step in range(10)]
            write_run(tmp, "stalled", records)
            found = by_code(ait.detect_anomalies(load(tmp)), "STALLED_GROUPS", "RED")
            self.assertTrue(found)
            self.assertGreaterEqual(found[0]["evidence"]["peak_stalled_groups"], 2)

    def test_order_failures_are_reported_per_faction(self):
        with tempfile.TemporaryDirectory() as tmp:
            counters = rec("COUNTERS", 30, {
                "decisions": 100, "reissued": 0, "retained": 90, "switches": 10,
                "nativeChanges": 0,
                "orders": {"attempts": 50, "success": 45, "failed": 5, "rejected": 0,
                           "unchanged": 0,
                           "byMission": {"BLUE": {"PRIMARY": {"success": 45, "failed": 5,
                                                             "rejected": 0, "unchanged": 0}}},
                           "byResult": {"success": 45, "failed": 5}}})
            write_run(tmp, "orders", [counters])
            found = by_code(ait.detect_anomalies(load(tmp)), "ORDER_FAILURES", "BLUE")
            self.assertTrue(found)
            self.assertEqual(found[0]["evidence"]["failed"], 5.0)
            self.assertEqual(found[0]["severity"], "critical")

    def test_reissue_storm_from_counter_deltas(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = []
            for step in range(10):
                records.append(faction_rec(step * 30, "BLUE", 100, 0, 0, 0))
                records.append(rec("COUNTERS", step * 30, {
                    "decisions": 100 * (step + 1), "reissued": 10 * (step + 1),
                    "retained": 0, "switches": 0, "nativeChanges": 0,
                    "orders": {"attempts": 10, "success": 10, "failed": 0,
                               "rejected": 0, "unchanged": 0,
                               "byMission": {}, "byResult": {}}}))
            write_run(tmp, "reissue", records)
            found = by_code(ait.detect_anomalies(load(tmp)), "REISSUE_STORM")
            self.assertTrue(found)
            self.assertGreaterEqual(found[0]["evidence"]["peak_per_minute"], 3.0)

    def test_posture_flapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            postures = ["BALANCED", "OFFENSIVE"] * 15
            records = [faction_rec(step * 5, "BLUE", 100, 0, 0, 0, posture=posture)
                       for step, posture in enumerate(postures)]
            write_run(tmp, "flap", records)
            found = by_code(ait.detect_anomalies(load(tmp)), "POSTURE_FLAPPING", "BLUE")
            self.assertTrue(found)
            self.assertGreaterEqual(found[0]["evidence"]["peak_rate_per_minute"], 2.0)

    def test_unengaged_fleet(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "BLUE", 100, 0, 0, 0,
                                   unengaged=950, unit_seconds=1000)
                       for step in range(5)]
            write_run(tmp, "unengaged", records)
            found = by_code(ait.detect_anomalies(load(tmp)), "UNENGAGED_FLEET", "BLUE")
            self.assertTrue(found)
            self.assertGreaterEqual(found[0]["evidence"]["fraction"], 0.9)

    def test_service_thrash_needs_repeat_entries_in_a_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "GOLD", 100, 0, 0, 0) for step in range(10)]
            for index, time in enumerate((100, 130, 170, 900, 950)):
                records.append(rec("FLEET_SERVICE", time, {
                    "faction": "GOLD", "ship": 42, "phase": "RETURNING",
                    "reason": "HULL_LOW", "ammo": 0, "hull": 0.1}))
            write_run(tmp, "thrash", records)
            found = by_code(ait.detect_anomalies(load(tmp)), "SERVICE_THRASH", "GOLD")
            self.assertTrue(found)
            self.assertEqual(found[0]["evidence"]["ship"], 42)
            self.assertEqual(found[0]["evidence"]["entries"], 3)

    def test_friendly_fire_cluster(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "BLUE", 100, 0, 0, 0) for step in range(10)]
            for time in (100, 110, 120, 130, 900):
                records.append(rec("FRIENDLY_HIT", time, {
                    "faction": "BLUE", "ship": 1, "target": 2, "sourceKind": "PROJECTILE",
                    "evidence": "weapon contact; resolved damage unknown"}))
            write_run(tmp, "ff", records)
            found = by_code(ait.detect_anomalies(load(tmp)), "FRIENDLY_FIRE_CLUSTER", "BLUE")
            self.assertTrue(found)
            self.assertEqual(found[0]["evidence"]["total_hits"], 5)
            # 100..130 cluster; the lone 900 hit is below the size threshold
            self.assertEqual(found[0]["evidence"]["clusters"], 1)


class AnomalyNegativeTests(unittest.TestCase):
    """The same detectors must stay quiet on a healthy match."""

    def _healthy(self, tmp):
        records = []
        for step in range(20):
            time = step * 30
            # buy something every window, keep options affordable but acted on
            records.append(build_rec(time, "BLUE", "PURCHASE_SELECTED",
                                     2000 + step * 100, 12))
            records.append(rec("PRODUCTION", time + 1, {
                "faction": "BLUE", "action": "QUEUE_ACCEPTED", "cost": 1400}))
            records.append(rec("PRODUCTION", time + 2, {
                "faction": "BLUE", "action": "UNIT_SPAWNED", "count": 4}))
            records.append(faction_rec(time + 3, "BLUE", 2000, 1400, 0, 0,
                                       idle=0, stalled=0, unengaged=100, unit_seconds=1000))
            records.append(rec("COUNTERS", time + 4, {
                "decisions": 100 * (step + 1), "reissued": 0,
                "retained": 100 * (step + 1), "switches": 1, "nativeChanges": 0,
                "orders": {"attempts": 10, "success": 10, "failed": 0, "rejected": 0,
                           "unchanged": 0, "byMission": {}, "byResult": {"success": 10}}}))
        write_run(tmp, "healthy", records)
        return load(tmp)

    def test_no_anomalies_on_a_healthy_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            found = ait.detect_anomalies(self._healthy(tmp))
            self.assertEqual([a["code"] for a in found], [], f"unexpected: {found}")

    def test_no_blackout_when_the_ai_buys_every_decision(self):
        with tempfile.TemporaryDirectory() as tmp:
            codes = [a["code"] for a in ait.detect_anomalies(self._healthy(tmp))]
            self.assertNotIn("PRODUCTION_BLACKOUT", codes)
            self.assertNotIn("PRODUCTION_DEFERRAL", codes)

    def test_no_stuck_reason_when_the_reason_keeps_changing(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [build_rec(step * 10, "BLUE",
                                 "SAVING_FOR_DESIRED_ROLE" if step % 2 else "INSUFFICIENT_CP",
                                 500, 5 if step % 2 else 0)
                       for step in range(20)]
            write_run(tmp, "alternating", records)
            codes = [a["code"] for a in ait.detect_anomalies(load(tmp))]
            self.assertNotIn("STUCK_BUILD_REASON", codes)

    def test_no_idle_anomaly_when_idle_is_always_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "GOLD", 100, 0, 0, 0, idle=0)
                       for step in range(10)]
            write_run(tmp, "noidle", records)
            self.assertEqual(by_code(ait.detect_anomalies(load(tmp)), "SUSTAINED_IDLE"), [])

    def test_no_friendly_fire_when_events_are_spread_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "BLUE", 100, 0, 0, 0) for step in range(10)]
            for time in (100, 400, 700):
                records.append(rec("FRIENDLY_HIT", time, {
                    "faction": "BLUE", "ship": 1, "target": 2, "sourceKind": "PROJECTILE",
                    "evidence": "weapon contact"}))
            write_run(tmp, "spread", records)
            self.assertEqual(
                by_code(ait.detect_anomalies(load(tmp)), "FRIENDLY_FIRE_CLUSTER"), [])

    def test_no_thrash_when_a_ship_is_serviced_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "GOLD", 100, 0, 0, 0) for step in range(10)]
            records.append(rec("FLEET_SERVICE", 100, {
                "faction": "GOLD", "ship": 42, "phase": "RETURNING", "reason": "HULL_LOW"}))
            write_run(tmp, "once", records)
            self.assertEqual(
                by_code(ait.detect_anomalies(load(tmp)), "SERVICE_THRASH"), [])

    def test_no_order_failure_when_every_order_succeeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "BLUE", 100, 0, 0, 0) for step in range(5)]
            for step in range(5):
                records.append(rec("COUNTERS", step * 30, {
                    "decisions": 10 * (step + 1), "reissued": 0, "retained": 0,
                    "switches": 0, "nativeChanges": 0,
                    "orders": {"attempts": 10, "success": 10, "failed": 0, "rejected": 0,
                               "unchanged": 0, "byMission": {}, "byResult": {}}}))
            write_run(tmp, "ok", records)
            codes = [a["code"] for a in ait.detect_anomalies(load(tmp))]
            self.assertNotIn("ORDER_FAILURES", codes)
            self.assertNotIn("REISSUE_STORM", codes)

    def test_empty_run_yields_no_anomalies_and_no_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "empty", [])
            match = load(tmp)
            self.assertEqual(match.records, 0)
            self.assertEqual(ait.detect_anomalies(match), [])
            self.assertEqual(match.series("BLUE"), [])


class MalformedInputTests(unittest.TestCase):
    def test_truncated_trailing_line_does_not_crash_or_lose_the_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "BLUE", 100, 0, 0, 0) for step in range(5)]
            records.append(build_rec(160, "BLUE", "SAVING_FOR_DESIRED_ROLE", 900, 11))
            write_run(tmp, "trunc", records,
                      trailing=b'{"schema":2,"event":"FACTION","time":170.0,"seq')
            match = load(tmp)
            self.assertEqual(match.records, 6)
            self.assertEqual(match.malformed, 1)
            self.assertTrue(match.truncated_tail)
            self.assertEqual(match.factions["BLUE"]["last_cp"], 100.0)
            self.assertGreater(match.last_time, 100)

    def test_blank_lines_and_non_dict_payloads_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "junk", [faction_rec(0, "BLUE", 100, 0, 0, 0)],
                      trailing=b"\n\n[1,2,3]\nnot json at all\n")
            match = load(tmp)
            self.assertEqual(match.records, 1)
            self.assertEqual(match.malformed, 2)

    def test_missing_optional_fields_do_not_raise(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "sparse", [
                rec("FACTION", 0, {"faction": "BLUE"}),
                rec("AI_BUILD_DECISION", 10, {"faction": "BLUE"}),
                rec("COUNTERS", 20, {}),
                rec("OPERATION", 30, {"faction": "BLUE"}),
                rec("DECISION", 40, {}),
                rec("CONTEST", 50, {"faction": "BLUE"}),
                rec("EXECUTION", 60, {}),
                rec("LOSS", 70, {"faction": "BLUE"}),
                rec("FLEET_SERVICE", 80, {"faction": "BLUE"}),
                rec("FRIENDLY_HIT", 90, {}),
                rec("PRODUCTION", 100, {"faction": "BLUE"}),
                rec("SENTRY_BUILD", 110, {"faction": "BLUE"}),
                rec("OBJECTIVE", 120, {"faction": "BLUE"}),
                rec("STATION_BEAM_HIT", 130, {}),
                rec("OUTCOME_CAUSE", 140, {}),
            ])
            match = load(tmp)
            ait.detect_anomalies(match)
            ait.phase_timeline(match, "BLUE")


class TerminationTests(unittest.TestCase):
    def test_simulation_cap_is_derived_without_engine_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "cap", [faction_rec(t, "BLUE", 1, 0, 0, 0)
                                   for t in range(0, 600, 30)])
            match = load(tmp)
            state, detail = ait.termination_state(match, {"max_sim_time": 600})
            self.assertEqual(state, "simulation_cap")
            self.assertIn("600", detail)
            # no engine-result.json anywhere in the fixture
            self.assertFalse(list(Path(tmp).rglob("engine-result.json")))

    def test_station_destroyed_wins_over_the_cap(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "destroyed", [
                faction_rec(0, "GOLD", 1, 0, 0, 0),
                rec("OUTCOME_CAUSE", 300, {"faction": "GOLD", "targetName": "RTS Gold Station",
                                           "elapsed": 300, "killers": [],
                                           "snapshot": {}}),
            ])
            state, _ = ait.termination_state(load(tmp), {"max_sim_time": 600})
            self.assertEqual(state, "station_destroyed")

    def test_unknown_when_there_is_no_cap_and_no_terminal_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "unknown", [faction_rec(0, "BLUE", 1, 0, 0, 0)])
            self.assertEqual(ait.termination_state(load(tmp), {})[0],
                             "truncated_or_unknown")

    def test_a_run_that_stopped_short_of_the_cap_is_not_called_a_cap_hit(self):
        """The four short runs in session-verify stop near t=500 of a 3000 s
        cap. Calling that "simulation_cap" would be a lie."""
        with tempfile.TemporaryDirectory() as tmp:
            write_run(tmp, "short", [faction_rec(t, "BLUE", 1, 0, 0, 0)
                                     for t in range(0, 500, 30)])
            state, detail = ait.termination_state(load(tmp), {"max_sim_time": 3000})
            self.assertEqual(state, "killed_before_cap")
            self.assertIn("of -max-sim-time 3000", detail)


class CliTests(unittest.TestCase):
    def _run(self, tmp, *args):
        script = str(Path(__file__).resolve().parent / "ai_timeline.py")
        return subprocess.run([sys.executable, script, *args], capture_output=True,
                              text=True, cwd=str(Path(__file__).resolve().parent))

    def test_cli_runs_from_the_tools_dir_and_writes_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = []
            for step in range(10):
                records.append(build_rec(step * 20, "BLUE",
                                         "SAVING_FOR_DESIRED_ROLE",
                                         1000 + step * 300, 13))
                records.append(faction_rec(step * 20 + 10, "BLUE", 1000 + step * 300,
                                           0, 0, 0, idle=3))
            records.append(build_rec(200, "BLUE", "PURCHASE_SELECTED", 4000, 13))
            write_run(tmp, "cli", records)
            out = Path(tmp) / "out.json"
            result = self._run(tmp, tmp, "--faction", "BLUE", "--resolution", "60",
                               "--json", str(out), "--events")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PRODUCTION_BLACKOUT", result.stdout)
            self.assertIn("EVENT CENSUS", result.stdout)
            self.assertIn("AI TIMELINE", result.stdout)
            payload = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(len(payload["matches"]), 1)
            match = payload["matches"][0]
            self.assertEqual(match["match"]["termination"], "truncated_or_unknown")
            codes = {a["code"] for a in match["anomalies"]}
            self.assertIn("PRODUCTION_BLACKOUT", codes)
            factions = match["factions"]
            self.assertIn("BLUE", factions)
            self.assertEqual(factions["BLUE"]["cumulative_cp_spent_from_interval_flow"], 0.0)
            self.assertTrue(factions["BLUE"]["series"])
            self.assertTrue(factions["BLUE"]["phase_timeline"])

    def test_cli_accepts_a_single_run_directory_and_a_from_to_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [faction_rec(step * 30, "GOLD", 100, 0, 0, 0) for step in range(10)]
            write_run(tmp, "run", records)
            run_dir = (Path(tmp) / "results" / "w" / "worker0" / "a-1" / "probe" / "data").parent.parent
            result = self._run(tmp, str(run_dir), "--from", "120", "--to", "240",
                               "--resolution", "30")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("GOLD", result.stdout)

    def test_cli_reports_a_missing_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self._run(tmp, str(Path(tmp) / "nope"))
            self.assertNotEqual(result.returncode, 0)


class SnapshotUnitTests(unittest.TestCase):
    """Two same-named fields with different units were misread during
    development; both are pinned here."""

    def test_outcome_cause_snapshot_station_hull_is_a_fraction_not_an_absolute(self):
        # the mod emits 0.7756 here, not 103000, and there is no stationMax
        self.assertEqual(ait._hull_text({"stationHull": 0.7756}), "hull=77.6%")
        self.assertEqual(ait._hull_text({"stationHull": -0.0001}), "hull=-0.0%")
        self.assertEqual(ait._hull_text({}), "hull=?")
        # an absolute-looking value must not be printed as a percent
        self.assertIn("absolute", ait._hull_text({"stationHull": 132600.0}))

    def test_base_damage_by_weapon_is_replaced_not_accumulated(self):
        """cumulative.byWeapon is re-emitted every FACTION record. Summing the
        snapshots multiplied the totals by the window count."""
        with tempfile.TemporaryDirectory() as tmp:
            def faction_record(time, hull):
                record = faction_rec(time, "RED", 100, 0, 0, 0, hull=hull)
                record["data"]["baseDamageTelemetry"] = {
                    "cumulative": {"elapsedSeconds": time, "hitCount": 1, "hullDamage": hull,
                                   "byWeapon": [{"attackerFaction": "GOLD", "weaponClass": "Mekhu",
                                                 "beamWeapon": False, "hitCount": 10,
                                                 "hullDamage": 500.0}]}}
                return record

            write_run(tmp, "basedmg", [faction_record(0, 132600),
                                       faction_record(30, 132100)])
            match = load(tmp)
            slots = list(match.base_damage.values())
            self.assertEqual(len(slots), 1)
            self.assertEqual(slots[0]["hull"], 500.0)
            self.assertEqual(slots[0]["hits"], 10.0)
            key = next(iter(match.base_damage))
            self.assertEqual(key[0], "RED")     # station that was hit
            self.assertEqual(key[1], "GOLD")    # who hit it


class HelperTests(unittest.TestCase):
    def test_num_tolerates_unknown_strings_and_bools(self):
        self.assertEqual(ait.num("unknown"), None)
        self.assertIsNone(ait.num(True))
        self.assertEqual(ait.num("12"), None)
        self.assertEqual(ait.num(12.5), 12.5)

    def test_sparkline_scales_and_resamples(self):
        line = ait.sparkline([0, 1, 2, 3, 4])
        self.assertEqual(len(line), 5)
        self.assertTrue(line[0] < line[-1])
        short = ait.sparkline(list(range(100)), width=10)
        self.assertEqual(len(short), 10)
        self.assertEqual(ait.sparkline([]), "")
        self.assertEqual(ait.sparkline([None, None]), "  ")

    def test_as_percent_and_ratio(self):
        self.assertAlmostEqual(ait.as_percent(50, 200), 25.0)
        self.assertIsNone(ait.as_percent(50, 0))
        self.assertIsNone(ait.as_percent(None, 10))

    def test_find_telemetry_prefers_results_and_ignores_base(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "base" / "data"
            base.mkdir(parents=True)
            (base / "rts-ai-decoy.jsonl").write_text("{}\n", encoding="utf-8")
            write_run(tmp, "real", [faction_rec(0, "BLUE", 1, 0, 0, 0)])
            found = ait.find_telemetry(Path(tmp))
            self.assertEqual(len(found), 1)
            self.assertIn("results", str(found[0]))

    def test_batch_plan_is_found_from_a_nested_run_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "batch.plan.json").write_text(
                json.dumps({"max_sim_time": 3000}), encoding="utf-8")
            run_dir = Path(tmp) / "results" / "w" / "a" / "a-1" / "probe"
            run_dir.mkdir(parents=True)
            self.assertEqual(ait.batch_plan(run_dir).get("max_sim_time"), 3000)

    def test_window_lookup_honours_inclusive_edges(self):
        points = [(10.0, 100.0), (20.0, 200.0), (30.0, 300.0)]
        self.assertEqual(ait._value_at(points, 20.0, True), 200.0)
        self.assertEqual(ait._value_at(points, 20.0, False), 100.0)
        self.assertEqual(ait._value_at(points, 5.0, True), 0.0)
        self.assertEqual(ait._spend_in_window(points, 10.0, 30.0), 100.0)


if __name__ == "__main__":
    unittest.main()