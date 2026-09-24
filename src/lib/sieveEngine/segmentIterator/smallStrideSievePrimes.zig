const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const LayoutMod = @import("../layout.zig");
const Layout = LayoutMod.Layout;
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

    const ROTATED_BITMASKS_PACKED: [Comptimes.ADMISSIBLE_RESIDUES.count]u64 = comptime blk: {
        var packedMasks: [Comptimes.ADMISSIBLE_RESIDUES.count]u64 = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |resumeAt| {
            var p: u64 = 0;
            for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |stepIndex| {
                p |= @as(u64, ROTATED_ACCUMULATED[resumeAt][stepIndex].bitMask) << @intCast(stepIndex * 8);
            }
            packedMasks[resumeAt] = p;
        }
        break :blk packedMasks;
    };

    const wheelStepIndex = entry.wheelStepIndex;
    const accumulatedWheelPattern = &ROTATED_ACCUMULATED[wheelStepIndex];
    const bitMasksPacked: u64 = ROTATED_BITMASKS_PACKED[wheelStepIndex];

    var accumulatedBucketIndexAdvance: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]usize = undefined;
    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count + 1) |stepIndex| {
        accumulatedBucketIndexAdvance[stepIndex] =
            initialBucketIndex * accumulatedWheelPattern[stepIndex].divMultiplicator + accumulatedWheelPattern[stepIndex].residueAddend;
    }

    while (currentBucketIndex + accumulatedBucketIndexAdvance[7] < bucketCount) {
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |si| {
            const mask: Types.SIEVE_BUCKET_TYPE = @truncate(bitMasksPacked >> (si * 8));
            buckets[currentBucketIndex + accumulatedBucketIndexAdvance[si]] &= mask;
        }
        currentBucketIndex += accumulatedBucketIndexAdvance[8];
    }

    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
        if (currentBucketIndex + accumulatedBucketIndexAdvance[ari] < bucketCount) {
            buckets[currentBucketIndex + accumulatedBucketIndexAdvance[ari]] &= accumulatedWheelPattern[ari].bitMask;
        } else {
            const rawExit = currentBucketIndex + accumulatedBucketIndexAdvance[ari];
            const reduced = if (rawExit >= segmentElems) rawExit - segmentElems else rawExit;
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
    stripeElems: usize,

    pub fn init(allocator: std.mem.Allocator, layout: Layout, maxPrime: usize) !SmallStrideSievePrimes {
        const capacity = Estimates.primeCountUpperBound(@min(maxPrime, layout.smallStrideThreshold));
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
            .segmentElems = layout.segmentElems,
            .stripeElems = layout.stripeElems,
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
        var stripeEnd = bucketsStart;
        while (stripeEnd < bucketsEndExclusive) {
            stripeEnd = @min(stripeEnd + self.stripeElems, bucketsEndExclusive);

            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                for (self.active[ari].items) |*entry| {
                    if (bucketsStart + entry.localOffset < stripeEnd) {
                        applyCompactSievePrimeIntoSegment(ari, buckets, bucketsStart, stripeEnd, self.segmentElems, entry);
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
