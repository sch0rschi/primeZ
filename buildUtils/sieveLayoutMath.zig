pub fn segmentElems(optSegmentSizeInKb: usize) usize {
    return 1024 * optSegmentSizeInKb;
}

pub fn stripeElems(l1CacheSizeInKb: usize, optSegmentSizeInKb: usize) usize {
    const smaller: usize = @min(l1CacheSizeInKb, optSegmentSizeInKb);
    return 1024 * smaller;
}

// Empirically better than stripeElems*5/4 (the point where a bulk 7-step
// cycle stops fitting in a stripe): small's apply() re-checks readiness
// once per stripe (~5x per segment vs medium's once), and that overhead
// outweighs moving more primes into small at the larger threshold.
pub fn smallMediumThreshold(l1CacheSizeInKb: usize, optSegmentSizeInKb: usize) usize {
    return stripeElems(l1CacheSizeInKb, optSegmentSizeInKb) / 5;
}

// A sieving prime's 7-of-8-step wheel cycle advances by at least 4/5 of
// its own value in buckets, worst case - segmentElems*5/4 is the point
// above which that bulk cycle can never fit in a segment. Kept lower, at
// segmentElems*1: largeSievePrimes.zig's batched-ILP stepping benchmarks
// faster than medium's bulk loop even below that crossover.
pub fn mediumLargeThreshold(optSegmentSizeInKb: usize) usize {
    return segmentElems(optSegmentSizeInKb) * 1;
}

// A single wheel step advances by at least 1/15 of the prime's own value
// in buckets, worst case over every residue class and resume point. At or
// above this threshold a single step already exceeds a full segment, so a
// prime crosses off at most once per segment.
pub fn largeHugeThreshold(optSegmentSizeInKb: usize) usize {
    return segmentElems(optSegmentSizeInKb) * 15;
}

// Splits [MEDIUM_LARGE_THRESHOLD, LARGE_HUGE_THRESHOLD] between two
// designs: largeSievePrimes.zig's batched-ILP stepping (pays off only
// once a shared step loop iterates more than once - needs >=2 genuine
// hits/segment) below this threshold, largeHeadSievePrimes.zig's
// comptime-folded single-step design (built for exactly one hit, rare
// bounded fallback) at or above it.
//
// A wheel-30 prime's per-step advance, in 1/30ths of its own value,
// cycles through the fixed gap sequence [6, 4, 2, 4, 2, 4, 6, 2]
// regardless of residue class or phase. The smallest single gap is 2
// (giving largeHugeThreshold's prime/15), but the smallest sum of two
// CONSECUTIVE gaps is 4+2=6 (a "2" is always neighbored by "4"s, never
// another "2") - the true worst-case pair advances by at least
// prime*6/30 = prime/5, not prime*2/15. So the point where even the
// tightest achievable pair of steps already spans a full segment
// (guaranteeing at most 2 hits) is prime/5 >= segmentElems.
pub fn largeHeadThreshold(optSegmentSizeInKb: usize) usize {
    return segmentElems(optSegmentSizeInKb) * 5;
}
