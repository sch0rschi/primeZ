# primeZ

primeZ is a prime number utility library written in Zig.\
Explicit performance. Close to the metal.

It takes inspiration from the Rust library
[primal](https://github.com/huonw/primal) and, transitively,\
from [primesieve](https://github.com/kimwalisch/primesieve).

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

The build supports configuring the assumed L1 cache size (used as the
sieve's segment size) via a build-time parameter:

``` sh
zig build -Dl1_cache_size=128
```

The value is specified in KiB.

### Comparing against primesieve

`bench/` vendors [primesieve](https://github.com/kimwalisch/primesieve)
as a git submodule and provides a `Makefile` that builds both, records
each with `perf`, and reports a side-by-side breakdown of time spent in
the small/medium/large sieving-prime regimes both implementations use
internally:

``` sh
git submodule update --init bench/primesieve
make -C bench bench
```

See `bench/Makefile` for the available targets and variables.

------------------------------------------------------------------------

## License

primeZ is licensed under the MIT License.

------------------------------------------------------------------------

## Trivia

The features of primeZ are mainly driven by what is needed to solve
prime related [Project Euler](https://projecteuler.net/) puzzles.
