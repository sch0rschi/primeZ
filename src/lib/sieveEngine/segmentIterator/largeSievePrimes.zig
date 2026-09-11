const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const ringSizeFor = @import("hugeSievePrimes.zig").ringSizeFor;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;

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

// Primes above MEDIUM_LARGE_THRESHOLD, up to LARGE_HEAD_THRESHOLD (not
// LARGE_HUGE_THRESHOLD - see largeHeadSievePrimes.zig for the sparser
// sub-range above that, and sieveLayoutMath.zig's largeHeadThreshold for
// the derivation of where the large tier is split): a full wheel cycle
// doesn't reliably fit within a single segment here, but more than one
// individual wheel step still can - a prime near the low end of this range
// can hit a segment several times.
//
// This batches BATCH_SIZE primes together and steps them one wheel-step at
// a time in lockstep, so their independent loads/stores can overlap
// instead of fully serializing per prime - a real ILP win, but ONLY once
// its shared step loop actually iterates more than once (the first
// iteration is pure setup cost - packing each prime's wheel-pattern
// pointer/indices into the batch's local arrays - not yet any shared
// work). That's exactly what this sub-range provides and
// largeHeadSievePrimes.zig's own sub-range doesn't (see largeHeadThreshold's
// derivation: below it, a worst-case third hit per segment remains
// possible; at or above it, at most 2 are, mostly 1 in practice). Correct
// for any prime magnitude above medium's own range regardless of exactly
// where MEDIUM_LARGE_THRESHOLD/LARGE_HEAD_THRESHOLD sit - those only affect
// how much of this algorithm's more-than-one-hit-per-segment capability
// actually gets used.
//
// 2026-09-10: split off a second design (largeHeadSievePrimes.zig,
// (residue, wheel-phase)-bucketed with a comptime-specialized first-step-
// only fast path, zero per-call setup cost) for the sparser sub-range
// above LARGE_HEAD_THRESHOLD, by reasoning about *why* each design is
// fast: this tier's batching needs primes with real multi-hit headroom
// (this tier's own low end, near MEDIUM_LARGE_THRESHOLD) to earn back its
// setup cost; the head design has no such setup at all and stays cheap as
// long as its rare runtime-indexed fallback stays rare (true near
// LARGE_HUGE_THRESHOLD, where most primes hit once).
//
// 2026-09-14: tried swapping the assignment (head taking this tier's own
// low end, batch taking head's sparser high end) at the user's explicit
// request - the opposite of the pairing above. Profiled both at a real,
// ~5s-scale benchmark (perf, N=1e19, a 4.4-billion-wide range-start
// window - large enough to get a trustworthy sample, unlike the small
// narrow-window checks used earlier in that same session): swapped,
// LargeSievePrimes.applyBatch + LargeHeadSievePrimes.apply combined were
// ~14.6% of total runtime (8.43% applyBatch + 6.15% head apply); reverted
// back to this (original) assignment, combined self-time dropped to
// ~12.9% (5.18% applyBatch + 7.76% head apply) - a real, measured ~11%
// relative reduction in this pair's own combined cost at the same
// benchmark point, confirming the original derivation (batch on the
// multi-hit end, head on the single-hit end) rather than the swap.
// Reverted; kept as the validated assignment. (One run each side, not a
// repeated/interleaved measurement - the direction is clear and matches
// the mechanistic prediction, but treat the exact percentages as
// indicative, not precise, per project convention.)
// 2026-09-10: replaced a flat sorted array (sortByPosition() + an
// activate() early-break scan needing that sort) with the same ring-buffer
// idea HugeSievePrimes already uses (see its own docstring and project
// memory huge_tier_bucket_list_idea) - not because large-tier primes hit
// at most once per segment the way huge-tier ones do (they don't - see
// applyNSievePrimesIntoSegment's own docstring), but because the sort
// existed purely to make *activation timing* (deciding when a not-yet-
// relevant prime becomes relevant) cheap, and a ring buffer answers that
// in O(1) per segment with no sort or per-segment scan at all: every
// large-tier prime's first occurrence lands within a bounded distance of
// bucketsStart (bounded by LARGE_HUGE_THRESHOLD itself here, not a
// query's own rootPrime - same reasoning as HugeSievePrimes.ringSizeFor,
// reused directly), so it can be filed into a ring slot for "which
// segment does it first become active in" at add() time, and each segment
// just drains that one ring slot into a flat `active` list - once
// active, apply()'s own per-item readiness check (in applyBatch, using
// the SAME data this tier already tracked) already correctly handles
// "already active but not due again on this specific segment", so
// `active` never needs to be sorted or scanned to decide *that*.
//
// Simpler than HugeSievePrimes' own ring in one respect: nothing here
// ever needs a "pending"-drained entry refiled a second time, since once
// a large-tier prime activates it has (at least) one occurrence in every
// later segment too (see applyNSievePrimesIntoSegment) rather than
// needing to wait for one specific future segment again - so a ring slot
// only ever needs to be drained once, into `active`, and never refilled.
pub const LargeSievePrimes = struct {
    active: std.ArrayList(SievePrime),

    ring: []std.ArrayList(SievePrime),
    ringHead: usize,

    // Overflow band for primes whose first occurrence is still beyond the
    // ring's reach at add() time - only ever the primes right at the top
    // of this tier's own range, whose target falls back to exactly
    // prime^2 (see HugeSievePrimes' struct docstring for the identical
    // argument, including why that band is already naturally sorted by
    // discovery order and never needs its own sort).
    pending: std.ArrayList(SievePrime),
    pendingStart: usize,

    pub fn init(allocator: std.mem.Allocator) !LargeSievePrimes {
        const ringLen = ringSizeFor(BuildUtils.LARGE_HEAD_THRESHOLD);
        const ring = try allocator.alloc(std.ArrayList(SievePrime), ringLen);
        for (ring) |*bucket| bucket.* = .empty;

        // Every large-tier prime is <= LARGE_HEAD_THRESHOLD (this tier
        // covers the sub-range closest to medium - see this file's own top
        // comment), a fixed build-time constant -
        // Estimates.primeCountUpperBound of it is a safe (if slightly
        // generous - it bounds the whole [0, threshold] prefix, not just
        // this tier's own slice above MEDIUM_LARGE_THRESHOLD) upper bound on
        // this tier's total population, reserved once here for `active`
        // since every entry ends up there eventually.
        const capacity = Estimates.primeCountUpperBound(BuildUtils.LARGE_HEAD_THRESHOLD);
        return LargeSievePrimes{
            .active = try std.ArrayList(SievePrime).initCapacity(allocator, capacity),
            .ring = ring,
            .ringHead = 0,
            .pending = try std.ArrayList(SievePrime).initCapacity(allocator, 0),
            .pendingStart = 0,
        };
    }

    pub fn deinit(self: *LargeSievePrimes, allocator: std.mem.Allocator) void {
        self.active.deinit(allocator);
        for (self.ring) |*bucket| bucket.deinit(allocator);
        allocator.free(self.ring);
        self.pending.deinit(allocator);
    }

    /// Places a freshly-discovered prime directly into its final position -
    /// see HugeSievePrimes.add, which this mirrors exactly (including the
    /// `bucketsStart` contract: it must be wherever ring[ringHead]
    /// currently corresponds to, not necessarily the query's own origin -
    /// see that function's docstring for why that distinction matters).
    pub fn add(self: *LargeSievePrimes, allocator: std.mem.Allocator, sievePrime: SievePrime, bucketsStart: usize) !void {
        const ringLen = self.ring.len;
        const segmentsAhead = destinationOf(sievePrime, ringLen, bucketsStart);
        if (segmentsAhead < ringLen) {
            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            try self.ring[slot].append(allocator, sievePrime);
        } else {
            try self.pending.append(allocator, sievePrime);
        }
    }

    fn destinationOf(sievePrime: SievePrime, ringLen: usize, bucketsStart: usize) usize {
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
        return if (segmentsAhead < ringLen) segmentsAhead else ringLen;
    }

    pub noinline fn activate(self: *LargeSievePrimes, allocator: std.mem.Allocator, bucketsStart: usize) !void {
        const ringLen = self.ring.len;

        // Drain any pending prime whose first occurrence has finally come
        // within the ring's reach - see HugeSievePrimes.activate, same
        // logic and the same early-break sorted-order argument.
        while (self.pendingStart < self.pending.items.len) {
            const sievePrime = self.pending.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
            if (segmentsAhead >= ringLen) break;

            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            try self.ring[slot].append(allocator, sievePrime);
            self.pendingStart += 1;
        }

        // This segment's own ring slot: every prime here is now active for
        // good (see the struct docstring) - move it into `active` once,
        // then free the slot's storage back for reuse whenever the ring
        // wraps around to this same index again later in the query.
        const current = &self.ring[self.ringHead];
        try self.active.appendSlice(allocator, current.items);
        current.clearRetainingCapacity();
        self.ringHead = (self.ringHead + 1) & (ringLen - 1);
    }

    pub fn apply(
        self: *LargeSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        applyBatch(BATCH_SIZE, buckets, bucketsStart, bucketsEndExclusive, self.active.items);
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
