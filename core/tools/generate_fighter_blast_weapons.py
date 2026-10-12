"""Generate fighter-only weapon variants from the installed retail tables.

Scope is stock fighter primary/secondary banks plus bundled FSPort fighter
defaults in fs2rts-fs1-ships-shp.tbm. Unknown third-party bank choices and
beam classes are deliberately not cloned or remapped.
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path

import retail_tables


ROOT = Path(__file__).resolve().parents[1]
TABLES = ROOT / "data" / "tables"
FSPORT_FIGHTERS = TABLES / "fs2rts-fs1-ships-shp.tbm"
OUTPUT = TABLES / "fs2rts-fighter-blast-wep.tbm"
FIGHTER_DAMAGE_TYPE = "RTS Fighter Weapons"
VARIANT_PREFIX = "RTSF "

_ENTRY = re.compile(r"(?ms)^[ \t]*\$Name:.*?(?=^[ \t]*\$Name:|\Z)")
_NAME = re.compile(r"(?m)^[ \t]*\$Name:[ \t]*(?P<name>[^\r\n;]+)")
_BANK_FIELD = re.compile(
    r"(?m)^[ \t]*\$(?:Allowed|Default)(?: Dogfight)? (?P<bank>[PS])Banks:[ \t]*"
)
_WEAPON_SECTION = re.compile(r"(?m)^#(?P<section>Primary Weapons|Secondary Weapons|Beam Weapons)\s*$", re.IGNORECASE)
_FLAGS_FIELD = re.compile(r"(?ms)^[ \t]*\$Flags:[ \t]*\((?P<items>.*?)\)")
_QUOTED = re.compile(r'"(?P<name>[^"]+)"')
_SPAWN_REF = re.compile(r'"Spawn[ \t]+(?P<name>[^,\"]+),[ \t]*\d+"', re.IGNORECASE)


@dataclass(frozen=True)
class Variant:
    source_name: str
    variant_name: str
    source_entry: str
    weapon_section: str
    fighter_sources: tuple[str, ...]
    spawn_children: tuple[str, ...]


def _canonical_name(value: str) -> str:
    name = value.split(";", 1)[0].strip()
    return name[1:] if name.startswith("@") else name


def named_entries(text: str) -> dict[str, str]:
    entries = {}
    for match in _ENTRY.finditer(text):
        block = match.group(0).rstrip()
        name_match = _NAME.search(block)
        if name_match:
            entries[_canonical_name(name_match.group("name"))] = block
    return entries


def spawn_children(block: str) -> tuple[str, ...]:
    flags = _FLAGS_FIELD.search(block)
    if not flags:
        return ()
    return tuple(sorted({_canonical_name(m.group("name")) for m in _SPAWN_REF.finditer(flags.group("items"))}))


def _fighter_bank_sources(text: str) -> dict[str, set[tuple[str, str]]]:
    sources: dict[str, set[tuple[str, str]]] = {}
    for ship_name, block in named_entries(text).items():
        flags = _FLAGS_FIELD.search(block)
        if not flags:
            continue
        flag_text = flags.group("items").lower()
        if '"fighter"' not in flag_text or '"bomber"' in flag_text:
            continue
        for bank_list in _BANK_FIELD.finditer(block):
            bank_kind = "primary" if bank_list.group("bank").upper() == "P" else "secondary"
            # Upstream accepts consecutive per-bank lists, including multiline lists.
            tail = block[bank_list.end():]
            tail = re.sub(r'(?m);[^\r\n]*', '', tail)
            lists = re.match(r'\s*(?:\([^)]*\)\s*)+', tail)
            if lists is None:
                raise ValueError(f"Malformed weapon banks for {ship_name}")
            for name in _QUOTED.findall(lists.group(0)):
                sources.setdefault(_canonical_name(name), set()).add((ship_name, bank_kind))
    return sources


def weapon_sections(text: str) -> dict[str, str]:
    """Map classes to the native table section that owns their parser."""
    sections = {}
    markers = list(_WEAPON_SECTION.finditer(text))
    for entry in _ENTRY.finditer(text):
        name = _NAME.search(entry.group(0))
        if not name:
            continue
        section = None
        for marker in markers:
            if marker.start() > entry.start():
                break
            section = marker.group("section").lower()
        if section:
            sections[_canonical_name(name.group("name"))] = section
    return sections


def _patch_fields(name: str, patch_files: list[Path]) -> tuple[str | None, list[str]]:
    main_type = None
    unsupported = []
    for path in patch_files:
        for patch_name, block in named_entries(path.read_text(encoding="utf-8", errors="replace")).items():
            if patch_name != name or not re.search(r"(?m)^[ \t]*\+nocreate\b", block):
                continue
            for line in block.splitlines():
                stripped = line.strip()
                if not stripped or stripped.startswith(";") or stripped == "+nocreate":
                    continue
                if stripped.startswith("$Name:") or stripped.startswith("$Dinky shockwave:"):
                    continue
                if stripped.startswith("$Damage Type:"):
                    main_type = stripped.split(":", 1)[1].strip()
                    continue
                if stripped.startswith("$Shockwave damage type:") or stripped.startswith("+Shockwave damage type:"):
                    continue
                if stripped.startswith(("$", "+")):
                    unsupported.append(f"{path.name}:{name}:{stripped}")
    return main_type, unsupported


def source_inventory() -> tuple[list[Variant], tuple[str, ...]]:
    ships_path = retail_tables.retail_ships_table()
    weapons_path = retail_tables.retail_weapons_table()
    if ships_path is None or weapons_path is None:
        raise FileNotFoundError(
            "Retail ships.tbl and weapons.tbl are required. Set RETAIL_SHIPS_TBL and "
            "RETAIL_WEAPONS_TBL or place them under the install tools directory."
        )
    if not FSPORT_FIGHTERS.is_file():
        raise FileNotFoundError(f"Bundled FSPort fighter table is missing: {FSPORT_FIGHTERS}")

    fighter_sources = _fighter_bank_sources(ships_path.read_text(encoding="utf-8", errors="replace"))
    for name, sources in _fighter_bank_sources(FSPORT_FIGHTERS.read_text(encoding="utf-8", errors="replace")).items():
        fighter_sources.setdefault(name, set()).update(sources)

    patch_files = sorted(TABLES.glob("*-wep.tbm"))
    weapon_text = weapons_path.read_text(encoding="utf-8", errors="replace")
    weapon_entries = named_entries(weapon_text)
    weapon_section_by_name = weapon_sections(weapon_text)
    for path in patch_files:
        patch_text = path.read_text(encoding="utf-8", errors="replace")
        patch_entries = named_entries(patch_text)
        patch_sections = weapon_sections(patch_text)
        for name, block in patch_entries.items():
            if name not in weapon_entries and not re.search(r"(?m)^[ \t]*\+nocreate\b", block):
                weapon_entries[name] = block
                if name in patch_sections:
                    weapon_section_by_name[name] = patch_sections[name]

    unknown = set()
    candidates: set[str] = set()
    pending = list(sorted(fighter_sources))
    seen = set()
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        block = weapon_entries.get(name)
        if block is None:
            unknown.add(name)
            continue
        children = spawn_children(block)
        section = weapon_section_by_name.get(name)
        if section == "beam weapons":
            unknown.add("beam:" + name)
        elif section in ("primary weapons", "secondary weapons"):
            candidates.add(name)
        else:
            unknown.add("section:" + name)
        pending.extend(child for child in children if child not in seen)

    variants = []
    for source_name in sorted(candidates):
        block = weapon_entries.get(source_name)
        if block is None:
            raise AssertionError(f"variant source disappeared: {source_name}")
        _, unsupported = _patch_fields(source_name, patch_files)
        if unsupported:
            raise ValueError(
                f"Cannot clone {source_name}: source patches contain fields this generator does not copy: "
                + "; ".join(unsupported)
            )
        variants.append(Variant(
            source_name=source_name,
            variant_name=VARIANT_PREFIX + source_name,
            source_entry=block,
            weapon_section=weapon_section_by_name[source_name],
            fighter_sources=tuple(sorted(ship for ship, _ in fighter_sources.get(source_name, set()))),
            spawn_children=spawn_children(block),
        ))
    return variants, tuple(sorted(unknown))


def has_shockwave_fields(block: str) -> bool:
    return re.search(
        r"(?m)^[ \t]*(?:\$Shockwave damage(?: type)?:|\$Blast Force:|\$Inner Radius:|\$Outer Radius:|\$Shockwave Speed:)",
        block,
    ) is not None


def _rename_entry(block: str, name: str, children: tuple[str, ...], main_type: str) -> str:
    renamed = _NAME.sub(lambda m: m.group(0).split(":", 1)[0] + ": " + name + " ", block, count=1)
    if main_type is not None:
        if re.search(r"(?m)^[ \t]*\$Damage Type:", renamed):
            renamed = re.sub(r"(?m)^([ \t]*\$Damage Type:)[^\r\n]*", rf"\1 {main_type}", renamed, count=1)
        else:
            damage = re.search(r"(?m)^[ \t]*\$Damage:[^\r\n]*\r?\n", renamed)
            if damage is None:
                raise ValueError(f"cannot preserve patched main damage type for {name}: no $Damage field")
            renamed = renamed[:damage.end()] + f"$Damage Type: {main_type}\n" + renamed[damage.end():]
    for child in children:
        renamed = re.sub(
            r'("Spawn[ \t]+)' + re.escape(child) + r'(,[ \t]*\d+")',
            lambda m: m.group(1) + VARIANT_PREFIX + child + m.group(2),
            renamed,
            flags=re.IGNORECASE,
        )
    if has_shockwave_fields(block):
        # Keep fields inside the parser's ordered shockwave sequence. FSO parses
        # these before armor/subsystem fields; tail-appended values are invalid.
        shockwave_type = f"$Shockwave damage type: {FIGHTER_DAMAGE_TYPE}"
        if re.search(r"(?m)^[ \t]*\$Shockwave damage type:", renamed):
            renamed = re.sub(r"(?m)^([ \t]*\$Shockwave damage type:)[^\r\n]*", rf"\1 {FIGHTER_DAMAGE_TYPE}", renamed, count=1)
        else:
            anchor = re.search(r"(?m)^[ \t]*\$Shockwave damage:[^\r\n]*\r?\n", renamed)
            if anchor is None:
                anchor = re.search(r"(?m)^[ \t]*\$Blast Force:", renamed)
                if anchor is None:
                    raise ValueError(f"cannot place shockwave type in {name}: no shockwave or blast field")
                renamed = renamed[:anchor.start()] + shockwave_type + "\n" + renamed[anchor.start():]
            else:
                renamed = renamed[:anchor.end()] + shockwave_type + "\n" + renamed[anchor.end():]
        dinky_type = f"+Shockwave damage type: {FIGHTER_DAMAGE_TYPE}"
        dinky = re.search(r"(?m)^[ \t]*\$Dinky shockwave:[^\r\n]*\r?\n", renamed)
        if dinky:
            tail_start = dinky.end()
            armor = re.search(r"(?m)^[ \t]*\$Armor Factor:", renamed[tail_start:])
            tail_end = tail_start + (armor.start() if armor else len(renamed) - tail_start)
            tail = renamed[tail_start:tail_end]
            if re.search(r"(?m)^[ \t]*\+Shockwave damage type:", tail):
                tail = re.sub(r"(?m)^([ \t]*\+Shockwave damage type:)[^\r\n]*", rf"\1 {FIGHTER_DAMAGE_TYPE}", tail, count=1)
            else:
                tail = dinky_type + "\n" + tail
            renamed = renamed[:tail_start] + tail + renamed[tail_end:]
        else:
            armor = re.search(r"(?m)^[ \t]*\$Armor Factor:", renamed)
            if armor is None:
                armor = re.search(r"(?m)^[ \t]*\$Lifetime(?: Min| Max)?:", renamed)
            if armor is None:
                raise ValueError(f"cannot place dinky shockwave type in {name}: no parser-order anchor")
            renamed = renamed[:armor.start()] + "$Dinky shockwave:\n" + dinky_type + "\n" + renamed[armor.start():]
    return "\n".join(line.rstrip() for line in renamed.splitlines())


def render_table(variants: list[Variant] | None = None) -> str:
    if variants is None:
        variants, unknown = source_inventory()
    else:
        unknown = ()
    if not variants:
        raise ValueError("No stock fighter-bank weapons were found")
    lines = [
        "; Generated by core/tools/generate_fighter_blast_weapons.py.",
        "; Coverage: stock fighter primary/secondary banks, bundled FSPort defaults, and spawned children.",
        "; Third-party weapons and beam classes are listed as unresolved and are not remapped.",
    ]
    if unknown:
        lines.append("; Unresolved bank names (not cloned): " + ", ".join(unknown))
    for section, header in (("primary weapons", "#Primary Weapons"), ("secondary weapons", "#Secondary Weapons")):
        grouped = [variant for variant in variants if variant.weapon_section == section]
        if not grouped:
            continue
        lines.extend(["", header])
        for variant in grouped:
            lines.extend(["", f"; Fighter chip variant for {variant.source_name}.",
                          _rename_entry(variant.source_entry, variant.variant_name,
                                        variant.spawn_children, FIGHTER_DAMAGE_TYPE)])
        lines.extend(["#End", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="write the generated table")
    mode.add_argument("--check", action="store_true", help="fail if the checked-in table differs")
    mode.add_argument("--list", action="store_true", help="list the covered source and variant classes")
    args = parser.parse_args()
    variants, unknown = source_inventory()
    if args.list:
        for variant in variants:
            print(f"{variant.weapon_section}\t{variant.source_name}\t{variant.variant_name}\tmain={FIGHTER_DAMAGE_TYPE}\tchildren={','.join(variant.spawn_children)}\tships={','.join(variant.fighter_sources)}")
        if unknown:
            print("UNRESOLVED\t" + ", ".join(unknown))
        return 0
    expected = render_table(variants)
    if args.write:
        OUTPUT.write_text(expected, encoding="utf-8", newline="\n")
        print(f"wrote {OUTPUT} ({len(variants)} variants)")
        return 0
    actual = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else None
    if actual != expected:
        print(f"FAIL: generated fighter blast table differs: {OUTPUT}")
        return 1
    print(f"PASS: {len(variants)} fighter primary/secondary weapon variants match the generator")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
