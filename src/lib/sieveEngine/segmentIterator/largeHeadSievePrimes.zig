const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
const CompactSievePrime = SievePrimeMod.LargeHeadCompactSievePrime;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;
const WHEEL_STEP_COUNT = @bitSizeOf(Types.SIEVE_BUCKET_TYPE);
const SievePrimesMap = [Comptimes.ADMISSIBLE_RESIDUES.count][WHEEL_STEP_COUNT]std.ArrayList(CompactSievePrime);

// Largest CONSECUTIVE-PAIR advance (in buckets, for a LARGE_HUGE_THRESHOLD
// -magnitude prime) any largeHead-tier entry can make in one apply() exit -
// an entry can fire at most twice (HEAD + one TAIL hit) before leaving a
// segment, so the relevant bound is the worst adjacent-step PAIR sum, not
// a single step doubled (those two maxima don't occur on the same step -
// doubling would overshoot by ~20%) and not the generic `max(divMultiplicator)
// + max(residueAddend)` combined padding hugeSievePrimes.zig's ringSizeFor
// uses for its own (differently-shaped, wheel-210) sizing - computed
// directly from this tier's own real wheel-30 table instead. Verified
// empirically (via a throwaway @compileLog during development) to land
// at ~3 segments for a single step and ~5 for the worst pair, for both a
// 4KB and the default 256KB segment config alike - a ratio, not an
// absolute, so segment-size-independent as expected.
const MAX_PAIR_ADVANCE: usize = blk: {
    const maxInitialBucketIndex = BuildUtils.LARGE_HUGE_THRESHOLD / Comptimes.WHEEL_CIRCUMFERENCE;
    var maxPair: usize = 0;
    for (Comptimes.WHEEL_PATTERNS) |row| {
        for (0..row.len) |i| {
            const s1 = row[i];
            const s2 = row[(i + 1) % row.len];
            const adv1 = maxInitialBucketIndex * @as(usize, s1.divMultiplicator) + @as(usize, s1.residueAddend);
            const adv2 = maxInitialBucketIndex * @as(usize, s2.divMultiplicator) + @as(usize, s2.residueAddend);
            maxPair = @max(maxPair, adv1 + adv2);
        }
    }
    break :blk maxPair;
};

// Worst-case total advance from a starting `localOffset` (itself <
// SEGMENT_ELEMS) is (SEGMENT_ELEMS - 1) + the worst pair above - the
// resulting segmentsAhead-from-here, after refile()'s own -1 adjustment
// (see refile()'s docstring), is what segmentsAhead must actually hold.
const MAX_SKIP: usize = ((SEGMENT_ELEMS - 1) + MAX_PAIR_ADVANCE) / SEGMENT_ELEMS - 1;
comptime {
    if (MAX_SKIP > 7) @compileError("largeHead's own max step exceeds segmentsAhead's u3 budget - widen that field (and CompactSievePrime) before raising this bound");
    if (SEGMENT_ELEMS > 1 << 23) @compileError("SEGMENT_ELEMS exceeds CompactSievePrime.localOffset's u23 budget - widen that field before raising this bound");
}

