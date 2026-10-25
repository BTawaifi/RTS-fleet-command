"""Select checks by evidence type; a new file cannot silently disappear."""
import pytest

LUA_FILES = set('''test_ai_assault_doctrine test_ai_concentration test_ai_escalation
test_ai_observation test_ai_rebalance test_alt_focus_input test_camera_director test_environment
test_faction_profiles test_feature_request test_fleet_life test_hud_layout
test_hud_perf test_operations test_pilot_capital test_pilot_fire test_pilot_wing
test_player_feedback test_review_regressions test_scenario_start test_service test_setup_backdrop test_station
test_telemetry_contracts test_user_orders'''.split())
STATIC_FILES = set('''test_lua_scope_order test_parse_check test_script_structure
test_table_references test_fighter_blast_weapons'''.split())
TOOLS_FILES = set('''test_ai_invariants test_ai_matchmap test_ai_tactics test_ai_timeline
test_analyze_batch test_compare_batches test_killcheck test_prepare_headless_batch
test_staged_diff test_verification_workflow test_run_evidence test_audit_fighter_weapon_overrides
test_stage_release'''.split())


def pytest_addoption(parser):
    parser.addoption(
        '--suite', choices=('all', 'lua', 'static', 'tools'), default='all',
        help='evidence type to run; none of these suites establishes balance')


def pytest_collection_modifyitems(config, items):
    suites = {
        name: kind
        for kind, names in (('lua', LUA_FILES), ('static', STATIC_FILES), ('tools', TOOLS_FILES))
        for name in names
    }
    selected = []
    excluded = []
    requested = config.getoption('--suite')
    for item in items:
        name = item.path.stem
        if name not in suites:
            raise pytest.UsageError(f'Classify {item.path.name} in conftest.py before using it as verification evidence')
        kind = suites[name]
        item.add_marker(getattr(pytest.mark, kind))
        (selected if requested in ('all', kind) else excluded).append(item)
    if excluded:
        config.hook.pytest_deselected(items=excluded)
    items[:] = selected
    if not selected:
        raise pytest.UsageError(f'No checks collected for --suite {requested}')
