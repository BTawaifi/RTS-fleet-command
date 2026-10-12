"""Freeze runtime data, retail VP hardlinks and a portable pilot for a batch.

The supported entry point is RTS-fleet-command-artifacts/headless/headless.py.
This lower-level stager never launches a batch unless --smoke is requested.
Existing tags are refused; completed runs can still be simulation-cap outcomes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(r"D:\Games\FreespaceOpen")
ARTIFACTS = ROOT / "FS2" / "RTS-fleet-command-artifacts" / "work"
BASE_TEMPLATE = ARTIFACTS.parent / "headless" / "base"
ENGINE = ROOT / "src" / "fs2open" / "build" / "bin" / "Release" / "fs2_open_26_1_0_x64_AVX2.exe"
RUNNER = ROOT / "src" / "fs2open" / "tools" / "rts_ai_experiments" / "run_batch.py"
TOOLS = Path(__file__).resolve().parent
DRIVER = TOOLS / "acceptance_driver.lua"
HOOK = TOOLS / "ai-probe-sct.tbm"
MISSION = "FS2_RTS_Escalation"
EXCLUDE_DIRS = {"__pycache__", ".pytest_cache", ".git", "staged", "node_modules"}
SCENARIOS = {
    "default": {}, "red-only": {"gold": False}, "gold-only": {"red": False},
    "hard-scarce": {"difficulty": 3, "economy": 1},
    "wide": {"distance": 3}, "rotated": {"rotation": 120},
    "original-factions": {"factions": 9, "profiles": True, "telemetry": False},
    "gta-shivans": {"factions": 2, "blueFaction": "GTA", "redFaction": "SHIVAN"},
    "pvn-shivans": {"factions": 2, "blueFaction": "PVN", "redFaction": "SHIVAN"},
    "ntf-gtva": {"factions": 2, "blueFaction": "NTF", "redFaction": "GTVA"},
    "gti-shivans": {"factions": 2, "blueFaction": "GTI_ROGUE", "redFaction": "SHIVAN"},
    "gti-loyal-gta": {"factions": 2, "blueFaction": "GTI_LOYAL", "redFaction": "GTA"},
    "hol-pve": {"factions": 2, "blueFaction": "HOL", "redFaction": "PVE"},
    "six-mirror": {"factions": 6, "mirror": True},
    "twelve-factions": {"factions": 12, "mirror": True, "telemetry": False},
    "max-factions": {"factions": 12, "mirror": True, "telemetry": False},
}
FACTION_CHOICES = ('GTA','GTVA','PVN','PVE','NTF','GTI_LOYAL','GTI_ROGUE','HOL','SHIVAN')


def write_batch_setup(path: Path, scenario: str, layout: str | None = None,
                      equal_economy=False, swap_slots=False, faction_choices=None) -> dict:
    fields=dict(SCENARIOS[scenario])
    if faction_choices is not None:
        if scenario!='default' or swap_slots:
            raise ValueError('Explicit faction choices require default scenario without slot swap')
        if not 2<=len(faction_choices)<=12 or any(choice not in FACTION_CHOICES for choice in faction_choices):
            raise ValueError('Choose 2–12 admitted faction identities')
        fields.update(factions=len(faction_choices),factionChoices=list(faction_choices))
    if equal_economy:
        fields['equalEconomy']=True
    if swap_slots:
        if 'blueFaction' not in fields or 'redFaction' not in fields:
            raise ValueError('Slot swaps require an explicit two-faction matchup scenario')
        fields['blueFaction'],fields['redFaction']=fields['redFaction'],fields['blueFaction']
    if layout is not None:
        if layout not in ('circle','star','multi-circle'): raise ValueError(f'Unknown layout: {layout}')
        fields['layout']=layout
    def lua_value(value):
        if isinstance(value,list): return '{ '+', '.join(json.dumps(item) for item in value)+' }'
        return json.dumps(value) if isinstance(value,str) else str(value).lower()
    values=[f'{key} = {lua_value(value)}' for key,value in sorted(fields.items())]
    path.write_text('return { '+', '.join(values)+' }\n',encoding='utf-8')
    return fields


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def copy_core(source: Path, destination: Path) -> None:
    """Copy the mod tree, skipping generated caches."""
    if not (source / "data" / "scripts" / "fs2rts.lua").is_file():
        raise FileNotFoundError(f"Not an RTS mod/core root: {source}")
    for path in sorted((source / "data").rglob("*")):
        rel = path.relative_to(source)
        if any(part in EXCLUDE_DIRS for part in rel.parts):
            continue
        target = destination / rel
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
    if (source / "mod.ini").is_file():
        shutil.copy2(source / "mod.ini", destination / "mod.ini")


def stage_base(destination: Path, core: Path, template: Path = BASE_TEMPLATE) -> None:
    if destination.exists():
        raise FileExistsError(f"Refusing to overwrite staged workspace: {destination}")
    destination.mkdir(parents=True)
    linked = 0
    for path in template.iterdir():
        if path.is_file() and path.suffix.lower() == ".vp":
            os.link(path.resolve(), destination / path.name)
            linked += 1
    if not linked:
        raise FileNotFoundError(f"No .vp files hardlinked from {template}")
    if (template / "data").is_dir():
        shutil.copytree(template / "data", destination / "data")
    probe = destination / "probe" / "data"
    (probe / "scripts").mkdir(parents=True)
    (probe / "tables").mkdir(parents=True)
    shutil.copy2(DRIVER, probe / "scripts" / "acceptance_driver.lua")
    shutil.copy2(HOOK, probe / "tables" / "ai-probe-sct.tbm")
    copy_core(core, destination / "rts")
    print(f"Staged workspace: {destination}")
    print(f"  .vp hardlinked  : {linked}")
    print(f"  rts core        : {core}")
    print(f"  driver sha256   : {digest(DRIVER)[:16]}")


def main() -> int:
    from run_evidence import manifest
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="fresh immutable staging label")
    parser.add_argument("--matches", type=int, default=8, help="number of independent runs")
    parser.add_argument("--workers", type=int, default=4, help="maximum concurrent engine processes")
    parser.add_argument("--sim-time", type=int, default=3000)
    parser.add_argument("--seed-start", type=int, default=0)
    parser.add_argument("--base-port", type=int, default=48000)
    parser.add_argument("--engine", type=Path, default=ENGINE)
    parser.add_argument("--runner", type=Path, default=RUNNER)
    parser.add_argument("--template", type=Path, default=BASE_TEMPLATE, help="retail VPs and portable pilot data")
    parser.add_argument("--output-root", type=Path, default=ARTIFACTS.parent / "headless" / "runs")
    parser.add_argument("--pilot", default="Alver")
    parser.add_argument("--scenario", choices=SCENARIOS, default="default")
    parser.add_argument("--layout", choices=['circle','star','multi-circle'])
    parser.add_argument('--equal-economy', action='store_true', help='experimental equal starting CP and base income')
    parser.add_argument('--swap-slots', action='store_true', help='reverse an explicit two-faction matchup')
    parser.add_argument('--faction-choices', nargs='+', choices=FACTION_CHOICES, help='exact 2–12 faction identities in slot order; mirror factions allowed')
    parser.add_argument("--core", type=Path, default=None,
                        help="mod root to stage as `rts`; default is this mod's core. "
                             "Point it at a pre-change snapshot for a paired control.")
    parser.add_argument("--smoke", action="store_true",
                        help="run one 90 s match before returning, to prove the driver loads")
    args = parser.parse_args()

    if args.faction_choices is not None and (not 2<=len(args.faction_choices)<=12 or args.scenario!='default' or args.swap_slots):
        parser.error('Explicit faction choices require 2–12 identities, default scenario, and no slot swap')

    import re
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,39}", args.tag):
        parser.error("tag must be 1-40 letters, digits, hyphens or underscores")
    if args.matches<1 or args.workers<1 or args.sim_time<1:
        parser.error("matches, workers and sim-time must be positive")
    workers=min(args.workers,args.matches)
    if args.base_port<1024 or args.base_port+workers-1>65535:
        parser.error("base-port must leave one valid port per worker")
    if not args.pilot or args.pilot in {'.','..'} or any(c in args.pilot for c in '/\\'):
        parser.error("pilot must be a stored pilot name, not a path")
    for path, label in ((args.engine, "engine"), (args.runner, "runner"), (DRIVER, "driver"),
                        (HOOK, "hook"), (args.template, "base template")):
        if not path.exists():
            raise SystemExit(f"Missing {label}: {path}")
    core = args.core or TOOLS.parents[0]
    if args.swap_slots and 'blueFaction' not in SCENARIOS[args.scenario]:
        parser.error('--swap-slots requires an explicit two-faction matchup scenario')
    if not (core / "data" / "scripts" / "fs2rts.lua").is_file():
        raise SystemExit(f"Not a mod core: {core}")

    matches = args.matches
    # VP hardlinks need a shared volume; fail before creating a partial stage.
    if args.template.resolve().drive.lower()!=args.output_root.resolve().drive.lower():
        parser.error("template and output-root must share a volume")
    if not (args.template/'data/players'/(args.pilot+'.json')).is_file():
        parser.error("template is missing the selected pilot JSON")
    stage_root = args.output_root.resolve() / args.tag
    if stage_root.exists():
        raise SystemExit(f"Refusing to reuse existing stage: {stage_root}")
    stage_root.mkdir(parents=True)

    base = stage_root / "base"
    stage_base(base, core, args.template)
    setup_path=base/'probe/data/scripts/batch_setup.lua'
    setup_fields=write_batch_setup(setup_path,args.scenario,args.layout,args.equal_economy,args.swap_slots,args.faction_choices)

    pilots = [base / "data" / "players" / (args.pilot+'.json')]
    missing = [str(p) for p in pilots if not p.is_file()]
    if missing:
        raise SystemExit("Missing staged pilot files: " + ", ".join(missing))

    seed_start = args.seed_start or (20260929 * 100 + 1)
    plan = {
        "engine": str(args.engine.resolve()),
        "base_workspace": str(base),
        "output_dir": str(stage_root / "results"),
        "mission": MISSION,
        "mod": ["probe", "rts"],
        "pilot": args.pilot,
        "workers": workers,
        "repeats": matches,
        "seed_start": seed_start,
        "seed_lua_random": True,
        "base_port": args.base_port,
        "fixed_dt": 1.0 / 30.0,
        "max_sim_time": args.sim_time,
        "scenario": args.scenario, "setup": setup_fields, "setup_sha256": digest(setup_path),
        # Allow slow machines/contention; record wall timeouts separately from caps.
        "timeout_seconds": max(1800, int(args.sim_time * 1.2)),
        "candidates": [{"id": "current-mod", "params": {}}],
    }
    plan_path = stage_root / "batch.plan.json"
    plan_path.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    # Freeze the runner's real overlay transformation instead of duplicating it.
    import importlib.util
    spec = importlib.util.spec_from_file_location('rts_experiment_runner', args.runner)
    runner_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner_module)
    overlay_hash = runner_module.make_config_overlay(
        base / 'rts/data/scripts/fs2rts_config.lua', {}, stage_root / 'expected-config.lua')
    freeze = {
        "config_overlay_sha256": overlay_hash,
        "schema": 2, "input_manifest": manifest(base), "plan_sha256": digest(plan_path),
        "tag": args.tag, "mod_core": str(core.resolve()), "engine": str(args.engine.resolve()),
        "runner": str(args.runner.resolve()), "template": str(args.template.resolve()), "workers": workers,
        "engine_sha256": digest(args.engine), "runner_sha256": digest(args.runner),
        "driver_sha256": digest(DRIVER), "matches": matches,
        "seeds": [seed_start + i for i in range(matches)],
        "max_sim_time": args.sim_time,
    }
    (stage_root / "freeze.json").write_text(json.dumps(freeze, indent=2) + "\n", encoding="utf-8")
    (stage_root / "HOW-TO-HARVEST.txt").write_text(
        "Telemetry for each match:\n"
        f"  {plan['output_dir']}\\w\\<worker>\\a-<n>\\probe\\data\\rts-ai-*.jsonl\n\n"
        "Copy those .jsonl files somewhere durable before deleting this staging\n"
        "tree. tools/analyze_batch.py and tools/ai_matchmap.py read them from a\n"
        "directory of run folders containing probe/data/rts-ai-*.jsonl.\n",
        encoding="utf-8")

    print(f"Plan   : {plan_path}")
    print(f"Freeze : {stage_root / 'freeze.json'}")
    print(f"Matches: {matches}, workers {workers}, seeds {freeze['seeds'][0]}-{freeze['seeds'][-1]}")
    if args.smoke:
        print("No batch launched; running the smoke match first.")
        return smoke(stage_root, plan_path, args.runner)
    print("No simulation was launched.")
    return 0


def smoke(stage_root: Path, plan_path: Path, runner: Path = RUNNER) -> int:
    """Run one short match before the real batch.

    A driver that fails to load looks exactly like a fleet of crashes: the whole
    batch fails in seconds with no telemetry. Paying for a 60 s match first turns
    that into an immediate, readable failure.
    """
    import subprocess

    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    plan.update({"workers": 1, "repeats": 1, "max_sim_time": 90,
                 "timeout_seconds": 240, "base_port": plan["base_port"],
                 "output_dir": str(stage_root / "smoke")})
    smoke_plan = stage_root / "smoke.plan.json"
    smoke_plan.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    print(f"Smoke  : {smoke_plan} (1 match, 90 simulated seconds)")
    completed = subprocess.run([sys.executable, "-B", str(runner), str(smoke_plan)],
                               cwd=str(runner.parent.parent.parent))
    if completed.returncode != 0:
        print("SMOKE FAILED - fix the driver before launching a batch.", file=sys.stderr)
        return completed.returncode
    telemetry = sorted((stage_root / "smoke").rglob("rts-ai-*.jsonl"))
    if not telemetry:
        print("SMOKE FAILED - the run produced no telemetry.", file=sys.stderr)
        return 1
    from compare_batches import stream_match
    match = stream_match(telemetry[-1])
    if match['malformed'] or not match['sequence_valid'] or match['events']['ACCEPTANCE_SETUP'] != 1:
        print('SMOKE FAILED - missing scenario setup or corrupt telemetry.', file=sys.stderr)
        return 1
    print(f"Smoke ok: scenario started; {match['records']} telemetry records. No balance acceptance implied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
