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

The build auto-detects the CPU's L1 and L2 cache sizes and derives a
segment size from them internally. Both cache sizes are build-time
parameters that can be overridden:

``` sh
zig build -Dl1_cache_size_in_kb=128 -Dl2_cache_size_in_kb=1024
```

Values are specified in KiB.

### Comparing against primesieve

`bench/` vendors [primesieve](https://github.com/kimwalisch/primesieve)
as a git submodule and provides a `Makefile` that builds both, records
each (`perf` on Linux, `sample` on macOS), and reports a side-by-side
breakdown of time spent in the small/medium/large sieving-prime regimes
both implementations use internally:

``` sh
git submodule update --init bench/primesieve
make -C bench bench
```

On macOS, `sample` ships with the Xcode Command Line Tools and needs
Python 3 on `PATH` to parse its output; if it can't attach to the
benchmark process, try re-running under `sudo`.

See `bench/Makefile` for the available targets and variables.

------------------------------------------------------------------------

## License

primeZ is licensed under the MIT License.

------------------------------------------------------------------------

## Trivia

The features of primeZ are mainly driven by what is needed to solve
prime related [Project Euler](https://projecteuler.net/) puzzles.
