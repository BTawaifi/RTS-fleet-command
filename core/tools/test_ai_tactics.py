"""Tests for ai_tactics.

Three kinds of fixture:

  * SYNTHETIC telemetry written to a temp directory. Each metric is driven with
    records engineered to produce a known value, so a sign error or a filter
    that never matches fails here rather than silently reporting n/a against a
    real batch.
  * DISCRIMINATION fixtures that build a deliberately good and a deliberately
    bad run from the same generator, proving the metric moves the right way
    without consulting a staged batch.
  * Shape guards for the things that bit this analyser while it was being
    written: string-typed telemetry scalars, the mislabelled FACTION
    damageDealt field, and record shapes the emitter is documented to produce.

Run from this directory:  python -m pytest -q
"""

import json
import math
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ai_tactics as at


# --------------------------------------------------------------------------
# Fixture helpers
# --------------------------------------------------------------------------

SCHEMA = 2.0


class RunBuilder:
    """Writes synthetic telemetry in the emitter's own record shape."""

    def __init__(self, path):
        self.path = path
        self._sequence = 0
        self._handle = open(path, "w", encoding="utf-8")

    def emit(self, event, data, time):
        self._sequence += 1
        self._handle.write(json.dumps(
            {"schema": SCHEMA, "sequence": self._sequence,
             "time": time, "event": event, "data": data},
            sort_keys=True) + "\n")

    def close(self):
        self._handle.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def node(group, value, x, z, target_x=0.0, target_z=0.0, mission="PRIMARY",
         role="fighter", count=4, signature=7):
    return {"group": group, "value": value, "x": x, "z": z, "radius": 100.0,
            "count": count, "mission": mission, "role": role,
            "targetX": target_x, "targetZ": target_z,
            "targetSignature": signature}


def write_batch(directory, runs):
    """runs: list of (filename, list of (event, data, time))."""
    os.makedirs(directory, exist_ok=True)
    for name, records in runs:
        with RunBuilder(os.path.join(directory, name)) as builder:
            for event, data, time in records:
                builder.emit(event, data, time)
    return directory


def analyse_single(directory):
    return at.analyse_batch(directory)


# --------------------------------------------------------------------------
# Reader
# --------------------------------------------------------------------------


class TestReader(unittest.TestCase):

    def test_streams_only_requested_events(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "rts-ai-x.jsonl")
            with RunBuilder(path) as b:
                b.emit("COHESION", {"faction": "BLUE", "groupCount": 1}, 1.0)
                b.emit("LOSS", {"faction": "BLUE"}, 2.0)
                b.emit("UNIT", {"faction": "BLUE"}, 3.0)
            got = [e for _t, e, _d in at.iter_records(path, ("COHESION", "LOSS"))]
            self.assertEqual(got, ["COHESION", "LOSS"])

    def test_substring_prefilter_never_drops_a_matching_record(self):
        """The prefilter must be a superset. A target name that happens to
        contain an event word must not change the result."""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "rts-ai-x.jsonl")
            with RunBuilder(path) as b:
                b.emit("COHESION", {"faction": "BLUE", "primaryName": "LOSS-TEST",
                                    "groupCount": 2}, 1.0)
            got = list(at.iter_records(path, ("COHESION",)))
            self.assertEqual(len(got), 1)
            self.assertEqual(got[0][2]["primaryName"], "LOSS-TEST")

    def test_malformed_line_is_skipped_not_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "rts-ai-x.jsonl")
            with RunBuilder(path) as b:
                b.emit("LOSS", {"faction": "BLUE"}, 1.0)
            with open(path, "a", encoding="utf-8") as h:
                h.write("{not json at all\n")
            with RunBuilder(os.path.join(tmp, "rts-ai-y.jsonl")) as b:
                b.emit("LOSS", {"faction": "RED"}, 2.0)
            result = at.analyse_batch(tmp)
            self.assertEqual(result["aggregate"]["_losses"], 2)

    def test_missing_time_field_does_not_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "rts-ai-x.jsonl")
            with open(path, "w", encoding="utf-8") as h:
                h.write(json.dumps({"event": "LOSS", "data": {"faction": "BLUE"},
                                    "sequence": 1, "schema": 2.0}) + "\n")
            got = list(at.iter_records(path, ("LOSS",)))
            self.assertEqual(len(got), 1)
            self.assertEqual(got[0][0], 0.0)

    def test_data_that_is_not_an_object_is_tolerated(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "rts-ai-x.jsonl")
            with open(path, "w", encoding="utf-8") as h:
                h.write(json.dumps({"event": "LOSS", "data": "oops",
                                    "sequence": 1, "time": 1.0, "schema": 2.0}) + "\n")
            got = list(at.iter_records(path, ("LOSS",)))
            self.assertEqual(got[0][2], {})

    def test_find_telemetry_only_matches_rts_ai_jsonl(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "results", "w", "x", "probe", "data"))
            data = os.path.join(tmp, "results", "w", "x", "probe", "data")
            for name in ("rts-ai-1.jsonl", "other.jsonl", "rts-ai-x.txt",
                         "rts-ai.jsonl.bak"):
                open(os.path.join(data, name), "w").close()
            found = [os.path.basename(p) for p in at.find_telemetry(tmp)]
            self.assertEqual(found, ["rts-ai-1.jsonl"])


# --------------------------------------------------------------------------
# Numeric coercion - the emitter and older batches disagree on types
# --------------------------------------------------------------------------


class TestCoercion(unittest.TestCase):

    def test_num_handles_string_scalars(self):
        self.assertEqual(at._num("12.5"), 12.5)
        self.assertEqual(at._num(7), 7.0)

    def test_num_rejects_junk_without_raising(self):
        for junk in (None, "unknown", "", "abc", float("nan"), float("inf")):
            self.assertEqual(at._num(junk), 0.0)

    def test_num_default_is_returned_for_junk(self):
        self.assertEqual(at._num(None, default=-1.0), -1.0)
        self.assertEqual(at._num("nope", default=-1.0), -1.0)

    def test_string_typed_metrics_still_produce_values(self):
        """session-fix writes damageDealt as 'unknown'. Every field must survive
        string-typed telemetry."""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "rts-ai-x.jsonl")
            with RunBuilder(path) as b:
                for t in range(10):
                    b.emit("CONTEST", {
                        "faction": "BLUE", "valueOnPrimary": "100",
                        "valueOnGroups": "50", "groupCount": "2",
                        "stalledGroups": "1", "worstStallSeconds": "40",
                        "stationHull": "0.5", "missionCounts": {"PRIMARY": "2"},
                    }, float(t))
                b.emit("FACTION", {"faction": "BLUE", "received": "500",
                                   "damageDealt": "unknown"}, 20.0)
            result = at.analyse_batch(tmp)
            m = result["aggregate"]
            self.assertIsNotNone(m["objective_commit_ratio"]["mean"])
            self.assertAlmostEqual(m["objective_commit_ratio"]["mean"], 100 / 150.0)
            self.assertAlmostEqual(m["mean_groups_per_faction"]["mean"], 2.0)


# --------------------------------------------------------------------------
# Metric registry
# --------------------------------------------------------------------------


