#!/usr/bin/env python3
"""Solves primeZ's presieve grouping (src/lib/sieveEngine/preSieve.zig's
GROUPS) as a 1D bin-packing problem.

Each group's period - the size of its precomputed AND-pattern buffer - is
the *product* of the primes assigned to it. The constraint "a group's
buffer must fit within CAP bytes" is therefore multiplicative:

    product(primes in group) <= cap

The log trick turns that into an additive constraint by taking log2 of
every prime and of the cap:

    sum(log2(p) for p in group) <= log2(cap)

which is exactly a 1D bin-packing instance: item sizes = log2(p), bin
capacity = log2(cap). Fewer bins is the objective, because every extra
group is one more full-range AND-pass in preSieve.fill()'s hot combine
loop (see the bench findings that motivated this) - so unlike textbook
bin packing where "fewest bins" is just the natural framing, here it is
also the actual performance metric that matters, distinct from and in
addition to keeping each bin within the cache-resident byte cap.

Solved exactly (or, for `cover`, best-effort within a time limit) with
Google OR-Tools' CP-SAT solver (a constraint/integer programming solver,
not a hand-rolled search). Four objectives, chosen with --objective:

  mincount (default): fewest bins under a --cap-kib byte cap. Standard
  bin-packing MIP - x[i,b] = 1 if item i is in bin b, y[b] = 1 if bin b
  is used at all, one-item-per-bin and per-bin-capacity constraints,
  minimize sum(y).

  balance: exactly --num-bins bins (no cap), minimizing RMS deviation of
  bin sizes from their mean. Since bin count and total size are both
  fixed here, the mean is fixed too, so minimizing sum((load_b-mean)^2)
  is equivalent to minimizing sum(load_b^2) - a plain sum-of-squares
  CP-SAT can optimize directly via AddMultiplicationEquality.

  minmax: exactly --num-bins bins (no cap), minimizing the single largest
  bin (makespan / "shortest longest bitmask"). A plain linear objective
  (a variable every load is constrained <=, minimized) rather than
  balance's quadratic one, so it typically solves much faster.

  maxmin: exactly --num-bins bins (no cap), maximizing the single
  *smallest* bin ("longest shortest bitmask" - the dual of minmax, same
  linear-objective shape but maximizing a variable every load is
  constrained >=). This is the one that actually targets fill()'s hot
  loop directly: chunk size there is min(remaining-period) across *all*
  groups at once (see GROUP_COUNT's inline for in preSieve.zig's fill()),
  so the smallest group's period - not the largest - is what caps the
  vectorized step size. minmax shrinks the largest bin but leaves the
  smallest wherever the partition happens to put it; maxmin pushes the
  smallest bin up directly, which is the quantity that actually gates
  throughput.

  maxcoverage: exactly --num-bins bins, each hard-capped at --cap-kib (e.g.
  the segment length, not the L1-target 32 KiB default), maximizing how
  many primes get pre-sieved at all - candidates aren't limited to the
  traditional 7..97 set, they extend past it (see EXTENDED_CANDIDATE_PRIMES)
  so the solver can pull in more/larger primes wherever there's still
  room under the cap. Every additional prime pre-sieved here is one fewer
  prime segmentIterator.zig has to track as an actual "small sieving
  prime" (with its own per-segment, per-stripe crossing-off cost) -
  distinct from mincount/balance/minmax/maxmin/cover, which all take the
  22-prime set as fixed and only vary how it's grouped.

  costmodel: no fixed bin count or fixed candidate set - both are decision
  variables, jointly optimized against a single objective built from
  primeZ's actual segmentIterator.zig/preSieve.zig structure rather than
  a proxy like "fewest bins" or "most primes":

    minimize  GROUP_COST * (bins used) + sum over EXCLUDED candidates of PRIME_COST(p)

  GROUP_COST is fill()'s hot loop: every byte of the *entire* sieve range
  gets AND'd once per group, vectorized VEC_LEN-wide, so one more group
  costs (total_bytes / VEC_LEN) vector-AND ops.

  PRIME_COST(p) is what leaving p un-presieved costs for its whole active
  lifetime as a tracked "small sieving prime" in segmentIterator.zig: its
  crossing-off work is applySievePrimeIntoSegment's wheel-cycle loop, run
  total_bytes/(WHEEL_CIRCUMFERENCE*p) times, each doing
  ADMISSIBLE_RESIDUES_COUNT scalar masked read-modify-write stores - so
  PRIME_COST(p) = HIT_COST_MULTIPLIER * ADMISSIBLE_RESIDUES_COUNT /
  (WHEEL_CIRCUMFERENCE * p) vector-AND-equivalent ops (a per-stripe
  "is this prime active yet" check, paid every stripe of the *entire*
  remaining sieve regardless of hit count, is a second, much smaller term
  - negligible here since STRIPE_ELEMS is large relative to any candidate
  prime's period, so it's dropped).

  Both are expressed in the same unit (one VEC_LEN-wide vector-AND op),
  so they're directly comparable - GROUP_COST falls straight out of
  VEC_LEN (an empirical fact of this build/CPU, see EXPECTED_VEC_LEN);
  PRIME_COST needs one extra assumption, HIT_COST_MULTIPLIER: how many
  vector-AND-op-equivalents one scalar masked store really costs. That
  can't be derived the same way (no comptime constant for it) - 1.0
  would mean "exactly as cheap as one lane of a vector op", which
  undersells a real scalar RMW to a semi-strided address; this module
  defaults it to 6.0 as a deliberately-labeled estimate, overridable with
  --hit-cost-multiplier. sum(log2(p) for p in group) <= log2(cap) is
  still enforced per bin (the same multiplicative-buffer-size constraint
  every other objective respects), and the same no-gaps rule as
  maxcoverage applies (a prime can only be excluded if every larger
  candidate is too) - here it's not just a symmetry break, it falls
  straight out of PRIME_COST(p) being strictly decreasing in p, so the
  model would never rationally want to skip a cheaper-to-exclude larger
  prime in favor of a pricier-to-exclude smaller one.

  cover: exactly --num-bins bins, every item covered at least once but
  NOT a partition - an item may additionally, redundantly appear in more
  than one bin (harmless for preSieve.zig's correctness: a prime's
  multiples being cleared by more than one group's pattern is idempotent).
  Minimizes sum((load_b - target)^2) where target = log2(--cap-kib), i.e.
  pulls every bin's log2 total toward a fixed target instead of toward
  each other's average. The motivating idea: fill()'s combine loop
  advances by min(remaining-period) across *all* groups at once, so a
  couple of groups much smaller than the rest (as `balance`/`mincount`
  both produce, given only 22 primes split unevenly across 8 bins) drag
  down that shared step size - padding the small groups with redundant
  already-used primes purely to lengthen them might help even though it
  adds no new presieve coverage.

  All four objectives are computed in log2-space (the log trick above)
  because the underlying constraint/quantity being capped/balanced/capped
  is multiplicative. That means `balance`/`minmax`/`cover` find the
  partition/cover with the most equal (or smallest-largest) *ratios*/
  orders of magnitude - not necessarily the most equal *byte counts*: by
  Jensen's inequality (exp is convex), a log2-optimal result can still
  show real spread in raw byte sizes. See report()'s side-by-side
  byte-space vs log2-space RMS for both numbers.

CP-SAT works over integers, so sizes are scaled and rounded (see SCALE
below); every returned bin's *exact* integer product is re-checked
against the real byte cap afterward (mincount only) as a safety net
against that rounding.

usage: solve.py [--objective mincount|balance|minmax|maxmin|maxcoverage|costmodel|cover] [--cap-kib 32] [--num-bins 8] [--primes 7,11,13,...]

Requires the `ortools` package (mincount/balance/minmax/maxmin/maxcoverage/
cover) and `highspy` (costmodel, solved as a MILP via HiGHS - pinned to an
exact version, see requirements.txt for why) - see requirements.txt / README
(run via `make solve`, which creates a venv and installs everything
automatically).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import time
from pathlib import Path

from ortools.sat.python import cp_model

# log2(p) values are scaled to integers at this resolution before being
# handed to CP-SAT (which requires integer coefficients). log2 of the
# primes/cap involved here is O(1-20), so 1e6 leaves ~6 significant
# digits of headroom - far finer than the exact-product safety check in
# main() would ever let slip through.
SCALE = 1_000_000

# The primes currently grouped by preSieve.zig's GROUPS (all primes from
# 7 up to 97 - the ones the mod-30 wheel doesn't already remove and that
# primesieve's own design presieves).
DEFAULT_PRIMES = [7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97]


def sieve_primes(limit: int) -> list[int]:
    """Plain sieve of Eratosthenes, primes in [2, limit] inclusive."""
    is_prime = [True] * (limit + 1)
    is_prime[0:2] = [False, False]
    for p in range(2, math.isqrt(limit) + 1):
        if is_prime[p]:
            for multiple in range(p * p, limit + 1, p):
                is_prime[multiple] = False
    return [p for p in range(2, limit + 1) if is_prime[p]]


# Structural constants for --objective costmodel, read straight out of
# this build/machine rather than guessed:
#   - WHEEL_CIRCUMFERENCE=30, ADMISSIBLE_RESIDUES_COUNT=8: the mod-30
#     wheel (primes 2,3,5) - see buildUtils/wheelShape.zig. phi(30)=8.
#   - EXPECTED_VEC_LEN=64: std.simd.suggestVectorLength(u8) on this
#     machine (AVX-512, confirmed by running it) - preSieve.zig's fill()
#     ANDs this many bytes per group per vector instruction. Override
#     with --vec-len if solving for a different target.
WHEEL_CIRCUMFERENCE = 30
ADMISSIBLE_RESIDUES_COUNT = 8
EXPECTED_VEC_LEN = 64

# Candidate pool for --objective maxcoverage: not capped at 97 like
# DEFAULT_PRIMES - deliberately extends further so the solver can pack in
# more/larger primes wherever a --cap-kib big enough (e.g. the segment
# length) leaves room. 2000 is comfortably past anything a realistic
# per-group cap could ever fit (log2(2000) =~ 11 bits, so even a generous
# 8 MiB/group cap - log2 =~ 23 bits - couldn't average much past ~2000
# with 8 bins), so this is a "more than enough" bound, not a tuned one.
EXTENDED_CANDIDATE_PRIMES = [p for p in sieve_primes(2000) if p >= 7]

EPS = 1e-9


def first_fit_decreasing(sizes: list[float], capacity: float) -> list[list[int]]:
    """Returns an initial (not necessarily optimal) bin assignment, as a
    list of bins each holding indices into `sizes`, sorted descending."""
    order = sorted(range(len(sizes)), key=lambda i: -sizes[i])
    bins_remaining: list[float] = []
    bins_content: list[list[int]] = []
    for i in order:
        s = sizes[i]
        placed = False
        for b in range(len(bins_remaining)):
            if bins_remaining[b] >= s - EPS:
                bins_remaining[b] -= s
                bins_content[b].append(i)
                placed = True
                break
        if not placed:
            bins_remaining.append(capacity - s)
            bins_content.append([i])
    return bins_content


def solve_bin_packing(sizes: list[float], capacity: float) -> tuple[int, list[list[int]]]:
    """Exact minimum-bin-count solver, via OR-Tools CP-SAT. Returns
    (bin_count, bins), where `bins` is a list of bins holding indices
    into `sizes`."""
    n = len(sizes)

    # Sort descending: makes the symmetry-breaking constraints below
    # (largest item -> bin 0) meaningful and shrinks the search space.
    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    int_sizes = [round(s * SCALE) for s in sizes_sorted]
    int_cap = math.floor(capacity * SCALE)  # floor: never round the cap up

    # FFD gives a valid upper bound on the bins needed, which both sizes
    # the model (one y/x set of variables per candidate bin) and seeds
    # CP-SAT's search with a decent starting solution. Run on the
    # already-sorted sizes so its returned indices line up with x[i]'s
    # sorted-order indexing below.
    ffd_bins = first_fit_decreasing(sizes_sorted, capacity)
    upper_bound = len(ffd_bins)

    model = cp_model.CpModel()
    # Standard bin-packing symmetry break: bins are otherwise fully
    # interchangeable, so canonically require item i (0-indexed, already
    # sorted descending) to land in a bin no higher than i - with fewer
    # than i+1 items placed, no canonical labeling could have opened more
    # than i+1 distinct bins yet. This also shrinks the variable count
    # (x[i][b] only exists for b <= min(i, upper_bound-1)).
    x = [[model.NewBoolVar(f"x_{i}_{b}") for b in range(min(i, upper_bound - 1) + 1)] for i in range(n)]
    y = [model.NewBoolVar(f"y_{b}") for b in range(upper_bound)]

    for i in range(n):
        model.AddExactlyOne(x[i])

    for b in range(upper_bound):
        items_reaching_b = [i for i in range(n) if b < len(x[i])]
        model.Add(sum(int_sizes[i] * x[i][b] for i in items_reaching_b) <= int_cap)
        model.Add(sum(x[i][b] for i in items_reaching_b) <= n * y[b])

    # More symmetry breaking: bins used in order (no gaps between used
    # bins), and bin loads non-increasing (further collapses equivalent
    # relabelings of same-sized bins).
    for b in range(upper_bound - 1):
        model.Add(y[b] >= y[b + 1])
        load_b = sum(int_sizes[i] * x[i][b] for i in range(n) if b < len(x[i]))
        load_b1 = sum(int_sizes[i] * x[i][b + 1] for i in range(n) if b + 1 < len(x[i]))
        model.Add(load_b >= load_b1)

    model.Minimize(sum(y))

    # (A warm-start hint from the FFD solution would help here, but
    # CpModel.add_hint is broken in the installed ortools release - it
    # raises even via its native snake_case API, unrelated to anything
    # above. The symmetry-breaking constraints already carry the load.)

    solver = cp_model.CpSolver()
    solver.parameters.num_search_workers = 8
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        raise RuntimeError(f"CP-SAT could not solve the model (status={solver.StatusName(status)})")
    if status != cp_model.OPTIMAL:
        print(f"warning: CP-SAT hit its limit before proving optimality (status={solver.StatusName(status)})")

    bins = []
    for b in range(upper_bound):
        if solver.Value(y[b]):
            bins.append([order[i] for i in range(n) if b < len(x[i]) and solver.Value(x[i][b])])

    return len(bins), bins


def solve_balanced_partition(sizes: list[float], num_bins: int) -> list[list[int]]:
    """Partitions items into exactly `num_bins` bins, minimizing the RMS
    deviation of bin sums from their average. Since num_bins and the total
    size are both fixed, the average is fixed too, so minimizing
    sum((load_b - mean)^2) is equivalent to minimizing sum(load_b^2) - the
    two differ only by a constant (see the algebra: expand the square and
    note sum(load_b) == total regardless of partition). That sidesteps
    needing `mean` in the model at all, and gives CP-SAT a plain
    sum-of-squares objective. Returns a list of `num_bins` bins, each a
    list of indices into `sizes`."""
    n = len(sizes)
    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    int_sizes = [round(s * SCALE) for s in sizes_sorted]
    total = sum(int_sizes)

    model = cp_model.CpModel()
    # Same bin-count symmetry break as solve_bin_packing: item i confined
    # to bins 0..min(i, num_bins-1).
    x = [[model.NewBoolVar(f"x_{i}_{b}") for b in range(min(i, num_bins - 1) + 1)] for i in range(n)]

    for i in range(n):
        model.AddExactlyOne(x[i])

    loads = []
    for b in range(num_bins):
        items_reaching_b = [i for i in range(n) if b < len(x[i])]
        load = model.NewIntVar(0, total, f"load_{b}")
        model.Add(load == sum(int_sizes[i] * x[i][b] for i in items_reaching_b))
        loads.append(load)

    # Symmetry breaking: bin loads non-increasing (valid regardless of
    # objective - it's purely a canonical relabeling of interchangeable
    # bins).
    for b in range(num_bins - 1):
        model.Add(loads[b] >= loads[b + 1])

    squares = []
    for b in range(num_bins):
        sq = model.NewIntVar(0, total * total, f"sq_{b}")
        model.AddMultiplicationEquality(sq, [loads[b], loads[b]])
        squares.append(sq)

    model.Minimize(sum(squares))

    solver = cp_model.CpSolver()
    solver.parameters.num_search_workers = 8
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        raise RuntimeError(f"CP-SAT could not solve the model (status={solver.StatusName(status)})")
    if status != cp_model.OPTIMAL:
        print(f"warning: CP-SAT hit its limit before proving optimality (status={solver.StatusName(status)})")

    return [[order[i] for i in range(n) if b < len(x[i]) and solver.Value(x[i][b])] for b in range(num_bins)]


def solve_minmax_partition(sizes: list[float], num_bins: int, max_load_log: float | None = None) -> list[list[int]]:
    """Partitions items into exactly `num_bins` bins, minimizing the
    *largest* bin sum (a.k.a. makespan / minimize the longest bitmask) -
    unlike solve_balanced_partition, which minimizes squared deviation
    from the mean (a quadratic objective), this is a plain linear
    objective (minimize a variable that every load is constrained to be
    <=), so CP-SAT typically closes it out much faster. If `max_load_log`
    is given (log2-space), every bin is additionally hard-capped at that
    size - e.g. to guarantee no group's buffer exceeds the segment length,
    independent of whatever the minimize-the-max objective would have
    settled for on its own. Returns a list of `num_bins` bins, each a list
    of indices into `sizes`."""
    n = len(sizes)
    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    int_sizes = [round(s * SCALE) for s in sizes_sorted]
    total = sum(int_sizes)

    model = cp_model.CpModel()
    # Same bin-count symmetry break as solve_bin_packing/solve_balanced_partition.
    x = [[model.NewBoolVar(f"x_{i}_{b}") for b in range(min(i, num_bins - 1) + 1)] for i in range(n)]

    for i in range(n):
        model.AddExactlyOne(x[i])

    loads = []
    for b in range(num_bins):
        items_reaching_b = [i for i in range(n) if b < len(x[i])]
        load = model.NewIntVar(0, total, f"load_{b}")
        model.Add(load == sum(int_sizes[i] * x[i][b] for i in items_reaching_b))
        loads.append(load)
        if max_load_log is not None:
            model.Add(load <= round(max_load_log * SCALE))

    # Symmetry breaking: bin loads non-increasing.
    for b in range(num_bins - 1):
        model.Add(loads[b] >= loads[b + 1])

    max_load = model.NewIntVar(0, total, "max_load")
    for b in range(num_bins):
        model.Add(max_load >= loads[b])
    model.Minimize(max_load)

    solver = cp_model.CpSolver()
    solver.parameters.num_search_workers = 8
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        raise RuntimeError(f"CP-SAT could not solve the model (status={solver.StatusName(status)})")
    if status != cp_model.OPTIMAL:
        print(f"warning: CP-SAT hit its limit before proving optimality (status={solver.StatusName(status)})")

    return [[order[i] for i in range(n) if b < len(x[i]) and solver.Value(x[i][b])] for b in range(num_bins)]


def solve_maxmin_partition(sizes: list[float], num_bins: int, max_load_log: float | None = None) -> list[list[int]]:
    """Partitions items into exactly `num_bins` bins, maximizing the
    *smallest* bin sum - the dual of solve_minmax_partition. Same linear-
    objective shape (a variable every load is constrained against,
    optimized), just maximizing a lower bound instead of minimizing an
    upper one. If `max_load_log` is given (log2-space), every bin is
    additionally hard-capped at that size (e.g. the segment length) -
    unlikely to bind here since maximizing the min already discourages
    lopsided bins, but kept for parity with solve_minmax_partition and as
    a safety net. Returns a list of `num_bins` bins, each a list of
    indices into `sizes`."""
    n = len(sizes)
    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    int_sizes = [round(s * SCALE) for s in sizes_sorted]
    total = sum(int_sizes)

    model = cp_model.CpModel()
    # Same bin-count symmetry break as solve_bin_packing/solve_balanced_partition/solve_minmax_partition.
    x = [[model.NewBoolVar(f"x_{i}_{b}") for b in range(min(i, num_bins - 1) + 1)] for i in range(n)]

    for i in range(n):
        model.AddExactlyOne(x[i])

    loads = []
    for b in range(num_bins):
        items_reaching_b = [i for i in range(n) if b < len(x[i])]
        load = model.NewIntVar(0, total, f"load_{b}")
        model.Add(load == sum(int_sizes[i] * x[i][b] for i in items_reaching_b))
        loads.append(load)
        if max_load_log is not None:
            model.Add(load <= round(max_load_log * SCALE))

    # Symmetry breaking: bin loads non-increasing.
    for b in range(num_bins - 1):
        model.Add(loads[b] >= loads[b + 1])

    min_load = model.NewIntVar(0, total, "min_load")
    for b in range(num_bins):
        model.Add(min_load <= loads[b])
    model.Maximize(min_load)

    solver = cp_model.CpSolver()
    solver.parameters.num_search_workers = 8
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        raise RuntimeError(f"CP-SAT could not solve the model (status={solver.StatusName(status)})")
    if status != cp_model.OPTIMAL:
        print(f"warning: CP-SAT hit its limit before proving optimality (status={solver.StatusName(status)})")

    return [[order[i] for i in range(n) if b < len(x[i]) and solver.Value(x[i][b])] for b in range(num_bins)]


def solve_covering_to_target(sizes: list[float], num_bins: int, target: float, time_limit_s: float = 60.0) -> list[list[int]]:
    """Assigns every item to at least one of exactly `num_bins` bins - NOT
    a partition: an item may additionally appear in more than one bin,
    redundantly (e.g. a small prime already covered by one group can also
    be thrown into another group purely to lengthen that group's buffer -
    harmless for correctness, since preSieve.isPreSieved() only checks
    membership, and a prime's multiples being cleared by more than one
    group's pattern is idempotent). Minimizes sum((load_b - target)^2),
    pulling every bin's log2 total toward a fixed target rather than
    toward each other's average (contrast solve_balanced_partition).

    Because repetition is allowed, the standard partition symmetry break
    (item i confined to bins 0..i) doesn't apply - an item may legitimately
    belong to several bins at once. Only a weak break is used here (pin
    the largest item to bin 0), so this is given a time limit and may
    return a good-but-unproven-optimal solution rather than a proven one.

    Returns a list of `num_bins` bins, each a list of indices into
    `sizes` - the same index can appear in more than one bin's list, but
    not twice within one bin."""
    n = len(sizes)
    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    int_sizes = [round(s * SCALE) for s in sizes_sorted]
    int_target = round(target * SCALE)
    max_load = sum(int_sizes)  # generous upper bound: every item in one bin

    model = cp_model.CpModel()
    x = [[model.NewBoolVar(f"x_{i}_{b}") for b in range(num_bins)] for i in range(n)]

    for i in range(n):
        model.AddAtLeastOne(x[i])  # covered >=1 time, repeats across bins allowed

    # Weak symmetry break only: with repetition allowed, an item may
    # legitimately need to sit in several bins, so it can't be confined to
    # a bin range the way a partition can. Just pin the single largest
    # item to bin 0 to cut plain bin-relabeling symmetry.
    model.Add(x[0][0] == 1)

    deviations = []
    for b in range(num_bins):
        load = model.NewIntVar(0, max_load, f"load_{b}")
        model.Add(load == sum(int_sizes[i] * x[i][b] for i in range(n)))
        dev = model.NewIntVar(-max_load, max_load, f"dev_{b}")
        model.Add(dev == load - int_target)
        sq = model.NewIntVar(0, max_load * max_load, f"sq_{b}")
        model.AddMultiplicationEquality(sq, [dev, dev])
        deviations.append(sq)

    model.Minimize(sum(deviations))

    solver = cp_model.CpSolver()
    solver.parameters.num_search_workers = 8
    solver.parameters.max_time_in_seconds = time_limit_s
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        raise RuntimeError(f"CP-SAT could not solve the model (status={solver.StatusName(status)})")
    if status != cp_model.OPTIMAL:
        print(f"warning: hit the {time_limit_s:.0f}s time limit before proving optimality "
              f"(status={solver.StatusName(status)}) - result is CP-SAT's best found, not a proven optimum")

    return [[order[i] for i in range(n) if solver.Value(x[i][b])] for b in range(num_bins)]


def solve_maxcoverage(sizes: list[float], num_bins: int, cap: float, time_limit_s: float = 60.0) -> list[list[int]]:
    """Partitions *some subset* of items into exactly `num_bins` bins, each
    hard-capped at `cap` (log2-space) - unlike every other solver here, not
    every item need be used: an item is either assigned to exactly one bin
    or left out entirely. Maximizes how many items get included, subject to
    a no-gaps rule: `sizes` must be given smallest-first, and item i can
    only be included if item i-1 is too - so the included set is always a
    clean prefix of the candidate list, never "skip 53 and 59 to fit 109
    instead." Meant to be called with a candidate list that extends well
    past what could ever fit (see EXTENDED_CANDIDATE_PRIMES), so the cap -
    not the candidate list - is what determines where the prefix ends.

    Because the no-gaps rule already fixes *which* items are in play (a
    prefix, decided by the objective itself) it also gives a natural
    item-range symmetry break, same idea as the partition solvers above:
    item i can't reach a bin index higher than i, since strictly fewer
    than i+1 smaller-or-equal items exist to have opened one. Returns a
    list of `num_bins` bins, each a list of indices into `sizes` - indices
    that appear in no bin at all were left out (always the longest
    suffix, per the no-gaps rule)."""
    n = len(sizes)
    int_sizes = [round(s * SCALE) for s in sizes]
    int_cap = math.floor(cap * SCALE)
    total = sum(int_sizes)

    model = cp_model.CpModel()
    x = [[model.NewBoolVar(f"x_{i}_{b}") for b in range(min(i, num_bins - 1) + 1)] for i in range(n)]

    included = [model.NewBoolVar(f"inc_{i}") for i in range(n)]
    for i in range(n):
        model.Add(included[i] == sum(x[i]))  # in at most one bin (sum of a bunch of bools <= 1), or left out
        model.AddAtMostOne(x[i])
    for i in range(1, n):
        model.Add(included[i] <= included[i - 1])  # no gaps: prefix only

    loads = []
    for b in range(num_bins):
        items_reaching_b = [i for i in range(n) if b < len(x[i])]
        load = model.NewIntVar(0, min(total, int_cap), f"load_{b}")
        model.Add(load == sum(int_sizes[i] * x[i][b] for i in items_reaching_b))
        model.Add(load <= int_cap)
        loads.append(load)

    # Symmetry breaking: bin loads non-increasing (still sound with
    # optional inclusion - it's purely a canonical relabeling of
    # interchangeable bins, independent of which items ended up in them).
    for b in range(num_bins - 1):
        model.Add(loads[b] >= loads[b + 1])

    model.Maximize(sum(included))

    solver = cp_model.CpSolver()
    solver.parameters.num_search_workers = 8
    solver.parameters.max_time_in_seconds = time_limit_s
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        raise RuntimeError(f"CP-SAT could not solve the model (status={solver.StatusName(status)})")
    if status != cp_model.OPTIMAL:
        print(f"warning: hit the {time_limit_s:.0f}s time limit before proving optimality "
              f"(status={solver.StatusName(status)}) - result is CP-SAT's best found, not a proven optimum")

    return [[i for i in range(n) if b < len(x[i]) and solver.Value(x[i][b])] for b in range(num_bins)]


def prime_cost(p: int, hit_cost_multiplier: float) -> float:
    """PRIME_COST(p) from the costmodel docstring above: what leaving
    prime p un-presieved costs, in vector-AND-op-equivalents, for its
    whole active lifetime as a small sieving prime - independent of the
    sieve's actual upper limit (see the docstring: every term in the
    model scales with total_bytes, so it cancels out of the tradeoff)."""
    return hit_cost_multiplier * ADMISSIBLE_RESIDUES_COUNT / (WHEEL_CIRCUMFERENCE * p)


def _tangent_points(x_max: float, count: int) -> list[float]:
    """`count` evenly spaced points across [0, x_max], including both ends -
    where _add_convex_quadratic_penalty below plants its tangent lines."""
    if count <= 1:
        return [x_max / 2]
    return [x_max * k / (count - 1) for k in range(count)]


def _add_convex_quadratic_penalty(h, expr, coef: float, x_max: float, num_segments: int = 12):
    """Adds coef*x^2 (x = `expr`, x in [0, x_max]) to a HiGHS model as a
    piecewise-linear convex underestimator - the standard MILP
    linearization of a convex penalty, and the reason this whole model
    can stay a clean MILP instead of the MIQCP an earlier CP-SAT/SCIP-MINLP
    version needed: the tangent line to y=coef*x^2 at x=x_k is
    y = 2*coef*x_k*x - coef*x_k^2, and since a convex function lies on or
    above every one of its tangent lines, `max` over `num_segments`
    tangent lines is itself a valid (and, near each tangent point, exact)
    lower bound on the true penalty everywhere in [0, x_max] - modeled as
    one new variable p >= each tangent line, with p appearing in the
    (minimized) objective with a positive weight, so the solver's own
    optimization pressure pushes p down to exactly that max, no extra
    machinery needed. Purely linear constraints throughout; more segments
    only tighten the approximation, they never add combinatorial
    difficulty the way a real quadratic constraint would. Returns the new
    variable `p` (not yet added to any objective - the caller collects
    these into whatever weighted sum it needs)."""
    p = h.addVariable(lb=0)
    for x_k in _tangent_points(x_max, num_segments):
        h.addConstr(p >= 2 * coef * x_k * expr - coef * x_k * x_k)
    return p


def _cost_model_ffd_hint(
    primes: list[int], max_bins: int, max_buffer_bytes: float
) -> list[int | None]:
    """First-fit construction, smallest/most-valuable-prime-first (see
    solve_cost_model_milp's docstring for why: PRIME_COST is largest for
    small p and inclusion is optional here, unlike classic bin-packing,
    so greedily seating the always-worth-it small primes first is what
    actually matters) - just a MIP start, not claimed optimal. `primes`
    is expected *descending* (matching solve_cost_model_milp's own
    indexing, largest first), so this walks it in reverse to process
    smallest/most-valuable first regardless. Returns a bin index (into
    the *same descending* indexing the caller uses) or None (excluded)
    for each candidate."""
    n = len(primes)
    assignment: list[int | None] = [None] * n
    bin_products = [1] * max_bins
    used_bins = 0
    for i in reversed(range(n)):
        placed = False
        for b in range(used_bins):
            if bin_products[b] * primes[i] <= max_buffer_bytes:
                assignment[i] = b
                bin_products[b] *= primes[i]
                placed = True
                break
        if not placed and used_bins < max_bins and primes[i] <= max_buffer_bytes:
            assignment[i] = used_bins
            bin_products[used_bins] = primes[i]
            used_bins += 1
    return assignment


def solve_cost_model_milp(
    primes: list[int],
    sizes: list[float],
    max_bins: int,
    hit_cost_multiplier: float,
    vec_len: int,
    cache_target_kib: float,
    cache_cost_coef: float,
    small_target_kib: float,
    small_cost_coef: float,
    max_buffer_kib: float,
    time_limit_s: float = 60.0,
    gap_limit: float = 0.0,
    warm_start: bool = True,
    jobs: int = 1,
    exact_bins: int | None = None,
) -> tuple[list[list[int]], float]:
    """Jointly optimizes bin count and prime coverage against:

      GROUP_COST * (bins used)                    - fill()'s extra AND-pass, see the module docstring
      + sum(PRIME_COST(p) for p excluded)          - un-presieved small-sieving-prime work, see the module docstring
      + sum(CACHE_COST for bins used) + SMALL_BUFFER_COST (once, on the smallest used bin)

    CACHE_COST is a steep, quadratic-shaped per-bin penalty for a bin
    drifting too far above a size target - expressed as a piecewise-linear
    convex underestimator (_add_convex_quadratic_penalty) instead of a real
    quadratic constraint, which is what makes this a MILP rather than a
    MIQCP: the solver handles it with the same machinery as every other
    constraint here, no spatial branch-and-bound. SMALL_BUFFER_COST is the
    same quadratic shape but applied *once*, to the smallest used bin's own
    shortfall below a size target, not summed per bin - see the comment
    where it's built in this function for why: fill()'s outer loop chunk
    size is min(remaining-period) across *every* group, so one small bin
    caps throughput for the whole combine pass, which a per-bin sum can't
    express. Neither coefficient/target is derived the way
    GROUP_COST/PRIME_COST are (from comptime constants) - real profiling
    would be needed for that; treat them as labeled guesses to react to
    empirically, not settled constants. `max_buffer_kib` is a generous
    *numerical* bound only (bounds the solver's domains, keeps comptime
    array generation from taking minutes), not a performance cap.

    Solved with HiGHS (highspy), not SCIP/CP-SAT: a dedicated, modern
    LP/MILP solver, the better structural fit for a *pure* MILP once this
    model dropped every non-linear term. `highspy` and `ortools` (already
    a hard dependency for every other objective in this file) bundle
    mutually incompatible builds of the HiGHS library in some version
    combinations - importing both in one process throws an undefined-
    symbol ImportError regardless of import order - but this is version-
    specific, not fundamental: confirmed via a clean-venv A/B across
    highspy 1.7.1-1.15.1 that only highspy>=1.15.0 collides with ortools
    9.15.6755's bundled HiGHS. requirements.txt pins `highspy==1.14.0`
    exactly for this reason - re-run that clean-venv A/B before ever
    bumping it.

    Symmetry breaking needed its own empirical pass for HiGHS - a
    diagnostic A/B (max_bins=14, mip_rel_gap=0, 30s cap) found: no breaks
    at all, ~11-13s to proven-optimal; y[b]>=y[b+1] alone, ~11-12s
    (barely different); the item-range restriction (x[i][b] confined to
    b<=i) alone, ~6.2-6.8s - the *opposite* of the equivalent SCIP finding,
    where this exact restriction was the most damaging break tried;
    y[b]>=y[b+1] *plus* item-range together, ~4.0-4.3s - the best
    combination found, and what's used below. A loads[b]>=loads[b+1]
    break, alone or combined with anything else, was uniformly bad here -
    never below a ~21-29% gap within the 30s cap - so it's dropped
    entirely. items are still sorted descending (largest-prime-first) and
    no-gaps is still included[i]<=included[i+1] (the included set is a
    descending-order *suffix* - the smallest primes). small_shortfall is
    gated by y[b] via an exact algebraic identity (small_shortfall_raw -
    small_target_log*(1-y[b])) rather than a reified/indicator constraint,
    since load=0 is already forced for an unused bin by the `<= n*y[b]`
    constraint, so the identity needs no case-split. Returns (bins, gap):
    a list of `max_bins` bins (many typically empty, each a list of
    indices into `sizes`/`primes`) and the solver's final relative
    optimality gap (0.0 if proven optimal) - NOTE: this gap is measured in
    the cost model's own abstract units, not real seconds, and is not the
    same quantity as a real-hardware benchmark gap against some other
    candidate."""
    import highspy

    n = len(sizes)
    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    primes_sorted = [primes[i] for i in order]
    prime_costs_sorted = [prime_cost(p, hit_cost_multiplier) for p in primes_sorted]

    max_load = math.log2(max_buffer_kib * 1024)
    cache_target_log = math.log2(cache_target_kib * 1024)
    small_target_log = math.log2(small_target_kib * 1024)
    max_buffer_bytes = max_buffer_kib * 1024
    group_cost = 1.0 / vec_len

    h = highspy.Highs()
    h.setOptionValue("output_flag", False)
    h.setOptionValue("time_limit", time_limit_s)
    h.setOptionValue("mip_rel_gap", max(gap_limit, 0.0))
    if jobs > 1:
        h.setOptionValue("threads", jobs)
        h.setOptionValue("parallel", "on")
    else:
        h.setOptionValue("threads", 1)
        h.setOptionValue("parallel", "off")

    x = [[h.addVariable(lb=0, ub=1, type=highspy.HighsVarType.kInteger, name=f"x_{i}_{b}") for b in range(max_bins)] for i in range(n)]
    y = [h.addVariable(lb=0, ub=1, type=highspy.HighsVarType.kInteger, name=f"y_{b}") for b in range(max_bins)]
    included = [h.addVariable(lb=0, ub=1, type=highspy.HighsVarType.kInteger, name=f"inc_{i}") for i in range(n)]

    for i in range(n):
        h.addConstr(included[i] == sum(x[i]))
        h.addConstr(sum(x[i]) <= 1)
    # No gaps: descending order, so the included set is a suffix (the
    # smallest primes) - inclusion is non-decreasing as i grows.
    for i in range(n - 1):
        h.addConstr(included[i] <= included[i + 1])

    # Item-range symmetry break: item i can only land in a bin b<=i. See
    # the docstring above for the empirical A/B behind keeping this for
    # HiGHS (it was the opposite finding for SCIP).
    for i in range(n):
        for b in range(i + 1, max_bins):
            h.addConstr(x[i][b] == 0)

    loads = []
    penalty_terms = []
    aux_vars = []
    for b in range(max_bins):
        load = h.addVariable(lb=0, ub=max_load, name=f"load_{b}")
        h.addConstr(load == sum(sizes_sorted[i] * x[i][b] for i in range(n)))
        h.addConstr(sum(x[i][b] for i in range(n)) <= n * y[b])
        loads.append(load)

        cache_excess = h.addVariable(lb=0, ub=max_load, name=f"cache_excess_{b}")
        h.addConstr(cache_excess >= load - cache_target_log)
        cache_penalty = _add_convex_quadratic_penalty(h, cache_excess, cache_cost_coef, max_load)
        penalty_terms.append(cache_penalty)

        aux_vars.append((cache_excess, cache_penalty))

    # SMALL_BUFFER_COST is a *global* penalty on the smallest used bin, not
    # a per-bin sum - see fill() in preSieve.zig: its outer loop's chunk
    # size is min(remaining-period) across *every* group at once, so a
    # single small-period bin caps the vectorized step size for the *whole*
    # combine pass, not just its own. A per-bin sum-of-shortfalls would let
    # the solver freely admit one very small bin as long as every other bin
    # stayed comfortably large - real benchmarks show that costs more than
    # this global-min formulation avoids.
    # `min_load <= load_b + max_load*(1-y[b])` only binds for used bins (an
    # unused bin's slack term makes it non-binding) - the minimize pressure
    # on the resulting shortfall penalty pushes min_load up to exactly the
    # smallest used bin's load, no reification needed.
    min_load = h.addVariable(lb=0, ub=max_load, name="min_load")
    for b in range(max_bins):
        h.addConstr(min_load <= loads[b] + max_load * (1 - y[b]))
    small_shortfall = h.addVariable(lb=0, ub=small_target_log, name="small_shortfall")
    h.addConstr(small_shortfall >= small_target_log - min_load)
    small_penalty = _add_convex_quadratic_penalty(h, small_shortfall, small_cost_coef, small_target_log)
    penalty_terms.append(small_penalty)

    # Bins used in order, no gaps between used bins - see the docstring
    # above for why this is kept alongside the item-range break above
    # (their combination was the fastest of every combination tried) and
    # loads[b]>=loads[b+1] is dropped entirely.
    for b in range(max_bins - 1):
        h.addConstr(y[b] >= y[b + 1])

    # exact_bins: for isolating "is bin count N itself good or bad,
    # optimally packed" from "did the free-bin-count objective's own
    # bin-count choice happen to be right" - see --exact-bins below. Forces
    # the solver to find the BEST packing/coverage at exactly this many
    # bins, rather than letting bins used be a free decision alongside
    # everything else.
    if exact_bins is not None:
        h.addConstr(sum(y) == exact_bins)

    h.setObjective(
        group_cost * sum(y)
        + sum(prime_costs_sorted[i] * (1 - included[i]) for i in range(n))
        + sum(penalty_terms),
        sense=highspy.ObjSense.kMinimize,
    )

    if warm_start:
        # Fully specified, not a partial solution - computing every
        # auxiliary variable (load, the cache/small excess/shortfall/gated
        # variables, the two piecewise penalty variables per bin) directly
        # from the FFD assignment is what makes the hint actually usable.
        # The two penalty values are set to the *exact* quadratic cost at
        # that load, which is always feasible for a piecewise-linear
        # *under*estimator (every tangent line lies on or below the true
        # convex curve, so the exact value satisfies every
        # `p >= tangent_line` constraint with room to spare - HiGHS can
        # tighten it further if beneficial).
        hint = _cost_model_ffd_hint(primes_sorted, max_bins, max_buffer_bytes)
        used_bins = sorted({b for b in hint if b is not None})
        bin_products = [1] * max_bins
        for i, b in enumerate(hint):
            if b is not None:
                bin_products[b] *= primes_sorted[i]

        col_value = [0.0] * h.numVariables
        for i in range(n):
            is_included = hint[i] is not None
            col_value[included[i].index] = 1.0 if is_included else 0.0
            for bb in range(max_bins):
                col_value[x[i][bb].index] = 1.0 if hint[i] == bb else 0.0
        load_vals = []
        for b in range(max_bins):
            is_used = b in used_bins
            load_val = math.log2(bin_products[b]) if bin_products[b] > 1 else 0.0
            load_vals.append(load_val)
            col_value[y[b].index] = 1.0 if is_used else 0.0
            col_value[loads[b].index] = load_val

            cache_excess, cache_penalty = aux_vars[b]
            cache_excess_val = max(0.0, load_val - cache_target_log)
            col_value[cache_excess.index] = cache_excess_val
            col_value[cache_penalty.index] = cache_cost_coef * cache_excess_val * cache_excess_val

        min_load_val = min((load_vals[b] for b in used_bins), default=max_load)
        small_shortfall_val = max(0.0, small_target_log - min_load_val)
        col_value[min_load.index] = min_load_val
        col_value[small_shortfall.index] = small_shortfall_val
        col_value[small_penalty.index] = small_cost_coef * small_shortfall_val * small_shortfall_val

        sol = highspy.HighsSolution()
        sol.col_value = col_value
        h.setSolution(sol)

    h.solve()
    status = h.getModelStatus()
    ok_statuses = (highspy.HighsModelStatus.kOptimal, highspy.HighsModelStatus.kTimeLimit,
                   highspy.HighsModelStatus.kIterationLimit, highspy.HighsModelStatus.kInterrupt)
    status_name = h.modelStatusToString(status)
    if status not in ok_statuses:
        raise RuntimeError(f"HiGHS could not solve the model (status={status_name})")
    info = h.getInfo()
    if status != highspy.HighsModelStatus.kOptimal and info.primal_solution_status != highspy.kSolutionStatusFeasible:
        raise RuntimeError(f"HiGHS found no feasible solution within the limit (status={status_name})")
    if status != highspy.HighsModelStatus.kOptimal:
        print(f"warning: HiGHS stopped before proving optimality (status={status_name}, gap={info.mip_gap * 100:.2f}%) "
              "- result is HiGHS's best found, not a proven optimum")

    x_vals = [h.vals(x[i]) for i in range(n)]
    result_bins = [[order[i] for i in range(n) if x_vals[i][b] > 0.5] for b in range(max_bins)]
    gap = info.mip_gap if status != highspy.HighsModelStatus.kOptimal else 0.0
    return result_bins, gap


def format_and_print_groups(group_primes_list: list[list[int]], elapsed: float, elapsed_note: str = "solved") -> None:
    """Prints the product table, byte-space/log2-space stats, and 'as a Zig
    GROUPS literal' block for an already-resolved list of per-group prime
    lists (each sorted ascending, groups sorted descending by max prime -
    report()'s ordering). Factored out of report() so a cached costmodel
    result (see solve_cost_model_cached) prints identically to a freshly
    solved one, without needing that path to fake up primes/bins/cap_bytes
    just to reuse report()'s bin-resolution logic."""
    products = [math.prod(group_primes) for group_primes in group_primes_list]
    for group_primes, product in zip(group_primes_list, products):
        print(f"  {group_primes}  product={product}  ({product / 1024:.2f} KiB)")

    if products:
        mean = sum(products) / len(products)
        rms = math.sqrt(sum((p - mean) ** 2 for p in products) / len(products))
        log_sizes = [math.log2(p) for p in products]
        log_mean = sum(log_sizes) / len(log_sizes)
        log_rms = math.sqrt(sum((s - log_mean) ** 2 for s in log_sizes) / len(log_sizes))
        print()
        print(f"byte-space:  mean {mean / 1024:.2f} KiB, RMS deviation {rms / 1024:.2f} KiB ({100 * rms / mean:.1f}% of mean)")
        print(f"log2-space:  mean {log_mean:.3f}, RMS deviation {log_rms:.3f}")
        print("(balance/cover minimize log2-space deviation, not byte-space - see the module docstring;")
        print(" byte-space RMS can look uneven even at the log2-optimal result, since equal ratios/orders")
        print(" of magnitude aren't the same as equal absolute byte counts.)")

    print(f"({elapsed_note} in {elapsed:.3f}s)")
    print()
    print("as a Zig GROUPS literal:")
    print("const GROUPS = [_][]const usize{")
    for group_primes in group_primes_list:
        print("    &[_]usize{ " + ", ".join(str(p) for p in group_primes) + " },")
    print("};")


def report(primes: list[int], bins: list[list[int]], elapsed: float, cap_bytes: float | None) -> list[list[int]]:
    group_primes_list = []
    for b in sorted(bins, key=lambda b: -max((primes[i] for i in b), default=0)):
        group_primes = sorted(primes[i] for i in b)
        if not group_primes:
            continue
        if cap_bytes is not None:
            product = math.prod(group_primes)
            assert product <= cap_bytes + 1e-6, f"group {group_primes} exceeds cap: {product} > {cap_bytes}"
        group_primes_list.append(group_primes)

    format_and_print_groups(group_primes_list, elapsed)
    return group_primes_list


def write_presieve_groups(path: Path, group_primes_list: list[list[int]]) -> None:
    """Writes a solved result to `path` in the plain text format build.zig's
    resolvePresieveGroups reads directly: one group per line, primes
    comma-separated, in report()'s order (largest-prime-first group order).
    Deliberately not Zig source and not a rewrite of any existing file -
    `path` is expected to be a build-output location (zig-out/ by default,
    see build.zig's SOLVED_PRESIEVE_GROUPS_PATH and
    wireRegenPresieveGroups), never a tracked source file, so a solved
    config can never get committed by accident. Creates parent directories
    as needed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [",".join(str(p) for p in group_primes) for group_primes in group_primes_list]
    path.write_text("\n".join(lines) + "\n")
    print(f"wrote {len(group_primes_list)} groups to {path}")


# Only the costmodel objective is expensive enough (default 60s cap, more
# for a tighter --gap-limit) to bother caching - see solve_cost_model_cached.
_SOLVE_CACHE_RELEVANT_ARGS = (
    "hit_cost_multiplier", "vec_len", "cache_target_kib", "cache_cost_coef",
    "small_target_kib", "small_cost_coef", "max_buffer_kib", "max_bins",
    "gap_limit", "time_limit", "primes", "exact_bins",
)


def _solve_cache_fingerprint(args: argparse.Namespace) -> str:
    """Hashes every solver-relevant CLI parameter together with solve.py's
    own source bytes - so a cache entry is invalidated both by a parameter
    change (e.g. build.zig passing a different --cache-target-kib) AND by
    editing the cost model/solver itself (the ongoing tuning work this is
    for), without needing to remember to bump a version number by hand.
    --clear-cache remains for the rare case neither of those covers (e.g. an
    ortools/highspy version bump changing what the same model solves to)."""
    relevant = {name: getattr(args, name) for name in _SOLVE_CACHE_RELEVANT_ARGS}
    payload = json.dumps(relevant, sort_keys=True).encode()
    source_hash = hashlib.sha256(Path(__file__).read_bytes()).digest()
    return hashlib.sha256(payload + source_hash).hexdigest()


def _print_costmodel_diagnostics(primes: list[int], group_primes_list: list[list[int]], max_bins: int) -> None:
    included = sorted(p for group in group_primes_list for p in group)
    excluded = [p for p in primes if p not in included]
    total_kib_actual = sum(math.prod(group) / 1024 for group in group_primes_list)
    print(f"bins used: {len(group_primes_list)}/{max_bins}")
    print(f"total footprint (actual): {total_kib_actual:.1f} KiB")
    print(f"included {len(included)}/{len(primes)} candidates: {included}")
    print(f"excluded (not worth a group): {excluded[:20]}{'...' if len(excluded) > 20 else ''}")
    print()


def solve_cost_model_cached(args: argparse.Namespace, primes: list[int]) -> list[list[int]]:
    """Wraps solve_cost_model_milp with a fingerprint-keyed cache (see
    _solve_cache_fingerprint) under --cache-dir, so repeat invocations with
    unchanged parameters and an unchanged solver (e.g. build.zig's
    regen-presieve-groups step run again with the same build config) skip
    straight to the cached result instead of re-running an expensive solve.
    Returns the resolved group_primes_list either way (report()'s ordering:
    groups sorted descending by max prime, primes within a group ascending),
    so the caller doesn't need to know whether this was a hit or a miss."""
    cache_dir = Path(args.cache_dir)
    if args.clear_cache and cache_dir.exists():
        shutil.rmtree(cache_dir)
        print(f"cleared solve cache at {cache_dir}")

    fingerprint = _solve_cache_fingerprint(args)
    cache_path = cache_dir / f"{fingerprint}.json"

    if cache_path.exists():
        cached = json.loads(cache_path.read_text())
        print(f"cache hit ({cache_path.name}, originally solved in {cached['elapsed']:.3f}s, "
              f"gap={cached['gap'] * 100:.2f}%) - pass --clear-cache to force a fresh solve")
        print()
        format_and_print_groups(cached["group_primes_list"], cached["elapsed"], elapsed_note="originally solved")
        print()
        _print_costmodel_diagnostics(primes, cached["group_primes_list"], args.max_bins)
        return cached["group_primes_list"]

    sizes = [math.log2(p) for p in primes]
    t0 = time.perf_counter()
    bins, gap = solve_cost_model_milp(
        primes, sizes, args.max_bins, args.hit_cost_multiplier, args.vec_len,
        args.cache_target_kib, args.cache_cost_coef, args.small_target_kib, args.small_cost_coef,
        args.max_buffer_kib, time_limit_s=args.time_limit, gap_limit=args.gap_limit,
        warm_start=not args.no_warm_start, jobs=args.jobs, exact_bins=args.exact_bins,
    )
    elapsed = time.perf_counter() - t0

    group_primes_list = report(primes, bins, elapsed, cap_bytes=None)
    _print_costmodel_diagnostics(primes, group_primes_list, args.max_bins)

    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps({
        "group_primes_list": group_primes_list,
        "elapsed": elapsed,
        "gap": gap,
    }))
    if gap > 0.0:
        print(f"note: cached result is not proven optimal (gap={gap * 100:.2f}%) - "
              "a future --clear-cache run with more time/a tighter --gap-limit could still improve on it")

    return group_primes_list


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--objective", choices=["mincount", "balance", "minmax", "maxmin", "maxcoverage", "costmodel", "cover"], default="mincount",
                         help="mincount: fewest bins under --cap-kib (default). "
                              "balance: exactly --num-bins bins (a partition), minimizing RMS deviation from the mean bin size. "
                              "minmax: exactly --num-bins bins (a partition), minimizing the single largest bin (makespan). "
                              "maxmin: exactly --num-bins bins (a partition), maximizing the single smallest bin - "
                              "the one that matters for fill()'s hot loop, see the module docstring. "
                              "maxcoverage: exactly --num-bins bins hard-capped at --cap-kib, maximizing how many "
                              "primes (candidates extend past 97, see EXTENDED_CANDIDATE_PRIMES) get pre-sieved at all. "
                              "costmodel: bin count, prime coverage, AND per-bin buffer shape all free, jointly "
                              "minimizing GROUP_COST*(bins used) + sum(PRIME_COST(p) for p excluded) + "
                              "sum(CACHE_COST for bins used) + SMALL_BUFFER_COST (once, smallest bin) - no hard per-bin cap at all, "
                              "solved as a clean MILP via HiGHS - see the module docstring and "
                              "solve_cost_model_milp's docstring. "
                              "cover: exactly --num-bins bins, every prime used >=1 time (repeats across bins allowed), "
                              "minimizing RMS deviation from the --cap-kib target.")
    parser.add_argument("--cap-kib", type=float, default=32.0, help="[mincount/maxcoverage] per-group buffer cap, in KiB (default: 32) - [cover] per-group target")
    parser.add_argument("--max-kib", type=float, default=None, help="[minmax/maxmin] optional hard per-group buffer ceiling in KiB (e.g. the segment length) - unset means no extra cap beyond the objective itself")
    parser.add_argument("--num-bins", type=int, default=8, help="[balance/maxmin/maxcoverage/cover] exact number of bins (default: 8)")
    parser.add_argument("--max-bins", type=int, default=16, help="[costmodel] generous upper bound on bins to consider - the objective decides how many are worth using (default: 16)")
    parser.add_argument("--exact-bins", type=int, default=None,
                         help="[costmodel] force exactly this many bins used (must be <= --max-bins) instead of "
                              "letting bin count be a free decision - for isolating 'is N bins itself good, "
                              "optimally packed' from 'did the free-bin-count objective's own choice happen to be "
                              "right', e.g. sweeping this to check whether the model's own bin-count pick is a "
                              "true local optimum in real benchmarks, not an artifact of not exploring neighboring "
                              "bin counts as thoroughly (default: unset - bin count is free)")
    parser.add_argument("--hit-cost-multiplier", type=float, default=6.0,
                         help="[costmodel] estimated cost of one scalar masked-store crossing-off op, in "
                              "vector-AND-op-equivalents - see PRIME_COST(p) in the module docstring. Not reliably "
                              "derivable from an isolated microbenchmark: independent small-sieving-primes' work "
                              "overlaps via the CPU's out-of-order/memory-level parallelism in a way that isn't a "
                              "fixed per-prime constant, so isolated timings don't reconcile with real profiled "
                              "behavior. Determined instead via a direct empirical grid search (build+benchmark "
                              "real `primez` end to end against candidate values) - values in roughly 5.7-6.3 are "
                              "statistically indistinguishable given normal run-to-run noise, so don't over-"
                              "interpret the third digit (default: 6.0)")
    parser.add_argument("--vec-len", type=int, default=EXPECTED_VEC_LEN, help=f"[costmodel] fill()'s SIMD width in bytes for this build (default: {EXPECTED_VEC_LEN}, this machine's std.simd.suggestVectorLength(u8))")
    parser.add_argument("--cache-target-kib", type=float, default=64.0,
                         help="[costmodel] soft per-bin size target above which CACHE_COST kicks in, in KiB - the "
                              "point where a group's pattern buffer stops being L1-resident. Measured directly on "
                              "real hardware (isolated single-group throughput, period swept 1.3KiB-2.2MiB): the "
                              "knee sits around 64 KiB, this machine's L1d size per core (default: 64)")
    parser.add_argument("--cache-cost-coef", type=float, default=0.000333,
                         help="[costmodel] CACHE_COST quadratic coefficient (piecewise-linearized, see "
                              "solve_cost_model_milp), in vector-AND-ops per (bit over target)^2. Least-squares fit "
                              "alongside --cache-target-kib over 7 period sizes (1.3KiB-2.2MiB) - there is a small "
                              "but real oversized-buffer penalty on this hardware (default: 0.000333)")
    parser.add_argument("--small-target-kib", type=float, default=4.0,
                         help="[costmodel] soft size target below which SMALL_BUFFER_COST kicks in - applied once, "
                              "to the smallest used bin, not per bin (see solve_cost_model_milp), in KiB. Measured "
                              "via a controlled hardware sweep (5 fixed ~400KiB bins plus 1 bin swept 71B-697KiB): "
                              "the fragmentation cliff sits around 1-4 KiB - fill() throughput was already back to "
                              "baseline by a 3.5KiB smallest bin (default: 4)")
    parser.add_argument("--small-cost-coef", type=float, default=0.000385,
                         help="[costmodel] SMALL_BUFFER_COST quadratic coefficient (piecewise-linearized, see "
                              "solve_cost_model_milp), in vector-AND-ops per (bit under target)^2 - applies once, "
                              "to the smallest used bin. Fit alongside --small-target-kib: two independent points "
                              "(a 71-byte and a 719-byte smallest bin, both against the same 5 normal ~400KiB bins) "
                              "backed out to matching coefficients (0.000392 and 0.000393) under a 4 KiB target "
                              "(default: 0.000385)")
    parser.add_argument("--max-buffer-kib", type=float, default=768.0, help="[costmodel] generous NUMERICAL bound only (bounds the solver's domains, keeps comptime array generation from taking minutes) - not a performance cap (default: 768)")
    parser.add_argument("--time-limit", type=float, default=60.0, help="[maxcoverage/costmodel/cover] solver time limit in seconds (default: 60)")
    parser.add_argument("--gap-limit", type=float, default=0.02, help="[costmodel] stop once within this relative gap of the best possible bound (0 disables - run to proven-optimal or the time limit) (default: 0.02, i.e. 2%%)")
    parser.add_argument("-j", "--jobs", type=int, default=1, help="[costmodel] HiGHS parallel search workers (default: 1 - no parallelization; pass e.g. -j 8 to opt in explicitly)")
    parser.add_argument("--no-warm-start", action="store_true", help="[costmodel] disable the FFD MIP-start hint (on by default) - useful to A/B whether it's actually helping on a given run")
    parser.add_argument("--write-groups-to", type=str, default=None,
                         help="[costmodel] path to write the result to, in a plain text format build.zig's "
                              "resolvePresieveGroups reads directly (one group per line, primes comma-separated) - "
                              "see write_presieve_groups(). A build-output path (build.zig defaults this to "
                              "zig-out/presieve-groups.txt via the regen-presieve-groups step), never a tracked "
                              "source file.")
    parser.add_argument("--cache-dir", type=str, default=str(Path(__file__).parent / ".solve_cache"),
                         help="[costmodel] directory for fingerprint-keyed cached solves - see solve_cost_model_cached "
                              "(default: .solve_cache next to this script). A cache entry is keyed on every solver-"
                              "relevant parameter AND this file's own source hash, so editing the cost model already "
                              "invalidates stale entries automatically; --clear-cache is for everything else "
                              "(e.g. an ortools/highspy version bump changing what the same model solves to).")
    parser.add_argument("--clear-cache", action="store_true", help="[costmodel] wipe --cache-dir before solving, forcing a fresh solve")
    parser.add_argument("--primes", type=str, default=None,
                         help="comma-separated prime list (default: preSieve.zig's current 7..97 set, or, for "
                              "maxcoverage/costmodel, EXTENDED_CANDIDATE_PRIMES - candidates well past 97)")
    args = parser.parse_args()

    if args.primes is not None:
        primes = [int(p) for p in args.primes.split(",")]
    elif args.objective in ("maxcoverage", "costmodel"):
        primes = EXTENDED_CANDIDATE_PRIMES
    else:
        primes = DEFAULT_PRIMES
    sizes = [math.log2(p) for p in primes]

    print(f"primes ({len(primes)}): {primes}")

    if args.objective == "mincount":
        cap_bytes = args.cap_kib * 1024
        cap_log = math.log2(cap_bytes)
        print(f"objective: fewest bins, cap = {cap_bytes:.0f} bytes ({args.cap_kib:g} KiB), log2(cap) = {cap_log:.4f}")
        print(f"sum(log2(p)) = {sum(sizes):.4f}  ->  L1 lower bound = {math.ceil(sum(sizes) / cap_log - EPS)} bins")
        print()

        t0 = time.perf_counter()
        bin_count, bins = solve_bin_packing(sizes, cap_log)
        elapsed = time.perf_counter() - t0
        print(f"optimal bin count: {bin_count}")
        report(primes, bins, elapsed, cap_bytes)
    elif args.objective == "balance":
        print(f"objective: {args.num_bins} bins (partition), minimize RMS deviation from mean bin size")
        print()

        t0 = time.perf_counter()
        bins = solve_balanced_partition(sizes, args.num_bins)
        elapsed = time.perf_counter() - t0
        report(primes, bins, elapsed, cap_bytes=None)
    elif args.objective == "minmax":
        max_load_log = math.log2(args.max_kib * 1024) if args.max_kib is not None else None
        cap_note = f", hard-capped at {args.max_kib:g} KiB/group" if args.max_kib is not None else ""
        print(f"objective: {args.num_bins} bins (partition), minimize the largest bin (makespan){cap_note}")
        print()

        t0 = time.perf_counter()
        bins = solve_minmax_partition(sizes, args.num_bins, max_load_log=max_load_log)
        elapsed = time.perf_counter() - t0
        cap_bytes = args.max_kib * 1024 if args.max_kib is not None else None
        report(primes, bins, elapsed, cap_bytes=cap_bytes)
    elif args.objective == "maxmin":
        max_load_log = math.log2(args.max_kib * 1024) if args.max_kib is not None else None
        cap_note = f", hard-capped at {args.max_kib:g} KiB/group" if args.max_kib is not None else ""
        print(f"objective: {args.num_bins} bins (partition), maximize the smallest bin{cap_note}")
        print()

        t0 = time.perf_counter()
        bins = solve_maxmin_partition(sizes, args.num_bins, max_load_log=max_load_log)
        elapsed = time.perf_counter() - t0
        cap_bytes = args.max_kib * 1024 if args.max_kib is not None else None
        report(primes, bins, elapsed, cap_bytes=cap_bytes)
    elif args.objective == "maxcoverage":
        cap_bytes = args.cap_kib * 1024
        cap_log = math.log2(cap_bytes)
        print(f"objective: {args.num_bins} bins, each capped at {cap_bytes:.0f} bytes ({args.cap_kib:g} KiB), "
              f"maximize how many of the {len(primes)} candidate primes get pre-sieved")
        print()

        t0 = time.perf_counter()
        bins = solve_maxcoverage(sizes, args.num_bins, cap_log, time_limit_s=args.time_limit)
        elapsed = time.perf_counter() - t0
        included = sorted(primes[i] for b in bins for i in b)
        excluded = [p for p in primes if p not in included]
        print(f"included {len(included)}/{len(primes)} candidates: {included}")
        print(f"excluded (didn't fit): {excluded[:20]}{'...' if len(excluded) > 20 else ''}")
        print()
        report(primes, bins, elapsed, cap_bytes)
    elif args.objective == "costmodel":
        if args.exact_bins is not None and args.exact_bins > args.max_bins:
            args.max_bins = args.exact_bins
        group_cost = 1.0 / args.vec_len
        crossover_p = args.hit_cost_multiplier * ADMISSIBLE_RESIDUES_COUNT / WHEEL_CIRCUMFERENCE * args.vec_len
        print(f"objective: minimize GROUP_COST*(bins used) + sum(PRIME_COST(p) for p excluded) "
              f"+ sum(CACHE_COST for bins used) + SMALL_BUFFER_COST (once, smallest bin), "
              f"up to {args.max_bins} bins, no hard cap (numerical bound {args.max_buffer_kib:g} KiB)")
        print(f"GROUP_COST = 1/vec_len = {group_cost:.5f}  (vec_len={args.vec_len})")
        print(f"PRIME_COST(p) = {args.hit_cost_multiplier:g} * {ADMISSIBLE_RESIDUES_COUNT} / ({WHEEL_CIRCUMFERENCE} * p)  -> crosses GROUP_COST at p ~= {crossover_p:.1f}")
        print(f"CACHE_COST: soft per-bin target {args.cache_target_kib:g} KiB, coef {args.cache_cost_coef:g} per (bit over)^2")
        print(f"SMALL_BUFFER_COST: soft target {args.small_target_kib:g} KiB on the smallest used bin (once, not per bin), coef {args.small_cost_coef:g} per (bit under)^2")
        print("backend: HiGHS (MILP)")
        print()

        group_primes_list = solve_cost_model_cached(args, primes)
        if args.write_groups_to:
            write_presieve_groups(Path(args.write_groups_to), group_primes_list)
    else:
        target_bytes = args.cap_kib * 1024
        target_log = math.log2(target_bytes)
        print(f"objective: {args.num_bins} bins (cover, repeats allowed), minimize RMS deviation from "
              f"{target_bytes:.0f}-byte ({args.cap_kib:g} KiB) target")
        print()

        t0 = time.perf_counter()
        bins = solve_covering_to_target(sizes, args.num_bins, target_log, time_limit_s=args.time_limit)
        elapsed = time.perf_counter() - t0
        report(primes, bins, elapsed, cap_bytes=None)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
