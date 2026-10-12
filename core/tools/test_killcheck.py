#!/usr/bin/env python3
"""Tests for the falsification harness itself (tools/killcheck.py).

A harness that cannot detect a vacuous test is worse than no harness, because
it reports a clean bill of health for guards nobody ever falsified. So these
tests do not check that killcheck finds the mod's real defects; they check that
killcheck can be TOLD to be wrong and will say so.

The three properties that matter:

  1. SOUNDNESS   A guard whose covering test really exercises it is reported
                 KILLED, and a deliberately vacuous covering test is reported
                 VACUOUS. Both are proven here against a purpose-built fixture
                 whose guards are real Lua in a real sandbox.
  2. READ-ONLY   A run leaves the repository byte-identical, and the harness
                 says so rather than assuming it.
  3. HONESTY     A mutation whose anchor no longer exists reports ERROR. It
                 must never be reported as a pass, or a concurrently edited
                 .lua file would silently certify itself.

Run: python -m pytest test_killcheck.py -q   (from core/tools)
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from pathlib import Path

import killcheck
from killcheck import (
    ConfigDefault,
    Guard,
    KillCheck,
    MoveBlock,
    MutationError,
    Replacement,
    Sandbox,
    diff_fingerprints,
    failed_node_ids,
    fingerprint,
    hung_node_ids,
    node_id_of,
    replace_once,
)

TOOLS = Path(__file__).resolve().parent


def guard_path(guard):
    """The script file that holds a guard's anchors (a part of a split module)."""
    return killcheck.SCRIPTS / killcheck.target_rel(guard.file, guard.mutations)


