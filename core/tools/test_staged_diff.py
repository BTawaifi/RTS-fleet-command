"""Tests for staged_diff.py - the arm provenance tool.

The interesting cases here are the ones that already went wrong once while
this tool was being written, because each was a way of reporting an A/B as
cleaner than it was:

* the baseline resolved to `<arm>/base` while the candidate stayed at the arm
  root, so every batch-plan field compared against None and both arms were
  reported "not comparable";
* `_split_assignments` stripped each part to column 0, destroying the
  indentation the nesting logic depended on, so every key was reported at the
  root and `--expect AI.CapitalAwareInvestment=true` failed on a flag that was
  set correctly;
* a closing brace cleared the whole table stack, losing the enclosing table;
* a `a = 1, b = 2` line recorded only `a`, with `b`'s name swallowed into the
  value, hiding a changed knob;
* `<absent>` and an explicit `nil` both rendered as None, making a flag that
  was ADDED indistinguishable from one set to nil.
"""
import json
import shutil
import tempfile
import unittest
from pathlib import Path

import staged_diff


CONFIG_NAME = "fs2rts_config.lua"


def write_config(root, body):
    path = Path(root) / "data" / "scripts" / CONFIG_NAME
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


def make_arm(root, config_body, plan=None, freeze=None, extra=None):
    """Build `<root>/base/rts/...` plus the arm-level json files."""
    arm = Path(root)
    mod = arm / "base" / "rts"
    write_config(mod, config_body)
    if extra:
        for relative, text in extra.items():
            target = mod / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
    if plan is not None:
        (arm / "batch.plan.json").write_text(json.dumps(plan), encoding="utf-8")
    if freeze is not None:
        (arm / "freeze.json").write_text(json.dumps(freeze), encoding="utf-8")
    return arm


BASE_PLAN = {"mission": "FS2_RTS_Escalation", "mod": ["probe", "rts"],
             "pilot": "Alver", "workers": 4, "repeats": 4,
             "seed_start": 2026092901, "seed_lua_random": True,
             "fixed_dt": 0.0333, "max_sim_time": 3000}
BASE_FREEZE = {"engine_sha256": "e" * 64, "runner_sha256": "r" * 64,
               "driver_sha256": "d" * 64, "matches": 4, "max_sim_time": 3000}


class TempTreeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="staged_diff_"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)


