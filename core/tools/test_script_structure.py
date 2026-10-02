"""Structural checks over data/scripts/*.lua, as a runnable suite.

tools/undefined_global_check.py already proves this, but only when a human
remembers to run it. This wraps the same analysis in unittest so the constraint
is enforced by the test run itself.

Why it matters: FSO aborts the process with an uncatchable C++ exception when a
scripting call resolves to an undefined global, so a missing name is not a Lua
error you notice in play -- it is a crash with no stack and no log line. The
same class of failure is a method the engine's scripting object does not have.

Run: python core/tools/test_script_structure.py
"""

import re
import unittest
from pathlib import Path

import undefined_global_check as checker

SCRIPTS = Path(__file__).resolve().parents[1] / "data" / "scripts"

# Methods FSO's l_Texture actually exposes. There is no use(); an earlier
# revision called tex:use() to "bind" a texture and it took the whole HUD draw
# hook down with it. gr.drawImage binds the handle itself.
TEXTURE_METHODS = {"isValid", "getFilename", "getWidth", "getHeight", "unload"}

# Names FSO does NOT define as scripting globals. The mod uses module-local
# `valid` helpers (fs2rts_ai_util.valid, fs2rts_util.shipValid) precisely
# because no global exists; a call to a bare `shipValid(...)` would abort the
# engine, and it would not be caught by any Lua test because the engine never
# gets to raise a Lua error.
NOT_FSO_GLOBALS = {"shipValid", "shipAlive", "valid", "UseIcon"}


def _sources():
    for path in sorted(SCRIPTS.glob("*.lua")):
        yield path, path.read_text(encoding="utf-8", errors="replace")


def _strip(text):
    """Blank out comments and string literals so prose is not read as code."""
    out = re.sub(r"--\[\[.*?\]\]", " ", text, flags=re.DOTALL)
    out = re.sub(r"--[^\n]*", " ", out)
    out = re.sub(r"'(\\.|[^'\\])*'", "''", out)
    return re.sub(r'"(\\.|[^"\\])*"', '""', out)


class UndefinedGlobalTests(unittest.TestCase):
    """The same analysis as tools/undefined_global_check.py, as a test."""

    def test_every_bare_global_call_is_a_module_local_or_a_real_fso_global(self):
        problems = []
        for path, text in _sources():
            known = checker.declared_names(text) | checker.FSO_GLOBALS
            stripped = _strip(text)
            for match in checker.CALL.finditer(stripped):
                name = match.group(1)
                if name in known or name in checker.LUA_KEYWORDS:
                    continue
                line = stripped[: match.start()].count("\n") + 1
                problems.append(f"{path.name}:{line}  {name}()")
        self.assertEqual(
            problems, [],
            "bare global calls that no module defines and FSO does not provide; "
            "FSO aborts the process on these:\n  " + "\n  ".join(problems))

    # The exact shipped set. A threshold cannot catch a module being renamed or
    # removed, and a structural test that silently scans fewer files than it
    # used to is worse than no test at all.
    EXPECTED = {
        "fs2rts.lua", "fs2rts_ai.lua", "fs2rts_ai_planning.lua", "fs2rts_ai_production.lua",
        "fs2rts_ai_telemetry.lua", "fs2rts_ai_util.lua", "fs2rts_camera.lua", "fs2rts_config.lua",
        "fs2rts_factions.lua", "fs2rts_hud.lua", "fs2rts_input.lua", "fs2rts_lifecycle.lua",
        "fs2rts_operations.lua", "fs2rts_orders.lua", "fs2rts_pilot.lua", "fs2rts_player_wing.lua",
        "fs2rts_production.lua", "fs2rts_selection.lua", "fs2rts_service.lua", "fs2rts_state.lua",
        "fs2rts_station.lua", "fs2rts_strategy.lua", "fs2rts_ui_text.lua", "fs2rts_util.lua",
    }

    def test_the_checker_covers_every_shipped_script(self):
        found = {p.name for p in SCRIPTS.glob("*.lua")}
        self.assertEqual(
            self.EXPECTED - found, set(),
            "scripts the structural checks no longer scan; a module was renamed, removed, "
            "or moved out of data/scripts")
        self.assertEqual(
            found - self.EXPECTED, set(),
            "unexpected scripts in data/scripts; add them to the allowlist or move them out")

    # An earlier draft of this class asserted "no module rebinds an FSO global".
    # It is deliberately not here: the check cannot be written without false
    # positives. The mod idiomatically aliases engine globals at module scope
    # (`local ship, mn, gr = ship, mn, gr`), which is a legitimate readability
    # idiom and is indistinguishable from a shadowing bug by text analysis
    # alone. 33 matches across 24 scripts means the test would only have
    # trained everyone to ignore it.


