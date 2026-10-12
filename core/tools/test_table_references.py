"""Table-reference tests: does every name the mod uses actually exist?

Two failure modes shipped undetected for a long time, and both were silent in
game rather than loud:

* `+nocreate` on a NEW `$Name:`. The flag means "patch this weapon IF it
  already exists"; combined with a new name the engine discards the entire
  entry (create_if_not_found=false, then an early return that skips to the next
  $Name:/#End). Four sentry weapons shipped that way, so sentries kept their
  stock 950-1375 m guns while the HUD and the project's own telemetry reported
  a 12,000 m reach - because GetSentryWeaponRange reads LifeMax/Speed off an
  INVALID HANDLE, gets 0, and falls back to the configured number.
* A `class = "..."` no table defines. `GVSG Sotar` and `GVSG Sekhem` were
  Gold's tier 3 and tier 4 sentry platforms and exist nowhere, so those slots
  could never spawn.

An unknown weapon name resolves to an invalid handle, NOT nil
(scripting/api/libs/tables.cpp), so a `== nil` guard in Lua can never catch
this. It has to be caught here, against a real table.

Retail tables are extracted from root_fs2.vp and live in tools/ beside the
install; RETAIL_WEAPONS_TBL / RETAIL_SHIPS_TBL override the location. When a
retail table is absent the corresponding checks skip rather than assert, because
"does this already exist in retail" is unanswerable without it.
"""
import re
import unittest
from pathlib import Path

import retail_tables as rt

TOOLS = Path(__file__).resolve().parent
CONFIG = rt.MOD_ROOT / "data" / "scripts" / "fs2rts_config.lua"

# The mod's own naming convention separates its table kinds. Getting this wrong
# would check ship names against weapons.tbl and fail on every re-skin, so the
# classification is explicit rather than guessed from the entry contents.
WEAPON_TABLE_MARKERS = ("-wep",)
SHIP_TABLE_MARKERS = ("-shp",)


def table_kind(path):
    name = path.name.lower()
    if any(marker in name for marker in WEAPON_TABLE_MARKERS):
        return "weapon"
    if any(marker in name for marker in SHIP_TABLE_MARKERS):
        return "ship"
    return None


def mod_nocreate_by_kind():
    out = {"weapon": {}, "ship": {}}
    for path in rt.mod_table_files():
        kind = table_kind(path)
        if kind is None:
            continue
        for name in rt.parse_nocreate_names(rt.read(path)):
            if kind == "weapon":
                name = rt.canonical_weapon_name(name)
            out[kind].setdefault(name, []).append(path.name)
    return out


def config_references(key):
    """Every `key = "value"` string reference in the config."""
    if not CONFIG.is_file():
        return {}
    pattern = re.compile(rf'\b{key}\s*=\s*"([^"]+)"')
    found = {}
    for match in pattern.finditer(rt.read(CONFIG)):
        found.setdefault(match.group(1), []).append(match.start())
    return found


class RetailTableAvailabilityTests(unittest.TestCase):
    def test_retail_tables_are_discoverable_or_reported_absent(self):
        """A silently-missing retail table would turn every check below into
        a no-op, which is the same class of blindness these tests exist to
        remove. Fail loudly when neither table resolves."""
        self.assertIsNotNone(rt.retail_weapons_table(),
                             "retail weapons.tbl not found; set "
                             "RETAIL_WEAPONS_TBL or place it in tools/")
        self.assertIsNotNone(rt.retail_ships_table(),
                             "retail ships.tbl not found; set "
                             "RETAIL_SHIPS_TBL or place it in tools/")


class NocreateTests(unittest.TestCase):
    """`+nocreate` is legal only for a weapon the retail game already has."""

    def test_every_nocreate_weapon_exists_in_the_retail_weapon_table(self):
        path = rt.retail_weapons_table()
        if path is None:
            self.skipTest("retail weapons.tbl unavailable")
        retail = rt.parse_weapon_names(rt.read(path))
        phantom = {name: files
                   for name, files in mod_nocreate_by_kind()["weapon"].items()
                   if name not in retail}
        self.assertEqual(
            phantom, {},
            "these are declared +nocreate but do not exist in retail, so the "
            "engine skips the whole entry and the list overstates its own "
            f"coverage: {phantom}")

    def test_every_nocreate_ship_exists_in_the_retail_ship_table(self):
        path = rt.retail_ships_table()
        if path is None:
            self.skipTest("retail ships.tbl unavailable")
        retail = rt.parse_names(rt.read(path))
        phantom = {name: files
                   for name, files in mod_nocreate_by_kind()["ship"].items()
                   if name not in retail}
        self.assertEqual(
            phantom, {},
            "a +nocreate ship class that retail does not define is skipped by "
            f"the engine: {phantom}")


