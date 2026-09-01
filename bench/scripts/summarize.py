#!/usr/bin/env python3
"""Normalizes a recording into a report cache, then prints its phase
breakdown (self-time by regex-matched symbol groups, see bench_lib.PHASES).

usage: summarize.py <tool> <recording> <total-seconds> <report-cache>

Stdlib only, no third-party dependencies.
"""

from __future__ import annotations

import sys
from pathlib import Path

from bench_lib import PHASES, extract_report, load_report, pct_to_seconds, phase_pct, write_report


def main() -> int:
    args = sys.argv[1:]
    if len(args) != 4:
        print(
            "usage: summarize.py <tool> <recording> <total-seconds> <report-cache>",
            file=sys.stderr,
        )
        return 1

    tool = args[0]
    recording = Path(args[1])
    total_seconds = float(args[2])
    report_cache = Path(args[3])

    if tool not in PHASES:
        print(f"error: unknown tool {tool!r} - expected one of {sorted(PHASES)}", file=sys.stderr)
        return 1

    if not recording.is_file():
        print(f"error: recording not found: {recording}", file=sys.stderr)
        return 1

    rows = extract_report(recording)
    write_report(rows, report_cache)
    rows = load_report(report_cache)

    phases = PHASES[tool]

    print(f"{'phase':<12} {'self%':>8} {'seconds':>10}")
    print(f"{'-----':<12} {'-----':>8} {'-------':>10}")

    matched_total = 0.0
    for label, regex in phases:
        pct = phase_pct(rows, regex)
        seconds = pct_to_seconds(pct, total_seconds)
        matched_total += pct
        print(f"{label:<12} {pct:>7.4f}% {seconds:>9.4f}s")

    other_pct = max(0.0, 100.0 - matched_total)
    other_seconds = pct_to_seconds(other_pct, total_seconds)
    print(f"{'other':<12} {other_pct:>7.4f}% {other_seconds:>9.4f}s")
    print(f"{'total':<12} {100.0:>7.4f}% {total_seconds:>9.4f}s")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