# ---------------------------------------------------------------------------
# Unit level
# ---------------------------------------------------------------------------
class FingerprintTests(unittest.TestCase):
    def test_fingerprint_sees_content_changes(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "a.lua").write_text("x = 1\n", encoding="utf-8")
            before = fingerprint(root)
            (root / "a.lua").write_text("x = 2\n", encoding="utf-8")
            after = fingerprint(root)
        changed = diff_fingerprints(before, after)
        self.assertEqual(len(changed), 1, changed)
        self.assertIn("a.lua", changed[0])

    def test_fingerprint_sees_additions_and_deletions(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "a.lua").write_text("x = 1\n", encoding="utf-8")
            before = fingerprint(root)
            (root / "b.lua").write_text("y = 2\n", encoding="utf-8")
            (root / "a.lua").unlink()
            changed = diff_fingerprints(before, fingerprint(root))
        self.assertEqual(len(changed), 2, changed)
        self.assertTrue(any(c.startswith("a.lua") for c in changed))
        self.assertTrue(any(c.startswith("b.lua") for c in changed))

    def test_interpreter_caches_are_excluded(self):
        """A __pycache__ churn during a run must not read as tree mutation."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "a.lua").write_text("x = 1\n", encoding="utf-8")
            before = fingerprint(root)
            cache = root / "tools" / "__pycache__"
            cache.mkdir(parents=True)
            (cache / "a.cpython-312.pyc").write_bytes(b"\x00\x01")
            (root / ".pytest_cache").mkdir()
            (root / ".pytest_cache" / "lastfailed").write_text("{}", encoding="utf-8")
            self.assertEqual(diff_fingerprints(before, fingerprint(root)), [])

    def test_identical_trees_produce_an_empty_diff(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "a.lua").write_text("x = 1\n", encoding="utf-8")
            snap = fingerprint(root)
            self.assertEqual(diff_fingerprints(snap, fingerprint(root)), [])


class MutationTests(unittest.TestCase):
    def test_replace_once_requires_exactly_one_match(self):
        with self.assertRaises(MutationError):
            replace_once("a\nb\n", "zzz", "y", what="missing")
        with self.assertRaises(MutationError):
            replace_once("a\na\n", "a", "y", what="ambiguous")

    def test_replace_once_reports_the_anchor_it_looked_for(self):
        """An ERROR must be actionable. Other agents are editing these very
        files, so a moved anchor has to say which anchor moved."""
        try:
            replace_once("body\n", "GONE", "x", what="MaxUnderFireSeconds branch")
        except MutationError as exc:
            self.assertIn("MaxUnderFireSeconds branch", str(exc))
            self.assertIn("found 0 times", str(exc))
        else:
            self.fail("a missing anchor must raise")

    def test_replace_once_substitutes(self):
        self.assertEqual(replace_once("a b c", "b", "B", what="t"), "a B c")

    def test_move_block_relocates_rather_than_deletes(self):
        text = ("local X={1}\nfunction f() return X[1] end\nfunction g() end\n")
        moved = MoveBlock(block="local X={1}\n", before="function g() end\n",
                          what="t").apply(text)
        self.assertIn("function f() return X[1] end\nlocal X={1}\nfunction g()",
                      moved)
        self.assertGreater(moved.index("local X={1}"),
                           moved.index("function f()"),
                           "the block must end up BELOW its first use, or the "
                           "out-of-scope defect is not reproduced")

    def test_move_block_rejects_a_missing_destination(self):
        with self.assertRaises(MutationError):
            MoveBlock(block="local X=1\n", before="function nope() end\n",
                      what="t").apply("local X=1\n")

    def test_config_default_only_touches_the_named_key(self):
        text = "        A = true,\n        B = true,\n"
        out = ConfigDefault(key="A", old="        A = true,\n",
                            new="        A = false,\n",
                            what="A").apply(text)
        self.assertIn("A = false", out)
        self.assertIn("B = true", out)


class ResultParsingTests(unittest.TestCase):
    def test_failed_node_ids_parses_pytest_summary(self):
        out = ("FAILED test_service.py::ServiceTests::test_a - AssertionError\n"
               "ERROR test_x.py::C::te\n"
               "5 passed, 1 failed\n")
        self.assertEqual(
            failed_node_ids(out),
            {"test_service.py::ServiceTests::test_a", "test_x.py::C::te"})

    def test_a_clean_run_reports_no_failures(self):
        self.assertEqual(failed_node_ids("12 passed in 4.0s\n"), set())

    def test_node_id_of_strips_parametrisation(self):
        self.assertEqual(
            node_id_of("test_a.py::C::t[1-2]"), "test_a.py::C::t")


# ---------------------------------------------------------------------------
# The fixture: a miniature mod whose guards are real Lua in a real sandbox
# ---------------------------------------------------------------------------
# A real .lua module with two independent guards, a real test file that loads
# it through lupa exactly the way this repo's suites do, and one guard with a
# test that exercises it and one with a test that only LOOKS like it does.
#
# Built by explicit concatenation rather than textwrap.dedent: dedent strips
# the common leading whitespace, which silently changes every anchor this file
# greps for. A fixture whose indentation shifts under you is a fixture whose
# tests pass or fail for the wrong reason.
FIXTURE_MODULE = (
    "local M = {}\n"
    "\n"
    "function M.capReserve(reserve, cap)\n"
    "    return math.min(reserve, math.max(0, cap))\n"
    "end\n"
    "\n"
    "function M.stationReserve(reserve, cap)\n"
    "    local stationReserve = M.capReserve(reserve, cap)\n"
    "    return stationReserve\n"
    "end\n"
    "\n"
    "function M.unrelatedSentinel()\n"
    "    return 7\n"
    "end\n"
    "\n"
    "return M\n"
)

FIXTURE_TEST = (
    '"""One guard is genuinely covered, one is deliberately vacuous."""\n'
    "import unittest\n"
    "from pathlib import Path\n"
    "from lupa.lua51 import LuaRuntime\n"
    '\n'
    'SCRIPTS = Path(__file__).resolve().parents[1] / "data" / "scripts"\n'
    "\n"
    "def load():\n"
    "    lua = LuaRuntime(unpack_returned_tuples=True)\n"
    "    lua.globals().scripts_path = SCRIPTS.resolve().as_posix()\n"
    "    lua.execute('package.path=scripts_path..\"/?.lua;\"..package.path')\n"
    "    return lua\n"
    "\n"
    "class RealTests(unittest.TestCase):\n"
    "    def test_station_reserve_is_capped(self):\n"
    '        """A REAL test: asserts the cap, so removing it goes red."""\n'
    "        lua = load()\n"
    "        got = lua.execute(\n"
    "            'local m = require(\"fx\") return m.stationReserve(5000, 1200)')\n"
    "        self.assertEqual(got, 1200)\n"
    "\n"
    "class Vacuous(unittest.TestCase):\n"
    "    def test_station_reserve_mentions_the_cap(self):\n"
    '        """A DELIBERATELY VACUOUS test.\n'
    "\n"
    "        It names the cap, reads the module, and asserts only something\n"
    "        true with or without the guard. This is the exact failure mode\n"
    "        killcheck exists to catch: a green checkmark certifying a fix it\n"
    "        never exercised.\n"
    '        """\n'
    "        lua = load()\n"
    "        reserve = lua.execute(\n"
    "            'local m = require(\"fx\") return m.stationReserve(5000, 1200)')\n"
    "        self.assertGreater(reserve, 0,\n"
    '                           "positive with or without the cap")\n'
    "\n"
    "def test_untouched_second_guard(self):\n"
    '    """A guard with no test at all - UNCOVERED, a real finding."""\n'
    "    lua = load()\n"
    "    self.assertEqual(lua.execute(\n"
    '        \'local m = require("fx") return m.unrelatedSentinel()\'), 7)\n'
)


