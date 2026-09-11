const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const WHEEL_STEP_COUNT = @bitSizeOf(Types.SIEVE_BUCKET_TYPE);
const SievePrimesMap = [Comptimes.ADMISSIBLE_RESIDUES.count][WHEEL_STEP_COUNT]std.ArrayList(SievePrime);

// Primes above LARGE_HEAD_THRESHOLD, up to LARGE_HUGE_THRESHOLD: at most 2
// hits per segment worst case, 1 the overwhelming majority of the time.
// (residue, wheel-phase)-bucketed like MediumSievePrimes, but doesn't
// precompute all 8 steps' accumulated advance up front - only the first
// step's, checked inline, falling to a plain runtime loop only on the
// rare second hit.
pub const LargeHeadSievePrimes = struct {
    maps: SievePrimesMap,
    mapsSwap: SievePrimesMap,

    pub fn init(allocator: std.mem.Allocator) !LargeHeadSievePrimes {
        // No cell can hold more than its residue's entire population
        // (every prime with that residue lives in exactly one of its 8
        // wsi cells at a time), so reserving the full per-residue count
        // for every wsi cell is always safe. That count is build-time-
        // exact (LARGE_HEAD_PRIME_COUNTS_BY_RESIDUE) - an earlier version
        // approximated it by splitting the total evenly across 8 residues,
        // which is only the AVERAGE, not a real bound, and could (and did)
        // undercount a residue whose actual share exceeds 1/8.
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

    // No discard-out-of-range filter: unlike the ring-based tiers, a
    // bucket-and-refile design doesn't spend a bounded resource on a
    // not-yet-due entry (it's just refiled unchanged next segment).
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

        // HEAD: wheelStepIndex is comptime-known here, so this is a
        // constant-folded table lookup, not a runtime index.
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
                sievePrime.currentBucketIndex = currentBucketIndex + bucketsStart;
                sievePrime.wheelStepIndex = nextWheelStepIndex;
                largeHeadSievePrimesMap[nextWheelStepIndex].appendAssumeCapacity(sievePrime.*);
                return;
            }
            runtimeWheelStepIndex = nextWheelStepIndex;
        }
    }
};
