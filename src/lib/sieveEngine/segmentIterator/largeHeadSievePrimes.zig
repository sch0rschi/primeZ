const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const WHEEL_STEP_COUNT = @bitSizeOf(Types.SIEVE_BUCKET_TYPE);
const SievePrimesMap = [Comptimes.ADMISSIBLE_RESIDUES.count][WHEEL_STEP_COUNT]std.ArrayList(SievePrime);

// Primes above LARGE_HEAD_THRESHOLD, up to LARGE_HUGE_THRESHOLD (see
// largeSievePrimes.zig's own top comment for the split rationale and
// sieveLayoutMath.zig's largeHeadThreshold for the derivation): still not
// guaranteed at most once per segment (that's HugeSievePrimes' own range,
// above LARGE_HUGE_THRESHOLD), but close to it - by largeHeadThreshold's
// own derivation, at most 2 hits per segment in the worst case, and 1 the
// overwhelming majority of the time in practice.
//
// Reuses MediumSievePrimes' own (residue class, wheel-phase)-bucketed
// storage and refile-on-exact-exit-phase scheme (mirrors primesieve's own
// EratMedium - see that struct's own comment for the citation): every
// prime landing in one of the 64 (ari, wsi) buckets enters its crossing-
// off call at the exact same, branch-predictor-friendly phase. Unlike
// MediumSievePrimes, does NOT precompute all 8 steps' accumulated advance
// up front (MediumSievePrimes.applySievePrimeIntoSegmentMedium) - this
// tier's primes exit after their first step the large majority of the
// time, so the per-prime function computes only that first step's advance
// (a single comptime-folded WHEEL_PATTERNS[ari][wsi] lookup, no array to
// build) and checks it inline; only on the rare occasion that step still
// lands within the segment does it fall through to a plain runtime-
// indexed loop (TAIL, in apply() below - unbounded and general, correct
// for any number of hits, not just one extra) for whatever additional
// steps are still needed - so the common case never touches steps 2-8's
// data at all, on demand rather than unconditionally up front.
//
// 2026-09-14: briefly swapped with largeSievePrimes.zig's own sub-range
// (this design moved to the denser, low end near MEDIUM_LARGE_THRESHOLD)
// at the user's explicit request, then reverted after profiling both at a
// real ~5s-scale benchmark showed the original pairing (this file on the
// sparse end) costing less - see largeSievePrimes.zig's matching
// 2026-09-14 entry for the measured numbers. Kept as the validated
// assignment.
pub const LargeHeadSievePrimes = struct {
    maps: SievePrimesMap,
    mapsSwap: SievePrimesMap,

    pub fn init(allocator: std.mem.Allocator) !LargeHeadSievePrimes {
        // Exact, provably safe bound - not a probabilistic/average one:
        // a sieving prime's wheel-phase (wsi) at registration depends on
        // the query's own start position (via firstAdmissibleMultiple),
        // not just the prime's own residue - so, unlike a per-residue
        // count, no per-(ari, wsi) cell has an independent upper bound of
        // its own regardless of query start. What IS provably true
        // (same argument MediumSievePrimes.init relies on): no cell can
        // ever hold more than its residue's ENTIRE population, since
        // every prime with that residue lives in exactly one of its 8
        // wsi cells at a time. Reserving that full per-residue count for
        // every one of the 8 wsi cells is therefore always safe,
        // regardless of how skewed a particular query's start happens to
        // make the wsi distribution - appendAssumeCapacity below can
        // never overflow.
        //
        // This tier's own per-residue population is build-time-counted
        // exactly (BuildUtils.LARGE_HEAD_PRIME_COUNTS_BY_RESIDUE, computed
        // by countPrimesByResidueTool.zig over this sub-tier's own
        // [LARGE_HEAD_THRESHOLD, LARGE_HUGE_THRESHOLD] range - see
        // build.zig), the same mechanism MediumSievePrimes.init relies on
        // for its own PRIME_COUNTS_BY_RESIDUE. An earlier version of this
        // function approximated the per-residue count instead (splitting
        // Estimates.primeCountUpperBound's total evenly across the 8
        // residue classes) - that's only the AVERAGE per-residue
        // population, not a real upper bound on any individual residue's
        // count, so it could (and did - see the appendAssumeCapacity
        // crash this was caught by) undercount a residue whose actual
        // share exceeds 1/8.
        var maps: SievePrimesMap = undefined;
        var mapsSwap: SievePrimesMap = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            const capacity = BuildUtils.LARGE_HEAD_PRIME_COUNTS_BY_RESIDUE[ari];
            for (0..WHEEL_STEP_COUNT) |wsi| {
                maps[ari][wsi] = try std.ArrayList(SievePrime).initCapacity(allocator, capacity);
                mapsSwap[ari][wsi] = try std.ArrayList(SievePrime).initCapacity(allocator, capacity);
            }
        }

        return LargeHeadSievePrimes{
            .maps = maps,
            .mapsSwap = mapsSwap,
        };
    }

    pub fn deinit(self: *LargeHeadSievePrimes, allocator: std.mem.Allocator) void {
        for (&self.maps) |*residueMaps| {
            for (residueMaps) |*list| list.deinit(allocator);
        }
        for (&self.mapsSwap) |*residueMaps| {
            for (residueMaps) |*list| list.deinit(allocator);
        }
    }

    // A large-tier prime's square is never within the segment where it
    // was discovered (LARGE_HEAD_THRESHOLD is always well above
    // sqrt(SEGMENT_ELEMS * 30) for any realistic cache-derived config) -
    // same reasoning as MediumSievePrimes.add, and no discard-out-of-range
    // filter either: unlike the ring-based tiers, a bucket-and-refile
    // design doesn't spend a bounded resource on a not-yet-due entry (it
    // just gets refiled unchanged next segment - see apply()), so there's
    // nothing to save by pre-filtering at discovery time.
    pub fn add(self: *LargeHeadSievePrimes, sievePrime: SievePrime) void {
        self.maps[sievePrime.initialInBucketIndex][sievePrime.wheelStepIndex].appendAssumeCapacity(sievePrime);
    }

    pub noinline fn apply(
        self: *LargeHeadSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            inline for (0..WHEEL_STEP_COUNT) |wsi| {
                for (self.maps[ari][wsi].items) |*sievePrime| {
                    if (sievePrime.currentBucketIndex < bucketsEndExclusive) {
                        applySievePrimeIntoSegmentLargeHead(
                            ari,
                            wsi,
                            buckets,
                            bucketsStart,
                            bucketsEndExclusive,
                            sievePrime,
                            &self.mapsSwap[ari],
                        );
                    } else {
                        self.mapsSwap[ari][wsi].appendAssumeCapacity(sievePrime.*);
                    }
                }
                self.maps[ari][wsi].clearRetainingCapacity();
            }
        }

        std.mem.swap(SievePrimesMap, &self.maps, &self.mapsSwap);
    }

    inline fn applySievePrimeIntoSegmentLargeHead(
        comptime initialInBucketIndex: u3,
        comptime wheelStepIndex: u3,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrime: *SievePrime,
        largeHeadSievePrimesMap: *[WHEEL_STEP_COUNT]std.ArrayList(SievePrime),
    ) void {
        const bucketCount = bucketsEndExclusive - bucketsStart;
        const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
        var currentBucketIndex = sievePrime.currentBucketIndex - bucketsStart;

        // HEAD: this segment's first (and, the large majority of the
        // time, only) step - wheelStepIndex is comptime-known here (the
        // caller dispatched on it), so this is a single constant-folded
        // table lookup, not a runtime index - no different in kind from
        // primesieve's own hardcoded per-case BITn/dist literals, just
        // derived from WHEEL_PATTERNS instead of hand-written.
        const headStep = comptime Comptimes.WHEEL_PATTERNS[initialInBucketIndex][wheelStepIndex];
        buckets[currentBucketIndex] &= headStep.bitMask;
        currentBucketIndex +=
            initialBucketIndex * @as(usize, headStep.divMultiplicator) + @as(usize, headStep.residueAddend);

        if (currentBucketIndex >= bucketCount) {
            sievePrime.currentBucketIndex = currentBucketIndex + bucketsStart;
            sievePrime.wheelStepIndex = wheelStepIndex +% 1;
            largeHeadSievePrimesMap[wheelStepIndex +% 1].appendAssumeCapacity(sievePrime.*);
            return;
        }

        // TAIL: a plain, general, unbounded loop - correct for however
        // many further hits this segment actually has, not capped at one.
        // largeHeadThreshold's own derivation only guarantees this is rare
        // (worst case one more hit, for a prime dispatched to this tier at
        // all) - it's a property this loop benefits from, not one it
        // depends on for correctness. wheelStepIndex is no longer
        // comptime-known past this point, so this falls back to a plain
        // runtime-indexed lookup - paid only when actually needed, never
        // on the common single-hit path above.
        var runtimeWheelStepIndex: u3 = wheelStepIndex +% 1;
        while (true) {
            const step = Comptimes.WHEEL_PATTERNS[initialInBucketIndex][runtimeWheelStepIndex];
            buckets[currentBucketIndex] &= step.bitMask;
            currentBucketIndex +=
                initialBucketIndex * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
            const nextWheelStepIndex = runtimeWheelStepIndex +% 1;

            if (currentBucketIndex >= bucketCount) {
                sievePrime.currentBucketIndex = currentBucketIndex + bucketsStart;
                sievePrime.wheelStepIndex = nextWheelStepIndex;
                largeHeadSievePrimesMap[nextWheelStepIndex].appendAssumeCapacity(sievePrime.*);
                return;
            }
            runtimeWheelStepIndex = nextWheelStepIndex;
        }
    }
};
