"""Apply explicitly chosen metric directions to explicitly chosen batches.

This is a heuristic comparison, not a gameplay-quality or statistical certificate.
Exit 2 means missing criteria or insufficient/inconclusive evidence.
"""
import argparse
import os
import sys

import compare_batches


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate")
    parser.add_argument("--baseline", default=os.environ.get("RTS_GATE_BASELINE"))
    parser.add_argument("--metric", action="append", dest="metrics", required=True)
    parser.add_argument("--polarity", action="append", default=[], metavar="NAME=higher|lower")
    parser.add_argument("--json", dest="json_path")
    parser.add_argument('--until', type=float)
    args = parser.parse_args(argv)
    if not args.baseline:
        parser.error("choose --baseline or set RTS_GATE_BASELINE; there is no implicit historical baseline")
    arguments = [args.baseline, args.candidate, "--quiet"]
    if args.until is not None:
        arguments += ['--until', str(args.until)]
    for metric in args.metrics:
        arguments += ["--fail-on", metric]
    for direction in args.polarity:
        arguments += ["--polarity", direction]
    if args.json_path:
        arguments += ["--json", args.json_path]
    return compare_batches.main(arguments)


if __name__ == "__main__":
    sys.exit(main())