def build_fixture_mod(root: Path) -> Path:
    """A throwaway mod tree shaped exactly like the real one."""
    core = root / "core"
    tools = core / "tools"
    scripts = core / "data" / "scripts"
    tools.mkdir(parents=True)
    scripts.mkdir(parents=True)
    (core / "data" / "tables").mkdir(parents=True)
    (scripts / "fx.lua").write_text(FIXTURE_MODULE, encoding="utf-8")
    (tools / "test_fixture.py").write_text(FIXTURE_TEST, encoding="utf-8")
    (core / "mod.ini").write_text("[mod]\n", encoding="utf-8")
    return core


def fixture_guards() -> list[Guard]:
    return [
        Guard(
            name="fx_station_reserve_cap",
            title="stationReserve must apply the cap",
            file="fx.lua",
            mutations=[Replacement(
                old="    local stationReserve = M.capReserve(reserve, cap)\n",
                new="    local stationReserve = reserve\n",
                what="fx cap")],
            tests=["test_fixture.py::RealTests::test_station_reserve_is_capped",
                   "test_fixture.py::Vacuous::test_station_reserve_mentions_the_cap"],
            keywords=["stationReserve"],
        ),
        Guard(
            name="fx_unrelated_sentinel",
            title="a real guard nobody asserts",
            file="fx.lua",
            mutations=[Replacement(
                old="    return 7\n",
                new="    return 8\n",
                what="fx sentinel")],
            tests=[],           # UNCOVERED by construction
            keywords=["unrelatedSentinel"],
        ),
    ]


