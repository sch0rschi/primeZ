#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import time
from pathlib import Path

from ortools.sat.python import cp_model

SCALE = 1_000_000

DEFAULT_PRIMES = [7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97]

def sieve_primes(limit: int) -> list[int]:
    is_prime = [True] * (limit + 1)
    is_prime[0:2] = [False, False]
    for p in range(2, math.isqrt(limit) + 1):
        if is_prime[p]:
            for multiple in range(p * p, limit + 1, p):
                is_prime[multiple] = False
    return [p for p in range(2, limit + 1) if is_prime[p]]

WHEEL_CIRCUMFERENCE = 30
ADMISSIBLE_RESIDUES_COUNT = 8
EXPECTED_VEC_LEN = 64

EXTENDED_CANDIDATE_PRIMES = [p for p in sieve_primes(2000) if p >= 7]

EPS = 1e-9

def first_fit_decreasing(sizes: list[float], capacity: float) -> list[list[int]]:
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
    n = len(sizes)

    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    int_sizes = [round(s * SCALE) for s in sizes_sorted]
    int_cap = math.floor(capacity * SCALE)

    ffd_bins = first_fit_decreasing(sizes_sorted, capacity)
    upper_bound = len(ffd_bins)

    model = cp_model.CpModel()
    x = [[model.NewBoolVar(f"x_{i}_{b}") for b in range(min(i, upper_bound - 1) + 1)] for i in range(n)]
    y = [model.NewBoolVar(f"y_{b}") for b in range(upper_bound)]

    for i in range(n):
        model.AddExactlyOne(x[i])

    for b in range(upper_bound):
        items_reaching_b = [i for i in range(n) if b < len(x[i])]
        model.Add(sum(int_sizes[i] * x[i][b] for i in items_reaching_b) <= int_cap)
        model.Add(sum(x[i][b] for i in items_reaching_b) <= n * y[b])

    for b in range(upper_bound - 1):
        model.Add(y[b] >= y[b + 1])
        load_b = sum(int_sizes[i] * x[i][b] for i in range(n) if b < len(x[i]))
        load_b1 = sum(int_sizes[i] * x[i][b + 1] for i in range(n) if b + 1 < len(x[i]))
        model.Add(load_b >= load_b1)

    model.Minimize(sum(y))

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
    n = len(sizes)
    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    int_sizes = [round(s * SCALE) for s in sizes_sorted]
    total = sum(int_sizes)

    model = cp_model.CpModel()
    x = [[model.NewBoolVar(f"x_{i}_{b}") for b in range(min(i, num_bins - 1) + 1)] for i in range(n)]

    for i in range(n):
        model.AddExactlyOne(x[i])

    loads = []
    for b in range(num_bins):
        items_reaching_b = [i for i in range(n) if b < len(x[i])]
        load = model.NewIntVar(0, total, f"load_{b}")
        model.Add(load == sum(int_sizes[i] * x[i][b] for i in items_reaching_b))
        loads.append(load)

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
    n = len(sizes)
    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    int_sizes = [round(s * SCALE) for s in sizes_sorted]
    total = sum(int_sizes)

    model = cp_model.CpModel()
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
    n = len(sizes)
    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    int_sizes = [round(s * SCALE) for s in sizes_sorted]
    total = sum(int_sizes)

    model = cp_model.CpModel()
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
    n = len(sizes)
    order = sorted(range(n), key=lambda i: -sizes[i])
    sizes_sorted = [sizes[i] for i in order]
    int_sizes = [round(s * SCALE) for s in sizes_sorted]
    int_target = round(target * SCALE)
    max_load = sum(int_sizes)

    model = cp_model.CpModel()
    x = [[model.NewBoolVar(f"x_{i}_{b}") for b in range(num_bins)] for i in range(n)]

    for i in range(n):
        model.AddAtLeastOne(x[i])

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
    n = len(sizes)
    int_sizes = [round(s * SCALE) for s in sizes]
    int_cap = math.floor(cap * SCALE)
    total = sum(int_sizes)

    model = cp_model.CpModel()
    x = [[model.NewBoolVar(f"x_{i}_{b}") for b in range(min(i, num_bins - 1) + 1)] for i in range(n)]

    included = [model.NewBoolVar(f"inc_{i}") for i in range(n)]
    for i in range(n):
        model.Add(included[i] == sum(x[i]))
        model.AddAtMostOne(x[i])
    for i in range(1, n):
        model.Add(included[i] <= included[i - 1])

    loads = []
    for b in range(num_bins):
        items_reaching_b = [i for i in range(n) if b < len(x[i])]
        load = model.NewIntVar(0, min(total, int_cap), f"load_{b}")
        model.Add(load == sum(int_sizes[i] * x[i][b] for i in items_reaching_b))
        model.Add(load <= int_cap)
        loads.append(load)

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
    return hit_cost_multiplier * ADMISSIBLE_RESIDUES_COUNT / (WHEEL_CIRCUMFERENCE * p)

def _tangent_points(x_max: float, count: int) -> list[float]:
    if count <= 1:
        return [x_max / 2]
    return [x_max * k / (count - 1) for k in range(count)]

def _add_convex_quadratic_penalty(h, expr, coef: float, x_max: float, num_segments: int = 12):
    p = h.addVariable(lb=0)
    for x_k in _tangent_points(x_max, num_segments):
        h.addConstr(p >= 2 * coef * x_k * expr - coef * x_k * x_k)
    return p

def _cost_model_ffd_hint(
    primes: list[int], max_bins: int, max_buffer_bytes: float
) -> list[int | None]:
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
    for i in range(n - 1):
        h.addConstr(included[i] <= included[i + 1])

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

    min_load = h.addVariable(lb=0, ub=max_load, name="min_load")
    for b in range(max_bins):
        h.addConstr(min_load <= loads[b] + max_load * (1 - y[b]))
    small_shortfall = h.addVariable(lb=0, ub=small_target_log, name="small_shortfall")
    h.addConstr(small_shortfall >= small_target_log - min_load)
    small_penalty = _add_convex_quadratic_penalty(h, small_shortfall, small_cost_coef, small_target_log)
    penalty_terms.append(small_penalty)

    for b in range(max_bins - 1):
        h.addConstr(y[b] >= y[b + 1])

    if exact_bins is not None:
        h.addConstr(sum(y) == exact_bins)

    h.setObjective(
        group_cost * sum(y)
        + sum(prime_costs_sorted[i] * (1 - included[i]) for i in range(n))
        + sum(penalty_terms),
        sense=highspy.ObjSense.kMinimize,
    )

    if warm_start:
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
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [",".join(str(p) for p in group_primes) for group_primes in group_primes_list]
    path.write_text("\n".join(lines) + "\n")
    print(f"wrote {len(group_primes_list)} groups to {path}")

_SOLVE_CACHE_RELEVANT_ARGS = (
    "hit_cost_multiplier", "vec_len", "cache_target_kib", "cache_cost_coef",
    "small_target_kib", "small_cost_coef", "max_buffer_kib", "max_bins",
    "gap_limit", "time_limit", "primes", "exact_bins",
)

def _solve_cache_fingerprint(args: argparse.Namespace) -> str:
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