class TestRegistry(unittest.TestCase):

    def test_every_metric_declares_a_known_polarity(self):
        for name, spec in at.METRICS.items():
            self.assertIn(spec["polarity"],
                          (at.HIGHER_BETTER, at.LOWER_BETTER, at.AMBIGUOUS),
                          "%s has an undeclared polarity" % name)

    def test_ambiguous_metrics_are_flagged_diagnostic(self):
        """An unresolved direction must never be silently scored."""
        for name, spec in at.METRICS.items():
            if spec["polarity"] == at.AMBIGUOUS:
                self.assertTrue(spec.get("diagnostic"),
                                "%s is ambiguous but not marked diagnostic" % name)

    def test_scored_metrics_are_not_flagged_diagnostic(self):
        for name, spec in at.METRICS.items():
            if spec["polarity"] != at.AMBIGUOUS:
                self.assertFalse(spec.get("diagnostic"),
                                 "%s is scored and marked diagnostic" % name)

    def test_every_metric_documents_itself(self):
        for name, spec in at.METRICS.items():
            for field in ("title", "description", "rationale", "unit", "source"):
                self.assertTrue(spec.get(field),
                                "%s is missing %s" % (name, field))

    def test_every_family_is_reachable_from_the_registry(self):
        for family, _label in at.FAMILIES:
            self.assertTrue(any(s["family"] == family for s in at.METRICS.values()),
                            "family %s has no metrics" % family)

    def test_registry_covers_all_families_and_no_orphans(self):
        covered = {s["family"] for s in at.METRICS.values()}
        declared = {f for f, _ in at.FAMILIES}
        self.assertEqual(covered, declared)

    def test_metric_help_renders_every_metric(self):
        for name in at.METRICS:
            text = at.metric_help(name)
            self.assertIn(name, text)
            self.assertIn("polarity", text)

    def test_gaps_all_name_the_field_that_closes_them(self):
        for question, why, field in at.GAPS:
            self.assertTrue(question and why and field)
            # a gap entry that names no emitter field is not actionable
            self.assertTrue(any(ch.isupper() for ch in field),
                            "gap %r names no field" % question)


# --------------------------------------------------------------------------
# Concentration
# --------------------------------------------------------------------------


class TestConcentration(unittest.TestCase):

    def _contest(self, primary, groups_value, count=1, hull=1.0, missions=None):
        return [("CONTEST", {
            "faction": "BLUE", "valueOnPrimary": primary,
            "valueOnGroups": groups_value, "groupCount": count,
            "stalledGroups": 0, "worstStallSeconds": 0, "stationHull": hull,
            "missionCounts": missions or {},
            "primaryName": "RTS Red Station", "groups": [],
        }, 0.0)]

    def test_commit_ratio_all_on_base_is_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", self._contest(100, 0) * 5)])
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["objective_commit_ratio"]["mean"], 1.0)

    def test_commit_ratio_all_on_groups_is_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", self._contest(0, 100) * 5)])
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["objective_commit_ratio"]["mean"], 0.0)

    def test_commit_ratio_excludes_samples_with_no_force_out(self):
        """A faction with nothing deployed has no commitment ratio. Including
        idle samples would drag every early-game number toward zero."""
        with tempfile.TemporaryDirectory() as tmp:
            records = self._contest(0, 0) * 20 + self._contest(100, 0) * 5
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["objective_commit_ratio"]["mean"], 1.0)

    def test_commit_ratio_is_a_share_of_value_not_of_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", self._contest(1000, 1000) * 3)])
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["objective_commit_ratio"]["mean"], 0.5)

    def test_duty_cycle_counts_samples_with_value_on_base(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = (self._contest(100, 0) * 3 + self._contest(0, 100) * 1) * 4
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["commitment_duty_cycle"]["mean"], 0.75)

    def test_peak_force_is_the_maximum_not_the_mean(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = self._contest(10, 0) + self._contest(5000, 0) + self._contest(10, 0)
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["value_on_primary_peak"]["mean"], 5000.0)

    def test_group_hhi_is_one_when_all_value_is_in_one_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            with RunBuilder(os.path.join(write_batch(tmp, []), "rts-ai-a.jsonl")) as b:
                b.emit("COHESION", {"faction": "BLUE", "groupCount": 1, "nodes": [
                    node("W1", 100, 0, 0), node("W2", 0, 0, 0)]}, 1.0)
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["group_value_hhi"]["mean"], 1.0)

    def test_group_hhi_halves_when_value_is_split_evenly(self):
        with tempfile.TemporaryDirectory() as tmp:
            with RunBuilder(os.path.join(write_batch(tmp, []), "rts-ai-a.jsonl")) as b:
                b.emit("COHESION", {"faction": "BLUE", "groupCount": 2, "nodes": [
                    node("W1", 100, 0, 0), node("W2", 100, 0, 0)]}, 1.0)
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["group_value_hhi"]["mean"], 0.5)

    def test_mean_groups_counts_groups_not_samples(self):
        """CONTEST carries groupCount alongside stalledGroups, so it is the
        denominator for the concentration and stall families alike."""
        with tempfile.TemporaryDirectory() as tmp:
            with RunBuilder(os.path.join(write_batch(tmp, []), "rts-ai-a.jsonl")) as b:
                for t in range(4):
                    b.emit("CONTEST", {"faction": "BLUE", "groupCount": 3,
                                       "valueOnPrimary": 0, "valueOnGroups": 1,
                                       "stalledGroups": 0, "worstStallSeconds": 0,
                                       "stationHull": 1.0, "missionCounts": {},
                                       "groups": []}, float(t))
                for t in range(4):
                    b.emit("CONTEST", {"faction": "RED", "groupCount": 5,
                                       "valueOnPrimary": 0, "valueOnGroups": 1,
                                       "stalledGroups": 0, "worstStallSeconds": 0,
                                       "stationHull": 1.0, "missionCounts": {},
                                       "groups": []}, float(t))
            m = analyse_single(tmp)["aggregate"]
            # (3*4 + 5*4) / 8 samples, not divided by faction count
            self.assertAlmostEqual(m["mean_groups_per_faction"]["mean"], 4.0)


# --------------------------------------------------------------------------
# Arrival coherence
# --------------------------------------------------------------------------


