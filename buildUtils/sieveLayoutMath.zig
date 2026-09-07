pub fn segmentElems(optSegmentSizeInKb: usize) usize {
    return 1024 * optSegmentSizeInKb;
}

pub fn stripeElems(l1CacheSizeInKb: usize, optSegmentSizeInKb: usize) usize {
    const smaller: usize = @min(l1CacheSizeInKb, optSegmentSizeInKb);
    return 1024 * smaller;
}

// The same "7-step cycle advances by at least 4/5 of the prime's own value"
// property that derives mediumLargeThreshold below would put this boundary
// at stripeElems*5/4 - the point where a bulk cycle can no longer fit within
// a stripe. That was tried and measured slower in practice: small's apply()
// re-checks every tracked prime's readiness once per stripe (~5x per
// segment, vs medium's once per segment), and that extra per-stripe
// checking overhead outweighs the bulk loop becoming reachable for the
// additional primes it would move from medium into small. Kept at this
// smaller, empirically better value instead.
pub fn smallMediumThreshold(l1CacheSizeInKb: usize, optSegmentSizeInKb: usize) usize {
    return stripeElems(l1CacheSizeInKb, optSegmentSizeInKb) / 5;
}

// A sieving prime's wheel cycle (7 of its 8 admissible-residue steps -
// applySievePrimeIntoSegmentMedium's bulk while loop condition) advances by
// at least 4/5 of the prime's own value in buckets, in the worst case over
// every residue class and wheel-step resume point - so segmentElems*5/4 is
// the point above which that bulk cycle can never fit in a segment for any
// resume point. That derivation says medium's own bulk loop stops paying
// off there, but largeSievePrimes.zig isn't the "no bulk loop" fallback its
// name once implied - it batches multiple primes' individual steps together
// for ILP (see that file), which benchmarked faster than medium's own bulk
// loop even somewhat below that crossover. Kept at segmentElems*1 instead -
// benchmarked against primesieve at N=1.2e12: batching plus this lower
// threshold together improved primeZ's margin from 0.53% to 1.17% versus
// segmentElems*5/4 with no batching.
pub fn mediumLargeThreshold(optSegmentSizeInKb: usize) usize {
    return segmentElems(optSegmentSizeInKb) * 1;
}

// A sieving prime's single wheel step (not a 7-step cycle) advances by at
// least 1/15 of its own value in buckets, in the worst case over every
// residue class and resume point. Below this threshold, a prime past
// MEDIUM_LARGE_THRESHOLD can still land more than once within a single
// segment (just never enough to complete a 7-step cycle); at or above it, a
// single step already exceeds a full segment regardless of where within the
// segment the prime is currently positioned, so it can cross off at most
// once per segment.
pub fn largeHugeThreshold(optSegmentSizeInKb: usize) usize {
    return segmentElems(optSegmentSizeInKb) * 15;
}
