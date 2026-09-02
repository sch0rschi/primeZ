const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const WHEEL_STEP_COUNT = @bitSizeOf(Types.SIEVE_BUCKET_TYPE);
const SievePrimesMap = [Comptimes.ADMISSIBLE_RESIDUES.count][WHEEL_STEP_COUNT]std.ArrayList(SievePrime);

pub const MediumSievePrimes = struct {
    maps: SievePrimesMap,
    mapsSwap: SievePrimesMap,

    pub fn init(allocator: std.mem.Allocator) !MediumSievePrimes {
        var maps: SievePrimesMap = undefined;
        var mapsSwap: SievePrimesMap = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            const capacity = BuildUtils.PRIME_COUNTS_BY_RESIDUE[ari];
            for (0..WHEEL_STEP_COUNT) |wsi| {
                maps[ari][wsi] = try std.ArrayList(SievePrime).initCapacity(allocator, capacity);
                mapsSwap[ari][wsi] = try std.ArrayList(SievePrime).initCapacity(allocator, capacity);
            }
        }

        return MediumSievePrimes{
            .maps = maps,
            .mapsSwap = mapsSwap,
        };
    }

    pub fn deinit(self: *MediumSievePrimes, allocator: std.mem.Allocator) void {
        for (&self.maps) |*residueMaps| {
            for (residueMaps) |*list| list.deinit(allocator);
        }
        for (&self.mapsSwap) |*residueMaps| {
            for (residueMaps) |*list| list.deinit(allocator);
        }
    }

    // A medium sieving prime's square is never within the segment where it
    // was discovered (SMALL_MEDIUM_THRESHOLD is always well above
    // sqrt(SEGMENT_ELEMS * 30) for any realistic cache-derived config), so
    // unlike SmallSievePrimes.add(), there's nothing to cross off yet.
    pub fn add(
        self: *MediumSievePrimes,
        allocator: std.mem.Allocator,
        sievePrime: SievePrime,
    ) !void {
        try self.maps[sievePrime.initialInBucketIndex][sievePrime.wheelStepIndex].append(allocator, sievePrime);
    }

    pub noinline fn apply(
        self: *MediumSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            inline for (0..WHEEL_STEP_COUNT) |wsi| {
                for (self.maps[ari][wsi].items) |*sievePrime| {
                    if (sievePrime.currentBucketIndex < bucketsEndExclusive) {
                        applySievePrimeIntoSegmentMedium(
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

    inline fn applySievePrimeIntoSegmentMedium(
        comptime initialInBucketIndex: u3,
        comptime wheelStepIndex: u3,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrime: *SievePrime,
        mediumSievePrimesMap: *[WHEEL_STEP_COUNT]std.ArrayList(SievePrime),
    ) void {
        const bucketCount = bucketsEndExclusive - bucketsStart;
        const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
        var currentBucketIndex = sievePrime.currentBucketIndex - bucketsStart;

        @setEvalBranchQuota(1 << 20);
        const accumulatedWheelPattern: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]Comptimes.WheelStep = comptime blk: {
            var wheelPattern = Comptimes.WHEEL_PATTERNS[initialInBucketIndex];
            std.mem.rotate(Comptimes.WheelStep, wheelPattern[0..], wheelStepIndex);
            var accumulatedWheelPattern_: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]Comptimes.WheelStep = undefined;
            accumulatedWheelPattern_[0].divMultiplicator = 0;
            accumulatedWheelPattern_[0].residueAddend = 0;
            for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |stepIndex| {
                accumulatedWheelPattern_[stepIndex + 1].divMultiplicator =
                    accumulatedWheelPattern_[stepIndex].divMultiplicator + wheelPattern[stepIndex].divMultiplicator;
                accumulatedWheelPattern_[stepIndex + 1].residueAddend =
                    accumulatedWheelPattern_[stepIndex].residueAddend + wheelPattern[stepIndex].residueAddend;
                accumulatedWheelPattern_[stepIndex].bitMask = wheelPattern[stepIndex].bitMask;
            }
            break :blk accumulatedWheelPattern_;
        };

        var accumulatedBucketIndexAdvance: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]usize = undefined;
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count + 1, accumulatedWheelPattern) |stepIndex, accumulatedWheelStep| {
            accumulatedBucketIndexAdvance[stepIndex] =
                initialBucketIndex * accumulatedWheelStep.divMultiplicator + accumulatedWheelStep.residueAddend;
        }

        while (currentBucketIndex + accumulatedBucketIndexAdvance[7] < bucketCount) {
            inline for (
                accumulatedBucketIndexAdvance[0..Comptimes.ADMISSIBLE_RESIDUES.count],
                accumulatedWheelPattern[0..Comptimes.ADMISSIBLE_RESIDUES.count],
            ) |abia, ws| {
                buckets[currentBucketIndex + abia] &= ws.bitMask;
            }
            currentBucketIndex += accumulatedBucketIndexAdvance[8];
        }

        inline for (
            0..Comptimes.ADMISSIBLE_RESIDUES.count,
            accumulatedBucketIndexAdvance[0..Comptimes.ADMISSIBLE_RESIDUES.count],
            accumulatedWheelPattern[0..Comptimes.ADMISSIBLE_RESIDUES.count],
        ) |wsi, abia, ws| {
            if (currentBucketIndex + abia < bucketCount) {
                buckets[currentBucketIndex + abia] &= ws.bitMask;
            } else {
                sievePrime.currentBucketIndex = currentBucketIndex + abia + bucketsStart;
                sievePrime.wheelStepIndex = wheelStepIndex +% @as(u3, wsi);
                mediumSievePrimesMap[(@as(usize, wheelStepIndex) + wsi) % WHEEL_STEP_COUNT].appendAssumeCapacity(sievePrime.*);
                return;
            }
        } else {
            unreachable;
        }
    }
};