class HarnessAgainstAFixtureMod(unittest.TestCase):
    """The load-bearing test: the harness must find a vacuous test I planted."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(prefix="killcheck_fixture_")
        root = Path(cls._tmp.name)
        core = build_fixture_mod(root)
        # Point the harness's module-level paths at the fixture, not the mod.
        cls._saved = (killcheck.CORE, killcheck.SCRIPTS, killcheck.CONFIG,
                      killcheck.MOD_ROOT)
        killcheck.CORE = core
        killcheck.SCRIPTS = core / "data" / "scripts"
        killcheck.CONFIG = killcheck.SCRIPTS / "fs2rts_config.lua"
        killcheck.MOD_ROOT = root
        cls._core = core
        cls._root = root

        # One run, shared by every assertion below. Each KillCheck run spawns a
        # real pytest inside the sandbox (~60s on a loaded box), so repeating it
        # per test would quadruple the suite's cost to re-derive the same
        # result. The tree is rebuilt fresh here, so the byte-identity
        # assertion still measures that run and nothing else.
        killcheck.WRITES.clear()
        with KillCheck(fixture_guards(), timeout=600) as kc:
            results, drift = kc.run()
            cls._results = {r.name: r for r in results}
            cls._drift = drift
            cls._escapes = kc.sandbox.writes_outside_sandbox()
        cls._writes = list(killcheck.WRITES)

    @classmethod
    def tearDownClass(cls):
        (killcheck.CORE, killcheck.SCRIPTS, killcheck.CONFIG,
         killcheck.MOD_ROOT) = cls._saved
        cls._tmp.cleanup()

    def test_a_planted_vacuous_test_is_reported_vacuous(self):
        real = self._results["fx_station_reserve_cap"]
        self.assertEqual(real.verdict, "KILLED",
                         f"the genuinely-covering test must be killed by "
                         f"removal: {real.detail}")
        outcomes = {node_id_of(t.node): t.verdict for t in real.outcomes}
        self.assertEqual(outcomes["test_fixture.py::RealTests::test_station_reserve_is_capped"],
                         "RED")
        # The headline capability: the vacuous test stayed green, and the
        # harness says so instead of reporting the guard as covered.
        self.assertEqual(outcomes["test_fixture.py::Vacuous::test_station_reserve_mentions_the_cap"],
                         "GREEN")
        vacuous_tests = [t.node for t in real.outcomes if t.verdict == "GREEN"]
        self.assertIn("test_fixture.py::Vacuous::test_station_reserve_mentions_the_cap",
                      vacuous_tests,
                      "the planted vacuous test must be individually flagged, "
                      "not hidden behind a sibling that did go red")

    def test_every_write_landed_inside_the_sandbox(self):
        """The safety claim, checked as behaviour: where did bytes actually go?

        A fingerprint comparison can be satisfied by luck or by a narrow path
        filter. This inspects the write list itself.
        """
        self.assertTrue(self._writes, "nothing was written at all, so the "
                                      "audit proves nothing")
        self.assertEqual(self._escapes, [],
                         f"the harness wrote outside its sandbox: {self._escapes}")

    def test_a_guard_with_no_covering_test_is_reported_uncovered(self):
        sentinel = self._results["fx_unrelated_sentinel"]
        self.assertEqual(sentinel.verdict, "UNCOVERED")
        self.assertEqual(sentinel.outcomes, [],
                         "a guard with no covering test must not acquire one "
                         "by accident")
        self.assertIn("no test names this guard", sentinel.detail)

    def test_the_run_leaves_the_tree_byte_identical(self):
        before = fingerprint(self._root)
        # Re-measure against the snapshot taken before the class-level run's
        # sandbox was built; the fixture tree must be untouched by it.
        self.assertEqual(self._drift, [],
                         "the harness reported drift it did not have")
        after = fingerprint(self._root)
        self.assertEqual(diff_fingerprints(before, after), [],
                         "reading the tree changed it, which is impossible and "
                         "means the fingerprint is not covering what it claims")
        for r in self._results.values():
            self.assertTrue(r.mutation_removed,
                            f"{r.name}: mutation was not actually applied, so "
                            f"its verdict is meaningless")

    def test_a_moved_anchor_reports_error_not_pass(self):
        """A guard whose anchor is gone must never be reported as covered.

        This is the concurrent-edit failure mode: another agent renames a
        local in fs2rts_service.lua between the inventory being written and
        the run happening. A no-op mutation would then report the covering
        test GREEN and call it vacuous - a false accusation.
        """
        bad = [Guard(
            name="fx_anchor_gone",
            title="anchor that no longer exists",
            file="fx.lua",
            mutations=[Replacement(old="RETURN 7\n", new="RETURN 8\n",
                                  what="moved anchor")],
            tests=["test_fixture.py::RealTests::test_station_reserve_is_capped"],
        )]
        with KillCheck(bad, timeout=600) as kc:
            results, _ = kc.run()
        self.assertEqual(results[0].verdict, "ERROR")
        self.assertFalse(results[0].mutation_removed)
        self.assertIn("anchor", results[0].detail.lower())


class SandboxTests(unittest.TestCase):
    def test_sandbox_restore_returns_a_mutated_script_to_pristine(self):
        """restore() undoes a mutation so the next guard starts from the
        shipped source. A guard whose mutation leaked into the next one would
        attribute one guard's removal to another's verdict."""
        with tempfile.TemporaryDirectory() as td:
            core = build_fixture_mod(Path(td))
            saved = killcheck.CORE
            killcheck.CORE = core
            try:
                sb = Sandbox(Path(td) / "sandbox")
                target = sb.root / "data" / "scripts" / "fx.lua"
                original = target.read_text(encoding="utf-8")
                sb.apply([Replacement(old="    return 7\n", new="    return 8\n",
                                      what="sentinel")], "fx.lua")
                self.assertIn("return 8", target.read_text(encoding="utf-8"))
                sb.restore()
                self.assertEqual(target.read_text(encoding="utf-8"), original,
                                 "restore did not return the script to its "
                                 "pristine contents")
            finally:
                killcheck.CORE = saved

    def test_sandbox_never_touches_the_source_tree(self):
        """The whole safety property, at the level it is implemented."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            core = build_fixture_mod(root)
            before = fingerprint(core)
            saved = killcheck.CORE
            killcheck.CORE = core
            try:
                sb = Sandbox(root / "sandbox")
                sb.apply([Replacement(old="    return 7\n", new="    return 8\n",
                                      what="sentinel")], "fx.lua")
            finally:
                killcheck.CORE = saved
            self.assertEqual(diff_fingerprints(before, fingerprint(core)), [],
                             "building a sandbox and mutating it changed the "
                             "source tree")


