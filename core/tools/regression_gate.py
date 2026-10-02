#!/usr/bin/env python3
"""One-command regression gate for headless AI batches.

Every change to the AI is supposed to be measured against a baseline, not
asserted in a commit message. This wraps compare_batches.py with the metric set
that has proven to move in practice, so a batch can be graded with a single
command and a non-zero exit.

The metrics below are gated on the polarity each one DECLARES in
compare_batches.METRICS. Do not override polarity here: a metric whose true
direction is unknown should have its polarity corrected in that table, with the
evidence, rather than being silently flipped per-invocation.

    python regression_gate.py <candidate-batch-dir>
    python regression_gate.py <candidate> --baseline <dir> --metric cp_spend_rate

Exit codes: 0 = no gated metric regressed, 1 = at least one did.
The candidate must have completed the same simulated duration as the baseline;
compare_batches reports disjoint duration ranges and the gate refuses to grade
totals that are not comparable.
"""

import argparse
import os
import sys

import compare_batches

# Metric keys that have moved in real batches and are worth refusing a merge
# over. Each carries its declared polarity in compare_batches.METRIC_BY_KEY.
# Do not override polarity here: a metric whose true direction is unknown should
# have its polarity corrected in that table, with the evidence, rather than
# being silently flipped per-invocation.
#
# sentry_builds is deliberately NOT listed. Its declared polarity is 'none',
# because the direction is not established. The apparent collapse (14.5 -> 2 per
# match) was a SYMPTOM, not a judgement on sentries: the same change that drove
# it also livelocked the saving clock, and the fleet ended up building no
# capital, heavy or juggernaut at all. Gating it now would encode an unverified
# belief or pass silently. Add it once the producer is fixed and the direction
# is measured against a fleet that can actually field hulls worth losing.
GATED_METRICS = (
    "decision_switch_rate",   # lower - an AI that thrashes orders is broken
    "cp_spend_rate",          # higher - a dead economy is the blackout failure
    "build_purchase_rate",    # higher - the production-starvation symptom
    "idle_mean",              # lower  - hulls with nothing to do
    "idle_fraction_mean",     # lower  - idle ships as a share of the fleet
    "station_hull_final_frac",  # higher - did the base survive
    "station_hull_min_frac",    # higher - worst-match base health
    "exec_idle_mode_rate",    # lower  - ships parked in IDLE execution mode
)


def _default_baseline():
    env = os.environ.get("RTS_GATE_BASELINE")
    if env:
        return env
    root = r"D:\Games\FreespaceOpen\FS2\rts-headless-staging"
    return os.path.join(root, "session-fix-20260930")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Grade a headless batch against a baseline and fail on regressions.")
    parser.add_argument("candidate", help="candidate batch directory")
    parser.add_argument("--baseline", default=_default_baseline(),
                        help="baseline batch directory (or set RTS_GATE_BASELINE)")
    parser.add_argument("--metric", action="append", dest="metrics",
                        help="gate on this metric instead of the default set; repeatable")
    parser.add_argument("--json", dest="json_path",
                        help="write the full machine-readable report here")
    args = parser.parse_args(argv)

    metrics = tuple(args.metrics) if args.metrics else GATED_METRICS

    unknown = [m for m in metrics if m not in compare_batches.METRIC_BY_KEY]
    if unknown:
        print("unknown metric key(s): %s" % ", ".join(sorted(unknown)), file=sys.stderr)
        print("run compare_batches.py --list-metrics for valid keys", file=sys.stderr)
        return 2

    # A metric whose polarity is 'none' can never fail its gate. Silently
    # passing is worse than not gating: it reads as a clean bill of health for a
    # number nobody agreed the direction of. Refuse instead.
    unpolarised = [m for m in metrics
                   if getattr(compare_batches.METRIC_BY_KEY[m], "polarity", "none") in (None, "none")]
    if unpolarised:
        print("refusing to gate metric(s) with no declared polarity: %s"
              % ", ".join(sorted(unpolarised)), file=sys.stderr)
        print("these cannot fail a gate; establish the expected direction in", file=sys.stderr)
        print("compare_batches.METRIC_BY_KEY with evidence, then gate them.", file=sys.stderr)
        return 2

    argv_out = [args.baseline, args.candidate, "--quiet"]
    for m in metrics:
        argv_out += ["--fail-on", m]
    if args.json_path:
        argv_out += ["--json", args.json_path]

    print("gate: %d metric(s), baseline=%s" % (len(metrics), args.baseline))
    print("      candidate=%s" % args.candidate)
    code = compare_batches.main(argv_out)
    if code == 0:
        print("GATE PASS: no gated metric regressed")
    else:
        print("GATE FAIL: see the failing rows above")
    return code


if __name__ == "__main__":
    sys.exit(main())
