"""Prove what a headless batch actually ran, before comparing its numbers.

A staged arm is a self-contained snapshot: `<arm>/base/rts/` holds the mod
that the engine loaded, and `<arm>/batch.plan.json` holds the seeds, worker
count and simulation cap. What it does NOT hold is the one fact every A/B in
this project actually turns on - which configuration flags and which code the
arm ran. `"candidates": [{"id": "current-mod", "params": {}}]` records no
parameters at all, so "this arm had CapitalAwareInvestment=true" is a claim
about the file contents that has to be re-derived by hand every single time.

Hand-deriving it is exactly how an arm gets compared against a baseline that
did not differ only in the intended knob. This tool makes it mechanical:

    python core/tools/staged_diff.py <baseline-arm> <candidate-arm>
    python core/tools/staged_diff.py <mod-core> <candidate-arm>
    python core/tools/staged_diff.py <baseline-arm> <candidate-arm> \
        --expect AI.CapitalAwareInvestment=true --expect AI.Doctrine.AssaultStaticDefenceLock=true
    python core/tools/staged_diff.py <baseline-arm> <candidate-arm> --require-clean

Exit codes: 0 clean, 1 an expectation was not met or --require-clean found a
difference, 2 the arguments do not describe two readable arms.

Design notes that matter for correctness:

* The snapshot is the authority, not the mod core the arm was copied from.
  freeze.json records `mod_core` as the directory the snapshot was taken FROM,
  which is the live repo - and the repo keeps moving after a batch is staged.
  Anyone diffing a staging tree against the live repo to work out what ran is
  comparing against whatever the next agent has since typed. So the baseline
  side is another arm's snapshot, not the repo. Passing a mod core as the
  baseline is still supported, but it answers the different question "has the
  repo drifted from this arm?", and it cannot compare batch plans at all,
  because a mod core has no plan or freeze file beside it.

* Config values are reported as resolved key paths (`AI.CapitalAwareInvestment`
  -> false -> true), not as a unified diff. A flag flip is a one-character
  change in a 1195-line file, which is invisible in a line diff and easy to
  miss in a hunk diff when the flag sits inside a 40-line comment block. The
  parser rebuilds the path from an indent stack, and reports the changed keys
  only; the file-level diff remains as the safety net for edits the parser
  cannot see (roster entries, whole-table rewrites, added or deleted keys).

* Plan and freeze deltas are reported because an arm that changed a flag AND
  a seed is not an A/B. Comparing metrics across different seeds or simulation
  caps produces differences that look like AI behaviour and are not; that
  mistake has already been made once in this project (a batch split into two
  disjoint duration clusters that a filtered comparison reported as a -52%
  spend change). `comparable: false` is the machine-readable form of that
  warning.

* Tools and caches inside the snapshot are excluded. The runner copies the
  whole mod core into the arm, including core/tools and its pytest cache, and
  those change for reasons that have nothing to do with the experiment.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

# Files under these names are copied into every arm by the runner but cannot
# affect a match: they are analysis code, not game code.
EXCLUDED_DIRS = ("tools", "__pycache__", ".pytest_cache", "results")
EXCLUDED_SUFFIXES = (".pyc",)

# Plan keys that make two arms comparable. Anything that changes the sample
# population or the amount of simulated time belongs here; `base_port` does
# not, because a port only has to be unique between concurrent runs.
PLAN_COMPARABILITY_KEYS = (
    "mission",
    "mod",
    "pilot",
    "workers",
    "repeats",
    "seed_start",
    "seed_lua_random",
    "fixed_dt",
    "max_sim_time",
)

FREEZE_COMPARABILITY_KEYS = (
    "engine_sha256",
    "runner_sha256",
    "driver_sha256",
    "matches",
    "max_sim_time",
)

_ASSIGNMENT = re.compile(
    r"^(?P<indent>[ \t]*)"
    r"(?P<key>[A-Za-z_]\w*)"
    r"[ \t]*=[ \t]*(?P<value>.+?)[ \t]*,?[ \t]*$")


class Absent:
    """A key that is not present, which is NOT the same as a nil value.

    An arm that adds a flag the baseline never had reports `<absent> -> true`,
    and an arm that deletes one reports `false -> <absent>`. Collapsing both
    into None would make adding a knob look like changing it to nil.
    """

    def __repr__(self):
        return "<absent>"

    def __eq__(self, other):
        return isinstance(other, Absent)


ABSENT = Absent()


def _split_assignments(text):
    """Split `a = 1, b = 2` into its parts, ignoring commas in strings.

    Lua allows several assignments on one line and this config uses that for
    every related cost knob, so treating the whole line as one value records
    `HullCostFraction` with the value ".35, AmmoCostFraction = .12" and never
    records `AmmoCostFraction` at all - which silently hides a changed knob.
    """
    parts, current, quote, i = [], [], None, 0
    while i < len(text):
        ch = text[i]
        if quote is not None:
            if ch == "\\" and i + 1 < len(text):
                current.append(text[i:i + 2])
                i += 2
                continue
            if ch == quote:
                quote = None
            current.append(ch)
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            current.append(ch)
            i += 1
            continue
        if ch == ",":
            parts.append("".join(current))
            current = []
            i += 1
            continue
        current.append(ch)
        i += 1
    if current:
        parts.append("".join(current))
    # Keep the leading indentation and drop only the trailing padding. The
    # indentation IS the nesting signal: a part stripped to column 0 pops the
    # whole table stack and reports every key on the line at the root.
    return [part.rstrip() for part in parts if part.strip()]


def parse_lua_scalars(text):
    """Return {name: [{"value":..., "line":...}, ...]} for a Lua file.

    Keys are bare assignment names, NOT reconstructed dotted paths. An earlier
    version rebuilt the path from an indent stack and was wrong on this very
    config: it reported `AI.StationReserveCap` for a key that lives under
    `Station.AI`, and reported the assault-doctrine flags at the root when the
    strategy code reads them from `AI.Doctrine`. A wrong path is worse than no
    path, because it makes --expect fail on a flag that is set correctly.

    A name assigned more than once (this config sets related cost knobs in more
    than one table) yields several entries; diff_config pairs them positionally
    and suffixes the report with `[n]`.
    """
    found = {}
    for number, raw in enumerate(text.splitlines(), start=1):
        line = strip_comment(raw)
        if not line.strip():
            continue
        for part in _split_assignments(line):
            # A line that opens an inline entry, as the sentry class lists do
            # (`{ class = "GTSG Watchdog", tier = 1, range = 11000 },`), hides
            # its FIRST assignment behind the opening brace. Without this the
            # class name itself is invisible to the diff.
            candidate = part.lstrip()
            if candidate.startswith("{"):
                candidate = candidate[1:].lstrip()
            match = _ASSIGNMENT.match(candidate)
            if not match:
                continue
            found.setdefault(match.group("key"), []).append(
                {"value": normalize_value(match.group("value")),
                 "line": number})
    return found


def strip_comment(line):
    """Drop a Lua `--` comment, ignoring `--` inside a quoted string.

    A naive `line.split('--')[0]` corrupts any value containing a double
    dash, and it would silently change the reported value of a key rather
    than failing, which is the failure mode this whole tool exists to remove.
    """
    out = []
    quote = None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote is not None:
            if ch == "\\" and i + 1 < len(line):
                out.append(line[i:i + 2])
                i += 2
                continue
            if ch == quote:
                quote = None
            out.append(ch)
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "-" and line[i + 1:i + 2] == "-":
            break
        out.append(ch)
        i += 1
    return "".join(out)


def normalize_value(raw):
    text = raw.strip()
    # An inline table entry leaves its closing brace on the last value, as in
    # `{ class = "GTSG Watchdog", range = 11000 }`. Reporting "11000 }" for a
    # number makes the diff unreadable on exactly the field a tuning change
    # turns on.
    if text.endswith("}"):
        text = text[:-1].rstrip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    return text


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 16), b""):
            digest.update(block)
    return digest.hexdigest()


def mod_dir_of(root):
    """Return the directory whose contents ARE the mod the engine loaded.

    An arm is `<arm>/base/<mod>/...`; the live repo core is
    `<core>/data/scripts/...`. Both are accepted so an arm can be compared
    against the repo, but the caller has to say which it wants.
    """
    root = Path(root)
    for candidate in (root / "base", root):
        for mod in ("rts", "probe"):
            probe = candidate / mod
            if (probe / "data" / "scripts").is_dir():
                return probe
    if (root / "data" / "scripts").is_dir():
        return root
    return None


def resolve_side(path):
    """Return (arm_root, mod_dir) for one side of the comparison.

    An arm root holds batch.plan.json and freeze.json BESIDE base/<mod>/, but
    every one of those three locations is a plausible thing for a person to
    type, so all of them are accepted: the arm root, `<arm>/base`, and
    `<arm>/base/<mod>`. Both sides must resolve the same way, because reading
    the plan from one side at depth N and the other at depth N+1 makes every
    plan field report as a delta against None - which reads as "not
    comparable" for arms that differ in exactly one flag.

    A mod core has no plan file at all, so the search falls back to the path
    itself; comparing a mod core against an arm then shows every plan field as
    absent on that side, which is the honest answer to a question that cannot
    be asked of a mod core.
    """
    path = Path(path)
    mod = None
    if (path / "base").is_dir():
        mod = mod_dir_of(path / "base")
    if mod is None:
        mod = mod_dir_of(path)
    for candidate in [path] + list(path.parents)[:3]:
        if (candidate / "batch.plan.json").is_file():
            return candidate, mod
    return path, mod


def snapshot_files(mod_root):
    """Map relative path -> sha256 for every game-affecting file."""
    out = {}
    for path in sorted(Path(mod_root).rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(mod_root)
        if any(part in EXCLUDED_DIRS for part in relative.parts):
            continue
        if relative.suffix in EXCLUDED_SUFFIXES:
            continue
        out[relative.as_posix()] = sha256_file(path)
    return out


def diff_snapshots(base_root, cand_root):
    base = snapshot_files(base_root)
    cand = snapshot_files(cand_root)
    changed, added, removed = [], [], []
    for path in sorted(set(base) | set(cand)):
        if path in base and path in cand:
            if base[path] != cand[path]:
                changed.append(path)
        elif path in cand:
            added.append(path)
        else:
            removed.append(path)
    return {"changed": changed, "added": added, "removed": removed,
            "base_file_count": len(base), "candidate_file_count": len(cand)}


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def _deltas(left, right, keys):
    out = {}
    for key in keys:
        before = left.get(key) if left else None
        after = right.get(key) if right else None
        if before != after:
            out[key] = {"baseline": before, "candidate": after}
    return out


def diff_json_docs(base_dir, cand_dir, filename, keys):
    return _deltas(read_json(Path(base_dir) / filename),
                   read_json(Path(cand_dir) / filename), keys)


def diff_config(base_root, cand_root):
    """Changed config assignments, with both values and both line numbers."""
    base_path = Path(base_root) / "data" / "scripts" / "fs2rts_config.lua"
    cand_path = Path(cand_root) / "data" / "scripts" / "fs2rts_config.lua"
    if not base_path.is_file() or not cand_path.is_file():
        return {"available": False, "changed": [],
                "baseline_path": str(base_path),
                "candidate_path": str(cand_path)}
    base = parse_lua_scalars(base_path.read_text(encoding="utf-8"))
    cand = parse_lua_scalars(cand_path.read_text(encoding="utf-8"))
    changed = []
    for name in sorted(set(base) | set(cand)):
        base_entries = base.get(name, [])
        cand_entries = cand.get(name, [])
        occurrences = max(len(base_entries), len(cand_entries))
        for index in range(occurrences):
            before = (base_entries[index]["value"]
                      if index < len(base_entries) else ABSENT)
            after = (cand_entries[index]["value"]
                     if index < len(cand_entries) else ABSENT)
            if before == after:
                continue
            label = name if occurrences == 1 else f"{name}[{index}]"
            entry = {"key": label, "baseline": before, "candidate": after}
            if index < len(base_entries):
                entry["baseline_line"] = base_entries[index]["line"]
            if index < len(cand_entries):
                entry["candidate_line"] = cand_entries[index]["line"]
            changed.append(entry)
    return {"available": True, "changed": changed,
            "assignment_count": sum(len(v) for v in base.values())}


def parse_expect(pairs):
    expected = {}
    for item in pairs or []:
        if "=" not in item:
            raise argparse.ArgumentTypeError(
                f"--expect expects key=value, got {item!r}")
        key, _, value = item.partition("=")
        expected[key.strip()] = value.strip()
    return expected


def build_report(base_dir, cand_dir, expect=None, require_clean=False):
    base_dir, cand_dir = Path(base_dir), Path(cand_dir)
    base_arm, base_mod = resolve_side(base_dir)
    cand_arm, cand_mod = resolve_side(cand_dir)
    if base_mod is None or cand_mod is None:
        return {"verdict": "unreadable", "baseline": str(base_arm),
                "candidate": str(cand_arm),
                "baseline_mod_dir": str(base_mod) if base_mod else None,
                "candidate_mod_dir": str(cand_mod) if cand_mod else None}

    files = diff_snapshots(base_mod, cand_mod)
    config = diff_config(base_mod, cand_mod)
    plan = diff_json_docs(base_arm, cand_arm, "batch.plan.json",
                          PLAN_COMPARABILITY_KEYS)
    freeze = diff_json_docs(base_arm, cand_arm, "freeze.json",
                            FREEZE_COMPARABILITY_KEYS)

    mismatches = []
    if expect:
        actual = {}
        if config.get("available"):
            for entry in config["changed"]:
                actual[entry["key"]] = entry["candidate"]
        for key, wanted in sorted(expect.items()):
            got = actual.get(key, ABSENT)
            if str(got) != wanted:
                mismatches.append({"key": key, "expected": wanted,
                                  "actual": got})
        # A changed key nobody declared is the more dangerous direction: it
        # means the arm differs from the baseline somewhere other than the
        # variable under test, so a metric delta cannot be attributed.
        undeclared = [entry["key"] for entry in config.get("changed", [])
                      if entry["key"] not in expect]

    verdict = "clean"
    if files["changed"] or files["added"] or files["removed"]:
        verdict = "differs"
    if config.get("changed"):
        verdict = "differs"
    if plan or freeze:
        verdict = "not-comparable" if verdict != "clean" else "not-comparable"
    if mismatches:
        verdict = "expectation-failed"

    return {
        "verdict": verdict,
        "baseline": str(base_arm),
        "candidate": str(cand_arm),
        "baseline_mod_dir": str(base_mod),
        "candidate_mod_dir": str(cand_mod),
        "plan_deltas": plan,
        "freeze_deltas": freeze,
        "files": files,
        "config": config,
        "expect": {"requested": expect or {}, "mismatches": mismatches,
                   "undeclared_changed_keys": undeclared if expect else []},
        "fail": bool(mismatches) or bool(require_clean and verdict != "clean"),
    }


def print_report(report, show_files=False):
    lines = []
    verdict = report["verdict"]
    lines.append(f"VERDICT {verdict}")
    lines.append(f"  baseline  {report['baseline']}")
    lines.append(f"  candidate {report['candidate']}")

    config = report.get("config", {})
    if config.get("available"):
        changed = config.get("changed", [])
        lines.append(f"  config keys differing: {len(changed)}")
        for entry in changed:
            where = ""
            if "baseline_line" in entry or "candidate_line" in entry:
                where = (f"  (line {entry.get('baseline_line', '-')} -> "
                         f"{entry.get('candidate_line', '-')})")
            lines.append(f"    {entry['key']}: "
                         f"{entry['baseline']!r} -> "
                         f"{entry['candidate']!r}{where}")
    elif "config" in report:
        lines.append("  config: NOT COMPARABLE, snapshot has no "
                     "fs2rts_config.lua")

    files = report.get("files")
    if files:
        lines.append(f"  files: {len(files['changed'])} changed, "
                     f"{len(files['added'])} added, "
                     f"{len(files['removed'])} removed "
                     f"({files['base_file_count']} vs "
                     f"{files['candidate_file_count']} files)")
        for path in files["changed"]:
            lines.append(f"    changed  {path}")
        for path in files["added"]:
            lines.append(f"    added    {path}")
        for path in files["removed"]:
            lines.append(f"    removed  {path}")
        if not show_files and files["changed"] and not config.get("changed"):
            lines.append("    (file changed with NO config key changed: this "
                         "is code or table data, not a flag)")

    for label, section in (("plan", report.get("plan_deltas")),
                           ("freeze", report.get("freeze_deltas"))):
        if section:
            lines.append(f"  {label} differs - arms are NOT like-for-like:")
            for key, pair in sorted(section.items()):
                lines.append(f"    {key}: {pair['baseline']!r} -> "
                             f"{pair['candidate']!r}")

    expect = report.get("expect") or {}
    for entry in expect.get("mismatches", []):
        lines.append(f"  EXPECT FAILED {entry['key']}: expected "
                     f"{entry['expected']!r}, actual {entry['actual']!r}")
    for key in expect.get("undeclared_changed_keys", []):
        lines.append(f"  UNDECLARED {key} also differs from the baseline")

    if report.get("fail"):
        lines.append("  FAIL")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Show exactly which code and flags a staged arm ran.")
    parser.add_argument("baseline",
                        help="staging arm directory, or a mod core to ask "
                             "'has the repo drifted from this arm?'")
    parser.add_argument("candidate", help="staging arm directory")
    parser.add_argument("--expect", action="append", metavar="KEY=VALUE",
                        help="assert this flag's value in the candidate; "
                             "repeatable. Fails if it does not match")
    parser.add_argument("--require-clean", action="store_true",
                        help="exit 1 if the arms differ in any way")
    parser.add_argument("--show-files", action="store_true",
                        help="list changed files even when a config key "
                             "changed (they are listed either way)")
    parser.add_argument("--json", dest="json_path", metavar="OUT",
                        help="write the full report as JSON")
    args = parser.parse_args(argv)

    try:
        expect = parse_expect(args.expect)
    except argparse.ArgumentTypeError as exc:
        parser.error(str(exc))
    if expect and args.require_clean:
        # --expect asserts that the candidate DIFFERS in a declared way, and
        # --require-clean asserts that it does not differ at all. Passing both
        # can only ever fail, which reads like a broken tool rather than a
        # contradictory request.
        parser.error("--expect and --require-clean contradict each other: the "
                     "first requires a declared difference, the second forbids "
                     "any difference")

    report = build_report(args.baseline, args.candidate, expect=expect,
                          require_clean=args.require_clean)
    if report["verdict"] == "unreadable":
        sys.stderr.write(
            "cannot locate a mod snapshot in both arguments:\n"
            f"  baseline  resolved to {report['baseline_mod_dir']}\n"
            f"  candidate resolved to {report['candidate_mod_dir']}\n")
        return 2

    print(print_report(report, show_files=args.show_files))
    if args.json_path:
        out = Path(args.json_path)
        if str(out.parent) not in ("", "."):
            out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2, sort_keys=True, default=str),
                       encoding="utf-8")
        print(f"wrote {out}")
    return 1 if report["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())