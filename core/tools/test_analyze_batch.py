"""Behaviour of the batch analyzer against synthetic telemetry.

The fixtures here are deliberately tiny, but every one of them reproduces a real
defect this tool had on the 2026-09-30 headless batches: a cap-terminated run
with no engine-result.json was reported as a crash and every statistic was
computed over an empty match; the economy flow is an interval and reads as 0 if
you take the last sample; the analyzer wanted combatantValue while the emitter
only wrote replacementValue.

Run from core/tools:
    python -m pytest -q
"""

import contextlib
import io
import json
import sys
import tracemalloc
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent))

import analyze_batch  # noqa: E402


class Fixture:
    """Builds a run folder shaped like results/w/<worker>/a-<id>/."""

    def __init__(self, root):
        self.root = Path(root)
        self.sequence = 0

    def record(self, event, when=0.0, **data):
        self.sequence += 1
        return {"schema": 2, "event": event, "time": float(when),
                "sequence": self.sequence, "data": data}

    def write(self, records, *, tail=b"", plan=None, result=None, name="a-1"):
        run = self.root / "results" / "w" / "worker0" / name
        data = run / "probe" / "data"
        data.mkdir(parents=True, exist_ok=True)
        blob = "".join(json.dumps(r) + "\n" for r in records).encode("utf-8")
        (data / "rts-ai-20260930-000000.jsonl").write_bytes(blob + tail)
        if plan is not None:
            (self.root / "batch.plan.json").write_text(json.dumps(plan), encoding="utf-8")
        if result is not None:
            (run / "engine-result.json").write_text(json.dumps(result), encoding="utf-8")
        return run


def faction_record(fixture, faction="BLUE", when=100.0, **data):
    body = {"faction": faction, "stationHull": 1000.0, "stationMax": 1000.0,
            "combatants": 2, "replacementValue": 900.0, "value": 900.0, "received": 10.0,
            "stationPosition": {"x": 0.0, "y": 0.0, "z": 0.0}}
    body.update(data)
    return fixture.record("FACTION", when, **body)


