"""Stage a headless RTS workspace from the CURRENT mod tree and write a run plan.

One match per worker. The workspace hardlinks the retail .vp files instead of
copying them, installs this mod as `rts`, and adds the acceptance driver as a
leading `probe` mod so a match ends naturally at the after-action screen rather
than being killed at the wall-clock limit.

    python tools/prepare_headless_batch.py --tag mylabel --matches 8
    python D:/Games/FreespaceOpen/src/fs2open/tools/rts_ai_experiments/run_batch.py <plan>

Staging is refused if the label already exists, so a label always identifies one
immutable workspace. Harvest the per-match telemetry
(results/w/*/a-*/probe/data/rts-ai-*.jsonl) before deleting the staging tree.
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
BASE_TEMPLATE = ARTIFACTS / "coordination-fixes-base-20260927"
ENGINE = ROOT / "src" / "fs2open" / "build" / "bin" / "Release" / "fs2_open_26_1_0_x64_AVX2.exe"
RUNNER = ROOT / "src" / "fs2open" / "tools" / "rts_ai_experiments" / "run_batch.py"
TOOLS = Path(__file__).resolve().parent
DRIVER = TOOLS / "acceptance_driver.lua"
HOOK = TOOLS / "ai-probe-sct.tbm"
MISSION = "FS2_RTS_Escalation"
EXCLUDE_DIRS = {"__pycache__", ".git", "staged", "node_modules"}


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
    for path in sorted(source.rglob("*")):
        rel = path.relative_to(source)
        if any(part in EXCLUDE_DIRS for part in rel.parts):
            continue
        target = destination / rel
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)


def stage_base(destination: Path, core: Path) -> None:
    if destination.exists():
        raise FileExistsError(f"Refusing to overwrite staged workspace: {destination}")
    destination.mkdir(parents=True)
    linked = 0
    for path in BASE_TEMPLATE.iterdir():
        if path.is_file() and path.suffix.lower() == ".vp":
            os.link(path.resolve(), destination / path.name)
            linked += 1
    if not linked:
        raise FileNotFoundError(f"No .vp files hardlinked from {BASE_TEMPLATE}")
    if (BASE_TEMPLATE / "data").is_dir():
        shutil.copytree(BASE_TEMPLATE / "data", destination / "data")
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="fresh immutable staging label")
    parser.add_argument("--matches", type=int, default=8, help="one match per worker")
    parser.add_argument("--sim-time", type=int, default=3000)
    parser.add_argument("--seed-start", type=int, default=0)
    parser.add_argument("--base-port", type=int, default=48000)
    parser.add_argument("--core", type=Path, default=None,
                        help="mod root to stage as `rts`; default is this mod's core. "
                             "Point it at a pre-change snapshot for a paired control.")
    parser.add_argument("--smoke", action="store_true",
                        help="run one 90 s match before returning, to prove the driver loads")
    args = parser.parse_args()

    for path, label in ((ENGINE, "engine"), (RUNNER, "runner"), (DRIVER, "driver"),
                        (HOOK, "hook"), (BASE_TEMPLATE, "base template")):
        if not path.exists():
            raise SystemExit(f"Missing {label}: {path}")
    core = args.core or TOOLS.parents[0]
    if not (core / "data" / "scripts" / "fs2rts.lua").is_file():
        raise SystemExit(f"Not a mod core: {core}")

    matches = max(1, args.matches)
    # Hardlinks cannot cross volumes, so staging must share a drive with the
    # base template. Keep it in a clearly named scratch area next to the mod
    # rather than inside the shared artifacts tree, which has been cleaned
    # underneath this work before and took the previous batch's evidence with it.
    stage_root = ROOT / "FS2" / "rts-headless-staging" / args.tag
    if stage_root.exists():
        raise SystemExit(f"Refusing to reuse existing stage: {stage_root}")
    stage_root.mkdir(parents=True)

    base = stage_root / "base"
    stage_base(base, core)

    pilots = [base / "data" / "players" / "Alver.json", base / "data" / "players" / "Alver.FreeSpace2.csg"]
    missing = [str(p) for p in pilots if not p.is_file()]
    if missing:
        raise SystemExit("Missing staged pilot files: " + ", ".join(missing))

    seed_start = args.seed_start or (20260929 * 100 + 1)
    plan = {
        "engine": str(ENGINE),
        "base_workspace": str(base),
        "output_dir": str(stage_root / "results"),
        "mission": MISSION,
        "mod": ["probe", "rts"],
        "pilot": "Alver",
        "workers": matches,
        "repeats": matches,
        "seed_start": seed_start,
        "seed_lua_random": True,
        "base_port": args.base_port,
        "fixed_dt": 1.0 / 30.0,
        "max_sim_time": args.sim_time,
        # Eight workers on four physical cores measured ~5x realtime, so 3000
        # simulated seconds needs a generous budget. An earlier plan used 0.4x
        # and the runner killed every match, which looked exactly like a crash.
        "timeout_seconds": max(1800, int(args.sim_time * 1.2)),
        "candidates": [{"id": "current-mod", "params": {}}],
    }
    plan_path = stage_root / "batch.plan.json"
    plan_path.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    freeze = {
        "tag": args.tag, "mod_core": str(core), "engine": str(ENGINE),
        "engine_sha256": digest(ENGINE), "runner_sha256": digest(RUNNER),
        "driver_sha256": digest(DRIVER), "matches": matches,
        "seeds": [seed_start + i for i in range(matches)],
        "max_sim_time": args.sim_time, "launched": False,
    }
    (stage_root / "freeze.json").write_text(json.dumps(freeze, indent=2) + "\n", encoding="utf-8")
    (stage_root / "HOW-TO-HARVEST.txt").write_text(
        "Telemetry for each match:\n"
        f"  {plan['output_dir']}\\w\\<worker>\\a-<n>\\probe\\data\\rts-ai-*.jsonl\n\n"
        "Copy those .jsonl files somewhere durable before deleting this staging\n"
        "tree. tools/analyze_batch.py and tools/plot_ai_maps.py read them from a\n"
        "directory of run folders containing probe/data/rts-ai-*.jsonl.\n",
        encoding="utf-8")

    print(f"Plan   : {plan_path}")
    print(f"Freeze : {stage_root / 'freeze.json'}")
    print(f"Matches: {matches} (one per worker), seeds {freeze['seeds'][0]}-{freeze['seeds'][-1]}")
    if args.smoke:
        print("No batch launched; running the smoke match first.")
        return smoke(stage_root, plan_path)
    print("No simulation was launched.")
    return 0


def smoke(stage_root: Path, plan_path: Path) -> int:
    """Run one short match before the real batch.

    A driver that fails to load looks exactly like a fleet of crashes: the whole
    batch fails in seconds with no telemetry. Paying for a 60 s match first turns
    that into an immediate, readable failure.
    """
    import subprocess

    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    plan.update({"workers": 1, "repeats": 1, "max_sim_time": 90,
                 "timeout_seconds": 240, "base_port": plan["base_port"] + 900,
                 "output_dir": str(stage_root / "smoke")})
    smoke_plan = stage_root / "smoke.plan.json"
    smoke_plan.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    print(f"Smoke  : {smoke_plan} (1 match, 90 simulated seconds)")
    completed = subprocess.run([sys.executable, "-B", str(RUNNER), str(smoke_plan)],
                               cwd=str(RUNNER.parent.parent.parent))
    if completed.returncode != 0:
        print("SMOKE FAILED - fix the driver before launching a batch.", file=sys.stderr)
        return completed.returncode
    telemetry = sorted((stage_root / "smoke").rglob("rts-ai-*.jsonl"))
    if not telemetry:
        print("SMOKE FAILED - the run produced no telemetry.", file=sys.stderr)
        return 1
    lines = sum(1 for _ in telemetry[-1].open(encoding="utf-8", errors="replace"))
    print(f"Smoke ok: {lines} telemetry records. Safe to launch the batch.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
