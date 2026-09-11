const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const STRIPE_ELEMS: usize = BuildUtils.STRIPE_ELEMS;
const SMALL_MEDIUM_THRESHOLD: usize = BuildUtils.SMALL_MEDIUM_THRESHOLD;

// Only small primes need this: their squares routinely fall within the
// segment where they were discovered, and unlike medium/large primes they
// aren't bucketed by wheel-step, so a prime can resume at any of the 8
// steps. ROTATED_ACCUMULATED precomputes all 8 possible resume points so
// each store address is `currentBucketIndex + <accumulated offset>`,
// independent of the others in the same cycle.
inline fn applySievePrimeIntoSegment(
    comptime inBucketIndex: u3,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    bucketsStart: usize,
    bucketsEndExclusive: usize,
    sievePrime: *SievePrime,
) void {
    const bucketCount = bucketsEndExclusive - bucketsStart;
    const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
    var currentBucketIndex = sievePrime.currentBucketIndex - bucketsStart;

    @setEvalBranchQuota(1 << 20);
    const ROTATED_ACCUMULATED: [Comptimes.ADMISSIBLE_RESIDUES.count][Comptimes.ADMISSIBLE_RESIDUES.count + 1]Comptimes.WheelStep = comptime blk: {
        var rotations: [Comptimes.ADMISSIBLE_RESIDUES.count][Comptimes.ADMISSIBLE_RESIDUES.count + 1]Comptimes.WheelStep = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |resumeAt| {
            var wheelPattern = Comptimes.WHEEL_PATTERNS[inBucketIndex];
            std.mem.rotate(Comptimes.WheelStep, wheelPattern[0..], resumeAt);

            rotations[resumeAt][0].divMultiplicator = 0;
            rotations[resumeAt][0].residueAddend = 0;
            for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |stepIndex| {
                rotations[resumeAt][stepIndex + 1].divMultiplicator =
                    rotations[resumeAt][stepIndex].divMultiplicator + wheelPattern[stepIndex].divMultiplicator;
                rotations[resumeAt][stepIndex + 1].residueAddend =
                    rotations[resumeAt][stepIndex].residueAddend + wheelPattern[stepIndex].residueAddend;
                rotations[resumeAt][stepIndex].bitMask = wheelPattern[stepIndex].bitMask;
            }
        }
        break :blk rotations;
    };

    const wheelStepIndex = sievePrime.wheelStepIndex;
    const accumulatedWheelPattern = &ROTATED_ACCUMULATED[wheelStepIndex];

    var accumulatedBucketIndexAdvance: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]usize = undefined;
    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count + 1) |stepIndex| {
        accumulatedBucketIndexAdvance[stepIndex] =
            initialBucketIndex * accumulatedWheelPattern[stepIndex].divMultiplicator + accumulatedWheelPattern[stepIndex].residueAddend;
    }

    while (currentBucketIndex + accumulatedBucketIndexAdvance[7] < bucketCount) {
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |si| {
            buckets[currentBucketIndex + accumulatedBucketIndexAdvance[si]] &= accumulatedWheelPattern[si].bitMask;
        }
        currentBucketIndex += accumulatedBucketIndexAdvance[8];
    }

    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
        if (currentBucketIndex + accumulatedBucketIndexAdvance[ari] < bucketCount) {
            buckets[currentBucketIndex + accumulatedBucketIndexAdvance[ari]] &= accumulatedWheelPattern[ari].bitMask;
        } else {
            sievePrime.currentBucketIndex = currentBucketIndex + accumulatedBucketIndexAdvance[ari] + bucketsStart;
            sievePrime.wheelStepIndex = wheelStepIndex +% @as(u3, ari);
            return;
        }
    } else {
        unreachable;
    }
}

pub const SmallSievePrimes = struct {
    map: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime),
    activeCounts: [Comptimes.ADMISSIBLE_RESIDUES.count]usize,

    pub fn init(allocator: std.mem.Allocator) !SmallSievePrimes {
        // Every small-tier prime is <= SMALL_MEDIUM_THRESHOLD, so reserving
        // that upper bound for each residue's own list lets add() use
        // appendAssumeCapacity.
        const capacity = Estimates.primeCountUpperBound(SMALL_MEDIUM_THRESHOLD);
        var map: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime) = undefined;
        for (&map) |*list| {
            list.* = try std.ArrayList(SievePrime).initCapacity(allocator, capacity);
        }

        return SmallSievePrimes{
            .map = map,
            .activeCounts = .{0} ** Comptimes.ADMISSIBLE_RESIDUES.count,
        };
    }

    pub fn deinit(self: *SmallSievePrimes, allocator: std.mem.Allocator) void {
        for (&self.map) |*list| {
            list.deinit(allocator);
        }
    }

    pub noinline fn add(
        self: *SmallSievePrimes,
        comptime inBucketIndex: u3,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrime: SievePrime,
    ) void {
        var registered = sievePrime;
        if (registered.currentBucketIndex < bucketsEndExclusive) {
            applySievePrimeIntoSegment(inBucketIndex, buckets, bucketsStart, bucketsEndExclusive, &registered);
        }
        self.map[inBucketIndex].appendAssumeCapacity(registered);
    }

    /// activate()'s early-break scan assumes each of the 8 per-residue
    /// lists is sorted by currentBucketIndex. Discovery files primes in
    /// increasing prime-value order, which only coincides with increasing
    /// currentBucketIndex order when every target is relative to 0 -
    /// targets relative to an arbitrary start aren't monotonic in prime.
    /// Must be called once, after discovery and before the first
    /// activate(), to restore that invariant.
    pub fn sortByPosition(self: *SmallSievePrimes) void {
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            std.mem.sortUnstable(SievePrime, self.map[ari].items, {}, SievePrimeMod.lessThanByCurrentBucketIndex);
        }
    }

    pub noinline fn activate(self: *SmallSievePrimes, bucketsEndExclusive: usize) void {
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            const pending = self.map[ari].items[self.activeCounts[ari]..];
            for (pending) |sievePrime| {
                if (sievePrime.currentBucketIndex < bucketsEndExclusive) {
                    self.activeCounts[ari] += 1;
                } else {
                    break;
                }
            }
        }
    }

    pub noinline fn apply(
        self: *SmallSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        var stripeEnd = bucketsStart;
        while (stripeEnd < bucketsEndExclusive) {
            stripeEnd = @min(stripeEnd + STRIPE_ELEMS, bucketsEndExclusive);

            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                for (self.map[ari].items[0..self.activeCounts[ari]]) |*sievePrime| {
                    if (sievePrime.currentBucketIndex < stripeEnd) {
                        applySievePrimeIntoSegment(ari, buckets, bucketsStart, stripeEnd, sievePrime);
                    }
                }
            }
        }
    }
};