class EngineApiShapeTests(unittest.TestCase):
    def test_no_script_calls_use_on_a_texture(self):
        offenders = []
        for path, text in _sources():
            for number, line in enumerate(text.splitlines(), 1):
                if ":use(" in line:
                    offenders.append(f"{path.name}:{number}: {line.strip()}")
        self.assertEqual(
            offenders, [],
            f"l_Texture exposes only {sorted(TEXTURE_METHODS)}; these call sites "
            "would abort the HUD draw hook:\n  " + "\n  ".join(offenders))

    def test_no_script_binds_an_fso_absent_global(self):
        offenders = []
        for path, text in _sources():
            # A module-local of the same name is exactly the fix, not the bug:
            # fs2rts_util defines shipValid and every consumer imports it with
            # `local shipValid = U.shipValid`. Only a call with no declaration
            # in scope is the engine-aborting case.
            declared = checker.declared_names(text)
            stripped = _strip(text)
            for name in sorted(NOT_FSO_GLOBALS):
                for match in re.finditer(rf"(?<![\w.:]){re.escape(name)}\s*\(", stripped):
                    if name in declared:
                        continue
                    line = stripped[: match.start()].count("\n") + 1
                    offenders.append(f"{path.name}:{line}  {name}()")
        self.assertEqual(
            offenders, [],
            "FSO defines no such scripting global; a call here aborts the process:\n  "
            + "\n  ".join(offenders))

    # test_every_required_helper_module_is_present used to live here. It was
    # redundant: UndefinedGlobalTests.test_the_checker_covers_every_shipped_script
    # pins the exact 24-file set, which is strictly stronger.


class UtilSurfaceTests(unittest.TestCase):
    """The harnesses stub fs2rts_util. The real module's export list is the
    contract those stubs have to mirror, so a helper added to the real module
    without a stub is a latent nil upvalue in every test that loads it."""

    EXPORTS = {
        "AI_FACTION_ORDER", "sortedNumericKeys", "clamp", "lower", "vec", "copyVec",
        "distance2", "objectValid", "shipValid", "shipAlive", "teamName",
        "tableContainsSignature",
    }

    def test_the_real_module_still_exports_every_helper(self):
        text = (SCRIPTS / "fs2rts_util.lua").read_text(encoding="utf-8", errors="replace")
        exported = set(re.findall(r"^\s{4}(\w+)\s*=\s*\w+,?\s*$", text, re.MULTILINE))
        self.assertEqual(self.EXPORTS - exported, set(),
                         "fs2rts_util lost an export; every test stub must be updated to match")

    def _stub_table(self, text, start):
        """The {...} literal the stub returns.

        Locating it by "the first return after the stub header" is wrong: these
        stubs build a vector metatable first, and the first `return` in the
        body belongs to createVector. Every `return` is tried and the table that
        matches the most export names wins, so the probe cannot be fooled by a
        helper defined above the real one."""
        best, best_score = None, -1
        cursor = start
        while True:
            ret = text.find("return", cursor)
            if ret < 0:
                break
            region = self._brace_table(text, ret)
            cursor = ret + 6
            if region is None:
                continue
            score = sum(1 for name in self.EXPORTS
                        if re.search(rf"(?:^|[\s,{{]){re.escape(name)}\s*=", region))
            if score > best_score:
                best, best_score = region, score
        return best

    @staticmethod
    def _brace_table(text, start):
        brace = text.find("{", start)
        if brace < 0:
            return None
        depth = 0
        index = brace
        quote = None
        while index < len(text):
            ch = text[index]
            if quote:
                if ch == "\\":
                    index += 2
                    continue
                if ch == quote:
                    quote = None
            elif ch in "'\"":
                quote = ch
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return text[brace:index + 1]
            index += 1
        return None

    def test_every_util_stub_in_the_harnesses_returns_the_whole_export_list(self):
        """A harness that stubs fs2rts_util leaves every helper it omits as a NIL
        module-local in each module that loads it. The call then dies on
        "attempt to call a nil value" -- a harness failure that reads like
        coverage. Each stub's returned table is located by brace matching, and
        every export name has to appear as a key in it, so a name that is only
        mentioned in a comment or in the test's own assertions does not count."""
        tools = Path(__file__).resolve().parent
        marker = re.compile(r"package\.preload\.fs2rts_util\s*=\s*function\s*\(\s*\)")
        problems = []
        checked = []
        for path in sorted(tools.glob("test_*.py")):
            if path.name == Path(__file__).name:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for match in marker.finditer(text):
                region = self._stub_table(text, match.end())
                if region is None:
                    problems.append(f"{path.name}: stub table literal could not be located")
                    continue
                checked.append(path.name)
                missing = sorted(
                    name for name in self.EXPORTS
                    if not re.search(rf"(?:^|[\s,{{]){re.escape(name)}\s*=", region))
                if missing:
                    line = text[: match.start()].count("\n") + 1
                    problems.append(
                        f"{path.name}:{line}: fs2rts_util stub omits {missing} -- nil upvalues in "
                        "every module that loads it")
        self.assertGreaterEqual(
            len(checked), 6, f"only located {len(checked)} fs2rts_util stubs: {checked}")
        self.assertEqual(problems, [], "\n  ".join(problems))


if __name__ == "__main__":
    unittest.main()
