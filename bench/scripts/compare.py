#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
import sys

SECONDS_RE = re.compile(r"Seconds:\s*([0-9.]+)")
PRIMES_RE = re.compile(r"Primes:\s*([0-9]+)")

def run(argv: list[str]) -> tuple[float, int]:
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"error: {' '.join(argv)} exited with status {result.returncode}\n{result.stderr}", file=sys.stderr)
        raise SystemExit(1)

    output = result.stdout + result.stderr
    seconds_m = SECONDS_RE.search(output)
    primes_m = PRIMES_RE.search(output)
    if not seconds_m or not primes_m:
        print(f"error: couldn't parse output of {' '.join(argv)}:\n{output}", file=sys.stderr)
        raise SystemExit(1)
    return float(seconds_m.group(1)), int(primes_m.group(1))

def best_of(argv: list[str], repeats: int) -> tuple[float, int]:
    best_seconds: float | None = None
    primes: int | None = None
    for _ in range(repeats):
        seconds, p = run(argv)
        if primes is None:
            primes = p
        elif primes != p:
            print(f"error: prime count differs across repeats of {' '.join(argv)}: {primes} vs {p}", file=sys.stderr)
            raise SystemExit(1)
        if best_seconds is None or seconds < best_seconds:
            best_seconds = seconds
    assert best_seconds is not None and primes is not None
    return best_seconds, primes

def fmt_ratio(pz_seconds: float, ps_seconds: float) -> str:
    if pz_seconds <= ps_seconds:
        return f"primeZ {ps_seconds / pz_seconds:.2f}x faster"
    return f"primesieve {pz_seconds / ps_seconds:.2f}x faster"

def main() -> int:
    args = sys.argv[1:]
    if len(args) < 2:
        print(
            "usage: compare.py <primez-bin> <primesieve-bin> [--repeats N] [--only name,name,...] "
            "<name> <start> <limit> ...",
            file=sys.stderr,
        )
        return 1

    primez_bin, primesieve_bin = args[0], args[1]
    rest = args[2:]

    repeats = 1
    if rest[:1] == ["--repeats"]:
        repeats = int(rest[1])
        rest = rest[2:]

    only: set[str] | None = None
    if rest[:1] == ["--only"]:
        only = {name.strip() for name in rest[1].split(",") if name.strip()}
        rest = rest[2:]

    if not rest or len(rest) % 3 != 0:
        print("error: scenarios must come in <name> <start> <limit> triples", file=sys.stderr)
        return 1

    scenarios = [(rest[i], int(rest[i + 1]), int(rest[i + 2])) for i in range(0, len(rest), 3)]
    if only is not None:
        unknown = only - {name for name, _, _ in scenarios}
        if unknown:
            print(f"error: --only names not in the scenario list: {sorted(unknown)}", file=sys.stderr)
            return 1
        scenarios = [s for s in scenarios if s[0] in only]

    rows: list[tuple[str, int, int, float, float]] = []
    for name, start, limit in scenarios:
        print(f"== {name}: [{start}, {limit}] ==", file=sys.stderr)
        pz_seconds, pz_primes = best_of([primez_bin, str(start), str(limit)], repeats)
        ps_seconds, ps_primes = best_of(
            [primesieve_bin, str(start), str(limit), "-t1", "--time", "--no-status"], repeats
        )
        if pz_primes != ps_primes:
            print(
                f"error: prime count MISMATCH for scenario {name!r} [{start}, {limit}]: "
                f"primeZ={pz_primes} primesieve={ps_primes}",
                file=sys.stderr,
            )
            return 1
        rows.append((name, start, limit, pz_seconds, ps_seconds))

    name_w = max([len(n) for n, *_ in rows] + [len("scenario")])
    range_w = max([len(f"[{s}, {l}]") for _, s, l, _, _ in rows] + [len("range")])

    header = f"{'scenario':<{name_w}} | {'range':<{range_w}} | {'primeZ':>10} | {'primesieve':>10} | result"
    print()
    print(header)
    print("-" * len(header))
    for name, start, limit, pz_seconds, ps_seconds in rows:
        rng = f"[{start}, {limit}]"
        print(
            f"{name:<{name_w}} | {rng:<{range_w}} | {pz_seconds:>9.3f}s | {ps_seconds:>9.3f}s | "
            f"{fmt_ratio(pz_seconds, ps_seconds)}"
        )

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
