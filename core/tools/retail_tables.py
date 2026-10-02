"""Read `$Name:` entries out of retail and mod table files.

Two facts about this project can only be established against a real table, and
both were invisible until they were expensive:

1. `+nocreate` means "patch this weapon IF it already exists". A NEW `$Name:`
   carrying `+nocreate` is discarded wholesale by the engine
   (code/weapon/weapons.cpp, create_if_not_found=false then an early return
   that skips to the next $Name:/#End). The four sentry weapons shipped exactly
   that way, so none of them existed in game and every sentry kept its stock
   loadout. Nothing in the mod noticed, because an unknown weapon name resolves
   to an INVALID HANDLE rather than nil
   (code/scripting/api/libs/tables.cpp), so a `== nil` guard cannot fire.
2. A `class = "..."` that no table defines is an invalid handle too. `GVSG
   Sotar` and `GVSG Sekhem` were listed as Gold's tier 3 and tier 4 sentry
   platforms and exist in no table at all, so those slots could never spawn.

Neither is checkable from the mod alone: a name is only wrong relative to what
already exists, which means retail. The retail tables are extracted from
root_fs2.vp; copies live beside this module's parent tree in
D:/Games/FreespaceOpen/tools/. Point RETAIL_SHIPS_TBL / RETAIL_WEAPONS_TBL (or
the matching environment variables) elsewhere if they move.

Retail tables are OPTIONAL. Without them the shipped-weapon rule cannot be
evaluated - a name may legitimately exist in retail - so the callers skip
rather than assert something they cannot know. The ship-class rule can still be
evaluated partially, because mod-defined hulls are resolvable without retail,
so it runs without retail and reports which hulls it could not verify.
"""
import os
import re
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
MOD_ROOT = TOOLS.parent
TABLES = MOD_ROOT / "data" / "tables"

_NAME = re.compile(r"^[ \t]*\$Name:[ \t]*(?P<name>.+?)[ \t]*$", re.MULTILINE)
_NOCREATE = re.compile(r"^[ \t]*\+nocreate\b", re.MULTILINE)
_ENTRY_SPLIT = re.compile(r"^\s*\$Name:.*?(?=^\s*\$Name:|\Z)",
                          re.MULTILINE | re.DOTALL)


def _first_existing(*candidates):
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    return None


def _retail_candidates(filename, override):
    """Env override first, then `tools/<filename>` at any level above us.

    The layout is <install>/tools/next to <install>/FS2/<mod>/core/tools, so a
    fixed relative depth is wrong the moment anyone moves the mod or installs
    it elsewhere. Walking up a few levels finds it regardless, and guessing a
    depth is how this returned None while the file sat two levels up.
    """
    seen = []
    if override:
        seen.append(override)
    base = TOOLS
    for _ in range(6):
        base = base.parent
        seen.append(base / "tools" / filename)
    return _first_existing(*seen)


def retail_weapons_table():
    """Path to a retail weapons.tbl, or None if none is available."""
    return _retail_candidates("weapons.tbl",
                              os.environ.get("RETAIL_WEAPONS_TBL"))


def retail_ships_table():
    """Path to a retail ships.tbl, or None if none is available."""
    return _retail_candidates("ships.tbl",
                              os.environ.get("RETAIL_SHIPS_TBL"))


def parse_names(text):
    """Every `$Name:` value in a table file.

    Trailing `;` comments are stripped, because retail writes some names as
    `$Name: @Akheton SDG\t\t;;      the anti-subsystem weapon` and a name that
    carries its own comment along can never match anything.
    """
    names = set()
    for match in _NAME.finditer(text):
        value = match.group("name").split(";", 1)[0].strip()
        if value:
            names.add(value)
    return names


def parse_nocreate_names(text):
    """Names whose entry carries `+nocreate`, i.e. patch-only declarations.

    Split on `$Name:` boundaries rather than scanning for the flag globally, so
    a `+nocreate` on one weapon cannot be attributed to another.
    """
    out = set()
    for block in _ENTRY_SPLIT.findall(text):
        name = _NAME.search(block)
        if name and _NOCREATE.search(block):
            out.add(name.group("name").strip())
    return out


def read(path):
    return Path(path).read_text(encoding="utf-8", errors="replace")


def mod_table_files(suffix=".tbm"):
    if not TABLES.is_dir():
        return []
    return sorted(TABLES.glob(f"*{suffix}"))


def mod_defined_names():
    """Every `$Name:` declared anywhere in the mod's own tables."""
    names = set()
    for path in mod_table_files():
        names |= parse_names(read(path))
    return names


def mod_nocreate_declarations():
    """{weapon_name: [files declaring it with +nocreate]} across mod tables."""
    out = {}
    for path in mod_table_files():
        for name in parse_nocreate_names(read(path)):
            out.setdefault(name, []).append(path.name)
    return out


def retail_beam_names():
    """Retail weapons the engine treats as beams.

    Two markers only: a `$BeamInfo:` block, or "beam" in `$Flags`. Those are
    the engine's own signals and they select 21 retail weapons.

    `@Laser Bitmap` was tried as a third marker and is wrong: it selects
    ordinary PROJECTILES drawn as lasers (Shivan Light Laser, Vasudan Light
    Laser, the Turret Laser family), which are not beams and do not need the
    base multiplier. It inflates the set to 49 and would have forced real
    beam-only weapons into the allowlist. MjolnirBeam is in the correct 21 -
    it was missed earlier only because a probe compared it case-sensitively.
    """
    path = retail_weapons_table()
    if path is None:
        return None
    beams = set()
    for block in _ENTRY_SPLIT.findall(read(path)):
        name = _NAME.search(block)
        if not name:
            continue
        value = name.group("name").split(";", 1)[0].strip()
        lowered = block.lower()
        if value and ("$beaminfo:" in lowered or '"beam"' in lowered):
            beams.add(value)
    return beams