class TestArrivalCoherence(unittest.TestCase):

    def _episode(self, times, primary):
        return [("CONTEST", {
            "faction": "BLUE", "valueOnPrimary": p, "valueOnGroups": 100,
            "groupCount": 1, "stalledGroups": 0, "worstStallSeconds": 0,
            "stationHull": 1.0, "missionCounts": {}, "groups": [],
        }, float(t)) for t, p in zip(times, primary)]

    def test_episodes_count_contiguous_runs(self):
        """An episode ends when valueOnPrimary returns to zero, so the gaps
        between the three attacks must be filled with disengaged samples."""
        with tempfile.TemporaryDirectory() as tmp:
            records = (self._episode([0, 10, 20], [50, 50, 50])
                       + self._episode([40, 50], [0, 0])        # disengaged
                       + self._episode([100], [50])
                       + self._episode([150, 160], [0, 0])      # disengaged
                       + self._episode([200, 210], [50, 50]))
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["assault_episodes_per_minute"],
                                   3.0 / (210.0 / 60.0), places=4)

    def test_episode_duration_spans_the_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = self._episode([100, 130, 160, 190], [50, 50, 50, 50])
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["assault_sustain_seconds"], 90.0)

    def test_single_sample_episode_has_zero_duration(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", self._episode([100], [50]))])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["assault_sustain_seconds"], 0.0)

    def test_volatility_is_zero_for_constant_commitment(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = self._episode([0, 10, 20, 30, 40], [100] * 5)
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["value_volatility"], 0.0, places=9)

    def test_volatility_rises_with_sawtooth_commitment(self):
        with tempfile.TemporaryDirectory() as tmp:
            steady = self._episode([0, 10, 20, 30, 40], [100] * 5)
            sawtooth = self._episode([0, 10, 20, 30, 40], [0, 200, 0, 200, 0])
            write_batch(tmp, [("rts-ai-steady.jsonl", steady),
                              ("rts-ai-saw.jsonl", sawtooth)])
            runs = {r["_file"]: r for r in analyse_single(tmp)["runs"]}
            steady_cv = runs["rts-ai-steady.jsonl"]["value_volatility"]
            saw_cv = runs["rts-ai-saw.jsonl"]["value_volatility"]
            self.assertAlmostEqual(steady_cv, 0.0, places=9)
            self.assertGreater(saw_cv, steady_cv)


# --------------------------------------------------------------------------
# Stall discipline
# --------------------------------------------------------------------------


class TestStallDiscipline(unittest.TestCase):

    def _contest(self, t, stalled, count, worst=0.0, stalled_seconds=0.0):
        return ("CONTEST", {
            "faction": "BLUE", "valueOnPrimary": 0, "valueOnGroups": 100,
            "groupCount": count, "stalledGroups": stalled,
            "worstStallSeconds": worst, "stationHull": 1.0,
            "missionCounts": {},
            # The emitter lists every group with its own stalledSeconds, so the
            # recovery path is driven by a group that stays present with a
            # falling stalledSeconds rather than by the group disappearing.
            "groups": [{"group": "W1", "stalledSeconds": stalled_seconds,
                        "distance": 5000.0, "value": 1.0}],
        }, float(t))

    def test_stalled_ratio_is_per_group_not_absolute(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", [
                self._contest(0, 2, 4), self._contest(10, 1, 2)])])
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["stalled_group_ratio"]["mean"], (0.5 + 0.5) / 2)

    def test_samples_with_no_groups_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", [
                self._contest(0, 0, 0), self._contest(10, 2, 2)])])
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["stalled_group_ratio"]["mean"], 1.0)

    def test_worst_stall_p95_uses_the_tail(self):
        """The p95 must track the long tail, so the tail has to be big enough to
        reach the 95th percentile rather than sitting at a single sample."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [self._contest(i * 10, 0, 1, worst=0.0) for i in range(90)]
            records += [self._contest(900 + i * 10, 0, 1, worst=500.0)
                        for i in range(10)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            m = analyse_single(tmp)["aggregate"]
            self.assertAlmostEqual(m["stall_p95_seconds"]["mean"], 500.0)

    def test_recovery_is_measured_from_flag_to_clear(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [
                self._contest(0, 1, 1, stalled_seconds=40.0),
                self._contest(10, 1, 1, stalled_seconds=50.0),
                self._contest(20, 1, 1, stalled_seconds=60.0),
                self._contest(30, 0, 1, stalled_seconds=0.0),
                self._contest(40, 0, 1, stalled_seconds=0.0),
            ]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["stall_recovery_seconds"], 30.0)

    def test_a_group_that_stays_stalled_never_counts_as_recovered(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [self._contest(i * 10, 1, 1, stalled_seconds=40.0)
                       for i in range(5)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertIsNone(run["stall_recovery_seconds"])

    def test_never_stalling_produces_no_recovery_samples(self):
        """A healthy fleet must report n/a, never a flattering zero."""
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl",
                               [self._contest(i * 10, 0, 1) for i in range(5)])])
            run = analyse_single(tmp)["runs"][0]
            self.assertIsNone(run["stall_recovery_seconds"])


# --------------------------------------------------------------------------
# Depth
# --------------------------------------------------------------------------


class TestDepth(unittest.TestCase):

    def _cohesion(self, t, node_x, node_z, station=(-9000.0, -5196.0),
                  primary=(9000.0, -5196.0), edge=0):
        return ("COHESION", {
            "faction": "BLUE", "stationX": station[0], "stationZ": station[1],
            "primaryX": primary[0], "primaryZ": primary[1],
            "arenaHalfExtent": 13500.0, "groupCount": 1,
            "nearArenaEdge": edge, "pairs": [],
            "nodes": [node("W1", 100, node_x, node_z, primary[0], primary[1])],
        }, float(t))

    def test_group_past_midpoint_counts_as_deep(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", [self._cohesion(0, 4000, 0)])])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["deep_commit_fraction"], 1.0)

    def test_group_at_home_is_not_deep(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", [self._cohesion(0, -8000, -5196)])])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["deep_commit_fraction"], 0.0)

    def test_one_deep_group_is_enough_for_the_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [("COHESION", {
                "faction": "BLUE", "stationX": -9000.0, "stationZ": -5196.0,
                "primaryX": 9000.0, "primaryZ": -5196.0, "groupCount": 2,
                "nearArenaEdge": 0, "pairs": [],
                "nodes": [node("W1", 100, -8000, -5196),
                          node("W2", 100, 4000, -5196)],
            }, 0.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["deep_commit_fraction"], 1.0)

    def test_edge_fraction_counts_flagged_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [self._cohesion(0, 0, 0, edge=0),
                       self._cohesion(10, 0, 0, edge=1),
                       self._cohesion(20, 0, 0, edge=2)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["near_arena_edge_fraction"], 2 / 3.0)

    def test_missing_station_is_not_treated_as_the_arena_origin(self):
        """A missing coordinate means unknown. Coercing it to 0.0 would place
        the station at the arena origin and turn every distance comparison into
        a confident wrong number."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [("COHESION", {
                "faction": "BLUE", "stationX": None, "stationZ": None,
                "primaryX": 9000.0, "primaryZ": -5196.0,
                "arenaHalfExtent": 13500.0, "groupCount": 1,
                "nearArenaEdge": 0, "pairs": [],
                "nodes": [node("W1", 100, 4000, -5196, 9000.0, -5196)],
            }, 0.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            # without a station the midpoint test cannot run
            self.assertAlmostEqual(run["deep_commit_fraction"], 0.0)
            self.assertIsNone(run["station_guard_response"])

    def test_missing_primary_is_not_treated_as_the_arena_origin(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [("COHESION", {
                "faction": "BLUE", "stationX": -9000.0, "stationZ": -5196.0,
                "primaryX": None, "primaryZ": None,
                "arenaHalfExtent": 13500.0, "groupCount": 1,
                "nearArenaEdge": 0, "pairs": [],
                "nodes": [node("W1", 100, 4000, -5196)],
            }, 0.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["deep_commit_fraction"], 0.0)

    def test_string_coordinates_are_rejected_rather_than_guessed(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [("COHESION", {
                "faction": "BLUE", "stationX": "unknown", "stationZ": "unknown",
                "primaryX": 9000.0, "primaryZ": -5196.0,
                "arenaHalfExtent": 13500.0, "groupCount": 1,
                "nearArenaEdge": 0, "pairs": [],
                "nodes": [node("W1", 100, 4000, -5196, 9000.0, -5196)],
            }, 0.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["deep_commit_fraction"], 0.0)


# --------------------------------------------------------------------------
# Withdrawal
# --------------------------------------------------------------------------


class TestWithdrawal(unittest.TestCase):

    def test_withdrawals_count_reggroup_and_retreat_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = []
            for i, mission in enumerate(["PRIMARY", "REGROUP", "RETREAT", "SCREEN"]):
                records.append(("OBJECTIVE", {
                    "faction": "BLUE", "mission": mission, "ship": i,
                    "previousAge": 10.0, "status": "ORDER_ACCEPTED"}, float(i)))
            for i in range(5):
                records.append(("LOSS", {"faction": "BLUE"}, 100.0 + i))
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["withdrawal_per_loss"], 2 / 5.0)

    def test_withdrawals_per_loss_is_none_without_losses(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", [
                ("OBJECTIVE", {"faction": "BLUE", "mission": "RETREAT",
                               "previousAge": 1.0}, 1.0)])])
            run = analyse_single(tmp)["runs"][0]
            self.assertIsNone(run["withdrawal_per_loss"])

    def test_retreat_duty_cycle_is_group_time_not_transition_count(self):
        """missionCounts is a per-sample group histogram, so the duty cycle is a
        share of group-samples. Counting OBJECTIVE transitions instead would
        weight a faction that re-tasks often more heavily than one that does
        not."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [
                ("CONTEST", {"faction": "BLUE", "valueOnPrimary": 0,
                             "valueOnGroups": 100, "groupCount": 4,
                             "stalledGroups": 0, "worstStallSeconds": 0,
                             "stationHull": 1.0, "groups": [],
                             "missionCounts": {"PRIMARY": 3, "REGROUP": 1}}, 0.0),
                ("CONTEST", {"faction": "BLUE", "valueOnPrimary": 0,
                             "valueOnGroups": 100, "groupCount": 2,
                             "stalledGroups": 0, "worstStallSeconds": 0,
                             "stationHull": 1.0, "groups": [],
                             "missionCounts": {"PRIMARY": 1}}, 10.0),
            ]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            # 1 regrouping group-sample out of 5 group-samples
            self.assertAlmostEqual(run["retreat_duty_cycle"], 0.2)

    def test_order_stickiness_averages_previous_age(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [("OBJECTIVE", {"faction": "BLUE", "mission": "PRIMARY",
                                      "previousAge": age}, float(i))
                       for i, age in enumerate([10.0, 20.0, 30.0])]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["order_commitment_seconds"], 20.0)


# --------------------------------------------------------------------------
# Defensive anchoring
# --------------------------------------------------------------------------


class TestDefence(unittest.TestCase):

    def _pair(self, t, hull_before, node_x, node_z, hull_after=1.0):
        """One CONTEST that sets stationHull, then COHESION samples."""
        return [
            ("CONTEST", {"faction": "BLUE", "valueOnPrimary": 0,
                         "valueOnGroups": 100, "groupCount": 1, "stalledGroups": 0,
                         "worstStallSeconds": 0, "stationHull": hull_before,
                         "missionCounts": {}, "groups": []}, float(t)),
            ("COHESION", {"faction": "BLUE", "stationX": 0.0, "stationZ": 0.0,
                          "primaryX": 9000.0, "primaryZ": 0.0,
                          "arenaHalfExtent": 13500.0, "groupCount": 1,
                          "nearArenaEdge": 0, "pairs": [],
                          "nodes": [node("W1", 100, node_x, node_z, 9000.0, 0.0)]},
             float(t) + 1.0),
            ("CONTEST", {"faction": "BLUE", "valueOnPrimary": 0,
                         "valueOnGroups": 100, "groupCount": 1, "stalledGroups": 0,
                         "worstStallSeconds": 0, "stationHull": hull_after,
                         "missionCounts": {}, "groups": []}, float(t) + 2.0),
        ]

    def test_value_coming_home_when_station_is_hit_scores_positive(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = (self._pair(0, 1.0, 8000, 0)        # healthy: value far
                       + self._pair(100, 0.5, 1000, 0))   # hit: value at home
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertGreater(run["station_guard_response"], 0.0)

    def test_value_staying_away_when_station_is_hit_scores_negative(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = (self._pair(0, 1.0, 1000, 0)        # healthy: at home
                       + self._pair(100, 0.5, 8000, 0))   # hit: still away
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertLess(run["station_guard_response"], 0.0)

    def test_station_hull_min_tracks_the_deepest_damage(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [("CONTEST", {"faction": "BLUE", "stationHull": hull,
                                    "valueOnPrimary": 0, "valueOnGroups": 0,
                                    "groupCount": 0, "missionCounts": {},
                                    "groups": []}, float(t))
                       for t, hull in enumerate([1.0, 0.8, 0.4, 0.6])]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["station_hull_min"], 0.4)


# --------------------------------------------------------------------------
# Threat response
# --------------------------------------------------------------------------


class TestThreatResponse(unittest.TestCase):

    def _decisions(self, count, role):
        return [("DECISION", {
            "faction": "BLUE", "reason": "CAPITAL_THREAT_PREEMPTION",
            "mission": "INTERCEPT", "targetRole": role,
            "targetX": 5000.0, "targetZ": 0.0}, float(i))
            for i in range(count)]

    def test_preempt_rate_is_per_thousand_decisions(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = self._decisions(10, "capital")
            records += [("DECISION", {"faction": "BLUE", "reason": "DEFEND_BASE"},
                         100.0 + i) for i in range(90)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["capital_preempt_rate"], 100.0)

    def test_decisions_without_preemption_is_a_real_zero(self):
        """Fifty decisions and no preemptions is a measured zero, and it is the
        damning kind. Only the ratio-with-no-denominator metric is undefined."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [("DECISION", {"faction": "BLUE", "reason": "DEFEND_BASE",
                                     "targetRole": "juggernaut"}, float(i))
                       for i in range(50)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["capital_preempt_rate"], 0.0)
            # no preemptions means there is no population to take a share of
            self.assertIsNone(run["preempt_on_capital_rate"])

    def test_no_decisions_at_all_reports_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", [("LOSS", {"faction": "BLUE"}, 1.0)])])
            run = analyse_single(tmp)["runs"][0]
            self.assertIsNone(run["capital_preempt_rate"])
            self.assertIsNone(run["preempt_on_capital_rate"])

    def test_preempt_on_capital_counts_capital_and_juggernaut(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = (self._decisions(3, "capital")
                       + self._decisions(2, "juggernaut")
                       + self._decisions(5, "escort"))
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["preempt_on_capital_rate"], 0.5)