class ConfigReferenceTests(unittest.TestCase):
    """Names the config points at must resolve to a real class."""

    def test_every_ship_class_named_in_the_config_exists(self):
        references = config_references("class")
        self.assertTrue(references, "no class references parsed; the regex "
                                    "or the config path is wrong")
        retail_path = rt.retail_ships_table()
        known = rt.mod_defined_names()
        if retail_path is not None:
            known |= rt.parse_names(rt.read(retail_path))
        missing = sorted(name for name in references if name not in known)
        self.assertEqual(
            missing, [],
            "these class names resolve to an invalid ship handle, so the slot "
            "can never spawn (an unknown class is not nil, it is an invalid "
            f"handle): {missing}")

    def test_every_weapon_named_in_the_config_exists(self):
        references = config_references("weapon")
        self.assertTrue(references, "no weapon references parsed; the regex "
                                    "or the config path is wrong")
        known = rt.mod_defined_names()
        retail_path = rt.retail_weapons_table()
        if retail_path is not None:
            known |= rt.parse_names(rt.read(retail_path))
        missing = sorted(name for name in references if name not in known)
        self.assertEqual(missing, [],
                         f"unresolvable weapon names: {missing}")


class FactionTableTests(unittest.TestCase):
    def test_additional_iffs_are_separate_from_nocreate_overrides(self):
        tables=rt.MOD_ROOT/"data"/"tables"
        legacy=(tables/"fs2rts-iff.tbm").read_text(encoding="utf-8")
        additions=(tables/"fs2rts-factions-iff.tbm").read_text(encoding="utf-8")
        names=re.findall(r"^\$IFF Name: (RTS Faction \d+)$",additions,re.MULTILINE)
        self.assertEqual(names,[f"RTS Faction {i}" for i in range(4,13)])
        self.assertNotIn("+nocreate",additions,
            "upstream keeps +nocreate set for the rest of one IFF table parse; new teams need a separate table")
        self.assertEqual(len(re.findall(r"^\$IFF Name: (?:Friendly|Hostile|Neutral)$",legacy,re.MULTILINE)),3)
        mission=(rt.MOD_ROOT/"data"/"missions"/"FS2_RTS_Escalation.fs2").read_text(encoding="utf-8")
        self.assertEqual(mission.count("+All Teams Attack"),1,
            "mirror species and extra teams need native hostility in upstream FSO")

    def test_faction_slots_and_native_colors_stay_one_to_one(self):
        tables=rt.MOD_ROOT/"data"/"tables"
        iff=(tables/"fs2rts-factions-iff.tbm").read_text(encoding="utf-8")
        colors=[tuple(map(int,row)) for row in re.findall(r"^\$Color: \(\s*(\d+),\s*(\d+),\s*(\d+)\s*\)$",iff,re.MULTILINE)]
        self.assertEqual(len(colors),9)
        self.assertEqual(len(set(colors)),9,"additional IFF teams must have distinct native colors")
        team=(tables/"fs2rts-clr.tbm").read_text(encoding="utf-8")
        names=set(re.findall(r"^\$Team Name: (RTS Faction (?:Blue|Red|Gold|\d+))$",team,re.MULTILINE))
        expected={"RTS Faction Blue","RTS Faction Red","RTS Faction Gold"}
        expected.update(f"RTS Faction {i}" for i in range(4,13))
        self.assertEqual(names,expected)


