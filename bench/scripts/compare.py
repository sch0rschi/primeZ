#!/usr/bin/env python3
"""Prints the primeZ vs. primesieve vs. primal side-by-side phase table from
cached report files (see summarize.py).

usage: compare.py <pz-report> <pz-total> <ps-report> <ps-total> [<primal-total>] [<primal-report>]

Stdlib only, no third-party dependencies.
"""

from __future__ import annotations

import sys
from pathlib import Path

from bench_lib import PHASES, load_report, pct_to_seconds, phase_pct

LW, PW, SW, RW, PRW = 11, 8, 9, 12, 13
GROUP_W = PW + 1 + SW
PS_GROUP_W = GROUP_W + 3 + RW
PRIMAL_GROUP_W = GROUP_W + 3 + PRW


def fmt_pct(p: float) -> str:
    return f"{p:.1f}%"


def fmt_sec(s: float) -> str:
    return f"{s:.2f}s"


def ratio(a: float, b: float | None) -> str:
    if not b:
        return "-"
    return f"{a / b:.2f}x"


def row(label: str, pz_pct: float, ps_pct: float, pz_total: float, ps_total: float,
        primal_pct: float | None = None, primal_seconds: float | None = None) -> str:
    pzs = pct_to_seconds(pz_pct, pz_total)
    pss = pct_to_seconds(ps_pct, ps_total)
    r = ratio(pzs, pss)
    if primal_pct is not None and primal_seconds is not None:
        primal_col = f"{fmt_pct(primal_pct):>{PW}} {fmt_sec(primal_seconds):>{SW}}"
        primal_r = ratio(pzs, primal_seconds)
    else:
        primal_col = f"{'-':>{PW}} {'-':>{SW}}"
        primal_r = "-"
    return (
        f"{label:<{LW}} | {fmt_pct(pz_pct):>{PW}} {fmt_sec(pzs):>{SW}} | "
        f"{fmt_pct(ps_pct):>{PW}} {fmt_sec(pss):>{SW}}   {r:>{RW}} | "
        f"{primal_col}   {primal_r:>{PRW}}"
    )


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 4:
        print(
            "usage: compare.py <pz-report> <pz-total> <ps-report> <ps-total> [<primal-total>] [<primal-report>]",
            file=sys.stderr,
        )
        return 1

    pz_report, pz_total = Path(args[0]), float(args[1])
    ps_report, ps_total = Path(args[2]), float(args[3])
    primal_total = float(args[4]) if len(args) > 4 and args[4].strip() else None
    primal_report = Path(args[5]) if len(args) > 5 and args[5].strip() else None

    for f in (pz_report, ps_report):
        if not f.is_file():
            print(f"error: report cache not found: {f} (run summarize.py first)", file=sys.stderr)
            return 1

    pz_rows = load_report(pz_report)
    ps_rows = load_report(ps_report)

    pz_phases = dict(PHASES["primez"])
    ps_phases = dict(PHASES["primesieve"])

    pz_presieve = phase_pct(pz_rows, pz_phases["presieve"])
    pz_small = phase_pct(pz_rows, pz_phases["small"])
    pz_medium = phase_pct(pz_rows, pz_phases["medium"])
    pz_large = phase_pct(pz_rows, pz_phases["large"])
    pz_collecting = phase_pct(pz_rows, pz_phases["collecting"])
    pz_other = max(0.0, 100.0 - (pz_presieve + pz_small + pz_medium + pz_large + pz_collecting))

    ps_presieve = phase_pct(ps_rows, ps_phases["presieve"])
    ps_small = phase_pct(ps_rows, ps_phases["small"])
    ps_medium = phase_pct(ps_rows, ps_phases["medium"])
    ps_large = phase_pct(ps_rows, ps_phases["large"])
    ps_collecting = phase_pct(ps_rows, ps_phases["collecting"])
    ps_other = max(0.0, 100.0 - (ps_presieve + ps_small + ps_medium + ps_large + ps_collecting))

    primal_collecting_pct = None
    primal_collecting_seconds = None
    if primal_report is not None and primal_total is not None and primal_report.is_file():
        primal_rows = load_report(primal_report)
        primal_phases = dict(PHASES["primal"])
        primal_collecting_pct = phase_pct(primal_rows, primal_phases["collecting"])
        primal_collecting_seconds = pct_to_seconds(primal_collecting_pct, primal_total)

    def dashes(n: int) -> str:
        return "-" * n

    print(f"{'':<{LW}} | {'primeZ':<{GROUP_W}} | {'primesieve':<{PS_GROUP_W}} | {'primal':<{PRIMAL_GROUP_W}}")
    print(
        f"{'phase':<{LW}} | {'self%':>{PW}} {'seconds':>{SW}} | "
        f"{'self%':>{PW}} {'seconds':>{SW}}   {'primeZ/ps':>{RW}} | "
        f"{'self%':>{PW}} {'seconds':>{SW}}   {'primeZ/primal':>{PRW}}"
    )
    print(
        f"{dashes(LW):<{LW}} | {dashes(PW):>{PW}} {dashes(SW):>{SW}} | "
        f"{dashes(PW):>{PW}} {dashes(SW):>{SW}}   {dashes(RW):>{RW}} | "
        f"{dashes(PW):>{PW}} {dashes(SW):>{SW}}   {dashes(PRW):>{PRW}}"
    )
    print(row("presieve", pz_presieve, ps_presieve, pz_total, ps_total))
    print(row("small", pz_small, ps_small, pz_total, ps_total))
    print(row("medium", pz_medium, ps_medium, pz_total, ps_total))
    print(row("large", pz_large, ps_large, pz_total, ps_total))
    print(row("collecting", pz_collecting, ps_collecting, pz_total, ps_total,
               primal_collecting_pct, primal_collecting_seconds))
    print(row("other", pz_other, ps_other, pz_total, ps_total))
    print(
        f"{dashes(LW):<{LW}} | {dashes(PW):>{PW}} {dashes(SW):>{SW}} | "
        f"{dashes(PW):>{PW}} {dashes(SW):>{SW}}   {dashes(RW):>{RW}} | "
        f"{dashes(PW):>{PW}} {dashes(SW):>{SW}}   {dashes(PRW):>{PRW}}"
    )
    print(row("total", 100.0, 100.0, pz_total, ps_total,
               100.0 if primal_total is not None else None, primal_total))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
