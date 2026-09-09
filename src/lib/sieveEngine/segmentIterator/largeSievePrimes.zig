const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

// applyNSievePrimesIntoSegment's fast path keeps 4 live values per batched
// prime (a wheel-pattern pointer, initialBucketIndex, currentBucketIndex,
// wheelStepIndex) in registers across the whole inner loop - a batch size
// that overflows the architecture's real GPR count spills some of those to
// the stack every iteration instead. On this machine (16 GPRs -> batch 3),
// sweeping 2/3/4/5/6/8 at N=6e11 (2 repeats each) found 3 consistently ~2%
// faster than the previous hardcoded 2, degrading smoothly above that as
// batch size grows past what fits in registers - consistent with the
// spilling theory. That margin didn't reproduce in a single N=1.2e12 run
// (statistically tied with batch 2 there), most likely single-run noise at
// that scale rather than the effect vanishing, but not independently
// confirmed. The /5 divisor itself is carried over unchanged from an older
// version of this codebase that used it for a differently-shaped tier
// split; it hasn't been independently re-derived for the current one.
const BATCH_SIZE: usize = BuildUtils.GENERAL_PURPOSE_REGISTER_COUNT / 5;

// Primes above MEDIUM_LARGE_THRESHOLD (up to LARGE_HUGE_THRESHOLD, see
// hugeSievePrimes.zig): a full wheel cycle doesn't reliably fit within a
// single segment, but more than one individual wheel step still can - a
// prime near the low end of this range can hit a segment several times.
// Rather than a bulk-cycle batch loop (unhelpful here) or per-prime
// comptime-specialized dispatch (measured no different from a flat
// runtime-indexed layout at this tier's once-per-segment call frequency -
// see project history), this batches BATCH_SIZE primes together and steps
// them one wheel-step at a time in lockstep, so their independent loads/
// stores can overlap instead of fully serializing per prime. Correct for
// any prime magnitude above medium's own range regardless of exactly where
// MEDIUM_LARGE_THRESHOLD/LARGE_HUGE_THRESHOLD sit - those only affect how
// much of this algorithm's more-than-one-hit-per-segment capability
// actually gets used.
pub const LargeSievePrimes = struct {
    list: std.ArrayList(SievePrime),
    activeCount: usize,

    pub fn init(allocator: std.mem.Allocator) !LargeSievePrimes {
        // Every large-tier prime is <= LARGE_HUGE_THRESHOLD, a fixed
        // build-time constant - Estimates.primeCountUpperBound of it is a
        // safe (if slightly generous - it bounds the whole [0, threshold]
        // prefix, not just this tier's own slice above MEDIUM_LARGE_THRESHOLD)
        // upper bound on this tier's population, letting add() use
        // appendAssumeCapacity.
        const capacity = Estimates.primeCountUpperBound(BuildUtils.LARGE_HUGE_THRESHOLD);
        return LargeSievePrimes{
            .list = try std.ArrayList(SievePrime).initCapacity(allocator, capacity),
            .activeCount = 0,
        };
    }

    pub fn deinit(self: *LargeSievePrimes, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    pub fn add(
        self: *LargeSievePrimes,
        sievePrime: SievePrime,
    ) void {
        self.list.appendAssumeCapacity(sievePrime);
    }

    /// See SmallSievePrimes.sortByPosition - same reasoning, same
    /// requirement to run once after discovery's add() calls and before
    /// the first activate().
    pub fn sortByPosition(self: *LargeSievePrimes) void {
        std.mem.sortUnstable(SievePrime, self.list.items, {}, SievePrimeMod.lessThanByCurrentBucketIndex);
    }

    pub noinline fn activate(self: *LargeSievePrimes, bucketsEndExclusive: usize) void {
        for (self.list.items[self.activeCount..]) |sievePrime| {
            if (sievePrime.currentBucketIndex < bucketsEndExclusive) {
                self.activeCount += 1;
            } else {
                break;
            }
        }
    }

    pub fn apply(
        self: *LargeSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        applyBatch(BATCH_SIZE, buckets, bucketsStart, bucketsEndExclusive, self.list.items[0..self.activeCount]);
    }

    noinline fn applyBatch(
        comptime batchSize: usize,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        activeSievePrimes: []SievePrime,
    ) void {
        var readySievePrimes: [batchSize]*SievePrime = undefined;
        var readySievePrimesCount: usize = 0;

        for (activeSievePrimes) |*sievePrime| {
            if (sievePrime.currentBucketIndex < bucketsEndExclusive) {
                readySievePrimes[readySievePrimesCount] = sievePrime;
                readySievePrimesCount += 1;
                if (readySievePrimesCount == batchSize) {
                    applyNSievePrimesIntoSegment(batchSize, buckets, bucketsStart, bucketsEndExclusive, &readySievePrimes);
                    readySievePrimesCount = 0;
                }
            }
        }

        if (readySievePrimesCount > 0) { // Leftover 1..n-1 primes: fall back to smaller batch.
            inline for (0..batchSize) |leftoverCount| {
                if (leftoverCount == readySievePrimesCount) {
                    applyNSievePrimesIntoSegment(leftoverCount, buckets, bucketsStart, bucketsEndExclusive, readySievePrimes[0..leftoverCount]);
                    break;
                }
            }
        }
    }

    inline fn applyNSievePrimesIntoSegment(
        comptime n: usize,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrimes: *[n]*SievePrime,
    ) void {
        const bucketCount = bucketsEndExclusive - bucketsStart;

        var wheelPatterns: [n]*const [Comptimes.ADMISSIBLE_RESIDUES.count]Comptimes.WheelStep = undefined;
        var initialBucketIndices: [n]usize = undefined;
        var currentBucketIndices: [n]usize = undefined;
        var wheelStepIndex: [n]usize = undefined;

        inline for (0..n) |i| {
            wheelPatterns[i] = &Comptimes.WHEEL_PATTERNS[sievePrimes[i].initialInBucketIndex];
            initialBucketIndices[i] = @as(usize, sievePrimes[i].initialBucketIndex);
            currentBucketIndices[i] = sievePrimes[i].currentBucketIndex - bucketsStart;
            wheelStepIndex[i] = @as(usize, sievePrimes[i].wheelStepIndex);
        }

        // Fast path: all n primes still have room in this segment.
        var allWithinBucketEndExclusive = true;
        while (allWithinBucketEndExclusive) {
            inline for (0..n) |spi| {
                const step = &wheelPatterns[spi][wheelStepIndex[spi]];
                buckets[currentBucketIndices[spi]] &= step.bitMask;
                currentBucketIndices[spi] +=
                    initialBucketIndices[spi] * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                wheelStepIndex[spi] += 1;
                wheelStepIndex[spi] %= Comptimes.ADMISSIBLE_RESIDUES.count;
                allWithinBucketEndExclusive &= currentBucketIndices[spi] < bucketCount;
            }
        }

        // Tail: each non exhausted sieve prime finishes alone.
        inline for (0..n) |spi| {
            while (currentBucketIndices[spi] < bucketCount) {
                const step = wheelPatterns[spi][wheelStepIndex[spi]];
                buckets[currentBucketIndices[spi]] &= step.bitMask;
                currentBucketIndices[spi] +=
                    initialBucketIndices[spi] * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                wheelStepIndex[spi] += 1;
                wheelStepIndex[spi] %= Comptimes.ADMISSIBLE_RESIDUES.count;
            }
            sievePrimes[spi].currentBucketIndex = currentBucketIndices[spi] + bucketsStart;
            sievePrimes[spi].wheelStepIndex = @intCast(wheelStepIndex[spi]);
        }
    }
};