class WeaponSectionHeaderTests(unittest.TestCase):
    """A *-wep.tbm with no section header parses to nothing, successfully.

    `parse_weaponstbl` (code/weapon/weapons.cpp) only reads entries inside a
    recognised section - `#Primary Weapons`, `#Secondary Weapons`,
    `#Beam Weapons`, `#Countermeasures`. Everything outside one is skipped as
    if it were a comment, and the function still returns success: no error, no
    warning, an empty table. This is what silently emptied
    fs2rts-sentry-wep.tbm, leaving the mod's sentries on their stock retail
    weapons while every lookup reported the class as unresolvable.

    It is indistinguishable from `+nocreate` on a new name, which is why it
    survived a review that found the latter.
    """

    SECTIONS = ("#Primary Weapons", "#Secondary Weapons",
                "#Beam Weapons", "#Countermeasures")

    def test_every_mod_weapon_table_has_a_section_header(self):
        tables = [p for p in rt.mod_table_files()
                  if "-wep" in p.name.lower()]
        self.assertTrue(tables, "no *-wep.tbm found; the glob is wrong")
        missing = []
        for path in tables:
            lines = rt.read(path).splitlines()
            if not any(line.strip() in self.SECTIONS for line in lines):
                missing.append(path.name)
        self.assertEqual(
            missing, [],
            "these weapon tables have no section header, so the engine parses "
            f"no entries from them at all: {missing}")

    def test_every_mod_weapon_entry_sits_after_a_section_header(self):
        for path in [p for p in rt.mod_table_files()
                     if "-wep" in p.name.lower()]:
            seen_header = False
            for number, line in enumerate(rt.read(path).splitlines(), 1):
                stripped = line.strip()
                if stripped in self.SECTIONS:
                    seen_header = True
                    continue
                if stripped.startswith("$Name:") and not seen_header:
                    self.fail(
                        f"{path.name}:{number} declares {stripped} before any "
                        "section header; the engine will never read it")


class BeamAllowlistTests(unittest.TestCase):
    """The base-damage cap is an allowlist, so it must be audited, not trusted.

    `RTS Base Hull` scales exactly one damage type, and the mod retypes named
    weapons into it. Anything not on the list hits a command station at full
    damage. A name list cannot be complete by construction, so this diffs it
    against the real retail beam set - which is how MjolnirBeam, a 750-damage
    continuous laser, stayed uncapped.
    """

    ALLOWLIST_TABLE = "fs2rts-capital-beams-wep.tbm"

    def _allowlist(self):
        path = rt.TABLES / self.ALLOWLIST_TABLE
        self.assertTrue(path.is_file(), f"missing {path}")
        return rt.parse_nocreate_names(rt.read(path))

    def test_every_retail_beam_is_retyped_onto_the_base_armor_damage_type(self):
        beams = rt.retail_beam_names()
        if beams is None:
            self.skipTest("retail weapons.tbl unavailable")
        allow = self._allowlist()
        uncovered = sorted(beams - allow)
        self.assertEqual(
            uncovered, [],
            "these retail beams are not retyped to `RTS Capital Beam`, so they "
            "damage `RTS Base Hull` at FULL damage instead of the 0.10 "
            f"multiplier: {uncovered}")

    def test_the_allowlist_contains_no_dead_entries(self):
        """Every entry here must name a weapon retail actually defines.

        Checked against ALL retail weapons, not just the beam set: this table
        also carries the sentry `Vasudan Flux Cannon` retype, which is a blast
        weapon and would look "dead" if compared against beams alone.
        """
        path = rt.retail_weapons_table()
        if path is None:
            self.skipTest("retail weapons.tbl unavailable")
        retail = rt.parse_names(rt.read(path))
        dead = sorted(self._allowlist() - retail)
        self.assertEqual(
            dead, [],
            "these entries are skipped by the engine because retail has no "
            f"such weapon, which makes the list look fuller than it is: {dead}")


class DebrisArmorCoverageTests(unittest.TestCase):
    def test_every_spawnable_hull_types_its_debris(self):
        # Completeness check only; cannon_range_probe exercises real impacts.
        names = set(config_references('class')) | {'GTI Arcadia', 'GVI Cairo', 'SI Arachnas'}
        typed = set()
        for path in rt.TABLES.glob('*-shp.tbm'):
            for block in re.findall(r'^\s*\$Name:.*?(?=^\s*\$Name:|\Z)', rt.read(path), re.M | re.S):
                if re.search(r'\$Debris:\s*\+Damage Type: RTS Debris Impact', block):
                    typed.add(re.search(r'\$Name:\s*(.*)', block)[1].strip())
        self.assertEqual(sorted(names - typed), [], 'spawnable wreckage bypasses command-station impact armor')