class HangDetectionTests(unittest.TestCase):
    """A hang is a falsification, but it is not a clean RED.

    Station.AI.StationReserveCap is the live example: with the cap removed,
    test_ai_never_spends_player_cp_from_the_real_station_ai does not fail, it
    stops terminating. Reporting that as a plain RED would understate it, and
    letting subprocess.TimeoutExpired escape would crash the whole run and
    lose every other guard's verdict.
    """

    def test_a_timeout_is_converted_into_failures_not_raised(self):
        with tempfile.TemporaryDirectory() as td:
            tools = Path(td) / "tools"
            tools.mkdir()
            (tools / "test_hang.py").write_text(
                "import time\n"
                "def test_never_ends():\n"
                "    while True:\n"
                "        time.sleep(0.01)\n",
                encoding="utf-8")
            code, out = killcheck._run(["test_hang.py::test_never_ends"],
                                      tools, timeout=5)
        self.assertNotEqual(code, 0)
        self.assertIn("test_hang.py::test_never_ends", failed_node_ids(out))
        self.assertIn("test_hang.py::test_never_ends", hung_node_ids(out),
                      "a timeout must be distinguishable from a clean failure")

    def test_only_observed_assertions_can_kill_a_guard(self):
        node = "test_fixture.py::RealTests::test_station_reserve_is_capped"
        controls = [
            (1, f"FAILED {node} - did not finish within 5s", "ERROR", "HUNG"),
            (1, f"ERROR {node} - RuntimeError", "ERROR", "ERROR"),
            (1, f"FAILED {node} - LuaError", "ERROR", "ERROR"),
            (0, "1 skipped", "ERROR", "ERROR"),
            (4, "runner could not start", "ERROR", "ERROR"),
            (0, f"TEST_PASSED {node}[1]\nTEST_UNVERIFIED {node}[2]", "ERROR", "ERROR"),
            (2, f"ASSERTION_FAILURE {node}", "ERROR", "ERROR"),
            (0, f"TEST_PASSED {node}", "VACUOUS", "GREEN"),
            (1, f"FAILED {node} - assert 1 == 2\nASSERTION_FAILURE {node}", "KILLED", "RED"),
        ]
        with tempfile.TemporaryDirectory() as folder:
            core = build_fixture_mod(Path(folder))
            with patch.object(killcheck, "CORE", core), KillCheck(fixture_guards()[:1]) as kc:
                guard = fixture_guards()[0]
                guard.tests = [node]
                for code, output, verdict, test_verdict in controls:
                    with self.subTest(output=output), patch.object(killcheck, "_run", return_value=(code, output)):
                        result = kc.run_guard(guard, set())
                        self.assertEqual(result.verdict, verdict)
                        self.assertEqual(result.outcomes[0].verdict, test_verdict)
                with patch.object(killcheck, "_run", return_value=(1, controls[-1][1])):
                    self.assertEqual(kc.run_guard(guard, {node}).verdict, "ERROR")

    def test_runner_distinguishes_assertions_setup_errors_skips_and_passes(self):
        source = (
            "import pytest, unittest\nfrom lupa.lua51 import LuaRuntime\n"
            "def test_pass(): assert True\n"
            "def test_assertion(): assert 1 == 2\n"
            "def test_exception(): raise RuntimeError('assertion is not the cause')\n"
            "def test_lua_assertion(): LuaRuntime().execute('assert(false, \"deliberate assertion\")')\n"
            "def test_lua_api_error(): LuaRuntime().execute('missing_api()')\n"
            "@pytest.fixture\ndef broken(): raise AssertionError('setup failed')\n"
            "def test_setup(broken): pass\n"
            "@pytest.mark.skip\ndef test_skip(): pass\n"
            "class TestUnit(unittest.TestCase):\n"
            "    def test_assertion(self): self.assertEqual(1, 2)\n"
            "@pytest.mark.parametrize('n', [1, 2])\n"
            "def test_param(n): assert n > 0\n"
            "@pytest.mark.parametrize('n', [1, 2])\n"
            "def test_partial(n):\n"
            "    if n == 2: pytest.skip('partial evidence')\n"
        )
        with tempfile.TemporaryDirectory() as folder:
            tools = Path(folder)
            (tools / "test_evidence.py").write_text(source, encoding="utf-8")
            code, output = killcheck._run(["test_evidence.py"], tools, timeout=30)
        self.assertEqual(code, 1, output)
        self.assertEqual(set(killcheck._ASSERTION_RE.findall(output)), {
            "test_evidence.py::test_assertion", "test_evidence.py::TestUnit::test_assertion",
            "test_evidence.py::test_lua_assertion"})
        self.assertEqual(set(killcheck._PASSED_RE.findall(output)), {
            "test_evidence.py::test_pass", "test_evidence.py::test_param[1]", "test_evidence.py::test_param[2]",
            "test_evidence.py::test_partial[1]"})
        self.assertEqual(set(killcheck._UNVERIFIED_RE.findall(output)), {
            "test_evidence.py::test_exception", "test_evidence.py::test_setup", "test_evidence.py::test_skip",
            "test_evidence.py::test_partial[2]", "test_evidence.py::test_lua_api_error"})

    def test_missing_or_failed_baseline_cannot_supply_green_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            core = build_fixture_mod(Path(folder))
            with patch.object(killcheck, "CORE", core), KillCheck(fixture_guards()[:1]) as kc:
                node = kc._all_nodes()[0]
                for response in ((0, "1 skipped"), (4, "runner failed"), (1, "FAILED test_fixture.py::bad"),
                                 (0, f"TEST_PASSED {node}[1]\nTEST_UNVERIFIED {node}[2]")):
                    with self.subTest(response=response), patch.object(killcheck, "_run", return_value=response):
                        _, failed = kc.baseline()
                        self.assertEqual(failed, set(kc._all_nodes()))


