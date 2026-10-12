"""Package/asset/API-pattern checks; not native engine or gameplay evidence.

Lua scope/use-before-declaration coverage is in test_lua_scope_order.
This file checks required-module closure and the boundary doubles' util surface,
plus the historical unsupported texture-use call pattern.
"""

import re
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1] / "data" / "scripts"

# Methods FSO's l_Texture actually exposes. There is no use(); an earlier
# revision called tex:use() to "bind" a texture and it took the whole HUD draw
# hook down with it. gr.drawImage binds the handle itself.
TEXTURE_METHODS = {"isValid", "getFilename", "getWidth", "getHeight", "unload"}



def _sources():
    for path in sorted(SCRIPTS.rglob("*.lua")):
        yield path, path.read_text(encoding="utf-8", errors="replace")


def _module(path):
    """require() name of a script: fs2rts_hud/common.lua -> fs2rts_hud.common."""
    return ".".join(path.relative_to(SCRIPTS).with_suffix("").parts)




class UndefinedGlobalTests(unittest.TestCase):
    """Package closure; name/scope correctness is covered by test_lua_scope_order."""



    def test_required_mod_modules_resolve_from_the_entrypoint(self):
        sources=dict((_module(path),text) for path,text in _sources())
        self.assertIn("fs2rts",sources,"mission scripting entrypoint is missing")
        required=set()
        for text in sources.values():
            required.update(re.findall(r'require\s*\(?\s*[\"\'](fs2rts[^\"\']*)',text))
        self.assertTrue(required,"no module imports were inspected")
        self.assertEqual(required-set(sources),set(),"required mod modules are missing")

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
        self.assertTrue(checked,"no util stubs were inspected")
        self.assertEqual(problems, [], "\n  ".join(problems))


if __name__ == "__main__":
    unittest.main()