# --------------------------------------------------------------------------
# Deception
# --------------------------------------------------------------------------


class TestDeception(unittest.TestCase):

    def test_decoy_needs_a_position_from_cohesion_first(self):
        """TACTIC carries the group id but no position. Without a prior COHESION
        placement the decoy is unscoreable and must be reported as unplaced,
        not as a conversion failure."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [("TACTIC", {"faction": "BLUE", "group": "W1",
                                   "mission": "FEINT", "reason": "TAUNT_DECOY",
                                   "target": 5.0, "targetName": "Red 1"}, 10.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertIsNone(run["lure_conversion"])
            self.assertEqual(run["_decoys_unplaced"], 1)

    def test_decoy_is_not_placed_from_a_positionless_cohesion_node(self):
        """A node with no x/z must not be recorded at the origin, or every
        decoy would resolve against a fabricated position."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [
                ("COHESION", {"faction": "BLUE", "stationX": -9000.0,
                              "stationZ": 0.0, "primaryX": 9000.0, "primaryZ": 0.0,
                              "groupCount": 1, "nearArenaEdge": 0, "pairs": [],
                              "nodes": [{"group": "W1", "value": 100}]}, 0.0),
                ("TACTIC", {"faction": "BLUE", "group": "W1", "mission": "LURE",
                            "reason": "PURSUER_LOCKED"}, 10.0),
            ]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertEqual(run["_decoys_unplaced"], 1)
            self.assertIsNone(run["lure_conversion"])

    def test_decision_without_a_target_position_cannot_convert_a_decoy(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [
                ("COHESION", {"faction": "BLUE", "stationX": -9000.0,
                              "stationZ": 0.0, "primaryX": 9000.0, "primaryZ": 0.0,
                              "groupCount": 1, "nearArenaEdge": 0, "pairs": [],
                              "nodes": [node("W1", 100, 2000, 0)]}, 0.0),
                ("TACTIC", {"faction": "BLUE", "group": "W1", "mission": "LURE",
                            "reason": "PURSUER_LOCKED"}, 10.0),
                ("DECISION", {"faction": "RED", "reason": "DEFEND_BASE",
                              "targetX": None, "targetZ": None}, 20.0),
            ]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["lure_conversion"], 0.0)

    def test_enemy_targeting_the_decoy_counts_as_conversion(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [
                ("COHESION", {"faction": "BLUE", "stationX": -9000.0,
                              "stationZ": 0.0, "primaryX": 9000.0, "primaryZ": 0.0,
                              "groupCount": 1, "nearArenaEdge": 0, "pairs": [],
                              "nodes": [node("W1", 100, 2000, 0)]}, 0.0),
                ("TACTIC", {"faction": "BLUE", "group": "W1", "mission": "LURE",
                            "reason": "PURSUER_LOCKED"}, 10.0),
                ("DECISION", {"faction": "RED", "reason": "INTERCEPT_IMMEDIATE_THREAT",
                              "targetX": 2100.0, "targetZ": 100.0}, 20.0),
            ]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["lure_conversion"], 1.0)

    def test_enemy_ignoring_the_decoy_is_not_conversion(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [
                ("COHESION", {"faction": "BLUE", "stationX": -9000.0,
                              "stationZ": 0.0, "primaryX": 9000.0, "primaryZ": 0.0,
                              "groupCount": 1, "nearArenaEdge": 0, "pairs": [],
                              "nodes": [node("W1", 100, 2000, 0)]}, 0.0),
                ("TACTIC", {"faction": "BLUE", "group": "W1", "mission": "LURE",
                            "reason": "PURSUER_LOCKED"}, 10.0),
                ("DECISION", {"faction": "RED", "reason": "DEFEND_BASE",
                              "targetX": -8000.0, "targetZ": 0.0}, 20.0),
            ]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["lure_conversion"], 0.0)

    def test_factions_own_decoys_do_not_count_as_conversion(self):
        """Otherwise the AI converting its own lure would read as the bait
        working."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [
                ("COHESION", {"faction": "BLUE", "stationX": -9000.0,
                              "stationZ": 0.0, "primaryX": 9000.0, "primaryZ": 0.0,
                              "groupCount": 1, "nearArenaEdge": 0, "pairs": [],
                              "nodes": [node("W1", 100, 2000, 0)]}, 0.0),
                ("TACTIC", {"faction": "BLUE", "group": "W1", "mission": "LURE",
                            "reason": "PURSUER_LOCKED"}, 10.0),
                ("DECISION", {"faction": "BLUE", "reason": "DEFEND_BASE",
                              "targetX": 2000.0, "targetZ": 0.0}, 20.0),
            ]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["lure_conversion"], 0.0)

    def test_tactic_outside_the_deception_missions_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [
                ("COHESION", {"faction": "BLUE", "stationX": -9000.0,
                              "stationZ": 0.0, "primaryX": 9000.0, "primaryZ": 0.0,
                              "groupCount": 1, "nearArenaEdge": 0, "pairs": [],
                              "nodes": [node("W1", 100, 2000, 0)]}, 0.0),
                ("TACTIC", {"faction": "BLUE", "group": "W1", "mission": "INTERCEPT",
                            "reason": "CAPITAL_THREAT_PREEMPTION"}, 10.0),
                ("DECISION", {"faction": "RED", "reason": "DEFEND_BASE",
                              "targetX": 2000.0, "targetZ": 0.0}, 20.0),
            ]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertIsNone(run["lure_conversion"])

    def test_deception_duty_cycle_counts_all_three_missions(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [("CONTEST", {
                "faction": "BLUE", "valueOnPrimary": 0, "valueOnGroups": 100,
                "groupCount": 4, "stalledGroups": 0, "worstStallSeconds": 0,
                "stationHull": 1.0, "groups": [],
                "missionCounts": {"PRIMARY": 3, "FEINT": 1, "LURE": 1, "TRAP": 1}},
                0.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["deception_duty_cycle"], 3 / 6.0)


# --------------------------------------------------------------------------
# Focus fire
# --------------------------------------------------------------------------


class TestFocusFire(unittest.TestCase):

    def _cohesion(self, signatures):
        nodes = [node("W%d" % i, 100, 0, 0, signature=s)
                 for i, s in enumerate(signatures)]
        return ("COHESION", {"faction": "BLUE", "groupCount": len(nodes),
                             "stationX": -9000.0, "stationZ": 0.0,
                             "primaryX": 9000.0, "primaryZ": 0.0,
                             "arenaHalfExtent": 13500.0, "nearArenaEdge": 0,
                             "pairs": [], "nodes": nodes}, 0.0)

    def test_one_shared_target_is_maximal_concentration(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", [self._cohesion([1, 1, 1])])])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["target_value_hhi"], 1.0)

    def test_all_distinct_targets_is_minimal_concentration(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl", [self._cohesion([1, 2, 3])])])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["target_value_hhi"], 1 / 3.0)

    def test_unshared_and_far_pairs_count_as_coincidental(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [("COHESION", {
                "faction": "BLUE", "groupCount": 2, "stationX": 0.0,
                "stationZ": 0.0, "primaryX": 9000.0, "primaryZ": 0.0,
                "arenaHalfExtent": 13500.0, "nearArenaEdge": 0,
                "nodes": [node("W1", 100, 0, 0, signature=1),
                          node("W2", 100, 9000, 0, signature=1)],
                "pairs": [{"a": "W1", "b": "W2", "distance": 9000.0,
                           "gap": 8800.0, "sharedTarget": True}],
            }, 0.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["coincident_share_rate"], 1.0)

    def test_shared_and_close_pairs_are_real_coordination(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [("COHESION", {
                "faction": "BLUE", "groupCount": 2, "stationX": 0.0,
                "stationZ": 0.0, "primaryX": 9000.0, "primaryZ": 0.0,
                "arenaHalfExtent": 13500.0, "nearArenaEdge": 0,
                "nodes": [node("W1", 100, 0, 0, signature=1),
                          node("W2", 100, 1000, 0, signature=1)],
                "pairs": [{"a": "W1", "b": "W2", "distance": 1000.0,
                           "gap": 800.0, "sharedTarget": True}],
            }, 0.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["coincident_share_rate"], 0.0)

    def test_unshared_pairs_are_excluded_from_the_denominator(self):
        """The emitter only emits a pair when targets are shared OR discs
        overlap. An overlap-only pair is not target agreement at all."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [("COHESION", {
                "faction": "BLUE", "groupCount": 2, "stationX": 0.0,
                "stationZ": 0.0, "primaryX": 9000.0, "primaryZ": 0.0,
                "arenaHalfExtent": 13500.0, "nearArenaEdge": 0,
                "nodes": [node("W1", 100, 0, 0, signature=1),
                          node("W2", 100, 200, 0, signature=2)],
                "pairs": [{"a": "W1", "b": "W2", "distance": 200.0,
                           "gap": 0.0, "sharedTarget": False}],
            }, 0.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertIsNone(run["coincident_share_rate"])


