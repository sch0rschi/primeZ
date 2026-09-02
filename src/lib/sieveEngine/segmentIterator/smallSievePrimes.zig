const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const STRIPE_ELEMS: usize = BuildUtils.STRIPE_ELEMS;

// Only small sieving primes need this: their squares (and thus their first
// multiple) routinely fall within the segment where they were discovered,
// and unlike medium/large primes they aren't bucketed by wheel-step, so a
// prime resuming mid-wheel across stripes can resume at any of the 8 steps.
//
// Every store address within an unrolled wheel cycle is computed as
// `currentBucketIndex + <comptime-accumulated offset>`, independent of the
// other stores in the same cycle, rather than chaining through a mutated
// index each sub-step - same technique as mediumSievePrimes.zig's
// applySievePrimeIntoSegmentMedium, generalized over all 8 possible
// (runtime) resume points (see ROTATED_ACCUMULATED below).
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
        var map: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime) = undefined;
        for (&map) |*list| {
            list.* = try std.ArrayList(SievePrime).initCapacity(allocator, 0);
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

    pub fn add(
        self: *SmallSievePrimes,
        allocator: std.mem.Allocator,
        comptime inBucketIndex: u3,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrime: SievePrime,
    ) !void {
        var registered = sievePrime;
        if (registered.currentBucketIndex < bucketsEndExclusive) {
            applySievePrimeIntoSegment(inBucketIndex, buckets, bucketsStart, bucketsEndExclusive, &registered);
        }
        try self.map[inBucketIndex].append(allocator, registered);
    }

    pub fn activate(self: *SmallSievePrimes, bucketsEndExclusive: usize) void {
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
