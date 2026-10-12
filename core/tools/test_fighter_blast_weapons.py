"""Checks generated fighter weapon variants and their chip armor routing."""

import re
import unittest

import generate_fighter_blast_weapons as generator
TABLE = generator.OUTPUT
LUA = generator.ROOT / "data" / "scripts" / "fs2rts_ai_telemetry.lua"
ARMOR = generator.TABLES / "fs2rts-base-beam-amr.tbm"


def _normalize_source_fields(block):
    block = "\n".join(
        line for line in block.splitlines()
        if not line.lstrip().startswith(";")
        and line.strip() not in ("#End", "#Primary Weapons", "#Secondary Weapons")
    )
    block = re.sub(r"(?m)^\s*\$Name:[^\r\n]*\r?\n", "", block)
    block = re.sub(r"(?m)^\s*\$Damage Type:[^\r\n]*\r?\n", "", block)
    block = re.sub(r"(?m)^\s*\$Shockwave damage type:[^\r\n]*\r?\n", "", block)
    block = re.sub(r"(?m)^\s*\$Dinky shockwave:\r?\n\s*\+Shockwave damage type:[^\r\n]*\r?\n", "", block)
    block = re.sub(r'"Spawn RTSF ([^,\"]+),', r'"Spawn \1,', block)
    return "\n".join(line.rstrip() for line in block.splitlines()).strip()


class FighterBlastWeaponTests(unittest.TestCase):
    def test_per_bank_lists_include_later_banks_but_not_neighbor_fields(self):
        sources = generator._fighter_bank_sources('''$Name: Test fighter
$Flags: ( "fighter" )
$Allowed PBanks: ( "First" ) ; first bank
  ( "Second" )
$Allowed Dogfight SBanks:
  ( "Third" )
  ( "Fourth" )
$Default SBanks: ( "Default" )
$Description: "Not a weapon"
$Name: Test bomber
$Flags: ( "bomber" )
$Allowed PBanks: ( "Bomber only" )
''')
        self.assertEqual(set(sources), {'First', 'Second', 'Third', 'Fourth', 'Default'})
        self.assertEqual(sources['Second'], {('Test fighter', 'primary')})
        self.assertEqual(sources['Fourth'], {('Test fighter', 'secondary')})

    @classmethod
    def setUpClass(cls):
        cls.variants, cls.unknown = generator.source_inventory()
        cls.generated = generator.named_entries(TABLE.read_text(encoding="utf-8"))

    def test_generated_full_clones_preserve_all_other_source_fields(self):
        self.assertFalse(self.unknown, f"unresolved fighter/spawn banks: {self.unknown}")
        self.assertEqual(len(self.variants), len({v.source_name for v in self.variants}))
        for variant in self.variants:
            clone = self.generated[variant.variant_name]
            self.assertEqual(
                _normalize_source_fields(clone),
                _normalize_source_fields(variant.source_entry),
                f"unexpected copied-field change for {variant.source_name}",
            )
            self.assertEqual(variant.weapon_section in ("primary weapons", "secondary weapons"), True)
            self.assertEqual("$Damage Type: RTS Fighter Weapons" in clone, True)
            if generator.has_shockwave_fields(variant.source_entry):
                self.assertIn("$Shockwave damage type: RTS Fighter Weapons", clone)
                self.assertIn("+Shockwave damage type: RTS Fighter Weapons", clone)
            else:
                self.assertNotIn("$Shockwave damage type:", clone)
            effective_main = generator.FIGHTER_DAMAGE_TYPE
            clone_main = re.search(r"(?m)^\$Damage Type: ([^\r\n]+)", clone)
            self.assertEqual(clone_main.group(1) if clone_main else None, effective_main)
        self.assertNotIn("+nocreate", TABLE.read_text(encoding="utf-8"))
        table = TABLE.read_text(encoding="utf-8")
        self.assertIn("#Primary Weapons", table)
        self.assertIn("#Secondary Weapons", table)

    def test_recursive_spawn_graph_uses_fighter_safe_child_classes(self):
        names = {variant.variant_name for variant in self.variants}
        for variant in self.variants:
            clone = self.generated[variant.variant_name]
            for child in variant.spawn_children:
                self.assertIn(f'"Spawn {generator.VARIANT_PREFIX}{child},', clone)
                self.assertIn(f"{generator.VARIANT_PREFIX}{child}", names)

    def test_only_command_hull_gets_five_percent_fighter_weapon_multiplier(self):
        armor = ARMOR.read_text(encoding="utf-8")
        command = re.search(r"(?ms)^\$Name: RTS Command Hull\s*(.*?)(?=^\$Name:|^#End)", armor)
        base = re.search(r"(?ms)^\$Name: RTS Base Hull\s*(.*?)(?=^\$Name:|^#End)", armor)
        self.assertIsNotNone(command)
        self.assertIsNotNone(base)
        self.assertRegex(command.group(1), r"\$Damage Type: RTS Fighter Weapons\s*\+Calculation: multiplicative\s*\+Value: 0\.05\b")
        self.assertNotIn("RTS Fighter Weapons", base.group(1))

    def test_weapon_created_route_matches_generated_variants_and_preserves_roles(self):
        lua = LUA.read_text(encoding="utf-8")
        self.assertIn("if role=='fighter' then", lua)
        self.assertIn("protected[weapon:getSignature()]=false", lua)
        self.assertIn("protected[weapon:getSignature()]=true", lua)
        self.assertIn("local chipAllowed=protected[projectile:getSignature()]==false", lua)
        self.assertIn("if chipAllowed then blocked=false", lua)
        self.assertIn("else blocked=protected[projectile:getSignature()]==true or suppress(target,parent) end", lua)
        self.assertIn("loadedVariants[variantName]=loaded==true", lua)
        self.assertIn("weapon.Class=variant", lua)
        known_block = re.search(r"(?s)local knownFighterChipSourceWeapons=\{(.*?)\n    \}", lua)
        self.assertIsNotNone(known_block)
        known = set(re.findall(r"\['([^']+)'\]=true", known_block.group(1)))
        self.assertEqual(known, {variant.source_name for variant in self.variants})
        self.assertIn("if knownFighterChipSourceWeapons[knownSource] then", lua)
        self.assertIn("KNOWN FIGHTER CHIP VARIANT MISSING; discarding weapon", lua)
        self.assertIn("weapon:vanish(); return", lua)
        self.assertIn("UNMAPPED FIGHTER WEAPON; direct station collisions remain blocked", lua)
        lifecycle = (generator.ROOT / "data" / "scripts" / "fs2rts_lifecycle.lua").read_text(encoding="utf-8")
        self.assertIn("self.FighterBlastVariantsLoaded={}", lifecycle)

    def test_generator_output_is_current(self):
        self.assertEqual(generator.render_table(self.variants), TABLE.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
