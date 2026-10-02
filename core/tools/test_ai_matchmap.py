"""Tests for ai_matchmap: the spatial reconstruction, every heat map, the force
commit curve, the decision replay in all four evidence states, and the
degenerate quiet match that must not crash a rendering pipeline.

Fixtures are written to a temp dir and shaped like the real telemetry:
{"schema":2,"event":..,"time":..,"sequence":..,"data":{..}}. Field names and
value shapes are taken from real session-fix-20260930 / capgate-20261001 runs,
including the details the tool exists to be honest about:

  * COHESION.nodes and CONTEST.groups arrive as a LIST in most records and as a
    dict in the first record of a run, so both shapes are exercised.
  * CONTEST.valueOnPrimary / valueOnGroups are per-sample gauges.
  * PRODUCTION emits one record per action; UNIT_SPAWNED is the hull existing.
  * LOSS carries no position at all, so a death can only be placed by joining
    the ship to its group and taking the group's last known centroid.
  * DAMAGE_TELEMETRY_STATUS is a one-shot registration receipt with no
    positions and no damage; a quiet match has exactly one of them.
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ai_matchmap as mm

STATIONS = {"BLUE": (-9000.0, -5196.1523), "RED": (9000.0, -5196.1523),
            "GOLD": (0.0, 10392.3047)}


def rec(event, time, data, sequence=None):
    return {"schema": 2, "event": event, "time": float(time),
            "sequence": sequence if sequence is not None else int(time * 10) + 1,
            "data": data}


def run_rec(time=0.25):
    return rec("RUN", time, {
        "detailedDecisionTelemetry": False, "detailedUnitTelemetry": True,
        "doctrine": {"MinimumCommitmentSeconds": 8.0, "ObjectiveSwitchCost": 25.0,
                     "LocalTargetRetentionSeconds": 8.0, "LocalStrengthRadius": 4500.0,
                     "RetargetImprovementRatio": 0.25, "RetreatCommitSeconds": 25.0},
        "setup": {"baseDistanceUnits": 18000.0, "factionCount": 3},
        "balance": {"aiRosters": {"BLUE": [
            {"class": "GTF Perseus", "role": "fighter", "tier": 1, "count": 4, "weight": 4},
            {"class": "GTB Zeus", "role": "bomber", "tier": 2, "count": 4, "weight": 3},
            {"class": "GTCv Deimos", "role": "capital", "tier": 3, "count": 1, "weight": 5},
            {"class": "GTD Hecate", "role": "heavy", "tier": 4, "count": 1, "weight": 4},
        ], "RED": [{"class": "SF Mara", "role": "fighter", "tier": 1, "count": 4}]}},
    })


def setup_rec(time=38.06):
    return rec("ACCEPTANCE_SETUP", time, {
        "factionCount": 3, "baseDistanceUnits": 18000.0, "difficultyIndex": 2,
        "stationPositions": {k: {"x": v[0], "y": 0.0, "z": v[1]} for k, v in STATIONS.items()},
    })


def decision(time, faction="BLUE", group="W1:fighter", x=-9000.0, z=-5196.0,
             ships=(5, 7, 9, 11), mission="PRIMARY", reason="OPERATION_ROLE_TARGET",
             score=120.0, target_class="GTI Arcadia", target_faction="RED",
             age=30.0, **extra):
    data = {"faction": faction, "group": group, "ships": list(ships), "role": "fighter",
            "posture": "OFFENSIVE", "target": 2, "mission": mission, "reason": reason,
            "score": score, "previousAge": age, "switchingCost": 25.0,
            "unitCount": len(ships), "centroidX": x, "centroidZ": z,
            "stationX": STATIONS[faction][0], "stationZ": STATIONS[faction][1],
            "targetClass": target_class, "targetFaction": target_faction,
            "targetName": "RTS %s Station" % target_faction.capitalize(),
            "targetRole": "capital", "arenaHalfExtent": 13500.0,
            "results": {str(s): "ORDER_ACCEPTED" for s in ships}}
    data.update(extra)
    return rec("DECISION", time, data)


def cohesion(time, faction="BLUE", nodes=None, as_dict=False):
    rows = nodes if nodes is not None else [
        {"group": "W1:fighter", "role": "fighter", "mission": "PRIMARY",
         "x": STATIONS[faction][0] + 2000.0, "z": STATIONS[faction][1], "count": 4,
         "value": 4000.0, "radius": 600.0, "targetSignature": 2.0}]
    return rec("COHESION", time, {
        "faction": faction, "time": time, "groupCount": len(rows),
        "nodes": {str(i): n for i, n in enumerate(rows)} if as_dict else rows,
        "pairs": [{"a": "W1:fighter", "b": "W2:fighter", "distance": 900.0,
                   "gap": -300.0, "sharedTarget": True}] if not as_dict else {},
        "stationX": STATIONS[faction][0], "stationZ": STATIONS[faction][1],
        "primaryX": STATIONS["RED"][0], "primaryZ": STATIONS["RED"][1],
        "arenaHalfExtent": 13500.0, "nearArenaEdge": 0})


def contest(time, faction="BLUE", on_primary=0.0, on_groups=10000.0, groups=None):
    rows = groups if groups is not None else [
        {"group": "W1:fighter", "role": "fighter", "mission": "PRIMARY", "value": 10000.0,
         "ships": 4, "distance": 4200.0, "stalledSeconds": 0.0, "targetIsStation": False}]
    return rec("CONTEST", time, {
        "faction": faction, "time": time, "primaryName": "RTS Red Station",
        "primaryX": STATIONS["RED"][0], "primaryZ": STATIONS["RED"][1],
        "stationHull": 1.0, "valueOnPrimary": on_primary, "valueOnGroups": on_groups,
        "groupCount": len(rows), "missionCounts": {"PRIMARY": 1, "SCREEN": 1},
        "stalledGroups": sum(1 for g in rows if (g.get("stalledSeconds") or 0) > 30),
        "worstStallSeconds": max([g.get("stalledSeconds") or 0.0 for g in rows] or [0.0]),
        "staleOrders": 0, "servicedShips": 0, "groups": rows})


def execution(time, ship=5, hit=True, hull_loss=0.0, mode="ENGAGED"):
    return rec("EXECUTION", time, {"faction": "BLUE", "ship": ship, "target": 2,
                                   "status": "OK", "mode": mode, "hitObserved": hit,
                                   "hullLoss": hull_loss, "distance": 4000.0,
                                   "effectiveRange": 5000.0, "rangeConfidence": 0.9,
                                   "closing": -10.0, "anchorAdvanced": False,
                                   "pursuit": False, "goalPresent": True,
                                   "native": -1.0})


def loss(time, faction="BLUE", cls="GTF Perseus", ship=5, attacker="RED",
         attacker_class="SF Mara", mission="INTERCEPT", cost=400.0):
    return rec("LOSS", time, {
        "ship": ship, "faction": faction, "class": cls, "replacementCost": cost,
        "baseUnitCost": cost, "bountyCP": 96.0, "rewardFaction": attacker,
        "objective": ({"mission": mission, "group": "W1:fighter", "score": 110.0}
                      if mission else None),
        "lethalHit": {"attackerFaction": attacker, "attackerClass": attacker_class,
                      "weaponClass": "Falcon", "damageType": "BALLISTIC",
                      "sourceKind": "PROJECTILE", "beamWeapon": False, "time": time,
                      "hullDamage": cost}})


def sentry(time, faction="BLUE", action="BUILD_COMPLETED", x=-7000.0, z=-5196.0):
    return rec("SENTRY_BUILD", time, {
        "faction": faction, "action": action, "class": "GTSG Cerberus",
        "signature": 900 + int(time), "cost": 400.0, "buildSeconds": 20.0,
        "position": {"x": x, "y": 0.0, "z": z}, "reason": "DEFENSE",
        "startedAt": time - 20.0, "finishAt": time})


def faction_rec(time, faction="BLUE"):
    return rec("FACTION", time, {
        "faction": faction, "combatants": 10, "idle": 1, "value": 50000,
        "received": 4000, "offense": 12000, "losses": {"GTF Perseus": 3},
        "composition": {"GTF Perseus": 4}, "stationHull": 132600, "stationMax": 132600,
        "stationPosition": {"x": STATIONS[faction][0], "y": 0.0, "z": STATIONS[faction][1]},
        "plan": {"posture": "OFFENSIVE", "missionCounts": {"PRIMARY": 2},
                 "canPush": True, "urgent": False, "primaryName": "RTS Red Station"},
        "combatDamageTelemetry": {"interval": {"hullDamage": 250.0, "hitCount": 3,
                                                "lethalHits": 1}},
        "economy": {"commandPoints": 900.0, "queueDepth": 1, "fleetCap": 64,
                    "combatants": 10, "flow": {"income": 300.0, "productionSpend": 0.0,
                                                "bounty": 96.0, "refund": 0.0}}})


def damage_status(time=0.25):
    return rec("DAMAGE_TELEMETRY_STATUS", time, {
        "enabled": True, "combatDamageRegistered": True, "registeredTargetCount": 3,
        "registrationErrors": {}, "source": "resolved damage pipeline",
        "stationBeamTrackingRegistered": True,
        "targets": [{"faction": f, "name": "RTS %s Station" % f, "registered": True}
                    for f in ("BLUE", "RED", "GOLD")]})


def write_run(directory, records, name="rts-ai-20261001-000000.jsonl"):
    path = Path(directory) / "results" / "w" / "worker-0" / "a-1" / "probe" / "data" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")
    return path


def build_busy_match():
    """A match with combat, deaths, stalls, sentries, a commit and a capture."""
    out = [run_rec(), damage_status(), setup_rec(38.0)]
    t = 40.0
    out.append(decision(t, x=-7000.0, z=-5196.0))
    out.append(cohesion(t, as_dict=True))
    out.append(contest(t, on_primary=0.0, on_groups=12000.0))
    out.append(execution(t + 1, hit=False, mode="APPROACHING"))
    out.append(execution(t + 2, hit=True))
    out.append(execution(t + 3, hit=True, hull_loss=180.0))
    out.append(sentry(50.0, action="BUILD_STARTED"))
    out.append(sentry(70.0, action="BUILD_COMPLETED", x=-7000.0))
    out.append(faction_rec(60.0))
    # a stall on the far side of the map, then the group gets there
    out.append(cohesion(100.0, nodes=[
        {"group": "W1:fighter", "role": "fighter", "mission": "PRIMARY",
         "x": 8000.0, "z": -5000.0, "count": 4, "value": 12000.0, "radius": 600.0}]))
    out.append(contest(100.0, on_primary=12000.0, on_groups=0.0, groups=[
        {"group": "W1:fighter", "role": "fighter", "mission": "PRIMARY", "value": 12000.0,
         "ships": 4, "distance": 5100.0, "stalledSeconds": 145.0, "targetIsStation": True}]))
    out.append(decision(101.0, x=8000.0, z=-5000.0, reason="OBJECTIVE_RETAINED",
                        age=20.0, score=76.0))
    # RED's SCREEN wing and BLUE's capital group, as the emitter would report them
    out.append(decision(110.0, faction="RED", group="W2:fighter", x=-7100.0,
                        z=-5078.0, ships=(21, 23, 25, 27), mission="SCREEN",
                        reason="DEFEND_BASE", target_class="GTI Arcadia",
                        target_faction="BLUE", target_name="RTS Blue Station"))
    out.append(decision(115.0, faction="BLUE", group="9556:capital", x=8000.0,
                        z=-5000.0, ships=(77,), role="capital", mission="PRIMARY",
                        reason="OPERATION_ROLE_TARGET", target_class="GTI Arcadia",
                        target_faction="RED", target_name="RTS Red Station"))
    out.append(loss(120.0, faction="RED", cls="SF Mara", ship=21, attacker="BLUE",
                    attacker_class="GTF Perseus", mission="SCREEN"))
    out.append(rec("OBJECTIVE", 121.0, {
        "ship": 21, "name": "Red Alpha 1", "faction": "RED", "status": "ORDER_ACCEPTED",
        "previous": 5, "previousMission": "PRIMARY", "previousAge": 30.0,
        "target": 9, "mission": "SCREEN", "assignedAt": 121.0, "native": 9}))
    out.append(loss(130.0, faction="BLUE", cls="GTCv Deimos", ship=77, attacker="RED",
                    attacker_class="SJ Sathanas", mission="PRIMARY", cost=8600.0))
    out.append(rec("FRIENDLY_HIT", 131.0, {
        "ship": 5, "faction": "BLUE", "target": 7, "targetFaction": "BLUE",
        "sourceName": "Blue Alpha 1", "targetName": "Blue Alpha 2",
        "sourceKind": "PROJECTILE", "mission": "PRIMARY", "native": 7,
        "plannerTarget": 7, "evidence": "weapon contact; resolved damage unknown"}))
    out.append(rec("PRODUCTION", 140.0, {
        "faction": "BLUE", "class": "GTCv Deimos", "role": "capital", "tier": 3,
        "action": "UNIT_SPAWNED", "count": 1, "cost": 8600.0, "producer": "GTCv Deimos",
        "queuedAt": 60.0, "startedAt": 62.0, "completedAt": 140.0, "buildSeconds": 78.0}))
    out.append(rec("PRODUCTION", 60.0, {
        "faction": "BLUE", "class": "GTCv Deimos", "role": "capital", "tier": 3,
        "action": "QUEUE_ACCEPTED", "count": 2, "cost": 8600.0, "producer": "GTCv Deimos"}))
    out.append(rec("TACTIC", 150.0, {
        "faction": "GOLD", "group": "W9:fighter", "role": "fighter", "mission": "LURE",
        "reason": "LURE_UNDER_PRESSURE", "target": 12, "targetClass": "SF Dragon",
        "targetRole": "fighter", "targetDistance": 4200.0, "forceRatio": 1.8}))
    out.append(rec("OUTCOME_CAUSE", 400.0, {
        "faction": "GOLD", "targetName": "RTS Gold Station", "time": 400.0, "elapsed": 400.0,
        "totalAttributedHullDamage": 132600.0, "killers": [], "snapshot": {}}))
    out.append(rec("COUNTERS", 400.0, {"decisions": 900, "retained": 800, "switches": 90,
                                       "reissued": 10, "nativeChanges": 40}))
    return out


def build_quiet_match():
    """A match that never fires a shot and never has a live group.

    This is the degenerate case: no combat density, no deaths, no stalls, no
    sentries, and every heat map has to render an empty panel rather than raise.
    """
    out = [run_rec(), damage_status(), setup_rec(38.0)]
    out.append(cohesion(38.0, nodes=[]))
    out.append(contest(38.0, on_primary=0.0, on_groups=0.0, groups=[]))
    out.append(faction_rec(60.0, "BLUE"))
    out.append(decision(38.0, ships=(), x=None, z=None, score=55.0,
                        reason="COORDINATED_APPROACH", target_class="RTS Blue Station",
                        target_faction="BLUE", mission="REGROUP"))
    out.append(execution(39.0, hit=False, mode="IDLE"))
    out.append(rec("COUNTERS", 3000.0, {"decisions": 4, "retained": 4, "switches": 0,
                                        "reissued": 0, "nativeChanges": 0}))
    return out


def load(records, name="rts-ai-20261001-000000.jsonl", **kwargs):
    tmp = tempfile.mkdtemp(prefix="ai_matchmap_test_")
    path = write_run(tmp, records, name)
    return mm.MatchMap(path, **kwargs).consume(), tmp


# ----------------------------------------------------------------- unit tests

class TestHelpers(unittest.TestCase):
    def test_num_rejects_unknown_strings_and_booleans(self):
        self.assertEqual(mm.num("unknown"), None)
        self.assertEqual(mm.num(True), None)
        self.assertEqual(mm.num(float("nan")), None)
        self.assertEqual(mm.num("12"), None)
        self.assertEqual(mm.num(7), 7.0)
        self.assertEqual(mm.as_int(7.9), 7)

    def test_rows_handles_dict_and_list_shapes(self):
        rows = [{"x": 1}, {"x": 2}]
        self.assertEqual(len(mm.rows(rows)), 2)
        self.assertEqual(len(mm.rows({"0": {"x": 1}, "1": {"x": 2}})), 2)
        self.assertEqual(mm.rows(None), [])
        self.assertEqual(mm.rows("nope"), [])

    def test_bounds_of_is_square_and_snapped(self):
        bounds = mm.bounds_of([(0.0, 0.0), (100.0, 30.0)], pad=0.0, cells=10)
        x0, z0, size = bounds
        self.assertAlmostEqual(size, 10.0)
        self.assertEqual(x0 % size, 0.0)
        self.assertEqual(z0 % size, 0.0)
        # square, and wide enough to hold every sample
        self.assertLessEqual(x0, 0.0)
        self.assertGreaterEqual(x0 + size * 10, 100.0)
        self.assertLessEqual(z0, 0.0)
        self.assertGreaterEqual(z0 + size * 10, 30.0)

    def test_concentration_measures_occupied_cells_not_all_cells(self):
        grid = mm.np.zeros((100, 100))
        grid[0, 0] = 5.0
        grid[50, 50] = 5.0
        # 2 occupied cells, top 10% of 2 = 0 -> at least 1, so 0.5. If the share
        # were measured over all 10,000 cells it would read 1.0 and be useless.
        self.assertAlmostEqual(mm.concentration(grid), 0.5)

    def test_concentration_and_peak_on_empty_grid(self):
        empty = mm.np.zeros((10, 10))
        self.assertEqual(mm.concentration(empty), 0.0)
        self.assertIsNone(mm.peak_cell(empty, (0.0, 0.0, 1.0)))

    def test_quantile_on_empty(self):
        self.assertIsNone(mm.median([]))
        self.assertIsNone(mm.quantile([], 0.9))


class TestSpatialReconstruction(unittest.TestCase):
    def test_busy_match_positions_deaths_from_group_centroids(self):
        match, _ = load(build_busy_match())
        self.assertEqual(match.positioned_losses, 2)
        self.assertEqual(match.unpositioned_losses, 0)
        heavy = [r for r in match.loss_rows if r["role"] == "capital"]
        self.assertEqual(len(heavy), 1)
        self.assertAlmostEqual(heavy[0]["x"], 8000.0)
        # the capital died next to the RED station, ~1000 units from it
        self.assertLess(mm.dist(heavy[0]["x"], heavy[0]["z"],
                                *STATIONS["RED"]), 1500.0)

    def test_stall_records_are_placed_at_the_last_cohesion_position(self):
        match, _ = load(build_busy_match())
        field = match.stall["BLUE"]
        self.assertEqual(len(field), 1)
        self.assertEqual((field.xs[0], field.zs[0]), (8000.0, -5000.0))
        self.assertEqual(field.ws[0], 145.0)
        self.assertEqual(mm.sget(match.faction_stats["BLUE"], "stall_seconds"), 145.0)
        self.assertEqual(mm.sget(match.faction_stats["BLUE"],
                                 "stall_on_station_records"), 1.0)

    def test_fire_points_join_to_the_ship_and_record_staleness(self):
        match, _ = load(build_busy_match())
        self.assertEqual(len(match.fire), 2)
        self.assertEqual(len(match.fire_hull), 1)
        self.assertEqual(match.fire_staleness, [2.0, 3.0])

    def test_death_without_a_known_position_is_counted_not_dropped(self):
        records = build_busy_match()
        # a ship that never appears in a DECISION group has no position
        records.append(loss(200.0, faction="GOLD", cls="GVF Thoth", ship=9999,
                            attacker="BLUE", attacker_class="GTF Perseus"))
        match, _ = load(records)
        self.assertEqual(match.positioned_losses, 2)
        self.assertEqual(match.unpositioned_losses, 1)
        self.assertEqual(mm.sget(match.faction_stats["GOLD"], "unpositioned_losses"), 1.0)

    def test_dwell_accumulates_group_centroids_per_faction(self):
        match, _ = load(build_busy_match())
        self.assertEqual(len(match.dwell["BLUE"]), 3)
        self.assertIn(8000.0, match.dwell["BLUE"].xs)
        self.assertEqual(len(match.dwell["RED"]), 1)

    def test_sentry_positions_and_coverage(self):
        match, _ = load(build_busy_match())
        self.assertEqual(len(match.sentries), 1)
        coverage = mm.sentry_coverage(match, radius=4000.0)
        # RED's SCREEN wing died 155 units from the completed BLUE sentry, so
        # BLUE's sentry grid is inside its own kill radius. RED never built one,
        # so RED has no kill of its own to place in a ring.
        self.assertEqual(coverage["BLUE"]["sentries"], 1)
        self.assertEqual(coverage["BLUE"]["killsByThisFaction"], 1)
        self.assertEqual(coverage["BLUE"]["killsInsideSentryRadius"], 1)
        self.assertEqual(coverage["RED"]["sentries"], 0)
        self.assertEqual(coverage["RED"]["killsInsideSentryRadius"], 0)

    def test_sentry_radius_boundary_is_respected(self):
        match, _ = load(build_busy_match())
        # the kill is 155 units out; a 100 unit ring must exclude it
        tight = mm.sentry_coverage(match, radius=100.0)
        self.assertEqual(tight["BLUE"]["killsInsideSentryRadius"], 0)
        self.assertEqual(tight["BLUE"]["killsByThisFaction"], 1)

    def test_production_counts_spawns_not_queued_orders(self):
        match, _ = load(build_busy_match())
        self.assertEqual(mm.sget(match.faction_stats["BLUE"], "built_capital"), 1.0)
        self.assertEqual(mm.sget(match.faction_stats["BLUE"], "ordered_capital"), 2.0)
        self.assertEqual(mm.sget(match.faction_stats["BLUE"], "production_QUEUE_ACCEPTED"), 1.0)
        self.assertEqual(mm.sget(match.faction_stats["BLUE"], "production_UNIT_SPAWNED"), 1.0)
        self.assertEqual(mm.sget(match.faction_stats["BLUE"], "built_class:GTCv Deimos"), 1.0)

    def test_faction_losses_are_cumulative_so_only_the_max_is_kept(self):
        records = build_busy_match()
        records.append(faction_rec(120.0))
        match, _ = load(records)
        # FACTION.losses is cumulative: 3 at t=60 and 3 at t=120 must not become 6
        self.assertEqual(mm.sget(match.faction_stats["BLUE"],
                                 "loss_cum_max:GTF Perseus"), 3.0)

    def test_bad_lines_are_counted_not_fatal(self):
        tmp = tempfile.mkdtemp(prefix="ai_matchmap_bad_")
        path = write_run(tmp, build_quiet_match())
        with path.open("a", encoding="utf-8") as handle:
            handle.write("{not json at all\n")
            handle.write("\n")
        match = mm.MatchMap(path).consume()
        self.assertEqual(match.bad_lines, 1)
        self.assertGreater(match.end_time, 0)


class TestForceCommit(unittest.TestCase):
    def test_share_is_a_per_sample_average_not_a_ratio_of_sums(self):
        records = [run_rec(), setup_rec(), cohesion(38.0)]
        records.append(contest(100.0, on_primary=1000.0, on_groups=9000.0))
        records.append(contest(110.0, on_primary=0.0, on_groups=0.0))
        match, _ = load(records)
        stats = match.faction_stats["BLUE"]
        self.assertEqual(mm.sget(stats, "contest_samples"), 2.0)
        # 1000/10000 then 0/0 -> 0.0, averaged to 0.05. Summing first and
        # dividing would give 1000/10000 = 0.1.
        self.assertAlmostEqual(mm.sget(stats, "share_sum") / 2.0, 0.05)
        self.assertEqual(mm.sget(stats, "samples_with_commit"), 1.0)
        self.assertEqual(mm.sget(stats, "samples_without_commit"), 1.0)

    def test_commit_series_preserves_every_sample(self):
        records = [run_rec(), setup_rec()]
        for index in range(5):
            records.append(contest(100.0 + index * 10, on_primary=float(index * 100)))
        match, _ = load(records)
        series = sorted(match.commit["BLUE"])
        self.assertEqual(len(series), 5)
        self.assertEqual([s[1] for s in series], [0.0, 100.0, 200.0, 300.0, 400.0])


class TestDecisionReplay(unittest.TestCase):
    def test_no_candidate_list_and_no_retain_is_score_only(self):
        data = decision(100.0)["data"]
        view = mm.explain_decision(100.0, data, mm.DOCTRINE_DEFAULTS)
        self.assertEqual(view["basis"], "SCORE_ONLY")
        self.assertIsNone(view["margin"])
        self.assertIn("no margin can be stated", view["plain"])

    def test_retain_past_the_age_gate_yields_a_challenger_upper_bound(self):
        data = decision(100.0, reason="OBJECTIVE_RETAINED", age=20.0, score=76.0)["data"]
        view = mm.explain_decision(100.0, data, mm.DOCTRINE_DEFAULTS)
        self.assertEqual(view["basis"], "RETAIN_BOUND")
        # lua:604 retained when challenger.score < incumbent.score + switchingCost
        self.assertAlmostEqual(view["runnerUp"]["upperBound"], 76.0 + 25.0)
        self.assertIn("challenger scored below 101.0", view["plain"])

    def test_retain_inside_the_age_gate_is_inertia_not_score(self):
        data = decision(100.0, reason="OBJECTIVE_RETAINED", age=3.0, score=76.0)["data"]
        view = mm.explain_decision(100.0, data, mm.DOCTRINE_DEFAULTS)
        self.assertEqual(view["basis"], "INERTIA")
        self.assertIn("age gate alone", view["plain"])

    def test_objective_candidates_give_a_real_margin_and_probabilities(self):
        data = decision(100.0, score=140.0)["data"]
        data["candidates"] = [
            {"target": 2, "mission": "PRIMARY", "score": 140.0, "reason": "PUSH_ENEMY_BASE",
             "factors": {"distance": -12.0, "coverage": 0.0, "superiority": 4.0},
             "distance": 5200.0, "eta": 2.4, "ratio": 1.9},
            {"target": 3, "mission": "INTERCEPT", "score": 121.5, "reason": "WEAPON_ROLE",
             "distance": 1800.0, "eta": 0.4, "ratio": 1.1},
            {"target": 4, "mission": "SCREEN", "score": 55.0, "reason": "DEFEND_BASE"},
        ]
        data["candidates"][0]["telemetry"] = {"probability": 0.61, "selected": True}
        data["candidates"][1]["telemetry"] = {"probability": 0.29}
        data["candidates"][2]["telemetry"] = {"probability": 0.10}
        view = mm.explain_decision(100.0, data, mm.DOCTRINE_DEFAULTS)
        self.assertEqual(view["basis"], "CANDIDATES")
        self.assertAlmostEqual(view["margin"], 18.5)
        self.assertEqual(sorted(view["probabilities"], reverse=True),
                         [0.61, 0.29, 0.10])
        self.assertIn("beat the runner-up", view["plain"])
        self.assertEqual(view["runnerUp"]["score"], 121.5)

    def test_roster_shaped_candidates_are_normalised_too(self):
        rows = mm.candidate_rows([
            {"entry": {"class": "GTB Zeus", "tier": 2, "role": "bomber"},
             "weight": 3.0, "estimate": {"cost": 2800},
             "telemetry": {"selectionWeight": 3.0, "probability": 0.42, "selected": True}},
            {"entry": {"class": "GTF Perseus", "tier": 1, "role": "fighter"},
             "weight": 4.0,
             "telemetry": {"selectionWeight": 4.0, "probability": 0.58}},
        ])
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["class"], "GTB Zeus")
        self.assertEqual(rows[0]["role"], "bomber")
        self.assertEqual(rows[0]["tier"], 2)
        self.assertAlmostEqual(rows[0]["probability"], 0.42)
        self.assertTrue(rows[0]["selected"])

    def test_candidate_rows_tolerates_junk(self):
        self.assertEqual(mm.candidate_rows(None), [])
        self.assertEqual(mm.candidate_rows("nope"), [])
        self.assertEqual(mm.candidate_rows([1, "two", None]), [])

    def test_filter_selects_by_group_class_and_window(self):
        decision_filter = mm.DecisionFilter(groups=["W1:fighter"], classes=["gti arcadia"],
                                           t_from=100.0, t_to=200.0, limit=5)
        self.assertTrue(decision_filter.wants(150.0, decision(150.0)["data"]))
        self.assertFalse(decision_filter.wants(150.0, decision(150.0, group="W2")["data"]))
        self.assertFalse(decision_filter.wants(150.0,
                                               decision(150.0, target_class="SF Dragon")["data"]))
        self.assertFalse(decision_filter.wants(99.0, decision(99.0)["data"]))
        self.assertFalse(decision_filter.wants(201.0, decision(201.0)["data"]))

    def test_filter_capture_respects_the_limit(self):
        records = [run_rec(), setup_rec()]
        for index in range(10):
            records.append(decision(100.0 + index))
        match, _ = load(records)
        match.decision_filter = mm.DecisionFilter(limit=4)
        match.consume()
        # consume() was already called once above, so re-read from scratch
        tmp = tempfile.mkdtemp(prefix="ai_matchmap_limit_")
        path = write_run(tmp, records)
        capped = mm.MatchMap(path)
        capped.decision_filter = mm.DecisionFilter(limit=4)
        capped.consume()
        self.assertEqual(len(capped.decisions), 4)
        self.assertEqual(match.decision_filter.limit, 4)


class TestMissionTimeline(unittest.TestCase):
    def test_segments_and_switch_rate(self):
        records = [run_rec(), setup_rec()]
        records.append(decision(100.0, mission="PRIMARY", reason="OPERATION_ROLE_TARGET"))
        records.append(decision(110.0, mission="PRIMARY", reason="OPERATION_ROLE_TARGET"))
        records.append(decision(120.0, mission="SCREEN", reason="DEFEND_BASE"))
        records.append(decision(130.0, mission="INTERCEPT", reason="LOCAL_ENGAGEMENT"))
        match, _ = load(records)
        rows = mm.group_timeline_rows(match)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["segments"], 3)
        self.assertEqual(row["switches"], 2)
        self.assertEqual(row["dominantMission"], "PRIMARY")
        self.assertEqual(row["lastMission"], "INTERCEPT")
        self.assertAlmostEqual(row["meanHold"], 10.0)
        self.assertAlmostEqual(row["tracked"], 30.0)

    def test_objective_retarget_is_separate_from_a_mission_switch(self):
        records = [run_rec(), setup_rec()]
        records.append(rec("OBJECTIVE", 100.0, {
            "ship": 5, "name": "Blue Alpha 1", "faction": "BLUE",
            "status": "ORDER_ACCEPTED", "previous": 5, "previousMission": "PRIMARY",
            "previousAge": 30.0, "target": 5, "mission": "PRIMARY", "assignedAt": 100.0,
            "native": 5}))
        records.append(rec("OBJECTIVE", 110.0, {
            "ship": 5, "name": "Blue Alpha 1", "faction": "BLUE",
            "status": "ORDER_ACCEPTED", "previous": 5, "previousMission": "PRIMARY",
            "previousAge": 30.0, "target": 9, "mission": "SCREEN", "assignedAt": 110.0,
            "native": 9}))
        match, _ = load(records)
        stats = match.faction_stats["BLUE"]
        self.assertEqual(mm.sget(stats, "retarget_same_mission"), 1.0)
        self.assertEqual(mm.sget(stats, "objective_mission_switches"), 1.0)


class TestMapsAndReports(unittest.TestCase):
    def test_every_map_renders_for_a_busy_match(self):
        match, tmp = load(build_busy_match(), cells=64)
        outdir = Path(tmp) / "out"
        written = mm.render_all(match, outdir, 64, 4000.0)
        self.assertEqual(len(written), 6)
        for path in written:
            self.assertTrue(path.is_file(), path)
            self.assertGreater(path.stat().st_size, 1000)

    def test_every_map_renders_for_a_quiet_match_with_no_combat(self):
        match, tmp = load(build_quiet_match(), cells=48)
        outdir = Path(tmp) / "out"
        written = mm.render_all(match, outdir, 48, 4000.0)
        self.assertEqual(len(written), 6)
        for path in written:
            self.assertTrue(path.is_file(), path)
        self.assertEqual(len(match.fire), 0)
        self.assertEqual(len(match.losses), 0)
        self.assertEqual(match.stall, {})

    def test_summary_is_greppable_and_names_the_evidence_limits(self):
        match, _ = load(build_busy_match())
        text = "\n".join(mm.match_summary(match, 64))
        for tag in ("MATCHMAP match=", "DEATHS total=", "COMBAT fire_observations=",
                    "COMMIT faction=BLUE", "STALL faction=BLUE", "DWELL faction=BLUE",
                    "HEAVY_DEATH_DETAIL", "BUILD faction=BLUE", "OUTCOME "):
            self.assertIn(tag, text)
        self.assertIn("GROUP CENTROID", text)
        self.assertIn("mission not recorded on", text)

    def test_quiet_match_summary_does_not_raise(self):
        match, _ = load(build_quiet_match())
        text = "\n".join(mm.match_summary(match, 48))
        self.assertIn("DEATHS total=0", text)
        self.assertIn("COMBAT fire_observations=0", text)

    def test_json_payload_is_serialisable(self):
        match, _ = load(build_busy_match())
        payload = json.loads(json.dumps(mm.to_json(match, 64), default=str))
        self.assertEqual(payload["deaths"]["positioned"], 2)
        self.assertEqual(payload["detailedDecisionTelemetry"], False)
        self.assertEqual(payload["stations"]["BLUE"]["x"], STATIONS["BLUE"][0])
        self.assertTrue(payload["groupTimelines"])
        self.assertEqual(len(payload["deaths"]["rows"]), 2)

    def test_timeline_report_renders(self):
        match, _ = load(build_busy_match())
        text = "\n".join(mm.timeline_report(match))
        self.assertIn("GROUP MISSION TIMELINE", text)
        self.assertIn("TIMELINE faction=BLUE group=W1:fighter", text)


class TestCli(unittest.TestCase):
    def _run(self, args):
        return subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parent / "ai_matchmap.py")] + args,
            capture_output=True, text=True, cwd=str(Path(__file__).resolve().parent))

    def test_cli_text_only_on_a_busy_match(self):
        tmp = tempfile.mkdtemp(prefix="ai_matchmap_cli_")
        write_run(tmp, build_busy_match())
        result = self._run([tmp, "--no-png"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("AI MATCHMAP", result.stdout)
        self.assertIn("COMMIT faction=BLUE", result.stdout)

    def test_cli_writes_pngs_and_json(self):
        tmp = tempfile.mkdtemp(prefix="ai_matchmap_cli2_")
        write_run(tmp, build_busy_match())
        outdir = Path(tmp) / "png"
        jsonout = Path(tmp) / "summary.json"
        result = self._run([tmp, "--outdir", str(outdir), "--json", str(jsonout),
                            "--cells", "48"])
        self.assertEqual(result.returncode, 0, result.stderr)
        pngs = sorted(p.name for p in outdir.glob("*.png"))
        self.assertEqual(len(pngs), 6)
        for name in ("combat_density", "deaths", "dwell", "stalls", "commit", "sentry"):
            self.assertTrue(any(name in p for p in pngs), name)
        payload = json.loads(jsonout.read_text(encoding="utf-8"))
        self.assertEqual(len(payload["matches"]), 1)

    def test_cli_explain_prints_a_plain_language_line(self):
        tmp = tempfile.mkdtemp(prefix="ai_matchmap_cli3_")
        write_run(tmp, build_busy_match())
        result = self._run([tmp, "--no-png", "--explain", "--reason-code",
                            "OBJECTIVE_RETAINED", "--limit", "3"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DECISION REPLAY", result.stdout)
        self.assertIn("EXPLAIN GOLD W1:fighter" if "GOLD W1:fighter" in result.stdout
                      else "EXPLAIN BLUE W1:fighter", result.stdout)
        self.assertIn("basis=RETAIN_BOUND", result.stdout)

    def test_cli_explain_with_no_match_says_so(self):
        tmp = tempfile.mkdtemp(prefix="ai_matchmap_cli4_")
        write_run(tmp, build_quiet_match())
        result = self._run([tmp, "--no-png", "--explain", "--group", "NOPE"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no DECISION record matched", result.stdout)

    def test_cli_rejects_a_missing_path(self):
        result = self._run(["Z:/definitely/not/here", "--no-png"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No such path", result.stderr + result.stdout)

    def test_cli_faction_filter(self):
        tmp = tempfile.mkdtemp(prefix="ai_matchmap_cli5_")
        write_run(tmp, build_busy_match())
        result = self._run([tmp, "--no-png", "--faction", "BLUE"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[BLUE]", result.stdout)
        self.assertNotIn("[RED] decisions", result.stdout)


if __name__ == "__main__":
    unittest.main()