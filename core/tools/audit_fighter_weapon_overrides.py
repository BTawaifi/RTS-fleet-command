"""List optional-mod weapon overrides that generated retail fighter clones bypass.

Read-only inventory, not a merge of FSO tables or a combat-parity certificate.
"""
import argparse
import json
import re
import struct
from pathlib import Path

import generate_fighter_blast_weapons as generator


def vp_tables(path):
    with path.open('rb') as stream:
        header = stream.read(16)
        if len(header) != 16:
            raise ValueError(f'Truncated VP header: {path}')
        magic, version, offset, count = struct.unpack('<4siii', header)
        size = path.stat().st_size
        if magic != b'VPVP' or version != 2 or offset < 16 or count < 0 or offset + count * 44 > size:
            raise ValueError(f'Invalid VP index: {path}')
        stream.seek(offset)
        index = stream.read(count * 44)
        directories = []
        for position in range(0, len(index), 44):
            start, length, raw_name, _ = struct.unpack_from('<ii32si', index, position)
            name = raw_name.split(b'\0', 1)[0].decode('ascii')
            if length == 0:
                if name == '..':
                    if not directories:
                        raise ValueError(f'Invalid directory traversal: {path}')
                    directories.pop()
                else:
                    directories.append(name)
                continue
            if start < 16 or length < 0 or start + length > offset:
                raise ValueError(f'Invalid VP entry: {path}:{name}')
            if directories[-2:] == ['data', 'tables'] and name.lower().endswith(('.tbl', '.tbm')):
                stream.seek(start)
                yield f'{path.name}:{name}', stream.read(length).decode('utf-8', errors='replace').replace('\r\n', '\n')


def audit(mod):
    variants, _ = generator.source_inventory()
    covered = {variant.source_name for variant in variants}
    tables = []
    for path in sorted(mod.glob('*.vp')):
        tables.extend(vp_tables(path))
    for path in sorted((mod / 'data' / 'tables').glob('*')):
        if path.suffix.lower() in ('.tbl', '.tbm'):
            tables.append((str(path.relative_to(mod)), path.read_text(encoding='utf-8', errors='replace')))
    overrides = []
    banks = {}
    for origin, text in tables:
        if origin.lower().endswith(('weapons.tbl', '-wep.tbm')):
            for name, block in generator.named_entries(text).items():
                if name in covered:
                    fields = [line.strip() for line in block.splitlines()
                              if line.lstrip().startswith(('$', '+')) and not line.lstrip().startswith('$Name:')]
                    overrides.append({'source': origin, 'weapon': name, 'fields': fields})
        if origin.lower().endswith(('ships.tbl', '-shp.tbm')):
            for weapon, sources in generator._fighter_bank_sources(text).items():
                banks.setdefault(weapon, set()).update(ship for ship, _ in sources)
    return {'mod': str(mod.resolve()), 'tables_scanned': len(tables),
            'covered_sources': len(covered), 'overrides': overrides,
            'unmapped_fighter_banks': {name: sorted(ships) for name, ships in sorted(banks.items()) if name not in covered},
            'limit': 'Partial ship patches without fighter flags and inherited banks need native inspection.'}


def variant_patch(text, covered):
    """Replay optional weapon patches on aliases while retaining their chip types."""
    sections = generator.weapon_sections(text)
    groups = {}
    for name, block in generator.named_entries(text).items():
        if name not in covered:
            continue
        if not re.search(r'(?m)^\s*\+nocreate\b', block):
            raise ValueError(f'Optional weapon replacement needs explicit review: {name}')
        if sections.get(name) not in ('primary weapons', 'secondary weapons'):
            raise ValueError(f'Unsupported optional weapon section: {name}')
        block = generator._NAME.sub('$Name: ' + generator.VARIANT_PREFIX + name, block, count=1)
        block = re.sub(r'(?m)^\s*(?:#(?:End|Primary Weapons|Secondary Weapons|Beam Weapons)|[$+]\s*(?:Damage Type|Shockwave damage type):)[^\r\n]*', '', block)
        for child in generator.spawn_children(block):
            if child not in covered:
                raise ValueError(f'Unmapped optional spawn child: {child}')
            block = re.sub(r'("Spawn\s+)' + re.escape(child) + r'(,\s*\d+")',
                           lambda m: m.group(1) + generator.VARIANT_PREFIX + child + m.group(2), block,
                           flags=re.IGNORECASE)
        groups.setdefault(sections[name], []).append(block.strip())
    lines = ['; Generated optional MediaVP alias patches; load only with MediaVP assets.']
    for section, header in (('primary weapons', '#Primary Weapons'), ('secondary weapons', '#Secondary Weapons')):
        if section in groups:
            lines.extend([header, *groups[section], '#End', ''])
    return '\n\n'.join(lines) + '\n' if groups else ''


def write_variant_patches(mod, destination):
    covered = {v.source_name for v in generator.source_inventory()[0]}
    pending = {}
    for vp in sorted(mod.glob('*.vp')):
        for origin, text in vp_tables(vp):
            if not origin.lower().endswith('-wep.tbm'):
                continue
            patch = variant_patch(text, covered)
            if patch:
                path = destination / ('z-rtsf-' + origin.split(':', 1)[1])
                if path in pending:
                    raise ValueError(f'Duplicate optional patch filename: {origin}')
                pending[path] = patch
    # Validate the whole inventory before replacing any existing generated table.
    for path, patch in pending.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(patch, encoding='utf-8')
    return list(pending)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mod', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--write-variant-patches', type=Path,
                        help='generate optional alias patches into this tables directory')
    args = parser.parse_args()
    if not args.mod.is_dir():
        parser.error('mod directory does not exist')
    report = audit(args.mod)
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    if args.write_variant_patches:
        paths = write_variant_patches(args.mod, args.write_variant_patches)
        print(f'Generated {len(paths)} optional alias patch tables.')
    print(f"{report['tables_scanned']} tables; {len(report['overrides'])} covered-source override entries; "
          f"{len(report['unmapped_fighter_banks'])} unmapped explicit fighter banks. Report: {args.output}")