class ParserTests(TempTreeTest):
    def test_comment_stripping_ignores_double_dash_inside_a_string(self):
        line = '    Motto = "peace -- maybe war" -- trailing note'
        self.assertEqual(staged_diff.strip_comment(line).strip(),
                         'Motto = "peace -- maybe war"')

    def test_multiline_value_containing_a_comma_in_quotes_is_not_split(self):
        parts = staged_diff._split_assignments('Name = "a, b", Other = 2')
        self.assertEqual(len(parts), 2)

    def test_several_assignments_on_one_line_are_all_recorded(self):
        text = ("    AI = {\n"
                "        HullCostFraction = .35, AmmoCostFraction = .12,\n"
                "    },\n")
        found = staged_diff.parse_lua_scalars(text)
        self.assertEqual(found["HullCostFraction"][0]["value"], ".35")
        self.assertEqual(found["AmmoCostFraction"][0]["value"], ".12")

    def test_a_name_assigned_in_two_tables_keeps_both_occurrences(self):
        text = ("    AI = {\n"
                "        ReturnHull = .40,\n"
                "    },\n"
                "    Station = {\n"
                "        ReturnHull = .25,\n"
                "    },\n")
        found = staged_diff.parse_lua_scalars(text)
        self.assertEqual(len(found["ReturnHull"]), 2)
        self.assertEqual([e["value"] for e in found["ReturnHull"]],
                         [".40", ".25"])

    def test_nesting_is_not_guessed_so_a_key_name_cannot_be_wrong(self):
        """The dotted-path reconstruction was wrong on the real config."""
        text = ("    Station = {\n"
                "        AI = {\n"
                "            CapitalAwareInvestment = true,\n"
                "        },\n"
                "    },\n")
        found = staged_diff.parse_lua_scalars(text)
        self.assertIn("CapitalAwareInvestment", found)
        # The value must be readable; the enclosing table is deliberately not
        # reconstructed, so the key can never claim the wrong parent.
        self.assertEqual(found["CapitalAwareInvestment"][0]["value"], "true")

    def test_line_numbers_are_reported_so_a_flag_can_be_opened_directly(self):
        text = "    AI = {\n        Flag = false,\n    },\n"
        found = staged_diff.parse_lua_scalars(text)
        self.assertEqual(found["Flag"][0]["line"], 2)

    def test_inline_table_entry_keeps_its_first_key_and_a_clean_last_value(self):
        """The sentry class lists are one entry per line, e.g.

            { class = "GTSG Watchdog", tier = 1, range = 11000 },

        The opening brace hides `class` and the closing brace sticks to the
        last value, so the reach - the field a tuning change turns on - would
        otherwise be reported as "11000 }" and `class` would not appear at all.
        """
        text = ('    Classes = {\n'
                '        { class = "GTSG Watchdog", tier = 1, range = 11000 },\n'
                '    },\n')
        found = staged_diff.parse_lua_scalars(text)
        self.assertEqual(found["class"][0]["value"], "GTSG Watchdog")
        self.assertEqual(found["tier"][0]["value"], "1")
        self.assertEqual(found["range"][0]["value"], "11000")

    def test_a_real_sentry_range_change_is_reported_as_two_numbers(self):
        before = ('    Classes = {\n'
                  '        { class = "GTSG Watchdog", range = 1375 },\n'
                  '    },\n')
        after = ('    Classes = {\n'
                 '        { class = "GTSG Watchdog", range = 11000 },\n'
                 '    },\n')
        base = make_arm(self.tmp / "a", before, plan=BASE_PLAN,
                        freeze=BASE_FREEZE)
        cand = make_arm(self.tmp / "b", after, plan=BASE_PLAN,
                        freeze=BASE_FREEZE)
        changed = staged_diff.build_report(base, cand)["config"]["changed"]
        self.assertIn({"key": "range", "baseline": "1375",
                       "candidate": "11000", "baseline_line": 2,
                       "candidate_line": 2}, changed)

    def test_comment_only_lines_produce_nothing(self):
        found = staged_diff.parse_lua_scalars("    -- Flag = true\n")
        self.assertEqual(found, {})


class SnapshotTests(TempTreeTest):
    def test_tools_and_caches_are_excluded_from_the_snapshot(self):
        mod = self.tmp / "arm" / "base" / "rts"
        write_config(mod, "return {\n}\n")
        (mod / "tools").mkdir(parents=True, exist_ok=True)
        (mod / "tools" / "ai_tactics.py").write_text("x = 1\n", encoding="utf-8")
        (mod / ".pytest_cache").mkdir(parents=True, exist_ok=True)
        (mod / ".pytest_cache" / "junk").write_text("y\n", encoding="utf-8")
        files = staged_diff.snapshot_files(mod)
        self.assertIn("data/scripts/" + CONFIG_NAME, files)
        self.assertNotIn("tools/ai_tactics.py", files)
        self.assertFalse(any(k.startswith(".pytest_cache") for k in files))

    def test_a_changed_lua_file_is_reported_even_with_no_config_change(self):
        base = make_arm(self.tmp / "a", "return {\n    Flag = false,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE,
                        extra={"data/scripts/fs2rts_strategy.lua": "return 1\n"})
        cand = make_arm(self.tmp / "b", "return {\n    Flag = false,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE,
                        extra={"data/scripts/fs2rts_strategy.lua": "return 2\n"})
        report = staged_diff.build_report(base, cand)
        self.assertEqual(report["config"]["changed"], [])
        self.assertEqual(report["files"]["changed"],
                         ["data/scripts/fs2rts_strategy.lua"])
        self.assertEqual(report["verdict"], "differs")


