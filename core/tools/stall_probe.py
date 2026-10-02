"""Which groups stop closing on their objective, and are they actually stuck?

The CONTEST record flags a group whose range to its objective has not fallen by
150 m for 30 s. This separates a genuine stall (far away, holding an attack
mission, not moving) from a legitimate hold (already in contact, or close enough
that 150 m of progress is not meaningful) so the flag is not read as a bug it is
not.

    python tools/stall_probe.py <evidence-dir>
"""
import collections
import json
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else
            r"D:\Games\FreespaceOpen\FS2\RTS-fleet-command-artifacts\evidence\outcome02")

STALL = 60.0
far_stall = collections.Counter()
close_stall = collections.Counter()
in_contact = collections.Counter()
healthy = collections.Counter()
by_role = collections.Counter()
ranges = collections.defaultdict(list)

for run in sorted(p for p in root.iterdir() if p.is_dir()):
    files = sorted(run.glob("rts-ai-*.jsonl")) or sorted(run.rglob("rts-ai-*.jsonl"))
    if not files:
        continue
    for line in files[-1].open(encoding="utf-8", errors="replace"):
        if '"CONTEST"' not in line:
            continue
        try:
            record = json.loads(line)
        except Exception:
            continue
        if record.get("event") != "CONTEST":
            continue
        data = record.get("data") or {}
        for group in data.get("groups") or []:
            stalled = group.get("stalledSeconds") or 0
            rng = group.get("distance")
            role = group.get("role") or "?"
            mission = group.get("mission") or "?"
            label = f"{mission}/{role}"
            if rng is not None:
                ranges[label].append(rng)
            if stalled < STALL:
                healthy[label] += 1
                continue
            by_role[label] += 1
            if rng is None or rng > 3000:
                far_stall[label] += 1
            else:
                close_stall[label] += 1
            if rng is not None and rng < 1500:
                in_contact[label] += 1

print(f"stall threshold: {STALL:.0f} s without closing by 150 m")
print(f"{'mission/role':26} {'stalled':>9} {'far(>3km)':>10} {'near(<3km)':>11} "
      f"{'of which <1.5km':>17} {'median range':>13} {'healthy':>9}")
for label in sorted(set(by_role) | set(healthy)):
    values = sorted(ranges.get(label, []))
    median = values[len(values) // 2] if values else float("nan")
    print(f"{label:26} {by_role[label]:9} {far_stall[label]:10} {close_stall[label]:11} "
          f"{in_contact[label]:17} {median:13.0f} {healthy[label]:9}")

print()
total_far = sum(far_stall.values())
total_close = sum(close_stall.values())
print(f"stalled samples: {total_far + total_close}  "
      f"({100 * total_far / max(1, total_far + total_close):.0f}% genuinely far from the objective)")
print("A group flagged while already within 1.5 km of its objective is in contact:")
print("not closing on a defended point is expected there, not a stall.")
