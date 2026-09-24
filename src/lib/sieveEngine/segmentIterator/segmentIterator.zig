const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const Utils = @import("../utils.zig");
const PreSieve = @import("../preSieve.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
const LargeSievePrime = SievePrimeMod.LargeSievePrime;

const SmallStrideSievePrimes = @import("smallStrideSievePrimes.zig").SmallStrideSievePrimes;
const SmallSegmentSievePrimes = @import("smallSegmentSievePrimes.zig").SmallSegmentSievePrimes;
const MediumSievePrimes = @import("mediumSievePrimes.zig").MediumSievePrimes;
const PreLargeSievePrimes = @import("preLargeSievePrimes.zig").PreLargeSievePrimes;
const LargeSievePrimes = @import("largeSievePrimes.zig").LargeSievePrimes;

const ALIGNMENT = std.mem.Alignment.@"8";

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;
const SMALL_STRIDE_THRESHOLD: usize = BuildUtils.SMALL_STRIDE_THRESHOLD;
const SMALL_SEGMENT_THRESHOLD: usize = BuildUtils.SMALL_SEGMENT_THRESHOLD;
const MEDIUM_THRESHOLD: usize = BuildUtils.MEDIUM_THRESHOLD;
const PRE_LARGE_THRESHOLD: usize = BuildUtils.PRE_LARGE_THRESHOLD;

const BUCKET_BITS = @bitSizeOf(Types.SIEVE_BUCKET_TYPE);

const Segment = struct {
    containerStart: usize,
    containerEndExclusive: usize,
    containers: []align(8) u64,
};

pub const SegmentIterator = struct {
    allocator: std.mem.Allocator,

    buckets: []align(8) Types.SIEVE_BUCKET_TYPE,
    containers: []align(8) Types.SIEVE_CONTAINER_TYPE,

    bucketsLength: usize,

    bucketsStart: usize,
    bucketsEndExclusive: usize,
    started: bool,

    smallStride: SmallStrideSievePrimes,
    smallSegment: SmallSegmentSievePrimes,
    medium: MediumSievePrimes,
    preLarge: PreLargeSievePrimes,
    large: LargeSievePrimes,

    pub noinline fn init(allocator: std.mem.Allocator, startInclusive: usize, limitInclusive: usize) !SegmentIterator {
        const bucketsLength = ALIGNMENT.forward(Utils.getSieveLength(limitInclusive));
        const buckets = try allocator.alignedAlloc(
            Types.SIEVE_BUCKET_TYPE,
            ALIGNMENT,
            @min(SEGMENT_ELEMS, bucketsLength),
        );

        const containers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(buckets));

        const startBucketIndex = ALIGNMENT.backward(startInclusive / Comptimes.WHEEL_CIRCUMFERENCE);
        const bucketsEndExclusive = @min(startBucketIndex + SEGMENT_ELEMS, bucketsLength);

        PreSieve.fill(buckets, startBucketIndex);
        if (startBucketIndex == 0) {
            @memcpy(buckets[0..PreSieve.OVERRIDE_BUCKET_COUNT], &PreSieve.OVERRIDE_BUCKETS);
        }

        const rootPrime = std.math.sqrt(limitInclusive);

        var self = SegmentIterator{
            .allocator = allocator,

            .buckets = buckets,
            .containers = containers,

            .bucketsLength = bucketsLength,

            .bucketsStart = startBucketIndex,
            .bucketsEndExclusive = bucketsEndExclusive,
            .started = false,

            .smallStride = try SmallStrideSievePrimes.init(allocator),
            .smallSegment = try SmallSegmentSievePrimes.init(allocator),
            .medium = try MediumSievePrimes.init(allocator),
            .preLarge = try PreLargeSievePrimes.init(allocator),
            .large = try LargeSievePrimes.init(allocator, rootPrime),
        };

        try discoverSievingPrimes(
            allocator,
            rootPrime,
            startInclusive,
            &self.smallStride,
            &self.smallSegment,
            &self.medium,
            &self.preLarge,
            &self.large,
            self.buckets,
            self.bucketsStart,
            self.bucketsEndExclusive,
            self.bucketsLength,
        );
        self.smallStride.sortByPosition();

        return self;
    }

    pub fn deinit(self: *SegmentIterator) void {
        self.allocator.free(self.buckets);
        self.smallStride.deinit(self.allocator);
        self.smallSegment.deinit(self.allocator);
        self.medium.deinit(self.allocator);
        self.preLarge.deinit(self.allocator);
        self.large.deinit(self.allocator);
        self.* = undefined;
    }

    pub noinline fn next(self: *SegmentIterator) !?Segment {
        if (!self.started) {
            if (self.bucketsStart >= self.bucketsLength) {
                return null;
            }
            self.started = true;
        } else {
            const candidateBucketsStart = self.bucketsStart + SEGMENT_ELEMS;
            if (candidateBucketsStart >= self.bucketsLength) {
                return null;
            }
            self.bucketsStart = candidateBucketsStart;
            self.bucketsEndExclusive = @min(self.bucketsStart + SEGMENT_ELEMS, self.bucketsLength);
            PreSieve.fill(self.buckets, self.bucketsStart);
        }

        crossOffSegment(&self.smallStride, &self.smallSegment, &self.medium, &self.preLarge, &self.large, self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        return Segment{
            .containerStart = self.bucketsStart / 8,
            .containerEndExclusive = self.bucketsEndExclusive / 8,
            .containers = self.containers,
        };
    }
};

fn crossOffSegment(
    smallStride: *SmallStrideSievePrimes,
    smallSegment: *SmallSegmentSievePrimes,
    medium: *MediumSievePrimes,
    preLarge: *PreLargeSievePrimes,
    large: *LargeSievePrimes,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    bucketsStart: usize,
    bucketsEndExclusive: usize,
) void {
    smallStride.activate(bucketsStart, bucketsEndExclusive);
    smallStride.apply(buckets, bucketsStart, bucketsEndExclusive);

    smallSegment.apply(buckets, bucketsStart, bucketsEndExclusive);

    medium.activate(bucketsStart);
    medium.apply(buckets, bucketsStart, bucketsEndExclusive);

    preLarge.activate(bucketsStart);
    preLarge.apply(buckets, bucketsStart, bucketsEndExclusive);

    large.activate(bucketsStart);
    large.apply(buckets, bucketsStart, bucketsEndExclusive);
}

noinline fn discoverSievingPrimes(
    allocator: std.mem.Allocator,
    rootPrime: usize,
    startInclusive: usize,
    smallStride: *SmallStrideSievePrimes,
    smallSegment: *SmallSegmentSievePrimes,
    medium: *MediumSievePrimes,
    preLarge: *PreLargeSievePrimes,
    large: *LargeSievePrimes,
    outputBuckets: Types.SIEVE_BUCKETS_TYPE,
    outputBucketsStart: usize,
    outputBucketsEndExclusive: usize,
    queryBucketsLength: usize,
) !void {
    if (rootPrime < 2) return;

    const dsp = std.math.sqrt(rootPrime);

    const selfBucketsLength = ALIGNMENT.forward(Utils.getSieveLength(rootPrime));
    const selfBuckets = try allocator.alignedAlloc(
        Types.SIEVE_BUCKET_TYPE,
        ALIGNMENT,
        @min(SEGMENT_ELEMS, selfBucketsLength),
    );
    defer allocator.free(selfBuckets);
    const selfContainers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(selfBuckets));

    var selfSmallStride = try SmallStrideSievePrimes.init(allocator);
    defer selfSmallStride.deinit(allocator);
    var selfSmallSegment = try SmallSegmentSievePrimes.init(allocator);
    defer selfSmallSegment.deinit(allocator);
    var selfMedium = try MediumSievePrimes.init(allocator);
    defer selfMedium.deinit(allocator);
    var selfPreLarge = try PreLargeSievePrimes.init(allocator);
    defer selfPreLarge.deinit(allocator);
    var selfLarge = try LargeSievePrimes.init(allocator, dsp);
    defer selfLarge.deinit(allocator);

    PreSieve.fill(selfBuckets, 0);
    @memcpy(selfBuckets[0..PreSieve.OVERRIDE_BUCKET_COUNT], &PreSieve.OVERRIDE_BUCKETS);

    var selfBucketsStart: usize = 0;
    var selfBucketsEndExclusive: usize = @min(SEGMENT_ELEMS, selfBucketsLength);
    var started = false;

    outer: while (true) {
        if (!started) {
            if (selfBucketsStart >= selfBucketsLength) break;
            started = true;
        } else {
            const candidate = selfBucketsStart + SEGMENT_ELEMS;
            if (candidate >= selfBucketsLength) break;
            selfBucketsStart = candidate;
            selfBucketsEndExclusive = @min(selfBucketsStart + SEGMENT_ELEMS, selfBucketsLength);
            PreSieve.fill(selfBuckets, selfBucketsStart);
        }

        crossOffSegment(&selfSmallStride, &selfSmallSegment, &selfMedium, &selfPreLarge, &selfLarge, selfBuckets, selfBucketsStart, selfBucketsEndExclusive);

        const containerStart = selfBucketsStart / 8;
        const containerEndExclusive = selfBucketsEndExclusive / 8;

        for (containerStart..containerEndExclusive, 0..) |containerIndex, localContainerIndex| {
            var containerWorkingCopy: u64 = selfContainers[localContainerIndex];
            while (containerWorkingCopy != 0) {
                const inContainerIndex: u6 = @intCast(@ctz(containerWorkingCopy));
                containerWorkingCopy &= containerWorkingCopy - 1;

                const bitIndex = 64 * containerIndex + inContainerIndex;
                const prime = Utils.admissibleNumberFromBitIndex(bitIndex);
                if (prime > rootPrime) break :outer;
                if (PreSieve.isPreSieved(prime)) continue;

                const bucketIndex = bitIndex / BUCKET_BITS;
                const inBucketIndex: u3 = @intCast(bitIndex % BUCKET_BITS);

                if (prime > MEDIUM_THRESHOLD) {
                    const target2310 = SievePrimeMod.firstAdmissibleMultiple2310(prime, startInclusive);
                    if (target2310.bucketIndex < queryBucketsLength) {
                        const realLargeSievePrime = LargeSievePrime.fromTarget2310(target2310, bucketIndex, inBucketIndex);
                        if (prime > PRE_LARGE_THRESHOLD) {
                            large.add(realLargeSievePrime, outputBucketsStart);
                        } else {
                            preLarge.add(realLargeSievePrime, outputBucketsStart);
                        }
                    }
                } else {
                    const target = SievePrimeMod.firstAdmissibleMultiple(prime, startInclusive);
                    if (prime > SMALL_SEGMENT_THRESHOLD) {
                        if (target.bucketIndex < queryBucketsLength) {
                            const realSievePrime = SievePrime.fromTarget(target, bucketIndex, inBucketIndex);
                            medium.add(realSievePrime, outputBucketsStart);
                        }
                    } else if (prime > SMALL_STRIDE_THRESHOLD) {
                        smallSegment.add(SievePrime.fromTarget(target, bucketIndex, inBucketIndex));
                    } else {
                        const realSievePrime = SievePrime.fromTarget(target, bucketIndex, inBucketIndex);
                        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                            if (ari == inBucketIndex) {
                                smallStride.add(ari, outputBuckets, outputBucketsStart, outputBucketsEndExclusive, realSievePrime);
                            }
                        }
                    }
                }

                if (prime <= dsp) {
                    if (prime > MEDIUM_THRESHOLD) {
                        const selfTarget2310 = SievePrimeMod.firstAdmissibleMultiple2310(prime, 0);
                        const selfLargeSievePrime = LargeSievePrime.fromTarget2310(selfTarget2310, bucketIndex, inBucketIndex);
                        if (prime > PRE_LARGE_THRESHOLD) {
                            selfLarge.add(selfLargeSievePrime, selfBucketsStart);
                        } else {
                            selfPreLarge.add(selfLargeSievePrime, selfBucketsStart);
                        }
                    } else {
                        const selfSievePrime = SievePrime.from(prime, bucketIndex, inBucketIndex, 0);
                        if (prime > SMALL_SEGMENT_THRESHOLD) {
                            selfMedium.add(selfSievePrime, selfBucketsStart);
                        } else if (prime > SMALL_STRIDE_THRESHOLD) {
                            selfSmallSegment.add(selfSievePrime);
                        } else {
                            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                                if (ari == inBucketIndex) {
                                    selfSmallStride.add(ari, selfBuckets, selfBucketsStart, selfBucketsEndExclusive, selfSievePrime);
                                }
                            }
                        }
                    }
                    containerWorkingCopy &= selfContainers[localContainerIndex];
                }
            }
        }
    }
}
