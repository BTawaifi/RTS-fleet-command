"""Static check: flag bare global function calls that no module defines and FSO
does not provide.

A missing name in a released mod is not a Lua error you notice in play. FSO
aborts the process with an uncatchable C++ exception when a scripting call
resolves to an undefined global, so the crash has no Lua stack and no log line.
This catches that class of bug before the engine ever runs.

Run: python tools/undefined_global_check.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "data" / "scripts"

# Names FSO actually exposes to mission Lua. This list is deliberately short and
# was verified against the engine source: a name listed here that the engine does
# not register hides exactly the bug this tool exists to catch (an undefined
# scripting global aborts the process with an uncatchable C++ exception and
# leaves no Lua stack or log line). Everything else must be a module local.
FSO_GLOBALS = {
    # Lua standard library
    "abs", "assert", "collectgarbage", "dofile", "error", "getfenv", "getmetatable",
    "ipairs", "load", "loadfile", "loadstring", "next", "pairs", "pcall", "print",
    "rawequal", "rawget", "rawlen", "rawset", "require", "select", "setfenv",
    "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall",
    "math", "string", "table", "os", "coroutine", "debug", "bit", "jit",
    # FSO scripting namespaces
    "vec", "vm", "mat", "ang", "color", "mn", "ba", "cf", "ad", "gr", "io",
    "font", "gn", "sp", "snd", "hud", "pc", "inf", "ship", "player", "mission",
    "id", "list", "pof", "ai", "event", "gamestate", "scripting", "sound",
    "battlescape", "system", "userdoc", "screen", "help", "script", "endgame",
    "cmds", "gameevents", "jumps", "control", "music", "gfx",
    # Verified against the engine source
    "pauseMusic", "resumeMusic", "restartMusic", "resetMusic", "getIndex",
    "setOverride", "setVolume", "lockViewport", "unlockViewport",
    "pushMatrix", "popMatrix", "table", "computeSpline", "drawSpline",
}

# FSO's own helper modules export these; they are re-exported as locals but a
# module may also legitimately reach for them by name after a local binding.
LOCAL_DECL = re.compile(
    r"^\s*local\s+(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)"
    r"|^\s*local\s+[^=]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*=",
    re.MULTILINE,
)
MULTI_LOCAL = re.compile(r"^\s*local\s+([A-Za-z_][\w,\s]*)\s*=", re.MULTILINE)
# Identifier start must allow uppercase: this codebase is full of camelCase
# helpers, and a lowercase-only class silently truncates "shipValid" to "alid",
# which hides exactly the bug this tool exists to find.
CALL = re.compile(r"(?<![\w.:])([A-Za-z_][A-Za-z0-9_]{2,})\s*\(")
ASSIGNED_LOCAL = re.compile(r"^\s*local\s+([^=]+)=", re.MULTILINE)

# "and (x)", "not (x)", "return (x)" are Lua syntax, not calls.
LUA_KEYWORDS = {
    "and", "or", "not", "function", "return", "end", "then", "elseif", "else",
    "while", "until", "repeat", "break", "goto", "do",
}


def declared_names(text: str) -> set[str]:
    names: set[str] = set()
    for match in LOCAL_DECL.finditer(text):
        name = match.group(1) or match.group(2)
        if name:
            names.add(name)
    for match in MULTI_LOCAL.finditer(text):
        for part in match.group(1).split(","):
            part = part.strip()
            if part and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", part):
                names.add(part)
    for match in ASSIGNED_LOCAL.finditer(text):
        for part in match.group(1).split(","):
            part = part.strip()
            if part and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", part):
                names.add(part)
    # This codebase packs several declarations onto one line
    # ("local role=...; local shape=..."), so line-anchored matching misses them.
    for match in re.finditer(r"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\s*=", text):
        names.add(match.group(1))
    # function parameters and for-loop variables
    for match in re.finditer(r"function\s*[^\n(]*\(([^)]*)\)", text):
        for part in match.group(1).split(","):
            part = part.strip()
            if part and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", part):
                names.add(part)
    for match in re.finditer(r"for\s+([A-Za-z_][\w,\s]*)\s+in\s", text):
        for part in match.group(1).split(","):
            part = part.strip()
            if part:
                names.add(part)
    # names that are table fields assigned from locals, e.g. local X = {...}
    for match in re.finditer(r"\bself\.([A-Za-z_][A-Za-z0-9_]*)\s*=", text):
        names.add(match.group(1))
    return names


def main() -> int:
    problems = []
    for path in sorted(SCRIPTS.rglob("*.lua")):
        text = path.read_text(encoding="utf-8", errors="replace")
        known = declared_names(text) | FSO_GLOBALS
        # strip string literals and comments so prose does not count as calls
        stripped = re.sub(r"--\[\[.*?\]\]", " ", text, flags=re.DOTALL)
        stripped = re.sub(r"--[^\n]*", " ", stripped)
        stripped = re.sub(r"'(\\.|[^'\\])*'", "''", stripped)
        stripped = re.sub(r'"(\\.|[^"\\])*"', '""', stripped)
        for match in CALL.finditer(stripped):
            name = match.group(1)
            if name in known or name in LUA_KEYWORDS:
                continue
            line = stripped[: match.start()].count("\n") + 1
            problems.append((path.name, line, name))
    if not problems:
        print("OK: every bare global call is either a module local or a real FSO global.")
        return 0
    print(f"{len(problems)} possibly-undefined global call(s):")
    seen = set()
    for filename, line, name in problems:
        key = (filename, name)
        if key in seen:
            continue
        seen.add(key)
        print(f"  {filename}:{line}  {name}()")
    return 1


if __name__ == "__main__":
    sys.exit(main())
