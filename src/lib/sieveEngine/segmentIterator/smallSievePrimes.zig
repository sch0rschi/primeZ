const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
const CompactSievePrime = SievePrimeMod.SmallCompactSievePrime;

const STRIPE_ELEMS: usize = BuildUtils.STRIPE_ELEMS;
const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;
const SMALL_MEDIUM_THRESHOLD: usize = BuildUtils.SMALL_MEDIUM_THRESHOLD;

comptime {
    if (SEGMENT_ELEMS > 1 << 23) @compileError("SEGMENT_ELEMS exceeds CompactSievePrime.localOffset's u23 budget - widen that field before raising this bound");
}

// Only small primes need this: their squares routinely fall within the
// segment where they were discovered, and unlike medium/large primes they
// aren't bucketed by wheel-step, so a prime can resume at any of the 8
// steps. ROTATED_ACCUMULATED precomputes all 8 possible resume points so
// each store address is `currentBucketIndex + <accumulated offset>`,
// independent of the others in the same cycle.
//
// `entry.localOffset` is local to `bucketsStart` (the CURRENT segment's
// start, constant across every stripe call within that segment) - unlike
// the absolute-position design this replaced, no `- bucketsStart` at
// entry. On exit, the raw local position can cross a segment boundary
// (by at most one step's worth - this tier's own threshold guarantees a
// single step is always tiny relative to a whole segment, let alone a
// stripe, so it can never cross TWO boundaries in one step) - the single
// `if (>= SEGMENT_ELEMS) -= SEGMENT_ELEMS` below folds that correction
// into the SAME write every fire already performs, not a separate
// recurring cost the way medium/large's own rebase attempt was (see the
// huge_tier_ringentry_shrink project memory) - this tier's entries
// essentially never have a "touched but not fired" segment once active.
inline fn applyCompactSievePrimeIntoSegment(
    comptime inBucketIndex: u3,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    bucketsStart: usize,
    bucketsEndExclusive: usize,
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

    // The 8 bulk-loop bitmasks, one per resume point, packed 8-to-a-u64
    // (one byte each) instead of read individually from
    // ROTATED_ACCUMULATED[resumeAt][0..8].bitMask every bulk-loop
    // iteration. `perf annotate` showed the compiler spilling 4 of the 8
    // per-iteration bitmask bytes to the stack (real register pressure -
    // `accumulatedBucketIndexAdvance`'s 9 usize values plus 8 more
    // one-byte masks exceeds the available GPRs) and reloading them from
    // stack every iteration; holding all 8 in ONE register and slicing a
    // byte out via a comptime-constant shift measured as a real, small,
    // consistent win (~0.5-1%) via interleaved benchmarking - see the
    // huge_tier_ringentry_shrink project memory's "surgical audit" entry.
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
            const reduced = if (rawExit >= SEGMENT_ELEMS) rawExit - SEGMENT_ELEMS else rawExit;
            entry.localOffset = @intCast(reduced);
            entry.wheelStepIndex = wheelStepIndex +% @as(u3, ari);
            return;
        }
    } else {
        unreachable;
    }
}

pub const SmallSievePrimes = struct {
    // Not-yet-active entries: full absolute SievePrime, since a target
    // can be arbitrarily far from `bucketsStart` at add() time (e.g. the
    // self-bootstrap discovery sieve, always 0-based) - same "pending
    // overflow band" argument every other tier's own pending makes.
    // Sorted by position (see sortByPosition()), drained via an
    // early-break scan in activate() exactly like large/huge's pending.
    pending: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime),
    pendingStart: [Comptimes.ADMISSIBLE_RESIDUES.count]usize,

    // Active entries: compact (localOffset + wheelStepIndex only, no
    // counter - see CompactSievePrime's own docstring). Once an entry is
    // promoted here it stays forever (this tier's population is never
    // "done" early the way large-head's steady-state is bounded).
    active: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(CompactSievePrime),

    pub fn init(allocator: std.mem.Allocator) !SmallSievePrimes {
        // Every small-tier prime is <= SMALL_MEDIUM_THRESHOLD, so reserving
        // that upper bound for each residue's own list lets add()/activate()
        // use appendAssumeCapacity. Both pending and active get the full
        // bound (a prime lives in exactly one of the two at any moment, so
        // this is generous but safe for each individually, same looseness
        // the original single-array design already had).
        const capacity = Estimates.primeCountUpperBound(SMALL_MEDIUM_THRESHOLD);
        var pending: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime) = undefined;
        var active: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(CompactSievePrime) = undefined;
        for (&pending, &active) |*p, *a| {
            p.* = try std.ArrayList(SievePrime).initCapacity(allocator, capacity);
            a.* = try std.ArrayList(CompactSievePrime).initCapacity(allocator, capacity);
        }

        return SmallSievePrimes{
            .pending = pending,
            .pendingStart = .{0} ** Comptimes.ADMISSIBLE_RESIDUES.count,
            .active = active,
        };
    }

    pub fn deinit(self: *SmallSievePrimes, allocator: std.mem.Allocator) void {
        for (&self.pending) |*list| list.deinit(allocator);
        for (&self.active) |*list| list.deinit(allocator);
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
        self.pending[inBucketIndex].appendAssumeCapacity(registered);
    }

    /// activate()'s early-break scan assumes each of the 8 per-residue
    /// pending lists is sorted by currentBucketIndex. Discovery files
    /// primes in increasing prime-value order, which only coincides with
    /// increasing currentBucketIndex order when every target is relative
    /// to 0 - targets relative to an arbitrary start aren't monotonic in
    /// prime. Must be called once, after discovery and before the first
    /// activate(), to restore that invariant.
    pub fn sortByPosition(self: *SmallSievePrimes) void {
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            std.mem.sortUnstable(SievePrime, self.pending[ari].items, {}, SievePrimeMod.lessThanByCurrentBucketIndex);
        }
    }

    pub noinline fn activate(self: *SmallSievePrimes, bucketsStart: usize, bucketsEndExclusive: usize) void {
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            while (self.pendingStart[ari] < self.pending[ari].items.len) {
                const sievePrime = self.pending[ari].items[self.pendingStart[ari]];
                if (sievePrime.currentBucketIndex >= bucketsEndExclusive) break;

                std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
                const localOffset = sievePrime.currentBucketIndex - bucketsStart;
                std.debug.assert(localOffset < SEGMENT_ELEMS);
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
        self: *SmallSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        var stripeEnd = bucketsStart;
        while (stripeEnd < bucketsEndExclusive) {
            stripeEnd = @min(stripeEnd + STRIPE_ELEMS, bucketsEndExclusive);

            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                for (self.active[ari].items) |*entry| {
                    if (bucketsStart + entry.localOffset < stripeEnd) {
                        applyCompactSievePrimeIntoSegment(ari, buckets, bucketsStart, stripeEnd, entry);
                    }
                }
            }
        }
    }
};

// Kept for add()'s own same-segment-immediate-apply path, which operates
// on the wide SievePrime (a freshly-discovered entry, not yet promoted to
// the compact representation) - identical to the pre-existing logic,
// unchanged, just renamed from applySievePrimeIntoSegment's old home
// (this file) since applyCompactSievePrimeIntoSegment above now covers
// the steady-state `active` path.
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
