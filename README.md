# primeZ

primeZ is a prime number utility library written in Zig.\
Explicit performance. Close to the metal.

It takes inspiration from [primesieve](https://github.com/kimwalisch/primesieve)
our thanks to Kim Walisch for such a fast, well-documented implementation.
Earlier on, it drew inspiration from the Rust library [primal](https://github.com/huonw/primal) as well.

------------------------------------------------------------------------

## What primeZ provides

primeZ exposes two core capabilities:

### 1. Prime generation

Generate all prime numbers up to a given upper bound using a segmented
sieve.

The result is a dense, ordered list of primes up to the requested limit.

### 2. Fast primality queries

After initialization, primeZ supports fast `isPrime(n)` queries for
numbers within the computed range. It falls back to Miller Rabin for
numbers outside the range.

------------------------------------------------------------------------

## Benchmark

The library itself (`src/lib/`) has no entry point — same as
libprimesieve. `src/main.zig` is primeZ's own small CLI, calling into
the library through its public module boundary, the same relationship
primesieve's `src/app/` (its CLI) has to libprimesieve. It sieves
primes up to a given limit and reports the count and elapsed time —
the same summary primesieve's own CLI prints with `--time`.

### Running it

Build once and call the binary directly, like primesieve:

``` sh
zig build
./zig-out/bin/primez 100000000000
```

The build is optimized for a hardware profile: the L1d, L2 and L3 cache
sizes. On a native build they are auto-detected; they can be overridden
(values in KiB), and cross builds without them default to a mainstream
fallback profile (32 KiB L1d, 1 MiB L2, 16 MiB L3):

``` sh
zig build -Dl1cs=48 -Dl2cs=1024 -Dl3cs=16384
```

At runtime the binary detects the actual cache sizes. If they match the
build profile it uses the build-optimal presieve; otherwise it derives the
layout from the detected caches and uses a fallback presieve tuned for the
fallback profile. The segment size is chosen per query
(`clamp(2*sqrt(limit), L2/2, L3/4)`, as a power of two, at most 8 MiB), and
the tier thresholds scale with it. `primez --print-layout <limit>` shows
the decision; `--profile l1,l2,l3` emulates another machine and
`--fallback` forces the fallback presieve. `-Dsegsz=<KiB>` pins the
segment size for experiments.

The binary carries two presieves. The build presieve's groups are solved
during the build for the build profile's L1d size and SIMD width with
presieveOpt's MILP (needs `python3` and `make`; the solve is cached). The
fallback presieve uses groups solved once for 32 KiB L1d and AVX2 and
hardcoded in `buildUtils/presieveGroups.zig`. When the build profile has the
fallback's L1d size and SIMD width, or the solver is disabled
(`-Dpresieve_solver=false`) or unavailable, only the fallback presieve is
built in.

### Comparing against primesieve

`bench/` vendors [primesieve](https://github.com/kimwalisch/primesieve)
as a git submodule and provides a `Makefile` that builds both and reports
a side-by-side wall-time comparison over four fixed range scenarios, each
calibrated to run in roughly 5-10s: two from-zero ranges ("small", "big")
and two much higher offsets at roughly the same window width ("high",
"extreme" - named for how deep the offset is, not window width):

``` sh
git submodule update --init bench/primesieve
make -C bench bench
```

Each scenario is checked for a matching prime count between the two
implementations before its timing is reported. See `bench/Makefile` for
the scenario bounds and other variables (`REPEATS` for best-of-N timing,
`ONLY` to run a subset of scenarios).

------------------------------------------------------------------------

## License

primeZ is licensed under the MIT License.

------------------------------------------------------------------------

## Trivia

The features of primeZ are mainly driven by what is needed to solve
prime related [Project Euler](https://projecteuler.net/) puzzles.