// Primes above LARGE_HEAD_THRESHOLD, up to LARGE_HUGE_THRESHOLD: at most 2
// hits per segment worst case, 1 the overwhelming majority of the time.
// (residue, wheel-phase)-bucketed like MediumSievePrimes, but doesn't
// precompute all 8 steps' accumulated advance up front - only the first
// step's, checked inline, falling to a plain runtime loop only on the
// rare second hit.
//
// maps/mapsSwap store CompactSievePrime (localOffset + a small
// segmentsAhead counter) instead of the wider SievePrime (an absolute
// position): a not-yet-due entry just has its segmentsAhead decremented
// and gets refiled into the SAME (ari, wsi) cell, no position rebase at
// all (bucketsStart and segmentsAhead both advance by exactly one
// segment each call, so `bucketsStart + segmentsAhead*SEGMENT_ELEMS +
// localOffset` stays invariant across the decrement - see
// applyCompactSievePrimeIntoSegmentLargeHead's docstring). This keeps
// apply() itself fully infallible: unlike an earlier ring-based attempt
// at this same idea (see the huge_tier_ringentry_shrink project memory),
// no allocator call or fallible path is ever reached from inside the hot
// per-step function - only add()/activate() (called once per prime or
// once per segment, never once per step) ever touch `pending`, the
// thin overflow band for an initial target still further than MAX_SKIP
// segments away (mirroring large/huge's own pending band exactly, same
// early-break argument for why it needs no explicit sort).
pub const LargeHeadSievePrimes = struct {
    maps: SievePrimesMap,
    mapsSwap: SievePrimesMap,

    pending: std.ArrayList(SievePrime),
    pendingStart: usize,

    pub fn init(allocator: std.mem.Allocator) !LargeHeadSievePrimes {
        // No cell can hold more than its residue's entire population
        // (every prime with that residue lives in exactly one of its 8
        // wsi cells at a time), so reserving the full per-residue count
        // for every wsi cell is always safe. That count is build-time-
        // exact (LARGE_HEAD_PRIME_COUNTS_BY_RESIDUE) - an earlier version
        // approximated it by splitting the total evenly across 8 residues,
        // which is only the AVERAGE, not a real bound, and could (and did)
        // undercount a residue whose actual share exceeds 1/8. Still a
        // safe bound now that entries can also sit in `pending` for a
        // while: at any moment a prime lives in exactly one of
        // pending/maps/mapsSwap, so maps' own worst case (every tracked
        // prime of that residue landing there at once) is unchanged.
        var maps: SievePrimesMap = undefined;
        var mapsSwap: SievePrimesMap = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            const capacity = BuildUtils.LARGE_HEAD_PRIME_COUNTS_BY_RESIDUE[ari];
            for (0..WHEEL_STEP_COUNT) |wsi| {
                maps[ari][wsi] = try std.ArrayList(CompactSievePrime).initCapacity(allocator, capacity);
                mapsSwap[ari][wsi] = try std.ArrayList(CompactSievePrime).initCapacity(allocator, capacity);
            }
        }

        return LargeHeadSievePrimes{
            .maps = maps,
            .mapsSwap = mapsSwap,
            .pending = try std.ArrayList(SievePrime).initCapacity(allocator, 0),
            .pendingStart = 0,
        };
    }

    pub fn deinit(self: *LargeHeadSievePrimes, allocator: std.mem.Allocator) void {
        for (&self.maps) |*residueMaps| {
            for (residueMaps) |*list| list.deinit(allocator);
        }
        for (&self.mapsSwap) |*residueMaps| {
            for (residueMaps) |*list| list.deinit(allocator);
        }
        self.pending.deinit(allocator);
    }

    const Split = struct { segmentsAhead: usize, localOffset: usize };

    fn splitPosition(absolutePosition: usize, bucketsStart: usize) Split {
        std.debug.assert(absolutePosition >= bucketsStart);
        const local = absolutePosition - bucketsStart;
        const segmentsAhead = local / SEGMENT_ELEMS;
        return .{ .segmentsAhead = segmentsAhead, .localOffset = local - segmentsAhead * SEGMENT_ELEMS };
    }

    fn fileCompact(self: *LargeHeadSievePrimes, sievePrime: SievePrime, split: Split) void {
        std.debug.assert(split.segmentsAhead <= MAX_SKIP);
        self.maps[sievePrime.initialInBucketIndex][sievePrime.wheelStepIndex].appendAssumeCapacity(CompactSievePrime{
            .localOffset = @intCast(split.localOffset),
            .segmentsAhead = @intCast(split.segmentsAhead),
            .initialBucketIndex = sievePrime.initialBucketIndex,
            .initialInBucketIndex = sievePrime.initialInBucketIndex,
            .wheelStepIndex = sievePrime.wheelStepIndex,
        });
    }

    pub fn add(self: *LargeHeadSievePrimes, allocator: std.mem.Allocator, sievePrime: SievePrime, bucketsStart: usize) !void {
        const split = splitPosition(sievePrime.currentBucketIndex, bucketsStart);
        if (split.segmentsAhead <= MAX_SKIP) {
            self.fileCompact(sievePrime, split);
        } else {
            try self.pending.append(allocator, sievePrime);
        }
    }

    // Same early-break-on-sorted-pending pattern as large/huge's own
    // activate(): whenever pending is non-empty, its entries' targets are
    // dominated by prime^2 (the only way `firstAdmissibleMultiple` lands
    // further than MAX_SKIP segments from bucketsStart in the first
    // place), which is monotonic in discovery order - same argument
    // those tiers' own docstrings already make for their pending bands.
    pub noinline fn activate(self: *LargeHeadSievePrimes, bucketsStart: usize) void {
        while (self.pendingStart < self.pending.items.len) {
            const sievePrime = self.pending.items[self.pendingStart];
            const split = splitPosition(sievePrime.currentBucketIndex, bucketsStart);
            if (split.segmentsAhead > MAX_SKIP) break;

            self.fileCompact(sievePrime, split);
            self.pendingStart += 1;
        }
    }

    pub noinline fn apply(
        self: *LargeHeadSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        const bucketCount = bucketsEndExclusive - bucketsStart;

        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            inline for (0..WHEEL_STEP_COUNT) |wsi| {
                for (self.maps[ari][wsi].items) |*entry| {
                    if (entry.segmentsAhead == 0 and entry.localOffset < bucketCount) {
                        applyCompactSievePrimeIntoSegmentLargeHead(
                            ari,
                            wsi,
                            buckets,
                            bucketCount,
                            entry,
                            &self.mapsSwap[ari],
                        );
                    } else {
                        var refiled = entry.*;
                        // The only way segmentsAhead==0 lands here is the
                        // truncated final segment (localOffset >=
                        // bucketCount but < SEGMENT_ELEMS) - moot since
                        // there is no next call to refile for; leave it
                        // unchanged rather than underflow the decrement.
                        if (refiled.segmentsAhead != 0) refiled.segmentsAhead -= 1;
                        self.mapsSwap[ari][wsi].appendAssumeCapacity(refiled);
                    }
                }
                self.maps[ari][wsi].clearRetainingCapacity();
            }
        }

        std.mem.swap(SievePrimesMap, &self.maps, &self.mapsSwap);
    }

    // `entry.localOffset` is already local to the CURRENT bucketsStart
    // (no subtraction needed, unlike the old absolute-position design) -
    // and `bucketsStart` itself is invariant-preserving across segments:
    // a refiled entry's (localOffset, segmentsAhead) pair always
    // satisfies `bucketsStart + segmentsAhead*SEGMENT_ELEMS +
    // localOffset == <the entry's true absolute due position>` no matter
    // which segment it was last touched on, since bucketsStart advances
    // by exactly SEGMENT_ELEMS and segmentsAhead decrements by exactly 1
    // every call in lockstep - so a "not due" touch never needs to touch
    // localOffset at all, only the counter.
    inline fn applyCompactSievePrimeIntoSegmentLargeHead(
        comptime initialInBucketIndex: u3,
        comptime wheelStepIndex: u3,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketCount: usize,
        entry: *CompactSievePrime,
        largeHeadMap: *[WHEEL_STEP_COUNT]std.ArrayList(CompactSievePrime),
    ) void {
        const initialBucketIndex = @as(usize, entry.initialBucketIndex);
        var currentBucketIndex: usize = entry.localOffset;

        // HEAD: wheelStepIndex is comptime-known here, so this is a
        // constant-folded table lookup, not a runtime index.
        const headStep = comptime Comptimes.WHEEL_PATTERNS[initialInBucketIndex][wheelStepIndex];
        buckets[currentBucketIndex] &= headStep.bitMask;
        currentBucketIndex +=
            initialBucketIndex * @as(usize, headStep.divMultiplicator) + @as(usize, headStep.residueAddend);

        if (currentBucketIndex >= bucketCount) {
            refile(largeHeadMap, wheelStepIndex +% 1, entry, currentBucketIndex);
            return;
        }

        // TAIL: general, unbounded - correct for however many further
        // hits this segment has, not capped at one.
        var runtimeWheelStepIndex: u3 = wheelStepIndex +% 1;
        while (true) {
            const step = Comptimes.WHEEL_PATTERNS[initialInBucketIndex][runtimeWheelStepIndex];
            buckets[currentBucketIndex] &= step.bitMask;
            currentBucketIndex +=
                initialBucketIndex * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
            const nextWheelStepIndex = runtimeWheelStepIndex +% 1;

            if (currentBucketIndex >= bucketCount) {
                refile(largeHeadMap, nextWheelStepIndex, entry, currentBucketIndex);
                return;
            }
            runtimeWheelStepIndex = nextWheelStepIndex;
        }
    }

    inline fn refile(
        largeHeadMap: *[WHEEL_STEP_COUNT]std.ArrayList(CompactSievePrime),
        newWheelStepIndex: u3,
        entry: *const CompactSievePrime,
        newLocalPosition: usize,
    ) void {
        const segmentsAheadFromHere = newLocalPosition / SEGMENT_ELEMS;
        // segmentsAheadFromHere==0 here is possible only in a truncated
        // final segment (bucketCount < SEGMENT_ELEMS - the only kind of
        // segment shorter than SEGMENT_ELEMS): this "exit" then means
        // "would be due right now, but the query is ending anyway", not
        // "still due next segment" - harmless (nothing reads this entry
        // back), so it's fine to leave storedSegmentsAhead at 0 rather
        // than underflow the -1 below.
        //
        // Otherwise storedSegmentsAhead MUST be segmentsAheadFromHere-1,
        // not segmentsAheadFromHere itself: this entry is being appended
        // into mapsSwap, which becomes `maps` for the *next* apply()
        // call (bucketsStart advances by one SEGMENT_ELEMS via the
        // maps/mapsSwap promotion) without ever passing through the
        // "not due, decrement" branch that normally does this exact
        // adjustment - computing segmentsAheadFromHere relative to THIS
        // call's own bucketsStart and storing it unadjusted double-counts
        // that one implicit segment, landing the entry's eventual fire
        // one whole segment (SEGMENT_ELEMS buckets) too late.
        const storedSegmentsAhead = if (segmentsAheadFromHere == 0) 0 else segmentsAheadFromHere - 1;
        std.debug.assert(storedSegmentsAhead <= MAX_SKIP);
        largeHeadMap[newWheelStepIndex].appendAssumeCapacity(CompactSievePrime{
            .localOffset = @intCast(newLocalPosition - segmentsAheadFromHere * SEGMENT_ELEMS),
            .segmentsAhead = @intCast(storedSegmentsAhead),
            .initialBucketIndex = entry.initialBucketIndex,
            .initialInBucketIndex = entry.initialInBucketIndex,
            .wheelStepIndex = newWheelStepIndex,
        });
    }
};