class ReportTests(TempTreeTest):
    def test_identical_arms_are_clean_and_comparable(self):
        body = "return {\n    AI = {\n        Flag = false,\n    },\n}\n"
        base = make_arm(self.tmp / "a", body, plan=BASE_PLAN,
                        freeze=BASE_FREEZE)
        cand = make_arm(self.tmp / "b", body, plan=BASE_PLAN,
                        freeze=BASE_FREEZE)
        report = staged_diff.build_report(base, cand)
        self.assertEqual(report["verdict"], "clean")
        self.assertEqual(report["plan_deltas"], {})
        self.assertEqual(report["freeze_deltas"], {})
        self.assertFalse(report["fail"])

    def test_plan_is_read_from_the_arm_root_on_both_sides(self):
        """The baseline/candidate depth asymmetry that broke this tool."""
        body = "return {\n    Flag = false,\n}\n"
        base = make_arm(self.tmp / "a", body, plan=BASE_PLAN,
                        freeze=BASE_FREEZE)
        cand = make_arm(self.tmp / "b", body, plan=BASE_PLAN,
                        freeze=BASE_FREEZE)
        # Same arm, but one argument points at base/ instead of the arm root.
        report = staged_diff.build_report(base / "base", cand)
        self.assertEqual(report["plan_deltas"], {},
                         "resolving one side deeper must not invent deltas")
        self.assertEqual(report["verdict"], "clean")

    def test_a_seed_or_cap_difference_marks_the_arms_not_comparable(self):
        body = "return {\n    Flag = false,\n}\n"
        other = dict(BASE_PLAN, seed_start=2026092999)
        base = make_arm(self.tmp / "a", body, plan=BASE_PLAN,
                        freeze=BASE_FREEZE)
        cand = make_arm(self.tmp / "b", body, plan=other,
                        freeze=BASE_FREEZE)
        report = staged_diff.build_report(base, cand)
        self.assertEqual(report["verdict"], "not-comparable")
        self.assertIn("seed_start", report["plan_deltas"])

    def test_an_engine_change_is_reported_from_freeze(self):
        body = "return {\n    Flag = false,\n}\n"
        base = make_arm(self.tmp / "a", body, plan=BASE_PLAN,
                        freeze=BASE_FREEZE)
        cand = make_arm(self.tmp / "b", body, plan=BASE_PLAN,
                        freeze=dict(BASE_FREEZE, engine_sha256="f" * 64))
        report = staged_diff.build_report(base, cand)
        self.assertIn("engine_sha256", report["freeze_deltas"])

    def test_one_flag_flip_is_reported_with_both_values_and_lines(self):
        base = make_arm(self.tmp / "a",
                        "return {\n    AI = {\n        X = false,\n    },\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE)
        cand = make_arm(self.tmp / "b",
                        "return {\n    AI = {\n        X = true,\n    },\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE)
        report = staged_diff.build_report(base, cand)
        changed = report["config"]["changed"]
        self.assertEqual(len(changed), 1)
        self.assertEqual(changed[0]["key"], "X")
        self.assertEqual(changed[0]["baseline"], "false")
        self.assertEqual(changed[0]["candidate"], "true")
        self.assertEqual(changed[0]["baseline_line"], 3)

    def test_an_added_flag_is_absent_not_nil(self):
        base = make_arm(self.tmp / "a", "return {\n    X = false,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE)
        cand = make_arm(self.tmp / "b",
                        "return {\n    X = false,\n    New = true,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE)
        report = staged_diff.build_report(base, cand)
        entry = next(e for e in report["config"]["changed"]
                     if e["key"] == "New")
        self.assertEqual(repr(entry["baseline"]), "<absent>")
        self.assertEqual(entry["candidate"], "true")

    def test_expectation_matching_passes_and_fails_correctly(self):
        base = make_arm(self.tmp / "a",
                        "return {\n    X = false,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE)
        cand = make_arm(self.tmp / "b",
                        "return {\n    X = true,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE)
        good = staged_diff.build_report(base, cand,
                                        expect={"X": "true"})
        self.assertEqual(good["expect"]["mismatches"], [])
        self.assertFalse(good["fail"])
        self.assertEqual(good["verdict"], "differs")

        bad = staged_diff.build_report(base, cand, expect={"X": "false"})
        self.assertEqual(len(bad["expect"]["mismatches"]), 1)
        self.assertTrue(bad["fail"])
        self.assertEqual(bad["verdict"], "expectation-failed")

    def test_expectation_fails_when_the_flag_is_absent_from_the_candidate(self):
        base = make_arm(self.tmp / "a", "return {\n    X = false,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE)
        cand = make_arm(self.tmp / "b", "return {\n    Y = false,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE)
        report = staged_diff.build_report(base, cand, expect={"X": "false"})
        self.assertEqual(len(report["expect"]["mismatches"]), 1)
        self.assertEqual(repr(report["expect"]["mismatches"][0]["actual"]),
                         "<absent>")

    def test_a_changed_but_undeclared_key_is_reported(self):
        base = make_arm(self.tmp / "a",
                        "return {\n    X = false,\n    Y = 1,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE)
        cand = make_arm(self.tmp / "b",
                        "return {\n    X = true,\n    Y = 2,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE)
        report = staged_diff.build_report(base, cand, expect={"X": "true"})
        self.assertEqual(report["expect"]["undeclared_changed_keys"], ["Y"])

    def test_require_clean_fails_on_a_code_only_change(self):
        base = make_arm(self.tmp / "a", "return {\n    X = false,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE,
                        extra={"data/scripts/fs2rts_hud.lua": "a\n"})
        cand = make_arm(self.tmp / "b", "return {\n    X = false,\n}\n",
                        plan=BASE_PLAN, freeze=BASE_FREEZE,
                        extra={"data/scripts/fs2rts_hud.lua": "b\n"})
        report = staged_diff.build_report(base, cand, require_clean=True)
        self.assertTrue(report["fail"])

    def test_a_missing_snapshot_is_unreadable_rather_than_clean(self):
        report = staged_diff.build_report(self.tmp / "nope", self.tmp / "nah")
        self.assertEqual(report["verdict"], "unreadable")
        self.assertIsNone(report["baseline_mod_dir"])

    def test_cli_returns_two_when_an_argument_is_not_an_arm(self):
        self.assertEqual(
            staged_diff.main([str(self.tmp / "nope"), str(self.tmp / "nah")]),
            2)

    def test_cli_refuses_expect_together_with_require_clean(self):
        with self.assertRaises(SystemExit) as raised:
            staged_diff.main(["a", "b", "--expect", "X=true",
                              "--require-clean"])
        self.assertNotEqual(raised.exception.code, 0)

    def test_parse_expect_rejects_a_pair_without_an_equals_sign(self):
        import argparse
        with self.assertRaises(argparse.ArgumentTypeError):
            staged_diff.parse_expect(["Xtrue"])


class RealArmTests(unittest.TestCase):
    """Checks against the actual staged arms, not a fixture.

    These lock in two provenance facts that were previously only hand-checked,
    and they are the reason this tool exists: one published "control" batch is
    byte-identical to another arm, and the capital-gate arm really is a
    single-file, single-assignment change against that control.
    """
    STAGING = (Path(__file__).resolve().parents[3] / "rts-headless-staging")

    def arm(self, name):
        path = self.STAGING / name
        if not path.is_dir():
            self.skipTest(f"staging arm not present: {path}")
        return path

    def test_the_published_control_is_byte_identical_to_another_arm(self):
        report = staged_diff.build_report(self.arm("fragctrl-20261001"),
                                          self.arm("fallbk-20261001"))
        self.assertEqual(report["files"]["changed"], [])
        self.assertEqual(report["config"]["changed"], [])
        self.assertEqual(report["verdict"], "clean",
                         "fragctrl and fallbk are the same run twice; any "
                         "metric difference between them is sampling noise")

    def test_the_capital_gate_arm_is_one_flag_against_its_control(self):
        report = staged_diff.build_report(
            self.arm("fragctrl-20261001"), self.arm("capgate-20261001"),
            expect={"CapitalAwareInvestment": "true"})
        self.assertEqual(report["expect"]["mismatches"], [])
        self.assertEqual(report["expect"]["undeclared_changed_keys"], [])
        self.assertEqual(report["files"]["changed"],
                         ["data/scripts/" + CONFIG_NAME])
        self.assertEqual(len(report["config"]["changed"]), 1)
        self.assertEqual(report["config"]["changed"][0]["key"],
                         "CapitalAwareInvestment")
        self.assertEqual(report["plan_deltas"], {})