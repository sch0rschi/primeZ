#!/usr/bin/env python3

"""
Per-sieve-tier primeZ vs. primesieve comparison.

primeZ's segmented sieve classifies each sieving prime into one of 5 tiers
(smallStride/smallSegment/medium/preLarge/large) purely by the prime's own magnitude,
using thresholds derived at build time from L1/L2 cache size (see
buildUtils/sieveLayoutMath.zig). Which tiers are "active" for a query is
decided entirely by sqrt(limit) - the window width (limit - start) only
controls how much work is done, not which tiers participate.

This script:
  1. Reads the *actual* build config straight from the primez binary's own
     printed "Sieve size" / "L1 stripe size" (not by reimplementing the
     build.zig formulas blind) and derives the 4 tier boundaries from it.
  2. For smallStride/smallSegment: uses the maximal available window (start=0,
     limit=threshold^2) - sqrt(limit) can't be pushed higher without
     leaving the tier, so the window (and thus runtime) is structurally
     capped. These almost never reach --target-seconds; that's expected,
     not a bug - see the tier-bench SKILL.md for why.
  3. For medium/preLarge/large: fixes limit = tier's own upper sqrt bound
     squared (large uses --large-multiplier x its lower bound instead,
     since large has no upper bound), then calibrates a start offset
     (start = limit - width) so the window width alone hits
     ~--target-seconds, via a few geometric-scaling primez runs.
  4. Runs primesieve on the *exact same* [start, limit] windows, checks
     the prime counts match, and prints a comparison table.

Usage:
  python3 bench/scripts/tier_bench.py [--target-seconds 10] [--tolerance 0.05]
      [--primez zig-out/bin/primez] [--primesieve bench/primesieve/build/primesieve]
      [--large-multiplier 10] [--only smallStride,smallSegment,medium,preLarge,large]

Run from the repo root (relative default paths assume that).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

SECONDS_RE = re.compile(r"Seconds:\s*([0-9.]+)")
PRIMES_RE = re.compile(r"Primes:\s*([0-9]+)")
SIEVE_SIZE_RE = re.compile(r"Sieve size = (\d+) KiB")
L1_SIZE_RE = re.compile(r"L1 stripe size = (\d+) KiB")


def run(argv: list[str]) -> str:
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"error: {' '.join(argv)} exited {result.returncode}\n{result.stderr}")
    return result.stdout + result.stderr


def floor_pow2_clamped(kib: int) -> int:
    kib = max(16, min(kib, 8192))
    return 1 << (kib.bit_length() - 1)


def detect_thresholds(primez_bin: str) -> dict[str, int]:
    out = run([primez_bin, "0", "100"])
    seg_kib = int(SIEVE_SIZE_RE.search(out).group(1))
    l1_kib = int(L1_SIZE_RE.search(out).group(1))
    stripe_elems = 1024 * min(l1_kib, seg_kib)
    segment_elems = 1024 * seg_kib
    return {
        "l1_kib": l1_kib,
        "seg_kib": seg_kib,
        "small_stride": stripe_elems // 5,
        "small_segment": segment_elems,
        "medium": segment_elems * 5,
        "pre_large": segment_elems * 15,
    }


def primez_run(primez_bin: str, start: int, limit: int) -> tuple[float, int]:
    out = run([primez_bin, str(start), str(limit)])
    return float(SECONDS_RE.search(out).group(1)), int(PRIMES_RE.search(out).group(1))


def primesieve_run(primesieve_bin: str, start: int, limit: int) -> tuple[float, int]:
    out = run([primesieve_bin, str(start), str(limit), "-t1", "--time", "--no-status"])
    return float(SECONDS_RE.search(out).group(1)), int(PRIMES_RE.search(out).group(1))


def calibrate_width(
    primez_bin: str,
    limit: int,
    target_seconds: float,
    tolerance: float,
    max_iters: int = 6,
) -> tuple[int, float, int]:
    """Find a window width (ending at `limit`) whose primez runtime is
    within `tolerance` of `target_seconds`. Returns (start, seconds, primes)
    for the final calibrated run."""
    width = min(limit, int(target_seconds * 5_000_000_000))  # generic ~5G/s starting guess
    seconds = primes = None
    for _ in range(max_iters):
        width = max(1, min(width, limit))
        start = limit - width
        seconds, primes = primez_run(primez_bin, start, limit)
        if seconds <= 0:
            width *= 4
            continue
        if abs(seconds - target_seconds) / target_seconds <= tolerance:
            return start, seconds, primes
        width = int(width * (target_seconds / seconds))
    return limit - width, seconds, primes


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target-seconds", type=float, default=10.0)
    ap.add_argument("--tolerance", type=float, default=0.05)
    ap.add_argument("--primez", default="zig-out/bin/primez")
    ap.add_argument("--primesieve", default="bench/primesieve/build/primesieve")
    ap.add_argument("--large-multiplier", type=float, default=10.0,
                     help="sqrt(limit) for the large scenario = this x the preLarge/large boundary")
    ap.add_argument("--only", default=None, help="comma-separated subset of smallStride,smallSegment,medium,preLarge,large")
    args = ap.parse_args()

    only = {s.strip() for s in args.only.split(",")} if args.only else None

    th = detect_thresholds(args.primez)
    print(f"# detected: L1={th['l1_kib']}KiB segment={th['seg_kib']}KiB", file=sys.stderr)
    print(
        f"# tier boundaries (sieving-prime magnitude): "
        f"smallStride<={th['small_stride']} smallSegment<={th['small_segment']} "
        f"medium<={th['medium']} preLarge<={th['pre_large']} large>{th['pre_large']}",
        file=sys.stderr,
    )

    tiers: list[dict] = []

    for name, sqrt_bound in [("smallStride", th["small_stride"]), ("smallSegment", th["small_segment"])]:
        if only and name not in only:
            continue
        limit = sqrt_bound * sqrt_bound
        seconds, primes = primez_run(args.primez, 0, limit)
        tiers.append({"name": name, "start": 0, "limit": limit, "pz_seconds": seconds, "pz_primes": primes, "capped": True})

    for name, sqrt_bound in [("medium", th["medium"]), ("preLarge", th["pre_large"])]:
        if only and name not in only:
            continue
        limit = sqrt_bound * sqrt_bound
        start, seconds, primes = calibrate_width(args.primez, limit, args.target_seconds, args.tolerance)
        tiers.append({"name": name, "start": start, "limit": limit, "pz_seconds": seconds, "pz_primes": primes, "capped": False})

    if not only or "large" in only:
        large_sqrt = int(th["pre_large"] * args.large_multiplier)
        limit = large_sqrt * large_sqrt
        start, seconds, primes = calibrate_width(args.primez, limit, args.target_seconds, args.tolerance)
        tiers.append({"name": "large", "start": start, "limit": limit, "pz_seconds": seconds, "pz_primes": primes, "capped": False})

    for t in tiers:
        print(f"== {t['name']}: [{t['start']}, {t['limit']}] ==", file=sys.stderr)
        ps_seconds, ps_primes = primesieve_run(args.primesieve, t["start"], t["limit"])
        if ps_primes != t["pz_primes"]:
            sys.exit(
                f"error: prime count MISMATCH for {t['name']} [{t['start']}, {t['limit']}]: "
                f"primeZ={t['pz_primes']} primesieve={ps_primes}"
            )
        t["ps_seconds"] = ps_seconds

    name_w = max(len(t["name"]) for t in tiers)
    range_w = max(len(f"[{t['start']}, {t['limit']}]") for t in tiers)

    header = f"{'tier':<{name_w}} | {'range [start, limit]':<{range_w}} | {'primeZ':>10} | {'primesieve':>10} | result"
    print()
    print(header)
    print("-" * len(header))
    for t in tiers:
        rng = f"[{t['start']}, {t['limit']}]"
        pz, ps = t["pz_seconds"], t["ps_seconds"]
        ratio = f"primeZ {ps / pz:.2f}x faster" if pz <= ps else f"primesieve {pz / ps:.2f}x faster"
        note = " (capped - see tier-bench SKILL.md)" if t["capped"] else ""
        print(f"{t['name']:<{name_w}} | {rng:<{range_w}} | {pz:>9.3f}s | {ps:>9.3f}s | {ratio}{note}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
