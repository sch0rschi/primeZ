const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const LayoutMod = @import("../layout.zig");
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
const CompactSievePrime = SievePrimeMod.SmallStrideCompactSievePrime;

comptime {
    if (LayoutMod.MAX_SEGMENT_ELEMS > 1 << 23) @compileError("MAX_SEGMENT_ELEMS exceeds CompactSievePrime.localOffset's u23 budget - widen that field before raising this bound");
}

inline fn applyCompactSievePrimeIntoSegment(
    comptime inBucketIndex: u3,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    bucketsStart: usize,
    bucketsEndExclusive: usize,
    segmentElems: usize,
    entry: *CompactSievePrime,
) void {
    const bucketCount = bucketsEndExclusive - bucketsStart;
    const initialBucketIndex = @as(usize, entry.initialBucketIndex);
    var currentBucketIndex: usize = entry.localOffset;

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

    const ROTATED_BY_BIT: [Comptimes.ADMISSIBLE_RESIDUES.count][Comptimes.ADMISSIBLE_RESIDUES.count]Comptimes.WheelStep = comptime blk: {
        var byBit: [Comptimes.ADMISSIBLE_RESIDUES.count][Comptimes.ADMISSIBLE_RESIDUES.count]Comptimes.WheelStep = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |resumeAt| {
            for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |stepIndex| {
                const step = ROTATED_ACCUMULATED[resumeAt][stepIndex];
                byBit[resumeAt][@ctz(~step.bitMask)] = step;
            }
        }
        break :blk byBit;
    };

    const wheelStepIndex = entry.wheelStepIndex;
    const accumulatedWheelPattern = &ROTATED_ACCUMULATED[wheelStepIndex];
    const byBit = &ROTATED_BY_BIT[wheelStepIndex];

    var bitAdvance: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = undefined;
    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |bit| {
        bitAdvance[bit] = initialBucketIndex * byBit[bit].divMultiplicator + byBit[bit].residueAddend;
    }
    const lastAdvance = initialBucketIndex * accumulatedWheelPattern[7].divMultiplicator + accumulatedWheelPattern[7].residueAddend;
    const wheelAdvance = initialBucketIndex * accumulatedWheelPattern[8].divMultiplicator + accumulatedWheelPattern[8].residueAddend;

    while (currentBucketIndex + lastAdvance < bucketCount) {
        const window = buckets[currentBucketIndex..];
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |bit| {
            window[bitAdvance[bit]] &= ~@as(Types.SIEVE_BUCKET_TYPE, 1 << bit);
        }
        currentBucketIndex += wheelAdvance;
    }

    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
        const index = currentBucketIndex + initialBucketIndex * accumulatedWheelPattern[ari].divMultiplicator + accumulatedWheelPattern[ari].residueAddend;
        if (index < bucketCount) {
            buckets[index] &= accumulatedWheelPattern[ari].bitMask;
        } else {
            const reduced = if (index >= segmentElems) index - segmentElems else index;
            entry.localOffset = @intCast(reduced);
            entry.wheelStepIndex = wheelStepIndex +% @as(u3, ari);
            return;
        }
    } else {
        unreachable;
    }
}

pub const SmallStrideSievePrimes = struct {
    pending: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime),
    pendingStart: [Comptimes.ADMISSIBLE_RESIDUES.count]usize,

    active: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(CompactSievePrime),

    segmentElems: usize,
    strideElems: usize,

    pub fn init(allocator: std.mem.Allocator, segmentElems: usize, strideElems: usize, minPrimeExclusive: usize, maxPrime: usize) !SmallStrideSievePrimes {
        const capacity: usize = @intCast(Estimates.primeCountInRangeUpperBound(minPrimeExclusive, maxPrime));
        var pending: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime) = undefined;
        var active: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(CompactSievePrime) = undefined;
        for (&pending, &active) |*p, *a| {
            p.* = try std.ArrayList(SievePrime).initCapacity(allocator, capacity);
            a.* = try std.ArrayList(CompactSievePrime).initCapacity(allocator, capacity);
        }

        return SmallStrideSievePrimes{
            .pending = pending,
            .pendingStart = @splat(0),
            .active = active,
            .segmentElems = segmentElems,
            .strideElems = strideElems,
        };
    }

    pub fn deinit(self: *SmallStrideSievePrimes, allocator: std.mem.Allocator) void {
        for (&self.pending) |*list| list.deinit(allocator);
        for (&self.active) |*list| list.deinit(allocator);
    }

    pub noinline fn add(
        self: *SmallStrideSievePrimes,
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
        self.pending[inBucketIndex].appendAssumeCapacity(registered);
    }

    pub fn sortByPosition(self: *SmallStrideSievePrimes) void {
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            std.mem.sortUnstable(SievePrime, self.pending[ari].items, {}, SievePrimeMod.lessThanByCurrentBucketIndex);
        }
    }

    pub noinline fn activate(self: *SmallStrideSievePrimes, bucketsStart: usize, bucketsEndExclusive: usize) void {
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            while (self.pendingStart[ari] < self.pending[ari].items.len) {
                const sievePrime = self.pending[ari].items[self.pendingStart[ari]];
                if (sievePrime.currentBucketIndex >= bucketsEndExclusive) break;

                std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
                const localOffset = sievePrime.currentBucketIndex - bucketsStart;
                std.debug.assert(localOffset < self.segmentElems);
                self.active[ari].appendAssumeCapacity(CompactSievePrime{
                    .localOffset = @intCast(localOffset),
                    .initialBucketIndex = sievePrime.initialBucketIndex,
                    .wheelStepIndex = sievePrime.wheelStepIndex,
                });
                self.pendingStart[ari] += 1;
            }
        }
    }

    pub noinline fn apply(
        self: *SmallStrideSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        var strideEnd = bucketsStart;
        while (strideEnd < bucketsEndExclusive) {
            strideEnd = @min(strideEnd + self.strideElems, bucketsEndExclusive);

            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                for (self.active[ari].items) |*entry| {
                    if (bucketsStart + entry.localOffset < strideEnd) {
                        applyCompactSievePrimeIntoSegment(ari, buckets, bucketsStart, strideEnd, self.segmentElems, entry);
                    }
                }
            }
        }
    }
};

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
