use std::time::Instant;

const DEFAULT_LIMIT: usize = 100_000_000_000;

fn main() {
    let limit = std::env::args()
        .nth(1)
        .map(|s| s.parse::<usize>().expect("limit must be an integer"))
        .unwrap_or(DEFAULT_LIMIT);

    let t0 = Instant::now();
    let count = primal::Sieve::new(limit).prime_pi(limit);
    let elapsed = t0.elapsed();

    println!("Seconds: {:.3}", elapsed.as_secs_f64());
    println!("Primes: {}", count);
}