class TerminationTests(unittest.TestCase):
    def test_telemetry_without_engine_result_is_not_a_crash(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [
                fixture.record("RUN", 0.0, factions=3),
                faction_record(fixture, when=100.0),
                fixture.record("PRODUCTION", 100.0, action="QUEUE_ACCEPTED", faction="BLUE",
                               cost=1600.0, role="fighter", **{"class": "GTF Perseus"}),
                fixture.record("PRODUCTION", 120.0, action="UNIT_SPAWNED", faction="BLUE",
                               spawnedCount=4, role="fighter"),
            ]
            run = fixture.write(records)
            out = analyze_batch.analyze(run)

            self.assertFalse((run / "engine-result.json").exists())
            self.assertFalse(out["crashed"],
                             "a run with well-formed telemetry was called a crash")
            self.assertEqual(out["records"], len(records))
            self.assertEqual(out["telemetry_state"], "ok")
            self.assertEqual(out["cp_spent"]["BLUE"], 1600.0)
            self.assertEqual(out["units_spawned"]["BLUE"], 4)
            self.assertNotEqual(out["termination"], "no_telemetry")

    def test_explicit_cap_result_is_reported_as_unresolved(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [faction_record(fixture, when=float(t)) for t in range(0, 3001, 100)]
            run = fixture.write(records, plan={"max_sim_time": 3000}, result={'time_limit_reached':True})
            out = analyze_batch.analyze(run)

            self.assertEqual(out["termination"], "simulation_cap")
            self.assertTrue(out["time_limit"])
            self.assertFalse(out["cap_inferred"])
            self.assertFalse(out["crashed"])
            self.assertAlmostEqual(out["cap_progress"], 100.0, places=1)
            self.assertEqual(out["termination_detail"].count("3000s cap"), 1)

    def test_absent_telemetry_does_not_prove_a_crash(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            run = fixture.write([])
            for path in (run / "probe" / "data").glob("rts-ai-*.jsonl"):
                path.unlink()
            out = analyze_batch.analyze(run)
            self.assertFalse(out["crashed"])
            self.assertEqual(out["termination"], "no_telemetry")
            self.assertEqual(out["records"], 0)

    def test_empty_telemetry_does_not_prove_a_crash(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            run = fixture.write([])
            out = analyze_batch.analyze(run)
            self.assertFalse(out["crashed"])
            self.assertEqual(out["telemetry_state"], "empty")
            self.assertEqual(out["records"], 0)

    def test_engine_result_reporting_a_crash_is_a_crash(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            run = fixture.write([faction_record(fixture)],
                                result={"seed": 7, "termination": "crash"})
            out = analyze_batch.analyze(run)
            self.assertTrue(out["crashed"])
            self.assertEqual(out["termination"], "engine_crash")
            self.assertEqual(out["seed"], 7)
            self.assertEqual(out["records"], 1)

    def test_battle_end_is_a_natural_terminal(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [faction_record(fixture), fixture.record("BATTLE_END", 200.0, result="BLUE", globalResolved=True, victorFaction='BLUE')]
            run = fixture.write(records, plan={"max_sim_time": 3000})
            out = analyze_batch.analyze(run)
            self.assertEqual(out["termination"], "battle_end")
            self.assertEqual(out["outcome"], "BLUE")
            self.assertFalse(out["crashed"])

    def test_engine_reported_mission_exit_is_natural(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            run = fixture.write([faction_record(fixture)],
                                result={"seed": 3, "termination": "mission_exit",
                                        "simulated_seconds": 1200.0, "wall_seconds": 900.0})
            out = analyze_batch.analyze(run)
            self.assertEqual(out["termination"], "mission_exit")
            self.assertFalse(out["crashed"])
            self.assertEqual(out["simulated_seconds"], 1200.0)


class TruncatedTailTests(unittest.TestCase):
    def test_healthy_tail_and_personal_report_do_not_prove_global_completion(self):
        with TemporaryDirectory() as tmp:
            fixture=Fixture(tmp)
            run=fixture.write([faction_record(fixture,when=3000),
                fixture.record('BATTLE_END',3000,result='DEFEAT')],plan={'max_sim_time':3000})
            match=analyze_batch.analyze(run)
            self.assertFalse(match['global_resolved'])
            self.assertFalse(match['time_limit'])
            self.assertIsNone(match['outcome'])
            self.assertEqual(match['personal_report'],'DEFEAT')
            self.assertEqual(match['termination'],'unknown_without_result')

    def test_truncated_trailing_line_is_tolerated(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [faction_record(fixture, when=100.0),
                       fixture.record("PRODUCTION", 110.0, action="QUEUE_ACCEPTED",
                                      faction="BLUE", cost=800.0, role="fighter")]
            run = fixture.write(records, tail=b'{"schema":2,"event":"DECISION","ti')
            out = analyze_batch.analyze(run)

            self.assertEqual(out["records"], 2)
            self.assertTrue(out["truncated_tail"])
            self.assertEqual(out["telemetry_state"], "truncated")
            self.assertEqual(out["malformed_lines"], 1)
            self.assertFalse(out["crashed"])
            self.assertEqual(out["cp_spent"]["BLUE"], 800.0)
            self.assertIn("truncated", out["termination_detail"])

    def test_bad_line_in_the_middle_is_not_called_a_tail(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [faction_record(fixture, when=100.0), faction_record(fixture, when=200.0)]
            path = None
            run = fixture.write(records)
            for candidate in (run / "probe" / "data").glob("rts-ai-*.jsonl"):
                path = candidate
            lines = path.read_text(encoding="utf-8").splitlines()
            path.write_text("\n".join([lines[0], "{oops", lines[1]]) + "\n", encoding="utf-8")
            out = analyze_batch.analyze(run)

            self.assertEqual(out["records"], 2)
            self.assertEqual(out["malformed_lines"], 1)
            self.assertFalse(out["truncated_tail"])
            self.assertEqual(out["telemetry_state"], "ok")

    def test_garbage_line_counted_when_nothing_follows(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            run = fixture.write([faction_record(fixture)], tail=b"{oops")
            out = analyze_batch.analyze(run)
            self.assertEqual(out["records"], 1)
            self.assertEqual(out["malformed_lines"], 1)
            self.assertTrue(out["truncated_tail"])
            self.assertFalse(out["crashed"])


class EconomyFlowTests(unittest.TestCase):
    def test_ledger_without_cumulative_observation_has_no_reconciliation_verdict(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            match = analyze_batch.analyze(fixture.write([
                fixture.record('CP_SPEND', 10, faction='BLUE', flow='productionSpend', amount=100),
                faction_record(fixture, when=20, economy={'flow': {'productionSpend': 100}}),
            ]))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                metrics = analyze_batch.report([match], 'legacy', False)
            self.assertIn('no cumulative spend snapshots; verdict unavailable', output.getvalue())
            self.assertIsNone(metrics['cp_spend_drift'])

    def test_reconciliation_compares_the_same_snapshot_cutoff(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [
                fixture.record('CP_SPEND', 10, faction='BLUE', flow='productionSpend', amount=100),
                faction_record(fixture, when=20, economy={'flowCumulative': {'productionSpend': 100}}),
                fixture.record('CP_SPEND', 20, faction='BLUE', flow='productionSpend', amount=500),
            ]
            match = analyze_batch.analyze(fixture.write(records))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                metrics = analyze_batch.report([match], 'cutoff', False)
            self.assertNotIn('MISMATCH', output.getvalue(), 'unsampled tail was called an accounting defect')
            self.assertEqual(metrics['cp_spend_drift'], 0)
            self.assertEqual(metrics['cp_spend_unobserved_tail'], 500)
            # A later cumulative snapshot covers that spend and exposes a real
            # disagreement. The cutoff must not hide observed accounting bugs.
            records.append(faction_record(fixture, when=30, economy={'flowCumulative': {'productionSpend': 400}}))
            match = analyze_batch.analyze(fixture.write(records, name='a-2'))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                metrics = analyze_batch.report([match], 'mismatch', False)
            self.assertIn('MISMATCH', output.getvalue())
            self.assertEqual(metrics['cp_spend_drift'], 200)
            self.assertEqual(metrics['cp_spend_unobserved_tail'], 0)

    def test_flow_spend_is_an_interval_so_it_must_be_summed(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [
                faction_record(fixture, when=30.0, economy={"flow": {
                    "income": 330.0, "productionSpend": 1600.0, "bounty": 0.0, "refund": 0.0}}),
                faction_record(fixture, when=60.0, economy={"flow": {
                    "income": 330.0, "productionSpend": 0.0, "bounty": 0.0, "refund": 0.0}}),
                faction_record(fixture, when=90.0, economy={"flow": {
                    "income": 330.0, "productionSpend": 2500.0, "bounty": 0.0, "refund": 0.0}}),
                fixture.record("PRODUCTION", 30.0, action="QUEUE_ACCEPTED", faction="BLUE", cost=1600.0),
                fixture.record("PRODUCTION", 90.0, action="QUEUE_ACCEPTED", faction="BLUE", cost=2500.0),
            ]
            run = fixture.write(records)
            out = analyze_batch.analyze(run)

            flow = out["flow"]["BLUE"]
            # the trap: the LAST interval sample is 0.0, which reads as an AI
            # that never built anything.
            self.assertEqual(flow["productionSpend"], 4100.0)
            self.assertEqual(out["flow_samples"]["BLUE"], 3)
            self.assertEqual(out["cp_spent"]["BLUE"], 4100.0)
            self.assertEqual(out["cp_queued"]["BLUE"], 2)
            self.assertAlmostEqual(flow["productionSpend"], out["cp_spent"]["BLUE"], places=6)

            last_flow = 0.0
            for record in records:
                if record["event"] == "FACTION":
                    last_flow = record["data"]["economy"]["flow"]["productionSpend"]
            self.assertEqual(last_flow, 2500.0)
            self.assertNotEqual(last_flow, flow["productionSpend"])

    def test_flow_without_economy_block_does_not_break(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            run = fixture.write([faction_record(fixture, when=30.0, economy={"queueDepth": 1})])
            out = analyze_batch.analyze(run)
            self.assertEqual(out["flow_samples"]["BLUE"], 0)

    def test_sentry_spend_is_a_second_path_that_production_misses(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [
                fixture.record("PRODUCTION", 30.0, action="QUEUE_ACCEPTED", faction="BLUE",
                               cost=1600.0),
                # the same sentry is reported three times; only the purchase is spend
                fixture.record("SENTRY_BUILD", 40.0, faction="BLUE", action="BUILD_STARTED",
                               cost=500.0, reason="THREAT"),
                fixture.record("SENTRY_BUILD", 60.0, faction="BLUE", action="BUILD_COMPLETED",
                               cost=500.0),
                fixture.record("SENTRY_BUILD", 50.0, faction="BLUE", action="BUILD_CANCELLED",
                               cost=500.0),
            ]
            run = fixture.write(records)
            out = analyze_batch.analyze(run)
            self.assertEqual(out["cp_spent"]["BLUE"], 1600.0)
            self.assertEqual(out["cp_sentry"]["BLUE"], 500.0)
            self.assertEqual(sum(out["cp_spent"].values()) + sum(out["cp_sentry"].values()), 2100.0)
            self.assertEqual(out["sentry_actions"]["BUILD_CANCELLED"], 1)
            self.assertEqual(out["events"]["SENTRY_BUILD"], 3)

    def test_fleet_service_labour_is_a_third_spend_path(self):
        """FLEET_SERVICE_WORK.spent is CP out of the same bank and lands in the
        same economy.flow.productionSpend, so a spend total that ignores it is
        short by the whole service budget. `spent` is the per-tick charge;
        totalSpent is the ship's running total and must not be summed."""
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [
                fixture.record("FLEET_SERVICE_WORK", 40.0, faction="BLUE", spent=60.0,
                               totalSpent=60.0, healed=10.0),
                fixture.record("FLEET_SERVICE_WORK", 42.0, faction="BLUE", spent=60.0,
                               totalSpent=120.0, healed=10.0),
                faction_record(fixture, faction="BLUE", when=100.0,
                               economy={"flow": {"productionSpend": 120.0}}),
            ]
            run = fixture.write(records)
            out = analyze_batch.analyze(run)
            self.assertEqual(out["cp_service"]["BLUE"], 120.0)
            self.assertEqual(out["service"]["BLUE"]["spent"], 120.0)
            self.assertEqual(out["flow"]["BLUE"]["productionSpend"], 120.0)

    def test_cp_spend_ledger_reconciles_the_otherwise_unattributable_spend(self):
        """Station upgrades and the faction ability deduct CP through the same
        chokepoint as everything else and publish no purchase event, which is
        why the flow could not previously be reconciled to within 10%. The
        CP_SPEND ledger is one record per CP movement and must reproduce the
        interval flow exactly."""
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [
                fixture.record("PRODUCTION", 30.0, action="QUEUE_ACCEPTED", faction="BLUE",
                               cost=1600.0),
                fixture.record("CP_SPEND", 30.0, faction="BLUE", flow="productionSpend",
                               amount=1600.0, cpAfter=400.0),
                # a station upgrade and a faction ability: no purchase event
                fixture.record("CP_SPEND", 50.0, faction="BLUE", flow="productionSpend",
                               amount=625.0, cpAfter=0.0),
                fixture.record("CP_SPEND", 70.0, faction="BLUE", flow="productionSpend",
                               amount=750.0, cpAfter=0.0),
                faction_record(fixture, faction="BLUE", when=100.0,
                               economy={"flow": {"productionSpend": 2975.0}}),
            ]
            run = fixture.write(records)
            out = analyze_batch.analyze(run)
            self.assertEqual(out["cp_spend_ledger"]["BLUE"], 2975.0)
            self.assertEqual(out["cp_spend_entries"], 3)
            self.assertEqual(out["flow"]["BLUE"]["productionSpend"], 2975.0)
            self.assertEqual(out["cp_spend_ledger"]["BLUE"]
                             - out["flow"]["BLUE"]["productionSpend"], 0.0)
            # 1600 is attributable, 1375 is not, and both are in the ledger.
            self.assertEqual(out["cp_spent"]["BLUE"], 1600.0)
            self.assertEqual(out["flow"]["BLUE"]["productionSpend"]
                             - out["cp_spent"]["BLUE"], 1375.0)

    def test_upgrade_levels_and_the_repair_gate_are_reported(self):
        """Station self-repair is gated on ARMOR L2, so a faction that never
        bought it reports totalRepaired 0 forever. Publishing the levels turns
        that zero from 'repair is broken' into 'the gate was never bought'."""
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            economy = {"flow": {"productionSpend": 0.0}, "upgradeSpend": 625.0,
                       "upgradeLevels": {"armor": 1, "defenses": 0,
                                         "logistics": 0, "command": 0},
                       "repairUnlocked": False}
            records = [
                faction_record(fixture, faction="BLUE", when=100.0, economy=economy),
                faction_record(fixture, faction="BLUE", when=200.0,
                               economy={"flow": {"productionSpend": 0.0},
                                        "upgradeSpend": 1875.0,
                                        "upgradeLevels": {"armor": 2, "defenses": 1,
                                                          "logistics": 0, "command": 0},
                                        "repairUnlocked": True}),
            ]
            run = fixture.write(records)
            out = analyze_batch.analyze(run)
            # cumulative gauge: the last snapshot, never the sum (2500)
            self.assertEqual(out["upgrade_spend"]["BLUE"], 1875.0)
            self.assertFalse(out["repair_unlocked"]["BLUE"] is False)
            self.assertTrue(out["repair_unlocked"]["BLUE"])

    def test_station_repair_reports_why_the_ceiling_blocked_repair(self):
        """STATION_REPAIR already carries hull and repairCeiling. Counting the
        samples where hull sat below the ceiling separates 'nothing to repair'
        from 'repair never fires', which a bare zero cannot."""
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [
                fixture.record("STATION_REPAIR", 10.0, faction="BLUE", repaired=0.0,
                               totalRepaired=0.0, hull=10000.0, maxHull=10000.0,
                               scarHull=0.0, repairCeiling=10000.0),
                fixture.record("STATION_REPAIR", 40.0, faction="BLUE", repaired=0.0,
                               totalRepaired=0.0, hull=7000.0, maxHull=10000.0,
                               scarHull=2500.0, repairCeiling=7500.0),
                fixture.record("STATION_REPAIR", 70.0, faction="BLUE", repaired=1200.0,
                               totalRepaired=4800.0, hull=7000.0, maxHull=10000.0,
                               scarHull=2000.0, repairCeiling=8000.0),
            ]
            run = fixture.write(records)
            out = analyze_batch.analyze(run)
            slot = out["repair"]["BLUE"]
            self.assertEqual(slot["samples"], 3)
            self.assertEqual(slot["below_ceiling_samples"], 2, "hull strictly below ceiling")
            self.assertEqual(slot["max_gap"], 1000.0, "largest ceiling minus hull")
            self.assertEqual(slot["ceiling_gap_samples"], 1500.0, "500 + 1000 hull short of the ceiling")
            self.assertEqual(slot["interval"], 1200.0)
            self.assertEqual(slot["cumulative"], 4800.0)


class ValueFieldTests(unittest.TestCase):
    def test_combatant_and_replacement_value_agree(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [
                faction_record(fixture, faction="BLUE", when=100.0, replacementValue=4400.0,
                               combatantValue=4400.0),
                faction_record(fixture, faction="RED", when=100.0, replacementValue=2200.0,
                               combatantValue=2200.0),
            ]
            run = fixture.write(records)
            out = analyze_batch.analyze(run)

            self.assertEqual(out["contract"]["value_present"], 2)
            self.assertEqual(out["contract"]["value_disagrees"], 0)
            self.assertEqual(out["battle"]["BLUE"][0][1]["value"], 4400.0)
            self.assertEqual(out["battle"]["RED"][0][1]["value"], 2200.0)

    def test_replacement_value_only_still_fills_the_arms_race_curve(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [faction_record(fixture, faction="BLUE", when=100.0, replacementValue=4400.0),
                       faction_record(fixture, faction="RED", when=100.0, replacementValue=2200.0)]
            run = fixture.write(records)
            out = analyze_batch.analyze(run)

            self.assertEqual(out["contract"]["value_replacement_only"], 2)
            self.assertEqual(out["battle"]["BLUE"][0][1]["value"], 4400.0)
            self.assertEqual(out["battle"]["RED"][0][1]["value"], 2200.0)

    def test_disagreeing_value_fields_are_flagged_not_ignored(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            run = fixture.write([faction_record(fixture, replacementValue=4400.0, combatantValue=10.0)])
            out = analyze_batch.analyze(run)
            self.assertEqual(out["contract"]["value_disagrees"], 1)
            self.assertEqual(out["battle"]["BLUE"][0][1]["value"], 10.0)

    def test_non_numeric_damage_fields_are_tolerated_and_counted(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [faction_record(fixture, damageDealt="unknown", stationDamageDealt="unknown"),
                       faction_record(fixture, when=200.0, damageDealt=1234.0,
                                      stationDamageDealt=56.0, received=99.0)]
            run = fixture.write(records)
            out = analyze_batch.analyze(run)

            self.assertEqual(out["contract"]["damageDealt_numeric"], 1)
            self.assertEqual(out["contract"]["damageDealt_non_numeric"], 1)
            self.assertEqual(out["contract"]["stationDamageDealt_numeric"], 1)
            self.assertEqual(out["contract"]["stationDamageDealt_non_numeric"], 1)
            # cumulative, so the maximum is the total, never a sum
            self.assertEqual(out["damage"]["BLUE"]["dealt"], 1234.0)
            self.assertEqual(out["damage"]["BLUE"]["station_dealt"], 56.0)
            self.assertFalse(out["crashed"])


class EventCoverageTests(unittest.TestCase):
    def _records(self, fixture):
        return [
            fixture.record("AI_BUILD_DECISION", 10.0, faction="BLUE", reason="SAVING_FOR_DESIRED_ROLE",
                           desiredRole="capital", tier=3.0, commandPoints=900.0, bankTarget=6000.0,
                           affordableOptions=0.0, unlockedOptions=6.0, fleetFitOptions=4.0),
            fixture.record("AI_BUILD_DECISION", 20.0, faction="BLUE", reason="PURCHASE_SELECTED",
                           desiredRole="fighter", tier=1.0, commandPoints=4000.0, bankTarget=6000.0,
                           affordableOptions=3.0, unlockedOptions=6.0, fleetFitOptions=4.0,
                           selectedClass="GTF Perseus"),
            fixture.record("AI_BUILD_DECISION", 30.0, faction="BLUE", reason="INSUFFICIENT_CP",
                           desiredRole="bomber", tier=2.0, commandPoints=100.0, bankTarget=6000.0,
                           affordableOptions=0.0, unlockedOptions=0.0, fleetFitOptions=0.0),
            fixture.record("EXECUTION", 31.0, faction="BLUE", status="NATIVE_TARGET_LOST",
                           mode="APPROACHING", pursuit=True, hitObserved=False, goalPresent="unknown",
                           hullLoss=4.0),
            fixture.record("EXECUTION", 32.0, faction="BLUE", status="NATIVE_TARGET_ACQUIRED",
                           mode="ENGAGED", pursuit=False, hitObserved=True, goalPresent=True,
                           hullLoss=0.0),
            fixture.record("COUNTERS", 33.0, decisions=10.0, retained=7.0, switches=3.0,
                           reissued=1.0, nativeChanges=2.0,
                           orders={"attempts": 5.0, "success": 5.0, "failed": 0.0,
                                   "rejected": 0.0, "unchanged": 0.0,
                                   "byMission": {"BLUE": {"PRIMARY": {"success": 5.0}}},
                                   "byResult": {}}),
            fixture.record("LOSS", 34.0, faction="BLUE", **{"class": "GTF Perseus"},
                           replacementCost=1600.0, bountyCP=384.0,
                           lethalHit={"attackerFaction": "RED", "weaponClass": "Harpoon"}),
            fixture.record("OPERATION", 35.0, faction="BLUE", phase="ASSEMBLE",
                           reason="NEW_OPERATION", serial=1.0),
            fixture.record("OPERATION", 95.0, faction="BLUE", phase="APPROACH",
                           reason="ASSEMBLY_RELEASE", previous="ASSEMBLE", serial=1.0),
            fixture.record("OPERATION", 155.0, faction="BLUE", phase="ENGAGE",
                           reason="CONTACT_OR_APPROACH_DEADLINE", previous="APPROACH", serial=1.0),
            fixture.record("FRIENDLY_HIT", 36.0, faction="BLUE", mission="SCREEN",
                           sourceKind="BEAM", sourceName="Blue A 1", targetName="Blue A 2",
                           targetFaction="BLUE"),
            fixture.record("TACTIC", 37.0, faction="BLUE", mission="PRIMARY", reason="LURE"),
            faction_record(fixture, when=100.0, economy={"flow": {"productionSpend": 900.0}}),
        ]

    def test_new_event_types_are_analysed(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            run = fixture.write(self._records(fixture))
            out = analyze_batch.analyze(run)

            build = out["build"]["BLUE"]
            self.assertEqual(build["samples"], 3)
            self.assertEqual(build["reasons"]["PURCHASE_SELECTED"], 1)
            self.assertEqual(build["roles"]["capital"], 1)
            self.assertEqual(build["zero_affordable"], 2)
            self.assertEqual(build["zero_unlocked"], 1)
            self.assertEqual(build["zero_fleet_fit"], 1)
            self.assertEqual(build["banked"], 3)
            self.assertEqual(build["selected"]["GTF Perseus"], 1)

            execution = out["execution"]["BLUE"]
            self.assertEqual(execution["samples"], 2)
            self.assertEqual(execution["status"]["NATIVE_TARGET_LOST"], 1)
            self.assertEqual(execution["mode"]["ENGAGED"], 1)
            self.assertEqual(execution["pursuit"], 1)
            self.assertEqual(execution["hit"], 1)
            self.assertEqual(execution["goal"]["unknown"], 1)
            self.assertEqual(execution["goal"]["present"], 1)
            self.assertEqual(execution["hull_loss"], 4.0)

            self.assertEqual(out["counters"]["orders"]["attempts"], 5.0)
            self.assertEqual(out["counters_samples"], 1)

            losses = out["losses"]["BLUE"]
            self.assertEqual(losses["count"], 1)
            self.assertEqual(losses["by_killer"]["RED"], 1)
            self.assertEqual(losses["replacement"], 1600.0)
            self.assertEqual(losses["bounty"], 384.0)

            phases = [entry[1] for entry in out["operations"]["BLUE"]]
            self.assertEqual(phases, ["ASSEMBLE", "APPROACH", "ENGAGE"])
            self.assertEqual([entry[3] for entry in out["operations"]["BLUE"]],
                             [None, "ASSEMBLE", "APPROACH"])

            friendly = out["friendly"]["BLUE"]
            self.assertEqual(friendly["count"], 1)
            self.assertEqual(friendly["mission"]["SCREEN"], 1)
            self.assertEqual(friendly["kind"]["BEAM"], 1)
            self.assertEqual(friendly["pairs"]["Blue A 1 -> Blue A 2"], 1)

            # everything except TACTIC has an accumulator, and TACTIC is reported
            # as counted-but-not-analysed rather than silently dropped.
            self.assertEqual(sum(out["unhandled_events"].values()), 1)
            self.assertEqual(out["unhandled_events"]["TACTIC"], 1)

    def test_build_blackout_run_length_is_measured(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [fixture.record("AI_BUILD_DECISION", float(t), faction="BLUE",
                                      reason="SAVING_FOR_DESIRED_ROLE", desiredRole="capital",
                                      commandPoints=100.0, bankTarget=6000.0, affordableOptions=0.0)
                       for t in range(0, 101, 10)]
            records.append(fixture.record("AI_BUILD_DECISION", 110.0, faction="BLUE",
                                          reason="PURCHASE_SELECTED", desiredRole="capital",
                                          commandPoints=9000.0, bankTarget=6000.0,
                                          affordableOptions=2.0))
            run = fixture.write(records)
            out = analyze_batch.analyze(run)
            stats = analyze_batch._build_stats(out["build"]["BLUE"])
            self.assertAlmostEqual(stats["cadence"], 10.0, places=6)
            # the run opens at t=0 and is still dark at the t=110 sample, which
            # is the first one that can afford something
            self.assertAlmostEqual(stats["longest_blackout"], 110.0, places=6)


class StreamingTests(unittest.TestCase):
    def test_scan_is_single_pass_and_does_not_retain_records(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            records = [fixture.record("DECISION", float(i), faction="BLUE", mission="PRIMARY",
                                      role="fighter", reason="DEFEND_BASE", ships=[1, 2, 3, 4],
                                      centroidX=1.0, centroidZ=2.0, spread=3.0, score=4.0)
                       for i in range(4000)]
            run = fixture.write(records)
            size = sum(len(json.dumps(r)) for r in records)

            tracemalloc.start()
            out = analyze_batch.analyze(run)
            _current, peak = tracemalloc.get_traced_memory()
            tracemalloc.stop()

            self.assertEqual(out["records"], 4000)
            self.assertEqual(out["decision_missions"]["PRIMARY"], 4000)
            # A retained-records implementation peaks well above the ~6 MB of
            # source text because every parsed dict stays alive; a streaming one
            # never holds more than a single record.
            self.assertLess(peak, size * 1024 * 4,
                            f"peak {peak} bytes suggests the records list came back")


class DiscoveryTests(unittest.TestCase):
    def test_matches_are_found_without_engine_result(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            fixture.write([faction_record(fixture)], name="a-1")
            fixture.write([faction_record(fixture)], name="a-2")
            jobs = analyze_batch.discover_jobs(Path(tmp))
            self.assertEqual(len(jobs), 2)
            self.assertTrue(all(telemetry is not None for _, telemetry in jobs))

    def test_engine_result_without_telemetry_is_still_a_job(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            run = fixture.write([faction_record(fixture)], result={"seed": 1}, name="a-1")
            (run / "probe" / "data" / "rts-ai-20260930-000000.jsonl").unlink()
            fixture.write([faction_record(fixture)], name="a-2")
            jobs = analyze_batch.discover_jobs(Path(tmp))
            self.assertEqual(len(jobs), 2)
            without = [job for job in jobs if job[1] is None]
            self.assertEqual(len(without), 1)
            # an engine result alone is not evidence of life: no telemetry means
            # there is nothing to analyse, whatever the result says.
            self.assertFalse(analyze_batch.analyze(*without[0])["crashed"])


class FactionDiscoveryTests(unittest.TestCase):
    def test_analyzer_discovers_every_active_team_in_station_and_telemetry_maps(self):
        match=analyze_batch.new_match()
        match['stations'].update({"FACTION_04":{},"FACTION_06":{}})
        match['flow']['FACTION_05']["income"]=1
        match['battle']['FACTION_07']=[(1,{"value":1})]
        self.assertEqual(analyze_batch.observed_factions([match]),(
            "BLUE","RED","GOLD","FACTION_04","FACTION_05","FACTION_06","FACTION_07"))


class ReportTests(unittest.TestCase):
    def _match(self, tmp):
        fixture = Fixture(tmp)
        records = [
            fixture.record("ACCEPTANCE_SETUP", 0.0, stationPositions={
                "BLUE": {"x": 0.0, "y": 0.0, "z": 0.0}, "RED": {"x": 20000.0, "y": 0.0, "z": 0.0}}),
            faction_record(fixture, faction="BLUE", when=100.0, replacementValue=4400.0,
                           combatantValue=4400.0, damageDealt=1200.0, stationDamageDealt=300.0,
                           economy={"flow": {"productionSpend": 1600.0, "income": 300.0}}),
            faction_record(fixture, faction="RED", when=100.0, replacementValue=1100.0,
                           combatantValue=1100.0, damageDealt=200.0, stationDamageDealt=0.0,
                           economy={"flow": {"productionSpend": 0.0, "income": 300.0}}),
            fixture.record("PRODUCTION", 100.0, action="QUEUE_ACCEPTED", faction="BLUE", cost=1600.0),
            fixture.record("PRODUCTION", 130.0, action="UNIT_SPAWNED", faction="BLUE",
                           spawnedCount=1, role="capital", **{"class": "GTVA Colossus"},
                           placements=[{"x": 5000.0, "y": 0.0, "z": 0.0}]),
            fixture.record("AI_BUILD_DECISION", 100.0, faction="BLUE",
                           reason="SAVING_FOR_DESIRED_ROLE", desiredRole="capital",
                           commandPoints=900.0, bankTarget=13825.0, affordableOptions=0.0),
            fixture.record("CONTEST", 100.0, faction="BLUE", groupCount=2, valueOnPrimary=10.0,
                           valueOnGroups=5.0, stalledGroups=1, worstStallSeconds=45.0,
                           staleOrders=0, servicedShips=1, stationHull=0.8, missionCounts={}),
            fixture.record("OUTCOME_CAUSE", 200.0, faction="RED", targetName="RTS Red Station",
                           elapsed=200.0, totalAttributedHullDamage=5000.0,
                           killers=[{"weapon": "BFRed", "attackerFaction": "BLUE", "beam": True,
                                     "hullDamage": 4000.0, "share": 0.8}],
                           snapshot={"BLUE": {"commandPoints": 900.0, "stationHull": 1.0},
                                     "RED": {"commandPoints": 10.0, "stationHull": 0.0}}),
            fixture.record("BATTLE_END", 210.0, result="BLUE", globalResolved=True, victorFaction='BLUE'),
        ]
        run = fixture.write(records, plan={"max_sim_time": 3000})
        return analyze_batch.analyze(run)

    def test_report_keeps_its_sections_and_adds_the_new_ones(self):
        with TemporaryDirectory() as tmp:
            match = self._match(tmp)
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                stats = analyze_batch.report([match], "TEST", True)
            text = buffer.getvalue()

        for section in ("-- production --", "-- capital spawn placement",
                        "-- base damage per hit", "-- station damage dealt",
                        "-- order compliance and progress (CONTEST) --",
                        "-- build decisions (AI_BUILD_DECISION) --", "-- execution (EXECUTION) --",
                        "-- order telemetry (COUNTERS", "-- losses (LOSS) --",
                        "-- operations (OPERATION) --", "-- friendly fire (FRIENDLY_HIT) --",
                        "-- fleet service and station repair --", "-- event mix --",
                        "-- outcome cause (who killed which base) --",
                        "-- arms race (who led on surviving combatant value) --", "-- outcomes --"):
            self.assertIn(section, text, f"report lost the {section} section")

        self.assertIn("telemetry records      : 9", text)
        self.assertEqual(stats["records"], 9)
        self.assertEqual(stats["crashed"], 0)
        self.assertEqual(stats["natural"], 1)
        self.assertEqual(stats["queued_spend"], 1600.0)
        self.assertEqual(stats["flow_spend"], 1600.0)
        self.assertEqual(stats["station_damage"], 300.0)
        self.assertEqual(stats["capitals"], 1)
        self.assertIn("no affordable option", text)

    def test_report_tolerates_a_match_with_nothing_in_it(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            run = fixture.write([faction_record(fixture)])
            for path in (run / "probe" / "data").glob("rts-ai-*.jsonl"):
                path.unlink()
            match = analyze_batch.analyze(run)
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                stats = analyze_batch.report([match], "TEST", False)
            text = buffer.getvalue()
        self.assertIn("no LOSS records", text)
        self.assertIn("no COUNTERS records", text)
        self.assertIn("no AI_BUILD_DECISION records", text)
        self.assertEqual(stats["crashed"], 0)

    def test_compare_prints_both_sides(self):
        with TemporaryDirectory() as tmp:
            match = self._match(tmp)
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                left = analyze_batch.report([match], "TEST", False)
                right = analyze_batch.report([match], "TEST", False)
                analyze_batch.compare(left, right, "current", "baseline")
            text = buffer.getvalue()
        self.assertIn("-- side-by-side --", text)
        self.assertIn("supersede", text)
        for name, _fmt in analyze_batch.COMPARE_ROWS:
            self.assertIn(name, text)


class MainTests(unittest.TestCase):
    def test_main_returns_zero_for_a_healthy_cap_terminated_batch(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            fixture.write([faction_record(fixture, when=2990.0)],
                          plan={"max_sim_time": 3000}, name="a-1")
            fixture.write([faction_record(fixture, when=2990.0)],
                          plan={"max_sim_time": 3000}, name="a-2")
            buffer = io.StringIO()
            argv = sys.argv
            sys.argv = ["analyze_batch.py", tmp]
            try:
                with contextlib.redirect_stdout(buffer):
                    code = analyze_batch.main()
            finally:
                sys.argv = argv
            text = buffer.getvalue()
        self.assertEqual(code, 0, text)
        self.assertIn("(2 matches)", text)
        self.assertIn("crashed / no telemetry : 0", text)

    def test_main_returns_nonzero_when_a_match_has_no_telemetry(self):
        with TemporaryDirectory() as tmp:
            fixture = Fixture(tmp)
            fixture.write([faction_record(fixture, when=2990.0)], plan={"max_sim_time": 3000},
                          name="a-1")
            broken = fixture.write([faction_record(fixture)], result={"seed": 5}, name="a-2")
            (broken / "probe" / "data" / "rts-ai-20260930-000000.jsonl").unlink()
            buffer = io.StringIO()
            argv = sys.argv
            sys.argv = ["analyze_batch.py", tmp, "--baseline", tmp]
            try:
                with contextlib.redirect_stdout(buffer):
                    code = analyze_batch.main()
            finally:
                sys.argv = argv
            text = buffer.getvalue()
        self.assertEqual(code, 2)
        self.assertIn("-- side-by-side --", text)
        self.assertIn("(2 matches)", text)


if __name__ == "__main__":
    unittest.main()
