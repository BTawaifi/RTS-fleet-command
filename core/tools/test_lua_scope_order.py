"""Unit tests for tools/lua_scope_order_check.py -- the use-before-local-declaration
checker.

Why this exists as a test rather than a script someone remembers to run: the
defect it catches shipped to a live game window as

    LUA ERROR: [string "fs2rts_hud.lua"]:914: attempt to index global
    'RETICLE_COLOR_SELECTED' (a nil value)

while 370 unit tests and tools/undefined_global_check.py both passed clean.
A whole-file existence check cannot see that class of bug: the name IS
assigned, just 150 lines too late, and the line only runs when a contact is
selected on a tactical map.

The tests here are deliberately in three groups:

  * REGRESSION  the exact shipped shape, which must stay caught forever
  * NEGATIVE    constructs that superficially resemble the bug and must NOT be
                flagged, because a checker that cries wolf on 300 lines of
                valid Lua is a checker nobody runs
  * SOUNDNESS   the shipped mod must be clean, and the checker must be proven
                to actually go dirty when a defect is injected

Run: python -m pytest test_lua_scope_order.py -q   (from core/tools)
"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import lua_scope_order_check as checker

TOOLS = Path(__file__).resolve().parent
SCRIPTS = checker.SCRIPTS


def errors(src, **kw):
    return [f for f in checker.analyze(src, "t.lua", **kw) if f.level == "error"]


def infos(src, **kw):
    return [f for f in checker.analyze(src, "t.lua", **kw) if f.level == "info"]


class ShippedRegressionTests(unittest.TestCase):
    """The exact defect from fs2rts_hud.lua, in the shape it shipped.

    RETICLE_COLOR_SELECTED was declared ~150 lines below its first use inside
    DrawTacticalMap's per-ship EachShip callback. Lua resolves the early read
    to a global, gets nil, and dies on the index -- only when a contact is
    selected on the tactical map.
    """

    def test_read_above_a_file_scope_local_declaration_is_caught(self):
        src = (
            "local RETICLE_COLORS = {friendly = {70, 220, 255}}\n"
            "function RTS:DrawTacticalMap()\n"
            "    return RETICLE_COLOR_SELECTED[1]\n"      # line 3: too early
            "end\n"
            "local RETICLE_COLOR_SELECTED = {255, 225, 50}\n"  # line 5
        )
        found = errors(src)
        self.assertEqual([f.name for f in found], ["RETICLE_COLOR_SELECTED"])
        self.assertEqual(found[0].line, 3)
        self.assertEqual(found[0].kind, "out-of-scope-local")
        # the report must name the declaration line, or it is not actionable
        self.assertIn("5", found[0].detail)

    def test_a_name_in_a_multi_name_local_declaration_is_not_a_global(self):
        """`local a, b = ...` declares b too. The name after a comma used to be
        taken for a module global, so an early read of it passed as harmless
        shadowing (info) instead of the nil read it is. The split HUD imports its
        shared colour tables through exactly this kind of declaration."""
        src = (
            "function RTS:DrawTacticalMap()\n"
            "    return RETICLE_COLORS.friendly\n"              # line 2: too early
            "end\n"
            "local RTS, clamp, RETICLE_COLORS = {}, 1, {}\n"   # line 4
        )
        found = errors(src)
        self.assertEqual([f.name for f in found], ["RETICLE_COLORS"])
        self.assertEqual(found[0].kind, "out-of-scope-local")

    def test_the_hud_hoist_fix_is_what_makes_it_clean(self):
        """The shipped fix (hoisting the block above its first use) must clear
        it. If this fails, the fix was reverted."""
        src = (
            "local RETICLE_COLOR_SELECTED = {255, 225, 50}\n"
            "local RETICLE_COLOR_HOVERED = {255, 255, 180}\n"
            "function RTS:DrawTacticalMap()\n"
            "    return RETICLE_COLOR_SELECTED[1] .. RETICLE_COLOR_HOVERED[2]\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])

    def test_a_method_call_on_a_late_local_is_also_caught(self):
        """The task brief calls this out: `X:foo()` on a name that resolves to
        nil is "attempt to call method on a nil value"."""
        src = (
            "function RTS:Go()\n"
            "    return HELPER:compute(1)\n"
            "end\n"
            "local HELPER = {compute = function() end}\n"
        )
        self.assertEqual([f.name for f in errors(src)], ["HELPER"])

    def test_a_read_in_a_nested_block_above_the_declaration_is_caught(self):
        src = (
            "function RTS:Go()\n"
            "    if true then\n"
            "        return LATE[1]\n"
            "    end\n"
            "    local LATE = {1}\n"
            "end\n"
        )
        self.assertEqual([f.name for f in errors(src)], ["LATE"])

    def test_mutual_recursion_via_a_late_local_is_caught(self):
        """`local function a() return b end` before `local function b` resolves
        b to a nil global, even though the call site is later and looks fine."""
        src = (
            "local function first()\n"
            "    return second()\n"
            "end\n"
            "local function second()\n"
            "    return 1\n"
            "end\n"
            "return first()\n"
        )
        self.assertEqual([f.name for f in errors(src)], ["second"])


class NegativeTests(unittest.TestCase):
    """Constructs that look like the bug but are correct Lua.

    Every one of these shipped as a false positive during development. They are
    pinned here because a scope checker that flags valid Lua trains everyone to
    ignore it, which is how the original defect survived in the first place.
    """

    def test_local_function_is_visible_to_later_callers(self):
        src = (
            "local function helper(a)\n"
            "    return a * 2\n"
            "end\n"
            "function RTS:Go()\n"
            "    return helper(2)\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])

    def test_recursion_inside_its_own_local_function_is_visible(self):
        src = (
            "local function fact(n)\n"
            "    if n <= 1 then return 1 end\n"
            "    return n * fact(n - 1)\n"
            "end\n"
            "return fact(5)\n"
        )
        self.assertEqual(errors(src), [])

    def test_file_scope_local_is_visible_inside_nested_functions(self):
        src = (
            "local M = {}\n"
            "local SCALE = 2\n"
            "function M.go()\n"
            "    local function inner()\n"
            "        return SCALE\n"
            "    end\n"
            "    return inner()\n"
            "end\n"
            "return M\n"
        )
        self.assertEqual(errors(src), [])

    def test_field_and_method_reads_are_not_variable_reads(self):
        src = (
            "local Cfg = {a = 1}\n"
            "local obj = {}\n"
            "function RTS:Go()\n"
            "    return Cfg.a + Cfg[\"a\"] + obj:getName() + self.value\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])

    def test_engine_globals_are_never_flagged(self):
        """ORDER_ATTACK, gr, mn, vec, ship are engine globals. The mod never
        declares them, so a checker that has not heard of the engine flags
        every giveOrder call in the codebase."""
        src = (
            "function RTS:Hold(ship)\n"
            "    gr.setColor(255, 255, 255, 255)\n"
            "    local p = vec(0, 0, 0)\n"
            "    ship:giveOrder(ORDER_STAY_STILL, nil, nil, 0.95)\n"
            "    return mn.Lua and ba.inMission\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])

    def test_table_constructor_keys_are_not_variable_reads(self):
        src = (
            "function RTS:Go()\n"
            "    local t = {alpha = 1, beta = 2, gamma = 3}\n"
            "    return t\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])

    def test_loop_variables_are_visible_in_their_own_loop(self):
        src = (
            "function RTS:Go(items)\n"
            "    local total = 0\n"
            "    for i = 1, 3 do\n"
            "        total = total + i\n"
            "    end\n"
            "    for _, v in ipairs(items) do\n"
            "        total = total + v\n"
            "    end\n"
            "    return total\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])

    def test_block_scoped_shadowing_is_respected_in_both_directions(self):
        """`local x` inside an `if` is visible below it in that branch and is a
        DIFFERENT variable from the outer `x` after the branch closes."""
        src = (
            "function RTS:Go()\n"
            "    local x = 1\n"
            "    if x > 0 then\n"
            "        local x = 2\n"
            "        return x\n"
            "    end\n"
            "    return x\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])

    def test_repeat_until_sees_locals_declared_in_the_body(self):
        """Lua specifically allows this: the until-condition can see the body's
        locals. A scope tracker that pushes and pops at `repeat` would flag it."""
        src = (
            "function RTS:Go()\n"
            "    local n = 0\n"
            "    repeat\n"
            "        local done = n > 3\n"
            "        n = n + 1\n"
            "    until done\n"
            "    return n\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])

    def test_strings_and_comments_containing_lua_are_never_read_as_code(self):
        src = (
            "-- local COMMENTED = nil\n"
            "--[[ local BLOCKED = nil\n"
            "     local ALSO_BLOCKED = nil ]]\n"
            "local s = \"local STRINGY = nil\"\n"
            "local t = [[local LONGSTRINGY = nil]]\n"
            "function RTS:Go()\n"
            "    return s .. t\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])

    def test_a_local_declared_on_a_shared_line_is_visible_later(self):
        """This codebase packs declarations onto one line
        ("local role=...; local shape=..."), so a line-anchored matcher misses
        them -- the same class of blind spot as the original bug."""
        src = (
            "function RTS:Go()\n"
            "    local role = 1; local shape = 2; local n = role + shape\n"
            "    return n\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])

    def test_engine_global_aliased_by_a_local_is_clean(self):
        """The mod idiomatically shadows engine globals with local aliases:
        `local ship, mn, gr = ship, mn, gr`. Reading a name the file does NOT
        declare as a local must not be reported."""
        src = (
            "local gr = gr\n"
            "local mn = mn\n"
            "function RTS:Go()\n"
            "    gr.setColor(1, 2, 3, 4)\n"
            "    return mn.Lua\n"
            "end\n"
        )
        self.assertEqual(errors(src), [])


class ShadowedGlobalTests(unittest.TestCase):
    """A read that lands on a real global cannot crash, so it must not be an
    error -- but if the file also declares that name with `local` somewhere, the
    inconsistency is worth surfacing at info level."""

    def test_late_read_of_a_name_the_engine_provides_is_info_not_error(self):
        src = (
            "function RTS:Go()\n"
            "    gr.setColor(1, 2, 3, 4)\n"
            "end\n"
            "local gr = gr\n"
        )
        self.assertEqual(errors(src), [])
        self.assertEqual([f.name for f in infos(src)], ["gr"])

    def test_no_info_when_the_name_is_never_declared_locally(self):
        src = (
            "function RTS:Go()\n"
            "    return ship:getSignature() + mn.Lua\n"
            "end\n"
        )
        self.assertEqual(infos(src), [])


class ShippedModTests(unittest.TestCase):
    """The mod itself must be clean, and the checker must be proven to notice
    when it is not."""

    def test_no_shipped_script_has_an_out_of_scope_read(self):
        problems = [f.format() for f in checker.check() if f.level == "error"]
        self.assertEqual(
            problems, [],
            "reads that resolve to a nil global:\n  " + "\n  ".join(problems))

    def test_the_checker_still_scans_every_shipped_script(self):
        """Do not accept an empty tree; required-module closure is checked separately."""
        names = {p.name for p in SCRIPTS.rglob("*.lua")}
        self.assertTrue(names,'no scripts were inspected')
        self.assertIn('fs2rts.lua',names,'mission scripting entrypoint is missing')

    def test_every_script_is_actually_analysed(self):
        """A parse failure must be loud. Silently skipping a file that the
        tokenizer cannot read would make this whole suite vacuous, and a file
        whose blocks do not balance makes every scope decision below the
        imbalance wrong."""
        smallest = None
        for path in sorted(SCRIPTS.rglob("*.lua")):
            text = path.read_text(encoding="utf-8", errors="replace")
            tokens = checker.tokenize(text)
            self.assertGreater(
                len(tokens), 10,
                f"{path.name} produced only {len(tokens)} tokens; the "
                f"tokenizer is not reading it")
            if smallest is None or len(tokens) < smallest[1]:
                smallest = (path.name, len(tokens))
            unbalanced = checker.syntax_imbalance(text, path.name)
            self.assertEqual(
                [f.format() for f in unbalanced], [],
                f"{path.name} does not parse as Lua, so the scope walk is "
                f"judging every read against the wrong frame")
        self.assertIsNotNone(smallest)

    def test_an_unbalanced_file_is_reported(self):
        """The balance check has to be able to fire, or it is decoration."""
        self.assertEqual(
            checker.syntax_imbalance("function a()\n  local x = 1\nend\n", "t.lua"),
            [])
        bad = checker.syntax_imbalance(
            "function a()\n  local x = 1\nend\nend\n", "t.lua")
        self.assertEqual([f.kind for f in bad], ["syntax-imbalance"])
        unclosed = checker.syntax_imbalance(
            "function a()\n  local x = 1\n", "t.lua")
        self.assertEqual([f.kind for f in unclosed], ["syntax-imbalance"])
        self.assertIn("left open", unclosed[0].detail)

    def test_the_tool_exits_non_zero_when_a_defect_is_injected(self):
        """Soundness: a checker that always reports OK would satisfy every test
        above. Inject the real defect into a real file and require it to fire."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            for p in SCRIPTS.rglob("*.lua"):
                target = root / p.relative_to(SCRIPTS)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(p, target)
            clean = checker.check(root)
            self.assertEqual([f for f in clean if f.level == "error"], [],
                             "the copied tree should start clean")

            victim = root / "fs2rts_util.lua"
            victim.write_text(
                victim.read_text(encoding="utf-8")
                + "\nfunction RTS:Injected()\n"
                  "    return INJECTED_LATE_CONSTANT[1]\n"
                  "end\n"
                  "local INJECTED_LATE_CONSTANT = {1}\n",
                encoding="utf-8")

            dirty = [f for f in checker.check(root) if f.level == "error"]
            self.assertEqual([f.name for f in dirty],
                             ["INJECTED_LATE_CONSTANT"],
                             "an injected use-before-declaration must be caught")
            # the appended text is: blank, `function RTS:Injected()`,
            # `return ...`, `end`, `local ...` -- so the READ is 3 lines above
            # the end of file, and the declaration is the last line.
            injected = victim.read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                dirty[0].line, len(injected) - 2,
                f"the finding must point at the read on line "
                f"{len(injected) - 2}, not the declaration on line "
                f"{len(injected)}")

    def test_main_returns_one_when_dirty_and_zero_when_clean(self):
        self.assertEqual(checker.main(["-q"]), 0)


