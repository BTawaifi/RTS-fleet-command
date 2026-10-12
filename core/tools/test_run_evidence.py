"""Combined evidence controls; these files are synthetic, never engine results."""
import json
from pathlib import Path

import pytest
import run_evidence as evidence
import compare_batches as compare
import ai_invariants as accounting


def freeze_fixture(batch, runs):
    """Supply explicit provenance/completion for analyzer contract fixtures."""
    batch = Path(batch)
    engine = batch / 'fixture-engine'
    runner = batch / 'fixture-runner'
    engine.write_text('synthetic engine', encoding='utf-8')
    runner.write_text('synthetic runner', encoding='utf-8')
    plan = {'output_dir': str(batch / 'results'), 'setup': {'difficulty': 2},
            'fixed_dt': 1 / 30, 'max_sim_time': 3000, 'mission': 'fixture'}
    plan_path = batch / 'batch.plan.json'
    plan_path.write_text(json.dumps(plan), encoding='utf-8')
    records = []
    for index, run in enumerate(runs):
        (run / 'input.txt').write_text('frozen asset', encoding='utf-8')
        result = {'termination': 'mission_exit', 'seed': index}
        (run / 'engine-result.json').write_text(json.dumps(result), encoding='utf-8')
        records.append({'workspace': str(run), 'status': 'completed', 'seed': index,
                        'exit_code': 0, 'engine_result': result})
    (batch / 'results/results.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in records), encoding='utf-8')
    freeze = {'schema': 2, 'engine': str(engine), 'runner': str(runner),
              'engine_sha256': evidence.digest(engine), 'runner_sha256': evidence.digest(runner),
              'driver_sha256': 'synthetic-driver', 'plan_sha256': evidence.digest(plan_path),
              'seeds': list(range(len(runs))), 'input_manifest': {'input.txt': evidence.digest(runs[0] / 'input.txt')}}
    (batch / 'freeze.json').write_text(json.dumps(freeze), encoding='utf-8')


def setup_fixture(tmp_path):
    run = tmp_path / 'results/w/worker/a-1'
    run.mkdir(parents=True)
    freeze_fixture(tmp_path, [run])
    return run


@pytest.mark.parametrize('damage', ['asset', 'engine', 'plan', 'failed', 'missing', 'duplicate', 'result'])
def test_provenance_completion_and_tampering_are_not_accepted(tmp_path, damage):
    run = setup_fixture(tmp_path)
    assert evidence.inspect_run(run)['verified']
    if damage in ('asset', 'engine', 'plan'):
        path = {'asset': run/'input.txt', 'engine': tmp_path/'fixture-engine', 'plan': tmp_path/'batch.plan.json'}[damage]
        path.write_text('changed', encoding='utf-8')
    elif damage == 'result':
        (run/'engine-result.json').write_text('{}', encoding='utf-8')
    else:
        log = tmp_path/'results/results.jsonl'
        row = json.loads(log.read_text())
        if damage == 'failed': row['status'] = 'timeout'
        log.write_text('' if damage == 'missing' else (json.dumps(row)+'\n')*(2 if damage=='duplicate' else 1), encoding='utf-8')
    assert not evidence.inspect_run(run)['verified']


def test_missing_and_zero_attempts_do_not_become_perfect_orders(tmp_path):
    path = tmp_path/'rts-ai-fixture.jsonl'
    for data in ({}, {'orders': {'attempts': 4}}, {'orders': {'attempts': 0, 'success': 0}}, {'orders': {'attempts': 4, 'success': 0}}):
        path.write_text(json.dumps({'event':'COUNTERS','sequence':1,'time':10,'data':data})+'\n', encoding='utf-8')
        match = compare.stream_match(path)
        vector = compare._match_vector(match)
        coverage = compare.metric_coverage(match, vector)
        assert coverage['order_success_rate'] == (data.get('orders',{}).get('attempts',0)>0 and 'success' in data.get('orders',{}))


def test_boolean_counter_cannot_pass_a_numeric_comparison_gate(tmp_path):
    def batch(name,failed):
        folder=tmp_path/name; runs=[]
        for i in range(2):
            run=folder/f'results/w/worker{i}/a-1'; (run/'probe/data').mkdir(parents=True)
            record={'event':'COUNTERS','time':20,'sequence':1,'data':{'orders':{'attempts':10,'failed':failed}}}
            (run/'probe/data/rts-ai-fixture.jsonl').write_text(json.dumps(record)+'\n',encoding='utf-8')
            runs.append(run)
        freeze_fixture(folder,runs)
        return folder,compare.load_batch(folder,name,until=20)
    baseline,base=batch('baseline',5)
    candidate,good=batch('numeric-zero',0)
    report=compare.build_report(base,good,baseline,candidate,polarity_overrides={'order_failed_rate':'lower'},fail_on=['order_failed_rate'])
    assert report['verdict']['overall']=='pass','observed numeric zero must remain valid'
    candidate,bad=batch('boolean-zero',False)
    report=compare.build_report(base,bad,baseline,candidate,polarity_overrides={'order_failed_rate':'lower'},fail_on=['order_failed_rate'])
    assert report['verdict']['overall']=='insufficient_evidence'
    row=next(r for r in report['metric_rows'] if r['metric']=='order_failed_rate')
    assert not row['coverage_complete'] and row['candidate_median'] is None


@pytest.mark.parametrize('missing', ['commandPoints','income','bounty','refund','productionSpend'])
def test_missing_economy_fields_cannot_pass_accounting(tmp_path,missing):
    path=tmp_path/'rts-ai-economy.jsonl'
    def check(incomplete):
        economy={'commandPoints':100,'flow':{'income':0,'bounty':0,'refund':0,'productionSpend':0}}
        if incomplete:
            if missing=='commandPoints': del economy[missing]
            else: del economy['flow'][missing]
        rows=[{'event':'FACTION','time':t,'sequence':i+1,'data':{'faction':'BLUE','economy':economy}} for i,t in enumerate((10,20))]
        path.write_text(''.join(json.dumps(row)+'\n' for row in rows),encoding='utf-8')
        return accounting.check_batch(tmp_path,paths=[str(path)])
    assert accounting.accounting_exit_code(check(False))==0
    result=check(True)
    assert accounting.accounting_exit_code(result)==2
    verdict=next(v for _,v in accounting.iter_verdicts(result) if v['invariant']=='production_spend_reconciles')
    assert verdict['status']=='WARN' and verdict['evidence']['incompleteEconomySnapshots']==2


@pytest.mark.parametrize('bad', [False,'100',float('nan'),float('inf')])
def test_invalid_economy_interval_does_not_create_a_false_bank_violation(tmp_path,bad):
    path=tmp_path/'rts-ai-economy.jsonl'
    rows=[]
    for i,cp in enumerate((100,bad,100,100)):
        rows.append({'event':'FACTION','time':10*(i+1),'sequence':i+1,'data':{'faction':'BLUE',
            'economy':{'commandPoints':cp,'flow':{'income':0,'bounty':0,'refund':0,'productionSpend':0}}}})
    path.write_text(''.join(json.dumps(row)+'\n' for row in rows),encoding='utf-8')
    result=accounting.check_batch(tmp_path,paths=[str(path)])
    assert accounting.accounting_exit_code(result)==2
    facts,_=accounting.scan_match(path)
    assert facts['BLUE'].conservation_violations==0
    assert facts['BLUE'].conservation_intervals==1


@pytest.mark.parametrize('faction', [[],{},False,3])
def test_invalid_faction_identity_is_reported_as_malformed(tmp_path,faction):
    path=tmp_path/'rts-ai-bad-faction.jsonl'
    record={'event':'FACTION','time':1,'sequence':1,'data':{'faction':faction}}
    assert not evidence.valid_record(record)
    path.write_text(json.dumps(record)+'\n',encoding='utf-8')
    assert compare.stream_match(path)['malformed']==1
    _,meta=accounting.scan_match(path)
    assert meta.integrity_errors==1


@pytest.mark.parametrize('field,bad', [('input_manifest',['input.txt']),('seeds',{}),('pilot_input_sha256',[]),('mod',{})])
def test_malformed_provenance_containers_return_incomplete_evidence(tmp_path,field,bad):
    run=setup_fixture(tmp_path)
    assert evidence.inspect_run(run)['verified']
    path=tmp_path/('results/results.jsonl' if field=='pilot_input_sha256' else 'batch.plan.json' if field=='mod' else 'freeze.json')
    value=json.loads(path.read_text()); value[field]=bad
    path.write_text(json.dumps(value)+'\n',encoding='utf-8')
    try:
        result=evidence.inspect_run(run)
    except AttributeError as exc:
        raise AssertionError('malformed provenance escaped its validation boundary') from exc
    assert not result['verified'] and result['issues']


def test_windows_and_missing_cohort_members_cannot_be_accepted(tmp_path):
    run=setup_fixture(tmp_path)
    row={'attempt':'fixture','evidence':evidence.inspect_run(run),'sequence_valid':True,
         'until':None,'vector':{'duration_seconds':20}}
    assert evidence.comparison_issues([row],[row])
    row['until']=20
    assert not evidence.comparison_issues([row],[row])
    row['evidence']['cohort_seeds']=[0,1]
    assert evidence.comparison_issues([row],[row])


@pytest.mark.parametrize('data', [{'economy':[]},{'economy':{'flow':[1]}},{'orders':[1]},{'plan':[1]}])
def test_malformed_nested_containers_are_incomplete_not_parser_exceptions(tmp_path, data):
    path=tmp_path/'rts-ai-malformed.jsonl'
    record={'event':'FACTION','data':data,'time':1,'sequence':1}
    assert not evidence.valid_record(record)
    path.write_text(json.dumps(record)+'\n',encoding='utf-8')
    assert compare.stream_match(path)['malformed']==1
    _,meta=accounting.scan_match(path)
    assert meta.integrity_errors==1


@pytest.mark.parametrize('when', [None,True,float('nan'),float('inf'),'10'])
def test_invalid_clocks_do_not_fabricate_a_zero_time_record(tmp_path,when):
    path=tmp_path/'rts-ai-clock.jsonl'
    record={'event':'COUNTERS','data':{},'time':when,'sequence':1}
    assert not evidence.valid_record(record)
    path.write_text(json.dumps(record)+'\n',encoding='utf-8')
    assert compare.stream_match(path)['malformed']==1
    _,meta=accounting.scan_match(path)
    assert meta.integrity_errors==1


def test_same_timestamp_ledger_after_snapshot_is_not_counted_at_publish(tmp_path):
    path = tmp_path/'rts-ai-fixture.jsonl'
    records = [
        {'event':'CP_SPEND','data':{'faction':'BLUE','flow':'productionSpend','amount':100}},
        {'event':'FACTION','data':{'faction':'BLUE','economy':{'flowCumulative':{'productionSpend':100}}}},
        {'event':'CP_SPEND','data':{'faction':'BLUE','flow':'productionSpend','amount':50}}]
    path.write_text(''.join(json.dumps(dict(r,time=10,sequence=i+1))+'\n' for i,r in enumerate(records)), encoding='utf-8')
    vector = compare._match_vector(compare.stream_match(path))
    assert vector['cp_spend_ledger'] == 150
    assert vector['cp_spend_drift'] == 0


def test_sequence_loss_and_window_cutoff_are_independent(tmp_path):
    path = tmp_path/'rts-ai-fixture.jsonl'
    records = [{'event':'COUNTERS','sequence':i,'time':i*10,'data':{'orders':{'attempts':i}}} for i in (1,2,3)]
    path.write_text(''.join(json.dumps(r)+'\n' for r in records), encoding='utf-8')
    match = compare.stream_match(path,until=20)
    assert match['sequence_valid'] and compare._match_vector(match)['order_attempts'] == 2
    records[-1]['sequence']=5
    path.write_text(''.join(json.dumps(r)+'\n' for r in records), encoding='utf-8')
    assert not compare.stream_match(path,until=20)['sequence_valid']


@pytest.mark.parametrize('action', ['UNIT_SPAWNED','BUILD_FAILED','QUEUE_CANCELLED','QUEUE_REFUNDED'])
def test_identical_time_builds_need_distinct_terminals_and_allow_failure_refund(tmp_path, action):
    path=tmp_path/'rts-ai-builds.jsonl'
    rows=[{'event':'PRODUCTION','data':{'action':'QUEUE_ACCEPTED','faction':'BLUE','class':'fighter',
            'jobId':i,'queuedAt':10,'buildSeconds':5}} for i in (1,2)]
    rows.extend([{'event':'FACTION','data':{'faction':'BLUE','economy':{}}},
                 {'event':'PRODUCTION','data':{'action':action,'faction':'BLUE','jobId':1}},
                 {'event':'PRODUCTION','data':{'action':action,'faction':'BLUE','jobId':2}}])
    def verdict():
        path.write_text(''.join(json.dumps(dict(r,time=30,sequence=i+1))+'\n' for i,r in enumerate(rows)),encoding='utf-8')
        facts,_=accounting.scan_match(path)
        return accounting.check_no_orphan_builds(facts,'fixture')[0].as_dict()
    good=verdict()
    assert good['status']=='PASS'
    assert good['evidence']['buildsSpawned']==(2 if action=='UNIT_SPAWNED' else 0)
    assert good['evidence']['buildsTerminated']==2
    rows[-1]['data']['jobId']=1
    bad=verdict()
    assert bad['status']=='FAIL' and bad['evidence']['orphanBuilds']==1


def test_loss_after_same_timestamp_snapshot_is_excluded(tmp_path):
    path=tmp_path/'rts-ai-losses.jsonl'
    rows=[{'event':'LOSS','data':{'faction':'BLUE'}},
          {'event':'FACTION','data':{'faction':'BLUE','losses':{'fighter':1},'economy':{}}},
          {'event':'LOSS','data':{'faction':'BLUE'}}]
    path.write_text(''.join(json.dumps(dict(r,time=10,sequence=i+1))+'\n' for i,r in enumerate(rows)),encoding='utf-8')
    facts,_=accounting.scan_match(path)
    assert facts['BLUE'].loss_events==2 and facts['BLUE'].loss_events_at_cut==1
    path.write_text(path.read_text()+'broken\n',encoding='utf-8')
    _,meta=accounting.scan_match(path)
    assert meta.integrity_errors==1


def test_sentry_completion_is_once_only(tmp_path):
    path=tmp_path/'rts-ai-sentries.jsonl'
    rows=[{'event':'SENTRY_BUILD','time':10,'data':{'faction':'BLUE','jobId':1,'action':'BUILD_STARTED','finishAt':20}},
          {'event':'SENTRY_BUILD','time':20,'data':{'faction':'BLUE','jobId':1,'action':'BUILD_COMPLETED'}}]
    def status():
        path.write_text(''.join(json.dumps(row)+'\n' for row in rows),encoding='utf-8')
        facts,_=accounting.scan_match(path)
        return accounting.check_no_orphan_builds(facts,'fixture')[0].status
    assert status()=='PASS'
    rows.append(rows[-1])
    assert status()=='FAIL'


def test_pilot_output_changes_are_allowed_only_with_matching_prelaunch_evidence(tmp_path):
    run=setup_fixture(tmp_path)
    pilot=run/'data/players/fixture.json'; pilot.parent.mkdir(parents=True)
    pilot.write_text('initial pilot',encoding='utf-8')
    freeze_path=tmp_path/'freeze.json'; freeze=json.loads(freeze_path.read_text())
    key='data/players/fixture.json'; freeze['input_manifest'][key]=evidence.digest(pilot)
    freeze_path.write_text(json.dumps(freeze),encoding='utf-8')
    log=tmp_path/'results/results.jsonl'; row=json.loads(log.read_text())
    row['pilot_input_sha256']={key:evidence.digest(pilot)}
    log.write_text(json.dumps(row)+'\n',encoding='utf-8')
    pilot.write_text('legitimate shutdown rewrite',encoding='utf-8')
    assert evidence.inspect_run(run)['verified']
    row['pilot_input_sha256'][key]='wrong initial pilot'
    log.write_text(json.dumps(row)+'\n',encoding='utf-8')
    assert not evidence.inspect_run(run)['verified']
