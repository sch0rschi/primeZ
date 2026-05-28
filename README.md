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

primeZ includes a benchmark for measuring sieve performance over 100
full runs.

The benchmark repeatedly constructs a segmented sieve for values up to
100 Million, followed by prime collection to measure performance.

### Running the benchmark

Build and run the benchmark with:

``` sh
zig build benchmark
```

The build supports configuring the assumed L1 cache size via a
build-time parameter:

``` sh
zig build benchmark -Dl1-cache-size=128
```

The value is specified in KiB.

------------------------------------------------------------------------

## License

primeZ is licensed under the MIT License.

------------------------------------------------------------------------

## Trivia

The features of primeZ are mainly driven by what is needed to solve
prime related [Project Euler](https://projecteuler.net/) puzzles.
