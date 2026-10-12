"""The real verification entry points must refuse misleading success."""
import subprocess
import sys
from pathlib import Path

import pytest

ROOT=Path(__file__).resolve().parents[2]


@pytest.mark.parametrize('suite',('lua','static','tools'))
def test_each_suite_collects_real_cases(suite):
    result=subprocess.run([sys.executable,'-m','pytest','--collect-only','--suite',suite,'-q'],
        cwd=ROOT,capture_output=True,text=True)
    assert result.returncode==0,result.stdout+result.stderr
    assert 'selected' in result.stdout and 'no tests collected' not in result.stdout


def test_regression_gate_has_no_default_experiment(monkeypatch,capsys):
    import regression_gate as gate
    monkeypatch.delenv('RTS_GATE_BASELINE',raising=False)
    with pytest.raises(SystemExit) as error: gate.main(['candidate','--metric','cp_spend_rate'])
    assert error.value.code==2
    assert 'no implicit historical baseline' in capsys.readouterr().err
    with pytest.raises(SystemExit) as error: gate.main(['candidate','--baseline','baseline'])
    assert error.value.code==2


def test_regression_gate_forwards_exact_experiment_criteria(monkeypatch):
    import regression_gate as gate
    observed=[]
    monkeypatch.setattr(gate.compare_batches,'main',lambda args: observed.append(args) or 2)
    assert gate.main(['candidate','--baseline','baseline','--metric','idle_fraction_mean',
        '--polarity','idle_fraction_mean=lower'])==2
    assert observed==[['baseline','candidate','--quiet','--fail-on','idle_fraction_mean',
        '--polarity','idle_fraction_mean=lower']]
