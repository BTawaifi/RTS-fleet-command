"""Fail-closed experiment evidence shared by descriptive analysis and gates."""
import hashlib
import json
import math
from pathlib import Path


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def manifest(root):
    root = Path(root)
    return {p.relative_to(root).as_posix(): digest(p)
            for p in sorted(root.rglob('*')) if p.is_file()
            and not any(part in ('__pycache__', '.pytest_cache') for part in p.parts)
            and p.suffix.lower() not in ('.log', '.jsonl')}


def read_object(path):
    value = json.loads(Path(path).read_text(encoding='utf-8'))
    if not isinstance(value, dict):
        raise ValueError(f'Expected object: {path}')
    return value


def is_finite_number(value):
    if isinstance(value,bool) or not isinstance(value,(int,float)):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def valid_record(record):
    if not isinstance(record, dict) or not isinstance(record.get('event'), str) or not isinstance(record.get('data'), dict):
        return False
    when=record.get('time')
    if not is_finite_number(when):
        return False
    data=record['data']
    if data.get('faction') is not None and (not isinstance(data['faction'],str) or not data['faction']):
        return False
    paths = ('economy', 'economy.flow', 'economy.flowCumulative', 'economy.queue',
             'plan', 'losses', 'composition', 'replacementValueByClass', 'orders', 'balance')
    for path in paths:
        value=data
        for key in path.split('.'):
            value=value.get(key) if isinstance(value,dict) else None
        if value is not None and not isinstance(value,dict):
            return False
    return True


def inspect_run(run):
    run = Path(run).resolve()
    out = {'verified': False, 'issues': [], 'seed': None, 'completion': 'unknown',
           'provenance': None, 'cohort_seeds': []}
    issues = out['issues']
    root = next((p for p in run.parents if (p / 'freeze.json').is_file()), None)
    if root is None:
        issues.append('No frozen provenance')
        return out
    try:
        freeze = read_object(root / 'freeze.json')
        plan = read_object(root / 'batch.plan.json')
        if freeze.get('schema') != 2 or not freeze.get('input_manifest'):
            issues.append('Legacy/incomplete provenance manifest')
            return out
        if not isinstance(freeze['input_manifest'],dict) or not all(isinstance(k,str) and isinstance(v,str) for k,v in freeze['input_manifest'].items()):
            raise ValueError('input_manifest must map file paths to hashes')
        if not isinstance(freeze.get('seeds'),list) or not all(type(seed) is int for seed in freeze['seeds']):
            raise ValueError('seeds must be a list of integers')
        mods=plan.get('mod',[])
        if not isinstance(mods,list) or not all(isinstance(mod,str) for mod in mods):
            raise ValueError('mod must be a list of directory names')
        if digest(root / 'batch.plan.json') != freeze['plan_sha256']:
            issues.append('Plan changed after freeze')
        for name, expected in freeze['input_manifest'].items():
            relative = Path(name)
            if relative.is_absolute() or '..' in relative.parts:
                issues.append('Unsafe manifest path')
                continue
            path = run / relative
            if name.startswith('data/players/'):
                # These outputs may legitimately differ after mission shutdown.
                continue
            if not path.is_file() or digest(path) != expected:
                issues.append(f'Input changed/missing: {name}')
        for key in ('engine', 'runner'):
            if digest(freeze[key]) != freeze[key + '_sha256']:
                issues.append(f'{key} identity changed')
        records = []
        result_log = Path(plan['output_dir']) / 'results.jsonl'
        for line in result_log.read_text(encoding='utf-8').splitlines():
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError('Invalid runner record')
            if Path(row.get('workspace', '')).resolve() == run:
                records.append(row)
        if len(records) != 1:
            issues.append('Missing/duplicate runner completion record')
            return out
        record = records[0]
        if not isinstance(record.get('pilot_input_sha256',{}),dict):
            raise ValueError('pilot_input_sha256 must map file paths to hashes')
        for name, expected in freeze['input_manifest'].items():
            if name.startswith('data/players/') and record.get('pilot_input_sha256', {}).get(name) != expected:
                issues.append(f'Unverified prelaunch pilot input: {name}')
        out['seed'] = record.get('seed')
        out['cohort_seeds'] = freeze['seeds']
        if out['seed'] not in freeze['seeds']:
            issues.append('Seed is outside frozen cohort')
        if result_log.parent.resolve() not in run.parents:
            issues.append('Run is outside planned results directory')
        result = read_object(run / 'engine-result.json')
        if result.get('seed') != out['seed']:
            issues.append('Native/runner seed mismatch')
        config = run / 'probe/data/scripts/fs2rts_config.lua'
        if 'rts/data/scripts/fs2rts_config.lua' in freeze['input_manifest']:
            overlay = root / 'expected-config.lua'
            if digest(overlay) != freeze.get('config_overlay_sha256'):
                issues.append('Frozen configuration overlay changed')
            expected = 'math.randomseed(' + str(out['seed']) + ')\n' + overlay.read_text(encoding='utf-8')
            if record.get('ai_params') != {} or config.read_text(encoding='utf-8') != expected:
                issues.append('Runtime configuration differs from frozen source/seed')
            if digest(config) != record.get('runtime_config_sha256'):
                issues.append('Runtime configuration hash mismatch')
        for mod in plan.get('mod', []):
            for folder in ('scripts', 'tables'):
                for path in (run / mod / 'data' / folder).rglob('*'):
                    if path.is_file():
                        key = path.relative_to(run).as_posix()
                        if key not in freeze['input_manifest'] and path != config:
                            issues.append(f'Unfrozen executable input: {key}')
        if record.get('engine_result') != result:
            issues.append('Runner/native result disagree')
        if record.get('status') != 'completed' or record.get('exit_code') != 0:
            issues.append('Runner reports failed/timeout/incomplete run')
        if result.get('crashed') or record.get('error'):
            issues.append('Run reports an error')
        if result.get('time_limit_reached') is True:
            out['completion'] = 'cap_unresolved'
        elif result.get('termination') == 'mission_exit':
            out['completion'] = 'mission_exit'
        else:
            issues.append('No explicit completion state')
        out['provenance'] = {key: freeze[key] for key in
                             ('engine_sha256', 'runner_sha256', 'driver_sha256')}
        out['provenance'].update(setup=plan['setup'], fixed_dt=plan['fixed_dt'],
                                 max_sim_time=plan['max_sim_time'], mission=plan['mission'],
                                 assets={k: v for k, v in freeze['input_manifest'].items()
                                         if not k.startswith('rts/data/scripts/')})
    except (OSError, ValueError, KeyError, TypeError) as exc:
        issues.append(f'Unreadable/incomplete evidence: {exc}')
    out['verified'] = not issues
    return out


