import struct

import pytest

import audit_fighter_weapon_overrides as audit


def write_vp(path, entries, payload=b'$Name: Test\n'):
    offset = 16 + len(payload)
    index = b''.join(struct.pack('<ii32si', start, size, name.encode(), 0)
                     for start, size, name in entries)
    path.write_bytes(struct.pack('<4siii', b'VPVP', 2, offset, len(entries)) + payload + index)


def test_vp_reads_only_table_entries(tmp_path):
    path = tmp_path / 'test.vp'
    write_vp(path, [(0, 0, 'data'), (0, 0, 'tables'), (16, 12, 'test-wep.tbm'),
                    (0, 0, '..'), (0, 0, 'maps'), (16, 12, 'fake-wep.tbm')])
    assert list(audit.vp_tables(path)) == [('test.vp:test-wep.tbm', '$Name: Test\n')]


def test_vp_normalizes_table_newlines_before_windows_write(tmp_path):
    path = tmp_path / 'crlf.vp'
    payload = b'$Name: Test\r\n'
    write_vp(path, [(0, 0, 'data'), (0, 0, 'tables'), (16, len(payload), 'test-wep.tbm')], payload)
    assert list(audit.vp_tables(path))[0][1] == '$Name: Test\n'


@pytest.mark.parametrize('entries', [[(0, 0, '..')], [(16, 5000, 'bad.tbl')]])
def test_vp_rejects_bad_entries(tmp_path, entries):
    path = tmp_path / 'bad.vp'
    write_vp(path, entries)
    with pytest.raises(ValueError):
        list(audit.vp_tables(path))


def test_vp_rejects_truncated_index(tmp_path):
    path = tmp_path / 'bad.vp'
    path.write_bytes(struct.pack('<4siii', b'VPVP', 2, 16, 1))
    with pytest.raises(ValueError):
        list(audit.vp_tables(path))


def test_optional_patches_keep_stats_effects_and_chip_types():
    source = '''#Secondary Weapons
$Name: Piranha
+nocreate
$Damage: 123
$Damage Type: Retail damage
$Shockwave damage type: Retail blast
$Dinky shockwave:
+Shockwave damage type: Retail dinky
$Flags: ( "Spawn Cluster Baby, 15" )
+Weapon Range: 2000
#End
'''
    result = audit.variant_patch(source, {'Piranha', 'Cluster Baby'})
    assert '$Name: RTSF Piranha' in result
    assert '+nocreate' in result and '$Damage: 123' in result
    assert '+Weapon Range: 2000' in result
    assert 'Spawn RTSF Cluster Baby, 15' in result
    assert 'Retail' not in result
    assert result.count('#Secondary Weapons') == 1 and result.count('#End') == 1
    with pytest.raises(ValueError, match='Unmapped optional spawn child'):
        audit.variant_patch(source, {'Piranha'})
    with pytest.raises(ValueError, match='replacement'):
        audit.variant_patch(source.replace('+nocreate', ''), {'Piranha', 'Cluster Baby'})
