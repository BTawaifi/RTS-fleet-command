"""Static check: flag a name READ that resolves to a nil global because its
`local` declaration comes too late.

Why this tool exists
--------------------
`tools/undefined_global_check.py` answers "is this name defined SOMEWHERE in
the file?". That is blind to ordering, and Lua's `local` is strictly
lexical-forward: `local X` is only visible from its own statement to the end
of the enclosing block. A name read above its own `local` declaration is not
in scope, so Lua raises no syntax error -- it falls through to a global
lookup, gets nil, and the crash surfaces wherever that code runs next. That
is exactly how this shipped:

    LUA ERROR: [string "fs2rts_hud.lua"]:914: attempt to index global
    'RETICLE_COLOR_SELECTED' (a nil value)
      [string "fs2rts_factions.lua"]:755: in function 'EachShip'
      [string "fs2rts_hud.lua"]:880: in function 'DrawTacticalMap'
      [string "fs2rts_hud.lua"]:1810: in function 'DrawHUD'

The declaration existed ~150 lines below the use, so a whole-file existence
check passed it, and so did 370 unit tests: the line only runs when a contact
is selected on a tactical map, and no harness drives that.

The distinction that makes a finding trustworthy
-----------------------------------------------
A read that falls out of scope is only a CRASH if the global it lands on is
nil. So a read is an error when it is out of scope AND the name is not a
global anything actually provides. Two lower-value shapes are reported
separately:

  out-of-scope-local  (error) the name is `local`-declared in this file, so
                                 the author meant a module-local, and it is
                                 not in scope here. Resolves to nil.
  unresolved-global   (error) no `local` anywhere and no known provider.
                                 Resolves to nil.
  shadowed-global     (info)  out of scope, but the name IS a real engine or
                                 mod global, so the read gets a value and
                                 nothing crashes. Still an inconsistency: the
                                 code reads the global while its neighbours
                                 read a local alias of it.

Run:  python core/tools/lua_scope_order_check.py [-q]
Exit: 0 clean, 1 when at least one error-level finding exists.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
SCRIPTS = TOOLS.parent / "data" / "scripts"

# Names the mod exports to other modules on purpose. Discovered automatically
# per file (see _file_globals); this is only the hand-written seed.
DECLARED_GLOBALS: set[str] = set()

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while",
}

# Operators that cannot begin a statement, so a NAME/keyword after a complete
# expression is a fresh statement rather than a continuation.
_OPERATORS = sorted(
    ["...", "..", "::", "==", "~=", "<=", ">=", "//",
     "+", "-", "*", "/", "%", "^", "#", "<", ">", "=",
     "(", ")", "{", "}", "[", "]", ";", ":", ",", "."],
    key=len, reverse=True)
_OPENERS = {"(", "{", "["}
_CLOSERS = {")", "}", "]"}
# After these, an expression is syntactically incomplete.
_CONTINUING = {"(", "{", "[", ",", ";", "+", "-", "*", "/", "%", "^", "..",
               "==", "~=", "<=", ">=", "and", "or"}
_VALUE_KEYWORDS = {"true", "false", "nil"}
_STATEMENT_STARTERS = {"local", "function", "if", "for", "while", "return",
                       "repeat", "do", "break", "goto"}


# Engine- and stdlib-provided globals.
#
# The engine half is GENERATED from the engine source by
# tools/gen_fso_lua_globals.py rather than hand-typed, because hand-typing is
# how `ai-fly-to` (an SEXP that does not exist) shipped in a release. If the
# engine moves, regenerate; the allowlist cannot silently drift.
#
# The stdlib half is written out because it comes from the Lua language, not
# from this engine.
LUA_STDLIB_GLOBALS = {
    "_G", "_VERSION", "self", "assert", "collectgarbage", "dofile", "error",
    "getfenv", "getmetatable", "ipairs", "load", "loadfile", "loadstring",
    "next", "pairs", "pcall", "print", "rawequal", "rawget", "rawlen",
    "rawset", "require", "select", "setfenv", "setmetatable", "tonumber",
    "tostring", "type", "unpack", "xpcall", "coroutine", "debug", "package",
    "string", "table", "math", "io", "os", "bit", "jit",
}

# Engine globals the generator's tree scan does not reach: the harness/UI
# convenience globals registered from freespace2/, the legacy (pre-ADE) script
# API surface, and the drawing primitives that predate the graphics library.
# Every name here is verified against the engine source; a name that only
# appears in this list and not in the generated set is a standing invitation to
# check it, which is why the test suite asserts none of them is load-bearing.
ENGINE_EXTRA_GLOBALS = {
    # legacy scripting API predating the ADE libraries
    "cmds", "gameevents", "jumps", "event", "battlescape", "endgame",
    "scripting", "script", "system", "userdoc", "screen", "hud", "music",
    "gfx", "FSO",
    # drawing / audio / input primitives from freespace2/
    "vec", "ang", "mat", "vm", "pc", "sp", "snd", "gn", "inf", "id", "list",
    "pof", "property",
    # gameplay clocks and limits
    "GameSettings", "PlayingTime", "GameTime", "MissionTime", "GameFrameCount",
    "ObjList", "Limits", "slowdownFactor", "Frametime", "savedGame0",
    "savedGame1", "statusMessages",
    # SCPUI / screen API
    "bindAltCnc", "bindKey", "enableButton", "disableButton", "setButtonText",
    "setButtonImage", "closeButton", "isVisible", "setWindowed",
    "getWindowed", "setResolution", "getResolution", "startScreen",
    "setBaseResolution", "getBaseResolution", "LuaScreen",
}

try:
    from fso_lua_globals_generated import FSO_LUA_GLOBALS as _GENERATED

    ENGINE_GLOBALS: set[str] = set(_GENERATED) | ENGINE_EXTRA_GLOBALS
except Exception as _exc:  # pragma: no cover - only if the list is missing
    ENGINE_GLOBALS = set(LUA_STDLIB_GLOBALS) | ENGINE_EXTRA_GLOBALS | {
        "ORDER_ATTACK", "ORDER_ATTACK_ANY", "ORDER_GUARD", "ORDER_STAY_STILL",
        "ORDER_WAYPOINTS_ONCE", "ORDER_DEPART", "ORDER_PLAY_DEAD",
    }


# --------------------------------------------------------------------------
# Tokenizer
# --------------------------------------------------------------------------
_NAME_START = re.compile(r"[A-Za-z_]")
_NAME_CHAR = re.compile(r"[A-Za-z0-9_]")
_NUMBER = re.compile(r"(?:0[xX][0-9a-fA-F]*|\d*\.?\d+(?:[eE][+-]?\d+)?)")
_LONG_OPEN = re.compile(r"\[(=*)\[")


@dataclass(frozen=True)
class Token:
    kind: str          # name | number | string | op
    value: str
    line: int
    col: int


def tokenize(text: str) -> list[Token]:
    """Lex Lua 5.1 source. Comments, short strings and long strings become
    single tokens so their contents can never be mistaken for code."""
    out: list[Token] = []
    i, line, n = 0, 1, len(text)

    def col_of(pos: int) -> int:
        return pos - text.rfind("\n", 0, pos)

    while i < n:
        ch = text[i]

        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch in " \t\r\f\v":
            i += 1
            continue

        # comments: -- ... and --[[ ... ]] / --[==[ ... ]==]
        if text.startswith("--", i):
            j = i + 2
            if j < n and text[j] == "[":
                m = _LONG_OPEN.match(text, j)
                if m:
                    close = "]" + m.group(1) + "]"
                    end = text.find(close, m.end())
                    if end < 0:
                        return out
                    line += text.count("\n", i, end + len(close))
                    i = end + len(close)
                    continue
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue

        # long strings [==[ ... ]==]
        if ch == "[":
            m = _LONG_OPEN.match(text, i)
            if m:
                close = "]" + m.group(1) + "]"
                end = text.find(close, m.end())
                if end < 0:
                    return out
                line += text.count("\n", i, end + len(close))
                out.append(Token("string", "", line, col_of(i)))
                i = end + len(close)
                continue

        # short strings, honouring escapes so a stray quote inside one cannot
        # shift every later token
        if ch in "\"'":
            quote = ch
            start, j = i, i + 1
            while j < n:
                c = text[j]
                if c == "\\":
                    if text.startswith("\\z", j):
                        j += 2
                        while j < n and text[j].isspace():
                            j += 1
                        continue
                    if text.startswith("\\x", j):
                        j += 2
                        while j < n and _NAME_CHAR.match(text[j]) and \
                                text[j] in "0123456789abcdefABCDEF":
                            j += 1
                        continue
                    if text.startswith("\\\n", j):
                        j += 2
                        line += 1
                        continue
                    j += 2
                    continue
                if c == "\n":
                    line += 1
                if c == quote:
                    j += 1
                    break
                j += 1
            out.append(Token("string", "", line, col_of(start)))
            i = j
            continue

        if ch.isdigit() or (ch == "." and i + 1 < n and text[i + 1].isdigit()):
            m = _NUMBER.match(text, i)
            out.append(Token("number", m.group(0), line, col_of(i)))
            i = m.end()
            continue

        if _NAME_START.match(ch):
            j = i + 1
            while j < n and _NAME_CHAR.match(text[j]):
                j += 1
            out.append(Token("name", text[i:j], line, col_of(i)))
            i = j
            continue

        for op in _OPERATORS:
            if text.startswith(op, i):
                out.append(Token("op", op, line, col_of(i)))
                i += len(op)
                break
        else:
            i += 1

    return out


def _ends_expression(t: Token | None) -> bool:
    if t is None:
        return False
    if t.kind in ("name", "number", "string"):
        return t.value not in KEYWORDS or t.value in _VALUE_KEYWORDS
    return t.value in _CLOSERS


def _scan_statement(tokens: list[Token], start: int) -> int:
    """Index just past the end of the statement beginning at `start`.

    Ends at a hard terminator (`;`, `end`, `else`, `elseif`, `until`,
    `then`), or when a complete expression is followed by something that can
    only begin a new statement, or at a newline boundary that the previous
    token cannot legally continue across."""
    i, n, depth = start, len(tokens), 0
    while i < n:
        t = tokens[i]
        if depth == 0 and t.kind == "op":
            if t.value in (";", "end", "else", "elseif", "until", "then"):
                break
        if depth == 0 and t.kind == "name":
            if t.value in _STATEMENT_STARTERS and _ends_expression(tokens[i - 1]):
                break
            nxt = tokens[i + 1] if i + 1 < n else None
            if _ends_expression(tokens[i - 1]) and nxt is not None \
                    and nxt.kind == "op" and nxt.value == "=" \
                    and not (i + 2 < n and tokens[i + 2].kind == "op"
                             and tokens[i + 2].value == "="):
                break  # NAME = ...  is a fresh assignment statement
            if (_ends_expression(tokens[i - 1]) and nxt is not None
                    and nxt.kind == "op" and nxt.value in (".", ":", "(", "[")):
                # `f(a)\n  RTS.Bar()` -- Lua allows these, but a NAME opening a
                # new line after a complete expression is a new statement in
                # every style this codebase uses. Only break when the previous
                # token actually ended its line, so a genuine wrapped
                # continuation is not cut in half.
                prev = tokens[i - 1]
                if prev.line < t.line:
                    break
        if t.kind == "op":
            if t.value in _OPENERS:
                depth += 1
            elif t.value in _CLOSERS:
                depth -= 1
        i += 1
    return i


# --------------------------------------------------------------------------
# Findings
# --------------------------------------------------------------------------
@dataclass
class Finding:
    path: str
    line: int
    col: int
    name: str
    kind: str
    detail: str
    level: str = "error"

    def format(self) -> str:
        return (f"{self.path}:{self.line}:{self.col}: {self.level}: {self.kind}: "
                f"{self.name} -- {self.detail}")


@dataclass
class _Frame:
    """One Lua block. `names` maps a name to the line of its `local`."""
    kind: str
    line: int
    names: dict = field(default_factory=dict)


def _module_globals(tokens: list[Token]) -> set[str]:
    """Names this file assigns at module scope WITHOUT `local`.

    `function Foo() end` and `Foo = ...` both write a global, and Lua resolves
    the target of `function Foo() end` with the same scope rule as a read, so
    one written near the bottom of a file legitimately makes the name defined
    from the top. Discovering these automatically is what lets a mod's own
    cross-module globals stay off the findings list without being hardcoded."""
    names: set[str] = set()
    depth = 0
    prev_is_local = False
    for idx, t in enumerate(tokens):
        if t.kind == "op":
            if t.value in _OPENERS:
                depth += 1
            elif t.value in _CLOSERS:
                depth -= 1
            prev_is_local = False
            continue
        if t.kind != "name":
            continue
        if depth != 0:
            prev_is_local = False
            continue
        if t.value == "local":
            prev_is_local = True
            continue
        if prev_is_local:
            # The names of a `local` declaration are NOT globals. Skipping them
            # is what stops every file-scope constant from being recorded as a
            # real global, which would in turn hide the very use-before-declare
            # defect this tool exists to find.
            prev_is_local = False
            continue
        if t.value == "function":
            nxt = tokens[idx + 1] if idx + 1 < len(tokens) else None
            after = tokens[idx + 2] if idx + 2 < len(tokens) else None
            if (nxt is not None and nxt.kind == "name"
                    and nxt.value not in KEYWORDS
                    and (after is None
                         or not (after.kind == "op"
                                 and after.value in (".", ":")))):
                names.add(nxt.value)
            prev_is_local = False
            continue
        prev_is_local = False
        if t.value in KEYWORDS:
            continue
        nxt = tokens[idx + 1] if idx + 1 < len(tokens) else None
        if nxt is not None and nxt.kind == "op" and nxt.value == "=":
            if not (idx + 2 < len(tokens) and tokens[idx + 2].kind == "op"
                    and tokens[idx + 2].value == "="):
                names.add(t.value)
    return names


def _collect_local_decls(tokens: list[Token]) -> dict[str, list[int]]:
    """Every name introduced by `local` in the file, with its line.

    A first pass is what makes a FORWARD reference detectable at all: while
    walking forward the walk has not reached the declaration yet, so consulting
    only locals seen so far would report every use-before-declaration as an
    unresolved global with no mention of the real declaration."""
    decls: dict[str, list[int]] = {}
    i, n = 0, len(tokens)
    while i < n:
        t = tokens[i]
        if t.kind == "op":
            i += 1
            continue
        if t.kind != "name" or t.value != "local":
            i += 1
            continue
        j = i + 1
        if j < n and tokens[j].kind == "name" and tokens[j].value == "function":
            # `local function f()` -- the name is the token after `function`
            k = j + 1
            if k < n and tokens[k].kind == "name":
                decls.setdefault(tokens[k].value, []).append(t.line)
            i = j
            continue
        while j < n and tokens[j].kind == "name" and tokens[j].value not in KEYWORDS:
            decls.setdefault(tokens[j].value, []).append(t.line)
            j += 1
            if j < n and tokens[j].kind == "op" and tokens[j].value == ",":
                j += 1
                continue
            break
        i = max(j, i + 1)
    return decls


def analyze(text: str, path_name: str = "<memory>",
            extra_globals: set[str] | None = None) -> list[Finding]:
    """Walk one Lua file in order, tracking when each `local` becomes visible."""
    tokens = tokenize(text)
    provided = ENGINE_GLOBALS | LUA_STDLIB_GLOBALS | DECLARED_GLOBALS \
        | _module_globals(tokens)
    if extra_globals:
        provided |= extra_globals
    all_locals = _collect_local_decls(tokens)

    frames: list[_Frame] = [_Frame("file", 0)]
    findings: list[Finding] = []
    pending_for: list[str] = []

    def push(block: str, line: int, names: dict | None = None) -> None:
        fr = _Frame(block, line)
        if names:
            fr.names.update(names)
        frames.append(fr)

    def drop() -> None:
        if len(frames) > 1:
            frames.pop()

    def read_at(idx: int) -> None:
        t = tokens[idx]
        if t.kind != "name" or t.value in KEYWORDS:
            return
        name = t.value
        p = tokens[idx - 1] if idx > 0 else None
        if p is not None and p.kind == "op" and p.value in (".", ":"):
            return                                   # a field, not a variable
        q = tokens[idx + 1] if idx + 1 < len(tokens) else None
        if q is not None and q.kind == "op" and q.value == "=":
            r = tokens[idx + 2] if idx + 2 < len(tokens) else None
            if r is None or not (r.kind == "op" and r.value == "="):
                return                                # assignment target
        if any(name in f.names for f in frames):
            return

        lines = all_locals.get(name)
        if lines:
            later = sorted(x for x in lines if x >= t.line)
            if later:
                detail = (f"`local` is declared at line {later[0]}, but this "
                          f"read is at line {t.line}: Lua local scope starts at "
                          f"the declaration, so this resolves to a nil global")
            else:
                detail = (f"`local` is declared at line {min(lines)} in a block "
                          f"that does not enclose this read at line {t.line}")
            if name in provided:
                # The read lands on a real global, so it does not crash -- but
                # the file shadows that name with a local elsewhere, which is
                # exactly the shape that turns into a nil dereference the day
                # the local is deleted or the engine drops the global.
                findings.append(Finding(
                    path_name, t.line, t.col, name, "shadowed-global",
                    f"declared `local {name}` in this file at line(s) "
                    f"{sorted(set(lines))} but read here at line {t.line}, "
                    f"outside that scope; resolves to the real global "
                    f"`{name}` so nothing crashes today",
                    level="info"))
            else:
                findings.append(Finding(
                    path_name, t.line, t.col, name, "out-of-scope-local",
                    detail + ", which does not exist -> nil global"))
            return
        if name in provided:
            return
        findings.append(Finding(
            path_name, t.line, t.col, name, "unresolved-global",
            "not a `local` in scope and not a global anything provides; Lua "
            "reads nil"))

    i, n = 0, len(tokens)
    while i < n:
        t = tokens[i]

        if t.kind == "name" and t.value == "function":
            j = i + 1
            is_method = False
            first: Token | None = None
            if j < n and tokens[j].kind == "name" and tokens[j].value not in KEYWORDS:
                first = tokens[j]
                j += 1
                while j + 1 < n and tokens[j].kind == "op" \
                        and tokens[j].value in (".", ":") \
                        and tokens[j + 1].kind == "name":
                    is_method = is_method or tokens[j].value == ":"
                    j += 2
            params: dict[str, int] = {}
            if is_method:
                params["self"] = t.line
            if j < n and tokens[j].kind == "op" and tokens[j].value == "(":
                k = j + 1
                while k < n:
                    p = tokens[k]
                    if p.kind == "op" and p.value == ")":
                        break
                    if p.kind == "name" and p.value not in KEYWORDS:
                        params[p.value] = t.line
                    k += 1
            # `local function f()` binds f in the ENCLOSING block, not just in
            # the function's own body. Missing this makes every later call to a
            # file-local helper look like an out-of-scope read.
            if first is not None and not is_method and i > 0 \
                    and tokens[i - 1].kind == "name" and tokens[i - 1].value == "local":
                enclosing = frames[-1]
                enclosing.names.setdefault(first.value, tokens[i - 1].line)
            push("func", t.line, params)
            i = j
            continue

        if t.kind == "name" and t.value == "local":
            j = i + 1
            if j < n and tokens[j].kind == "name" and tokens[j].value == "function":
                i = j
                continue
            names: dict[str, int] = {}
            while j < n and tokens[j].kind == "name" and tokens[j].value not in KEYWORDS:
                names[tokens[j].value] = t.line
                j += 1
                if j < n and tokens[j].kind == "op" and tokens[j].value == ",":
                    j += 1
                    continue
                break
            end = _scan_statement(tokens, j) if j < n and tokens[j].kind == "op" \
                and tokens[j].value == "=" else j
            frames[-1].names.update(names)
            i = end
            continue

        if t.kind == "name" and t.value == "for":
            j = i + 1
            loop: list[str] = []
            while j < n and tokens[j].kind == "name":
                loop.append(tokens[j].value)
                j += 1
                if j < n and tokens[j].kind == "op" and tokens[j].value == ",":
                    j += 1
                    continue
                break
            pending_for = loop
            i = j
            continue

        if t.kind == "name" and t.value == "do":
            push("block", t.line, {nm: t.line for nm in pending_for})
            pending_for = []
            i += 1
            continue
        if t.kind == "name" and t.value == "then":
            push("block", t.line)
            i += 1
            continue
        if t.kind == "name" and t.value == "repeat":
            push("block", t.line)
            i += 1
            continue
        if t.kind == "name" and t.value in ("else", "elseif"):
            drop()
            if t.value == "else":
                push("block", t.line)
                i += 1
                continue
            # the elseif condition is evaluated in the ENCLOSING scope
            i += 1
            while i < n and not (tokens[i].kind == "name"
                                 and tokens[i].value == "then"):
                read_at(i)
                i += 1
            if i < n:
                push("block", tokens[i].line)
                i += 1
            continue
        if t.kind == "name" and t.value == "until":
            i += 1
            while i < n and not (tokens[i].kind == "name"
                                 and tokens[i].value == "end"):
                read_at(i)
                i += 1
            drop()
            continue
        if t.kind == "name" and t.value == "end":
            drop()
            i += 1
            continue

        read_at(i)
        i += 1

    return findings


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------
def syntax_imbalance(text: str, path_name: str) -> list[Finding]:
    """Report a file whose block openers and closers do not balance.

    A file that does not parse is not a subtle crash: the whole mod fails to
    load. But it is worth checking here rather than only in a test, because a
    scope walk running over a file whose `end`s do not match judges every read
    against the WRONG frame -- so an unbalanced file can hide a real
    use-before-declaration behind a flood of nonsense."""
    findings: list[Finding] = []
    depth = 0
    for t in tokenize(text):
        if t.kind != "name":
            continue
        if t.value in ("function", "if", "do", "repeat"):
            depth += 1
        elif t.value in ("until", "end"):
            depth -= 1
            if depth < 0:
                findings.append(Finding(
                    path_name, t.line, t.col, "<block>",
                    "syntax-imbalance",
                    f"`{t.value}` with no open block; this file does not parse "
                    f"as Lua, so every scope decision below this line is made "
                    f"against the wrong frame"))
                return findings
    if depth != 0:
        findings.append(Finding(
            path_name, 1, 1, "<block>", "syntax-imbalance",
            f"{depth} block(s) left open at end of file; this file does not "
            f"parse as Lua, so the scope walk is desynchronised"))
    return findings


def analyze_file(path: Path) -> list[Finding]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return syntax_imbalance(text, path.name) + analyze(text, path.name)


def check(scripts_dir: Path | str | None = None,
          include_info: bool = True) -> list[Finding]:
    root = Path(scripts_dir) if scripts_dir else SCRIPTS
    out: list[Finding] = []
    for path in sorted(root.glob("*.lua")):
        out.extend(analyze_file(path))
    if not include_info:
        out = [f for f in out if f.level == "error"]
    return out


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    quiet = "-q" in argv
    findings = check()
    errors = [f for f in findings if f.level == "error"]
    infos = [f for f in findings if f.level == "info"]
    if not errors:
        print("OK: every read resolves to an in-scope local or a real global, "
              "and every script's blocks balance.")
    else:
        print(f"{len(errors)} blocking finding(s):\n")
        for f in errors:
            print(f"  {f.format()}")
        print("\nFor out-of-scope reads, hoist the `local` above its first use. "
              "A whole-file existence check cannot see these: the name IS "
              "assigned, just too late.")
    if infos and not quiet:
        print(f"\n{len(infos)} info -- reads that fall back to a real global "
              f"(no crash, but inconsistent):")
        for f in infos:
            print(f"  {f.format()}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