def comparison_issues(base, candidate):
    issues = []
    for side, rows in (('baseline', base), ('candidate', candidate)):
        for row in rows:
            evidence = row.get('evidence', {})
            if not evidence.get('verified'):
                issues.append(f'{side}/{row.get("attempt")}: unverified run evidence')
            if not row.get('sequence_valid'):
                issues.append(f'{side}/{row.get("attempt")}: missing/broken sequence')
    if issues:
        return issues
    b = {r['evidence']['seed']: r for r in base}
    c = {r['evidence']['seed']: r for r in candidate}
    if len(b) != len(base) or len(c) != len(candidate) or set(b) != set(c):
        issues.append('Cohorts need unique matching seeds; no attempt cherry-picking')
    for rows in (base, candidate):
        if rows and set(r['evidence']['seed'] for r in rows) != set(rows[0]['evidence']['cohort_seeds']):
            issues.append('Frozen cohort has missing runs; cannot accept successful survivors only')
    for seed in b.keys() & c.keys():
        left, right = b[seed], c[seed]
        if left['evidence']['provenance'] != right['evidence']['provenance']:
            issues.append(f'Seed {seed}: engine/assets/setup/window mismatch')
        if left.get('until') is None or left.get('until') != right.get('until'):
            issues.append(f'Seed {seed}: explicit common --until window required for metric gates')
        elif min(left['vector']['duration_seconds'], right['vector']['duration_seconds']) < left['until'] - 1:
            issues.append(f'Seed {seed}: telemetry did not reach requested window')
    return issues