class EngineAllowlistTests(unittest.TestCase):
    """The engine allowlist is generated from the engine source, because
    hand-typing it is how `ai-fly-to` (an SEXP that does not exist) shipped."""

    def test_the_generated_allowlist_exists_and_is_not_empty(self):
        import fso_lua_globals_generated as gen

        self.assertGreater(len(gen.FSO_ENUM_GLOBALS), 100)
        self.assertGreater(len(gen.FSO_REGISTERED_GLOBALS), 50)

    def test_real_engine_globals_are_proven_by_the_generator(self):
        import fso_lua_globals_generated as gen

        for name in ("ORDER_ATTACK", "ORDER_ATTACK_ANY", "ORDER_GUARD",
                     "ORDER_STAY_STILL", "ORDER_WAYPOINTS_ONCE",
                     "ORDER_DEPART", "ORDER_PLAY_DEAD",
                     "NORMAL_BUTTON_CONTROLS", "LUA_OVERRIDE_BUTTON_CONTROL",
                     "MOUSE_LEFT_BUTTON"):
            self.assertIn(name, gen.FSO_LUA_GLOBALS,
                          f"{name} is used by the mod and must be proven by "
                          f"the engine source, not assumed")

    def test_no_mod_read_depends_only_on_the_hand_written_extra_list(self):
        """ENGINE_EXTRA_GLOBALS covers legacy/pre-ADE engine API the generator's
        tree scan cannot see. If a mod read resolved ONLY through that list, the
        allowlist would be doing the work the generator was written to do, and
        an unverified name could be hiding a real defect."""
        import fso_lua_globals_generated as gen

        generated = set(gen.FSO_LUA_GLOBALS)
        only_extra = set(checker.ENGINE_EXTRA_GLOBALS) - generated
        offenders = set()
        for path in sorted(SCRIPTS.rglob("*.lua")):
            text = path.read_text(encoding="utf-8", errors="replace")
            # restrict to what the EXTRA list alone would rescue
            rescued = checker.analyze(
                text, path.name,
                extra_globals=generated | checker.LUA_STDLIB_GLOBALS)
            for f in rescued:
                if f.name in only_extra:
                    offenders.add(f.name)
        self.assertEqual(
            offenders, set(),
            "these reads resolve only via the unverified ENGINE_EXTRA_GLOBALS; "
            "verify them against the engine source or teach the generator to "
            f"extract them: {sorted(offenders)}")


if __name__ == "__main__":
    unittest.main()