# --------------------------------------------------------------------------
# Attrition
# --------------------------------------------------------------------------


class TestAttrition(unittest.TestCase):

    def _faction(self, faction, t, taken, received=1000.0, ff_pairs=()):
        return ("FACTION", {
            "faction": faction, "received": received,
            # deliberately present and deliberately wrong: the emitter fills it
            # from a target-keyed table, so it carries damage RECEIVED
            "damageDealt": float(taken),
            "combatDamageTelemetry": {"interval": {
                "hullDamage": taken, "friendlyFirePairs": list(ff_pairs)}},
        }, float(t))

    def test_damage_dealt_is_derived_from_other_factions(self):
        """FACTION.damageDealt is keyed by TARGET faction in the emitter, so it
        reports damage received. Damage dealt must come from the other two."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [self._faction("BLUE", 0, 1000.0),
                       self._faction("RED", 1, 3000.0),
                       self._faction("GOLD", 2, 5000.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            # BLUE dealt 8000 into RED+GOLD; RED dealt 6000; GOLD dealt 4000
            dealt = run["_damage_dealt_by_faction"]
            self.assertAlmostEqual(dealt["BLUE"], 8000.0)
            self.assertAlmostEqual(dealt["RED"], 6000.0)
            self.assertAlmostEqual(dealt["GOLD"], 4000.0)

    def test_mislabelled_damage_dealt_field_is_ignored(self):
        """damageDealt here holds each faction's own damage taken. Trusting it
        would make every faction look like it dealt exactly what it took."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [self._faction("BLUE", 0, 1000.0),
                       self._faction("RED", 1, 1.0),
                       self._faction("GOLD", 2, 1.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["_damage_dealt_by_faction"]["BLUE"], 2.0)

    def test_damage_per_loss_divides_by_ship_losses(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [self._faction("BLUE", 0, 0.0),
                       self._faction("RED", 1, 1000.0),
                       self._faction("GOLD", 2, 0.0),
                       ("LOSS", {"faction": "BLUE"}, 10.0),
                       ("LOSS", {"faction": "BLUE"}, 20.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            # BLUE dealt 1000 (all RED took) across 2 lost ships
            self.assertAlmostEqual(run["_damage_dealt_by_faction"]["BLUE"], 1000.0)
            self.assertAlmostEqual(run["damage_per_loss"], 500.0)

    def test_damage_per_loss_is_averaged_over_factions_that_lost_ships(self):
        """Factions with no losses have no exchange rate and must not contribute
        a zero, which would drag the mean down for the wrong reason."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [self._faction("BLUE", 0, 0.0),
                       self._faction("RED", 1, 1000.0),
                       self._faction("GOLD", 2, 0.0),
                       ("LOSS", {"faction": "BLUE"}, 10.0),
                       ("LOSS", {"faction": "RED"}, 20.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            # BLUE: 1000/1 = 1000. RED: 0/1 = 0. GOLD lost nothing, excluded.
            self.assertAlmostEqual(run["damage_per_loss"], 500.0)

    def test_exchange_ratio_is_not_forced_to_one(self):
        """Dealt comes from the combat hook and taken from FACTION.received.
        Using one source for both sides would make the ratio exactly 1."""
        with tempfile.TemporaryDirectory() as tmp:
            records = [self._faction("BLUE", 0, 100.0, received=400.0),
                       self._faction("RED", 1, 100.0, received=100.0),
                       self._faction("GOLD", 2, 100.0, received=100.0)]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            # every faction dealt 200; BLUE took 400, the others 100 each
            self.assertAlmostEqual(run["damage_exchange_ratio"],
                                   (200 / 400.0 + 200 / 100.0 + 200 / 100.0) / 3.0)
            self.assertNotAlmostEqual(run["damage_exchange_ratio"], 1.0)

    def test_friendly_fire_share_uses_the_same_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            records = [self._faction("BLUE", 0, 1000.0, ff_pairs=[
                {"attackerName": "a", "targetName": "b", "hullDamage": 100.0}])]
            write_batch(tmp, [("rts-ai-a.jsonl", records)])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["friendly_fire_damage_ratio"], 0.1)

    def test_friendly_fire_absent_is_zero_not_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_batch(tmp, [("rts-ai-a.jsonl",
                               [self._faction("BLUE", 0, 1000.0)])])
            run = analyse_single(tmp)["runs"][0]
            self.assertAlmostEqual(run["friendly_fire_damage_ratio"], 0.0)


# --------------------------------------------------------------------------
# Discrimination: a good run and a bad run from one generator
# --------------------------------------------------------------------------


def good_run(seconds=600, groups=2, on_base=0.8, capital_preempts=60,
             deep=True, capital_role="juggernaut", stalled=0,
             retreat_missions=None):
    """A faction that masses for the objective, answers capital threats, pulls
    damaged ships out, and does not park groups in the open.

    Every dimension a scored metric reads is a parameter, so a test can vary one
    axis at a time and know which metric is responsible for the movement.
    """
    records = []
    station = (-9000.0, -5196.0)
    primary = (9000.0, -5196.0)
    retreat_missions = retreat_missions or {"PRIMARY": max(1, groups - 1),
                                            "REGROUP": 1}
    for t in range(0, seconds, 10):
        value = 4000.0
        on = value * on_base
        group_stalled = [{"group": "W%d" % i, "stalledSeconds": 45.0,
                          "distance": 5000.0, "value": 1.0}
                         for i in range(min(stalled, groups))]
        records.append(("CONTEST", {
            "faction": "BLUE", "valueOnPrimary": on, "valueOnGroups": value - on,
            "groupCount": groups, "stalledGroups": len(group_stalled),
            "worstStallSeconds": 45.0 if group_stalled else 0.0,
            "stationHull": 0.9, "missionCounts": dict(retreat_missions),
            "groups": group_stalled,
            "primaryName": "RTS Red Station"}, float(t)))
    for t in range(0, seconds, 2):
        x = 5000.0 if deep else -9000.0
        nodes = [node("W%d" % i, 4000.0 // groups, x, -5196.0,
                      primary[0], primary[1], signature=7)
                 for i in range(groups)]
        records.append(("COHESION", {
            "faction": "BLUE", "stationX": station[0], "stationZ": station[1],
            "primaryX": primary[0], "primaryZ": primary[1],
            "arenaHalfExtent": 13500.0, "groupCount": groups,
            "nearArenaEdge": 0, "pairs": [], "nodes": nodes}, float(t)))
    for i in range(capital_preempts):
        records.append(("DECISION", {
            "faction": "BLUE", "reason": "CAPITAL_THREAT_PREEMPTION",
            "mission": "INTERCEPT", "targetRole": capital_role,
            "targetX": 5000.0, "targetZ": 0.0}, 100.0 + i))
    for i in range(seconds // 10):
        records.append(("DECISION", {"faction": "BLUE", "reason": "DEFEND_BASE"},
                        float(i)))
    return records


def bad_run(seconds=600, groups=8, on_base=0.0, capital_preempts=0,
            deep=False, capital_role="escort", stalled=4,
            retreat_missions=None):
    """A dribbling faction: many tiny groups, none committed to the base, no
    capital-threat response, groups parked in the open, and no withdrawal
    doctrine at all.

    `deep` defaults False because a faction that puts nothing on the enemy
    station has no business being past the midpoint either; leaving that
    parameterised lets a test isolate one dimension at a time.
    """
    records = []
    station = (-9000.0, -5196.0)
    primary = (9000.0, -5196.0)
    retreat_missions = retreat_missions or {"PRIMARY": groups // 2,
                                            "SCREEN": groups // 2}
    for t in range(0, seconds, 10):
        value = 8000.0
        on = value * on_base
        group_stalled = [{"group": "W%d" % i, "stalledSeconds": 120.0,
                          "distance": 5000.0, "value": 1.0}
                         for i in range(min(stalled, groups))]
        records.append(("CONTEST", {
            "faction": "BLUE", "valueOnPrimary": on, "valueOnGroups": value - on,
            "groupCount": groups, "stalledGroups": len(group_stalled),
            "worstStallSeconds": 120.0 if group_stalled else 0.0,
            "stationHull": 1.0, "missionCounts": dict(retreat_missions),
            "groups": group_stalled,
            "primaryName": "RTS Red Station"}, float(t)))
    for t in range(0, seconds, 2):
        x = 5000.0 if deep else -9000.0
        nodes = [node("W%d" % i, 8000.0 // groups, x, -5196.0,
                      primary[0], primary[1], signature=7 + i)
                 for i in range(groups)]
        records.append(("COHESION", {
            "faction": "BLUE", "stationX": station[0], "stationZ": station[1],
            "primaryX": primary[0], "primaryZ": primary[1],
            "arenaHalfExtent": 13500.0, "groupCount": groups,
            "nearArenaEdge": 0, "pairs": [], "nodes": nodes}, float(t)))
    for i in range(capital_preempts):
        records.append(("DECISION", {
            "faction": "BLUE", "reason": "CAPITAL_THREAT_PREEMPTION",
            "mission": "INTERCEPT", "targetRole": capital_role,
            "targetX": 5000.0, "targetZ": 0.0}, 100.0 + i))
    for i in range(seconds // 10):
        records.append(("DECISION", {"faction": "BLUE", "reason": "DEFEND_BASE"},
                        float(i)))
    return records


class TestDiscrimination(unittest.TestCase):
    """Each assertion is a kill-check: reverting the metric's intended behaviour
    makes it fail. A metric that passes for the wrong reason would survive."""

    def _pair(self, good_kw=None, bad_kw=None):
        good_kw = good_kw or {}
        bad_kw = bad_kw or {}
        tmp = tempfile.mkdtemp()
        write_batch(tmp, [("rts-ai-good.jsonl", good_run(**good_kw)),
                          ("rts-ai-bad.jsonl", bad_run(**bad_kw))])
        result = at.analyse_batch(tmp)
        runs = {r["_file"]: r for r in result["runs"]}
        return runs["rts-ai-good.jsonl"], runs["rts-ai-bad.jsonl"]

    def test_massing_beats_dribbling_on_every_higher_is_better_metric(self):
        """A metric whose declared polarity says higher is better must actually
        come out higher for the good run. This is the kill-check for the whole
        registry: flipping any polarity here fails."""
        good, bad = self._pair()
        checked = 0
        for name, spec in at.METRICS.items():
            if spec["polarity"] != at.HIGHER_BETTER:
                continue
            if good.get(name) is None or bad.get(name) is None:
                continue
            self.assertGreater(good[name], bad[name],
                               "%s (%s): good run should beat bad run"
                               % (name, spec["title"]))
            checked += 1
        self.assertGreater(checked, 5)

    def test_lower_is_better_metrics_come_out_lower_for_the_good_run(self):
        good, bad = self._pair()
        checked = 0
        for name, spec in at.METRICS.items():
            if spec["polarity"] != at.LOWER_BETTER:
                continue
            if good.get(name) is None or bad.get(name) is None:
                continue
            self.assertLess(good[name], bad[name],
                            "%s (%s): good run should be lower"
                            % (name, spec["title"]))
            checked += 1
        self.assertGreater(checked, 2)

    def test_fewer_groups_is_the_right_direction(self):
        good, bad = self._pair()
        self.assertLess(good["mean_groups_per_faction"], bad["mean_groups_per_faction"])

    def test_separation_reports_separates_for_the_pure_case(self):
        good, bad = self._pair()
        verdict, ratio, _strength = at.separation(
            "mean_groups_per_faction", [good], [bad])
        self.assertEqual(verdict, "separates")
        # ratio is a degradation factor: always >1 means the compared run is worse
        self.assertGreater(ratio, 1.0)

    def test_separation_reports_overlaps_when_runs_are_identical(self):
        good, _bad = self._pair()
        verdict, _ratio, _strength = at.separation(
            "mean_groups_per_faction", [good], [good])
        self.assertEqual(verdict, "overlaps")

    def test_degradation_ratio_is_above_one_for_both_polarities(self):
        """A report column that mixes 'x4 worse' with 'x0.25 worse' cannot be
        read. Above 1.0 must always mean worse."""
        good, bad = self._pair()
        _v, ratio_higher, _s = at.separation("target_value_hhi", [good], [bad])
        _v, ratio_lower, _s = at.separation("mean_groups_per_faction", [good], [bad])
        self.assertGreater(ratio_higher, 1.0)
        self.assertGreater(ratio_lower, 1.0)

    def test_degradation_ratio_is_none_when_the_compared_mean_is_zero(self):
        """A metric driven to exactly zero has no finite ratio; inventing one
        would print an infinity in the table."""
        good, bad = self._pair()
        _v, ratio, _s = at.separation("objective_commit_ratio", [good], [bad])
        self.assertIsNone(ratio)

    def test_separation_reports_insufficient_not_a_pass(self):
        """A metric with no data on either side is unknown, never a pass."""
        verdict, _ratio, _strength = at.separation(
            "capital_preempt_rate", [{}], [{}])
        self.assertEqual(verdict, "insufficient")

    def test_separation_reports_insufficient_when_only_one_side_has_data(self):
        verdict, _ratio, _strength = at.separation(
            "capital_preempt_rate", [{"capital_preempt_rate": 5.0}], [{}])
        self.assertEqual(verdict, "insufficient")

    def test_threat_preemption_zero_separates_from_a_positive_rate(self):
        """A measured zero against a positive rate is real evidence, not a gap."""
        good, bad = self._pair()
        verdict, _ratio, _strength = at.separation(
            "capital_preempt_rate", [good], [bad])
        self.assertEqual(verdict, "separates")

    def test_threat_preemption_absent_from_the_bad_run(self):
        good, bad = self._pair()
        self.assertGreater(good["capital_preempt_rate"], 0.0)
        self.assertAlmostEqual(bad["capital_preempt_rate"], 0.0)
        # with no preemptions there is no population to take a share of
        self.assertIsNone(bad["preempt_on_capital_rate"])

    def test_stall_metric_moves_when_only_the_stall_dimension_varies(self):
        """Isolating one axis proves the metric reads that axis and not a
        neighbour."""
        good, bad = self._pair(good_kw={"stalled": 0}, bad_kw={"stalled": 4})
        self.assertAlmostEqual(good["stalled_group_ratio"], 0.0)
        self.assertAlmostEqual(bad["stalled_group_ratio"], 0.5)
        verdict, _r, _s = at.separation("stalled_group_ratio", [good], [bad])
        self.assertEqual(verdict, "separates")

    def test_withdrawal_metric_moves_when_only_withdrawal_varies(self):
        good, bad = self._pair(
            good_kw={"retreat_missions": {"PRIMARY": 1, "REGROUP": 1}},
            bad_kw={"retreat_missions": {"PRIMARY": 4, "SCREEN": 4}})
        self.assertAlmostEqual(good["retreat_duty_cycle"], 0.5)
        self.assertAlmostEqual(bad["retreat_duty_cycle"], 0.0)
        verdict, _r, _s = at.separation("retreat_duty_cycle", [good], [bad])
        self.assertEqual(verdict, "separates")

    def test_separation_is_ambiguous_for_diagnostic_metrics(self):
        verdict, _r, _s = at.separation(
            "station_hull_min", [{"station_hull_min": 0.5}], [{"station_hull_min": 0.9}])
        self.assertEqual(verdict, "ambiguous")

    def test_ambiguous_metrics_pass_through_separation_untouched(self):
        """A diagnostic must never be reported as a pass or a failure."""
        for name, spec in at.METRICS.items():
            if spec["polarity"] != at.AMBIGUOUS:
                continue
            verdict, _r, _s = at.separation(name, [{name: 1.0}], [{name: 99.0}])
            self.assertEqual(verdict, "ambiguous", name)


# --------------------------------------------------------------------------
# Batch aggregation and reporting
# --------------------------------------------------------------------------


class TestAggregation(unittest.TestCase):

    def test_aggregate_reports_mean_min_max_and_count(self):
        agg = at.aggregate([{"objective_commit_ratio": 1.0},
                            {"objective_commit_ratio": 3.0},
                            {"objective_commit_ratio": None}])
        entry = agg["objective_commit_ratio"]
        self.assertAlmostEqual(entry["mean"], 2.0)
        self.assertAlmostEqual(entry["min"], 1.0)
        self.assertAlmostEqual(entry["max"], 3.0)
        self.assertEqual(entry["n"], 2)

    def test_aggregate_covers_every_registered_metric(self):
        agg = at.aggregate([{}])
        for name in at.METRICS:
            self.assertIn(name, agg)
            self.assertIsNone(agg[name]["mean"])
            self.assertEqual(agg[name]["n"], 0)

    def test_aggregate_of_nothing_is_none_not_zero(self):
        agg = at.aggregate([])
        self.assertIsNone(agg["objective_commit_ratio"]["mean"])

    def test_totals_sum_across_runs(self):
        agg = at.aggregate([{"_losses": 5, "_run_seconds": 100.0},
                            {"_losses": 7, "_run_seconds": 200.0}])
        self.assertEqual(agg["_losses"], 12)
        self.assertAlmostEqual(agg["_run_seconds"], 300.0)

    def test_batch_name_comes_from_the_directory(self):
        tmp = tempfile.mkdtemp(prefix="my-batch-20260101")
        write_batch(tmp, [("rts-ai-a.jsonl", [("LOSS", {"faction": "BLUE"}, 1.0)])])
        self.assertEqual(at.analyse_batch(tmp)["batch"], os.path.basename(tmp))

    def test_report_renders_every_metric_and_family(self):
        tmp = tempfile.mkdtemp()
        good_dir = os.path.join(tmp, "goodbatch")
        bad_dir = os.path.join(tmp, "badbatch")
        write_batch(good_dir, [("rts-ai-a.jsonl", good_run())])
        write_batch(bad_dir, [("rts-ai-a.jsonl", bad_run())])
        table, _verdicts, ambiguous = at.report(
            [at.analyse_batch(good_dir), at.analyse_batch(bad_dir)], "goodbatch")
        for name, spec in at.METRICS.items():
            self.assertIn(spec["title"][:24], table)
        for _family, label in at.FAMILIES:
            self.assertIn(label, table)
        self.assertIn("ambig", table)
        for name in ambiguous:
            self.assertIn(at.METRICS[name]["title"][:24], table)

    def test_report_compares_each_batch_against_the_baseline_separately(self):
        """Pooling every other batch into one group hides a metric that
        separates the baseline from exactly one of them."""
        tmp = tempfile.mkdtemp()
        good_dir = os.path.join(tmp, "goodbatch")
        a_dir = os.path.join(tmp, "abadch")
        b_dir = os.path.join(tmp, "bbatch")
        write_batch(good_dir, [("rts-ai-a.jsonl", good_run(groups=2))])
        write_batch(a_dir, [("rts-ai-a.jsonl", bad_run(groups=8))])
        # Same group count as the baseline, so group count overlaps, but its
        # groups are parked in the open, so stall time separates.
        write_batch(b_dir, [("rts-ai-a.jsonl", good_run(groups=2, stalled=1))])
        table, verdicts, _ambiguous = at.report(
            [at.analyse_batch(good_dir), at.analyse_batch(a_dir),
             at.analyse_batch(b_dir)], "goodbatch")
        self.assertIn("vs abadch", table)
        self.assertIn("vs bbatch", table)
        self.assertEqual(verdicts["abadch"]["mean_groups_per_faction"][0],
                         "separates")
        # identical group count cannot separate
        self.assertEqual(verdicts["bbatch"]["mean_groups_per_faction"][0],
                         "overlaps")
        # but a different dimension still can, which is what pooling would hide
        self.assertEqual(verdicts["bbatch"]["stalled_group_ratio"][0],
                         "separates")

    def test_report_accepts_a_full_path_for_baseline(self):
        tmp = tempfile.mkdtemp()
        good_dir = os.path.join(tmp, "goodbatch")
        bad_dir = os.path.join(tmp, "badbatch")
        write_batch(good_dir, [("rts-ai-a.jsonl", good_run())])
        write_batch(bad_dir, [("rts-ai-a.jsonl", bad_run())])
        table, _v, _a = at.report(
            [at.analyse_batch(good_dir), at.analyse_batch(bad_dir)], good_dir)
        self.assertIn("goodbatch", table)

    def test_report_falls_back_when_baseline_is_unknown(self):
        tmp = tempfile.mkdtemp()
        write_batch(tmp, [("rts-ai-a.jsonl", good_run())])
        table, _v, _a = at.report([at.analyse_batch(tmp)], "does-not-exist")
        self.assertIn(os.path.basename(tmp), table)

    def test_gaps_report_names_a_field_for_every_gap(self):
        text = at.gaps_report()
        for question, _why, field in at.GAPS:
            self.assertIn(field, text)
        self.assertIn("GAPS", text)


# --------------------------------------------------------------------------
# Formatting
# --------------------------------------------------------------------------


class TestFormatting(unittest.TestCase):

    def test_none_formats_as_not_available(self):
        self.assertEqual(at.format_value(at.METRICS["objective_commit_ratio"], None),
                         "n/a")

    def test_zero_is_not_confused_with_missing(self):
        """Zero is a real, and often damning, measurement."""
        self.assertEqual(at.format_value(at.METRICS["objective_commit_ratio"], 0.0),
                         "0.000")
        self.assertNotEqual(at.format_value(at.METRICS["objective_commit_ratio"], 0.0),
                            "n/a")

    def test_every_declared_unit_formats(self):
        units = {s["unit"] for s in at.METRICS.values()}
        for unit in units:
            spec = dict(unit=unit)
            text = at.format_value(spec, 1.5)
            self.assertNotEqual(text, "n/a", unit)
            self.assertTrue(text.strip(), unit)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


class TestCLI(unittest.TestCase):

    def _batch(self, tmp, name, records):
        path = os.path.join(tmp, name)
        write_batch(path, [("rts-ai-a.jsonl", records)])
        return path

    def test_gaps_flag_needs_no_batch(self):
        self.assertEqual(at.main(["--gaps"]), 0)

    def test_metric_flag_explains_one_metric(self):
        self.assertEqual(at.main(["--metric", "lure_conversion"]), 0)

    def test_unknown_metric_is_an_error(self):
        with self.assertRaises(SystemExit):
            at.main(["--metric", "no_such_metric"])

    def test_no_batches_is_an_error(self):
        with self.assertRaises(SystemExit):
            at.main([])

    def test_json_output_is_machine_readable(self):
        tmp = tempfile.mkdtemp()
        a = self._batch(tmp, "goodbatch", good_run())
        b = self._batch(tmp, "badbatch", bad_run())
        import io
        from contextlib import redirect_stdout
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            at.main([a, b, "--baseline", "goodbatch", "--json"])
        payload = json.loads(buffer.getvalue())
        self.assertEqual(len(payload["batches"]), 2)
        self.assertIn("objective_commit_ratio", payload["polarity"])
        self.assertEqual(len(payload["gaps"]), len(at.GAPS))
        self.assertIn("runs", payload["batches"][0])

    def test_json_polarity_matches_the_registry(self):
        tmp = tempfile.mkdtemp()
        a = self._batch(tmp, "goodbatch", good_run())
        import io
        from contextlib import redirect_stdout
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            at.main([a, "--json"])
        payload = json.loads(buffer.getvalue())
        self.assertEqual(payload["polarity"],
                         {k: v["polarity"] for k, v in at.METRICS.items()})


# --------------------------------------------------------------------------
# Streaming behaviour
# --------------------------------------------------------------------------


class TestStreaming(unittest.TestCase):

    def test_memory_does_not_scale_with_record_count(self):
        """Counters must stay O(1) in the record count. Only previousAge is
        genuinely per-record, and even that is a bounded sample of the
        distribution rather than a retained log."""

        def retained(n):
            tmp = tempfile.mkdtemp()
            path = os.path.join(tmp, "rts-ai-a.jsonl")
            with RunBuilder(path) as b:
                for i in range(n):
                    b.emit("OBJECTIVE", {
                        "faction": "BLUE", "mission": "PRIMARY",
                        "previousAge": float(i % 60)}, float(i))
            acc = at.RunAccumulator()
            for t, e, d in at.iter_records(path, at._NEEDED):
                acc.feed(t, e, d)
            return (sum(acc.transitions.values()), len(acc.transitions),
                    len(acc.withdrawals), sum(acc.losses.values()))

        small = retained(2000)
        large = retained(20000)
        # every record is counted...
        self.assertEqual(large[0], 20000)
        # ...by a number of keys that does not grow with the file
        self.assertEqual(small[1], large[1])
        self.assertEqual(small[2], large[2])
        self.assertEqual(small[3], large[3])

    def test_large_file_is_processed_in_one_pass(self):
        tmp = tempfile.mkdtemp()
        path = os.path.join(tmp, "rts-ai-a.jsonl")
        with RunBuilder(path) as b:
            for i in range(20000):
                b.emit("COHESION", {"faction": "BLUE", "groupCount": 2,
                                    "nearArenaEdge": 0, "pairs": [],
                                    "stationX": -9000.0, "stationZ": 0.0,
                                    "primaryX": 9000.0, "primaryZ": 0.0,
                                    "arenaHalfExtent": 13500.0,
                                    "nodes": [node("W1", 50, -8000, 0),
                                              node("W2", 50, -7000, 0)]},
                            float(i))
        result = at.analyse_batch(tmp)
        run = result["runs"][0]
        # both groups are at home, so neither is past the midpoint, and with all
        # value on one target the target concentration is maximal
        self.assertAlmostEqual(run["deep_commit_fraction"], 0.0)
        self.assertAlmostEqual(run["target_value_hhi"], 1.0)
        self.assertEqual(result["aggregate"]["_losses"], 0)


if __name__ == "__main__":
    unittest.main()