class RealTreeSafetyTests(unittest.TestCase):
    """The safety property against the actual repository, not a fixture.

    Scoped to the files this harness is allowed to be near: the .lua sources
    and killcheck's own two files. Other agents are actively editing
    fs2rts_ai_production.lua, fs2rts_config.lua, fs2rts_service.lua and
    fs2rts_hud.lua RIGHT NOW, and unrelated suites are mid-edit, so a
    whole-tree fingerprint here would fail on someone else's keystroke and
    tell the reader nothing about this harness. The full-tree fingerprint is
    still taken by `python -m killcheck` and reported in its own output.
    """

    GUARDED = ("data/scripts", "tools/killcheck.py", "tools/test_killcheck.py")

    def _guarded_fingerprint(self):
        return {k: v for k, v in fingerprint(killcheck.MOD_ROOT).items()
                if any(k.startswith(p) for p in self.GUARDED)}

    def test_a_real_run_does_not_modify_the_scripts(self):
        guards = [g for g in killcheck.GUARDS
                  if g.name == "service_max_under_fire_seconds"]
        self.assertEqual(len(guards), 1, "inventory lost the guard under test")
        # This fingerprints the LIVE data/scripts tree, so an edit landing
        # inside the run window is indistinguishable from a write by killcheck.
        # The class docstring already scopes the fingerprint down for exactly
        # this reason; the retry finishes the job. A diff that survives three
        # consecutive attempts still fails.
        diff = None
        for _ in range(3):
            before = self._guarded_fingerprint()
            with KillCheck(guards, timeout=1800) as kc:
                results, _ = kc.run()
            after = self._guarded_fingerprint()
            diff = diff_fingerprints(before, after)
            if not diff:
                break
            time.sleep(2.0)
        self.assertEqual(diff, [],
                         "killcheck wrote to the mod it was meant to only read")
        self.assertTrue(results[0].mutation_removed,
                        "the guard's mutation was not applied, so its verdict "
                        "means nothing")
        self.assertNotEqual(results[0].verdict, "ERROR",
                            f"real run failed to falsify: {results[0].detail}")

    def test_the_removal_actually_changes_the_sandbox_copy(self):
        """A mutation that writes the same bytes back would report every
        covering test GREEN and accuse it of being vacuous."""
        guard = next(g for g in killcheck.GUARDS
                     if g.name == "service_max_under_fire_seconds")
        source = guard_path(guard).read_text(encoding="utf-8")
        # Other agents are editing this file right now, so a read can land in
        # the middle of a write and miss the anchor. That is the harness
        # correctly refusing to falsify; retry rather than fail spuriously.
        for _ in range(5):
            try:
                mutated = source
                for mutation in guard.mutations:
                    mutated = mutation.apply(mutated)
                break
            except MutationError:
                time.sleep(2.0)
                source = guard_path(guard).read_text(encoding="utf-8")
        else:
            self.fail(f"{guard.name}: anchor never settled; another agent is "
                      f"actively editing {guard.file}")
        self.assertNotEqual(
            mutated, source,
            "the guard's mutations leave the source text byte-identical")
        self.assertLess(len(mutated), len(source),
                        "removing the release branch should delete code")

    def test_every_guard_names_at_least_one_test_or_is_declared_uncovered(self):
        """Guard bookkeeping: a guard with an empty `tests` list is a finding,
        so it has to be a DELIBERATE one, and every other guard has to name
        the test that claims it."""
        for guard in killcheck.GUARDS:
            self.assertTrue(guard.name, "a guard with no name")
            self.assertTrue(guard.title, f"{guard.name}: no title")
            self.assertTrue(guard.file.endswith(".lua"),
                            f"{guard.name}: file must be a .lua, got "
                            f"{guard.file}")
            self.assertTrue(guard.mutations, f"{guard.name}: no mutation")
            if guard.tests:
                for node in guard.tests:
                    self.assertIn("::", node,
                                  f"{guard.name}: covering test {node!r} is not "
                                  f"a node id")
                    path = killcheck.TOOLS / node.split("::")[0]
                    self.assertTrue(path.is_file(),
                                    f"{guard.name}: covering test file missing: {path}")
                    self.assertIn(
                        node.split("::")[-1],
                        path.read_text(encoding="utf-8", errors="replace"),
                        f"{guard.name}: {node} does not exist in {path.name}")

    def test_covering_test_node_ids_are_unique_per_guard(self):
        for guard in killcheck.GUARDS:
            self.assertEqual(len(guard.tests), len(set(guard.tests)),
                             f"{guard.name}: duplicate covering tests")

    def test_every_guard_anchor_exists_in_the_real_source(self):
        """Every removal anchor must match its .lua file exactly once.

        This exists because one did not. The MaxUnderFireSeconds anchor
        shipped as `underFireSeconds` while the real Lua identifier is
        `underFireSince`; the mutation then missed, the guard reported ERROR,
        and the run took three minutes to say so. A silently non-matching
        anchor is indistinguishable from a moved guard, so it is checked here
        rather than discovered during a run.
        """
        problems = []
        for guard in killcheck.GUARDS:
            path = guard_path(guard)
            if not path.is_file():
                problems.append(f"{guard.name}: no such file {path}")
                continue
            text = path.read_text(encoding="utf-8")
            for mutation in guard.mutations:
                anchor = killcheck.anchor_of(mutation)
                count = text.count(anchor)
                if count != 1:
                    problems.append(
                        f"{guard.name} in {path.name}: anchor matches {count} "
                        f"times, expected 1: {anchor[:90]!r}")
        self.assertEqual(problems, [], "\n  ".join(problems))

    def test_every_mutation_actually_changes_its_file(self):
        """A mutation that silently no-ops makes every covering test GREEN.

        The guard would then be reported VACUOUS or UNCOVERED for entirely the
        wrong reason, and a reviewer chasing that finding would find nothing.
        So each mutation is applied to a scratch copy and required to change
        the text.
        """
        no_ops = []
        for guard in killcheck.GUARDS:
            text = original = None
            error = None
            # A read can land in the middle of someone else's write, which is
            # the harness correctly refusing to falsify, not a broken guard.
            # Retry, as test_the_removal_actually_changes_the_sandbox_copy does.
            for _ in range(5):
                try:
                    original = guard_path(guard).read_text(encoding="utf-8")
                    text = original
                    for mutation in guard.mutations:
                        text = mutation.apply(text)
                    error = None
                    break
                except MutationError as exc:
                    error = exc
                    time.sleep(2.0)
            if error is not None:
                no_ops.append(f"{guard.name}: {error}")
                continue
            if text == original:
                no_ops.append(f"{guard.name}: mutation left "
                              f"{guard_path(guard).name} byte-identical")
        self.assertEqual(no_ops, [], "\n  ".join(no_ops))

    def test_the_harness_exits_non_zero_when_a_guard_is_vacuous(self):
        """The exit code is what CI reads, so it is tested by BEHAVIOUR.

        Asserting on the source text of the `bad = bool(...)` line would only
        prove the string is present. This actually calls the reporter with each
        failure mode and requires a non-zero exit from every one of them, plus
        a zero exit when everything is clean.
        """
        def outcome(verdict):
            return killcheck.GuardOutcome(
                name="g", title="t", file="f.lua", verdict=verdict, note="")

        clean = [outcome("KILLED")]
        self.assertEqual(killcheck.report(clean, [], [], []), 0,
                         "a fully killed inventory must exit 0, or the harness "
                         "is unusable as a gate")
        for verdict in ("VACUOUS", "UNCOVERED", "ERROR"):
            self.assertNotEqual(
                killcheck.report([outcome(verdict)], [], [], []), 0,
                f"a {verdict} guard must make the harness exit non-zero")
        self.assertNotEqual(
            killcheck.report(clean, [], [], ["C:/somewhere/real.lua"]), 0,
            "a write outside the sandbox must make the harness exit non-zero")
        self.assertNotEqual(killcheck.report(clean, ["data/scripts/changed.lua"], [], []), 0,
                            "source drift must prevent a clean verification gate")


class UnguardedConfigDiscoveryTests(unittest.TestCase):
    def test_boolean_defaults_are_discovered_from_the_config_not_the_list(self):
        keys = killcheck.discover_boolean_config_keys()
        self.assertIsInstance(keys, set)
        # Whatever else the file has grown, these four are guarded behaviour
        # and the discovery must find them from the file alone.
        for expected in ("FieldCheapHullWhileSaving",
                         "PreserveSavingClockWhileFielding"):
            self.assertIn(expected, keys,
                          f"discovery missed {expected}; the inventory would "
                          f"silently omit a guard")


if __name__ == "__main__":
    unittest.main()
