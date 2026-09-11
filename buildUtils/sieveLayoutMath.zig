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

// Splits the [MEDIUM_LARGE_THRESHOLD, LARGE_HUGE_THRESHOLD] band in two,
// each half matched to a different sieving-prime design by *why* that
// design is fast, not just by benchmarking until one wins:
//
// - "batch" sub-tier below this (largeSievePrimes.zig): steps BATCH_SIZE
//   primes together one wheel-step at a time in a shared loop, so their
//   independent loads/stores can overlap (ILP) instead of serializing.
//   That overlap is only real work while the shared loop actually keeps
//   iterating - the first iteration is fully consumed just packing each
//   prime's wheel-pattern pointer/indices into the batch's local arrays,
//   so a batch that manages only one shared step before some prime in it
//   is already done has paid full setup cost for nothing a plain per-
//   prime step wouldn't have paid too. It needs at least a second shared
//   iteration to come out ahead.
// - "head" sub-tier at or above it (largeHeadSievePrimes.zig): (residue,
//   wheel-phase)-bucketed so every prime in a call shares the same
//   entering phase, letting the compiler constant-fold the first step's
//   table lookup - no runtime index, no batch-array setup at all. It's
//   built to assume exactly one hit (the cheap, comptime-folded path) and
//   fall back to a plain runtime-indexed loop only for whatever's left
//   over - correct for any number of extra hits, but only actually cheap
//   because that fallback is rare by construction in this sub-tier.
//
// So the mechanism that decides the winner is the same on both sides: how
// many hits-per-segment headroom is actually available to spend. Below
// this threshold, batch's shared loop still has >= 2 genuine iterations of
// headroom to amortize its setup cost against, worst case; at or above it,
// there's worst-case room for at most one hit beyond the first, which is
// exactly head's designed-for common case (one comptime-folded step) with
// a bounded, rarely-taken fallback - never the *unbounded* per-step tail
// batch would otherwise need to keep affording its own setup cost.
//
// Derived the same way as largeHugeThreshold (a worst-case step-size
// bound), one step further - but NOT by naively doubling
// largeHugeThreshold's own single-step minimum (prime/15): that assumes
// two minimal steps can occur back to back, which the wheel's own step
// sequence never actually allows. A wheel-30 sieving prime's per-step
// advance, in 1/30ths of its own value, cycles through the same 8-long
// gap sequence [6, 4, 2, 4, 2, 4, 6, 2] regardless of residue class or
// starting phase (only the phase shifts, not the multiset or its order -
// verified by simulating buildWheelPatterns()'s own comptime logic, see
// project memory large_head_threshold_derivation). The smallest SINGLE
// gap is 2 (giving largeHugeThreshold's prime/15), but the smallest sum
// of any two CONSECUTIVE gaps in that fixed cyclic sequence is 4+2 = 6
// (a "2" is always neighbored by "4"s, never by another "2") - i.e. the
// true worst-case pair of steps advances by at least prime*6/30 =
// prime/5, not the looser prime*2/15 a naive doubling would assume.
//
// So the real "at most 2 hits guaranteed" point is where even that
// tightest achievable pair already spans a full segment:
// prime/5 >= segmentElems, i.e. prime >= segmentElems*5 - below which
// more than 2 hits per segment are still (worst-case) possible, and at
// or above which at most 2 are. Notably closer to mediumLargeThreshold's
// own segmentElems*1 than to largeHugeThreshold's segmentElems*15 - most
// of this tier's own [MEDIUM_LARGE_THRESHOLD, LARGE_HUGE_THRESHOLD] span
// belongs to the head design, not the batch one (see largeSievePrimes.zig
// for why: batch's shared per-batch setup cost only earns anything back
// once its lockstep loop manages a second real iteration, which needs
// this same "genuine 3-hit headroom" this threshold is about).
pub fn largeHeadThreshold(optSegmentSizeInKb: usize) usize {
    return segmentElems(optSegmentSizeInKb) * 5;
}
