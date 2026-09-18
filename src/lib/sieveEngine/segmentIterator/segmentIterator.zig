const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const Utils = @import("../utils.zig");
const PreSieve = @import("../preSieve.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
const HugeSievePrime = SievePrimeMod.HugeSievePrime;

const SmallSievePrimes = @import("smallSievePrimes.zig").SmallSievePrimes;
const MediumSievePrimes = @import("mediumSievePrimes.zig").MediumSievePrimes;
const LargeSievePrimes = @import("largeSievePrimes.zig").LargeSievePrimes;
const PreHugeSievePrimes = @import("preHugeSievePrimes.zig").PreHugeSievePrimes;
const HugeSievePrimes = @import("hugeSievePrimes.zig").HugeSievePrimes;

const ALIGNMENT = std.mem.Alignment.@"8";

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;
const SMALL_MEDIUM_THRESHOLD: usize = BuildUtils.SMALL_MEDIUM_THRESHOLD;
const MEDIUM_LARGE_THRESHOLD: usize = BuildUtils.MEDIUM_LARGE_THRESHOLD;
const LARGE_HEAD_THRESHOLD: usize = BuildUtils.LARGE_HEAD_THRESHOLD;
const LARGE_HUGE_THRESHOLD: usize = BuildUtils.LARGE_HUGE_THRESHOLD;

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

    small: SmallSievePrimes,
    medium: MediumSievePrimes,
    large: LargeSievePrimes,
    preHuge: PreHugeSievePrimes,
    huge: HugeSievePrimes,

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

            .small = try SmallSievePrimes.init(allocator),
            .medium = try MediumSievePrimes.init(allocator),
            .large = try LargeSievePrimes.init(allocator),
            .preHuge = try PreHugeSievePrimes.init(allocator),
            .huge = try HugeSievePrimes.init(allocator, rootPrime),
        };

        try discoverSievingPrimes(
            allocator,
            rootPrime,
            startInclusive,
            &self.small,
            &self.medium,
            &self.large,
            &self.preHuge,
            &self.huge,
            self.buckets,
            self.bucketsStart,
            self.bucketsEndExclusive,
            self.bucketsLength,
        );
        self.small.sortByPosition();

        return self;
    }

    pub fn deinit(self: *SegmentIterator) void {
        self.allocator.free(self.buckets);
        self.small.deinit(self.allocator);
        self.medium.deinit(self.allocator);
        self.large.deinit(self.allocator);
        self.preHuge.deinit(self.allocator);
        self.huge.deinit(self.allocator);
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

        crossOffSegment(&self.small, &self.medium, &self.large, &self.preHuge, &self.huge, self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        return Segment{
            .containerStart = self.bucketsStart / 8,
            .containerEndExclusive = self.bucketsEndExclusive / 8,
            .containers = self.containers,
        };
    }
};

fn crossOffSegment(
    small: *SmallSievePrimes,
    medium: *MediumSievePrimes,
    large: *LargeSievePrimes,
    preHuge: *PreHugeSievePrimes,
    huge: *HugeSievePrimes,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    bucketsStart: usize,
    bucketsEndExclusive: usize,
) void {
    small.activate(bucketsStart, bucketsEndExclusive);
    small.apply(buckets, bucketsStart, bucketsEndExclusive);

    medium.apply(buckets, bucketsStart, bucketsEndExclusive);

    large.activate(bucketsStart);
    large.apply(buckets, bucketsStart, bucketsEndExclusive);

    preHuge.activate(bucketsStart);
    preHuge.apply(buckets, bucketsStart, bucketsEndExclusive);

    huge.activate(bucketsStart);
    huge.apply(buckets, bucketsStart, bucketsEndExclusive);
}

noinline fn discoverSievingPrimes(
    allocator: std.mem.Allocator,
    rootPrime: usize,
    startInclusive: usize,
    small: *SmallSievePrimes,
    medium: *MediumSievePrimes,
    large: *LargeSievePrimes,
    preHuge: *PreHugeSievePrimes,
    huge: *HugeSievePrimes,
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

    var selfSmall = try SmallSievePrimes.init(allocator);
    defer selfSmall.deinit(allocator);
    var selfMedium = try MediumSievePrimes.init(allocator);
    defer selfMedium.deinit(allocator);
    var selfLarge = try LargeSievePrimes.init(allocator);
    defer selfLarge.deinit(allocator);
    var selfPreHuge = try PreHugeSievePrimes.init(allocator);
    defer selfPreHuge.deinit(allocator);
    var selfHuge = try HugeSievePrimes.init(allocator, dsp);
    defer selfHuge.deinit(allocator);

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

        crossOffSegment(&selfSmall, &selfMedium, &selfLarge, &selfPreHuge, &selfHuge, selfBuckets, selfBucketsStart, selfBucketsEndExclusive);

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

                if (prime > LARGE_HUGE_THRESHOLD) {
                    const target210 = SievePrimeMod.firstAdmissibleMultiple210(prime, startInclusive);
                    if (target210.bucketIndex < queryBucketsLength) {
                        const realHugeSievePrime = HugeSievePrime.fromTarget210(target210, bucketIndex, inBucketIndex);
                        huge.add(realHugeSievePrime, outputBucketsStart);
                    }
                } else {
                    const target = SievePrimeMod.firstAdmissibleMultiple(prime, startInclusive);
                    if (prime > LARGE_HEAD_THRESHOLD) {
                        if (target.bucketIndex < queryBucketsLength) {
                            const realSievePrime = SievePrime.fromTarget(target, bucketIndex, inBucketIndex);
                            preHuge.add(realSievePrime, outputBucketsStart);
                        }
                    } else if (prime > MEDIUM_LARGE_THRESHOLD) {
                        if (target.bucketIndex < queryBucketsLength) {
                            const realSievePrime = SievePrime.fromTarget(target, bucketIndex, inBucketIndex);
                            large.add(realSievePrime, outputBucketsStart);
                        }
                    } else if (prime > SMALL_MEDIUM_THRESHOLD) {
                        medium.add(SievePrime.fromTarget(target, bucketIndex, inBucketIndex));
                    } else {
                        const realSievePrime = SievePrime.fromTarget(target, bucketIndex, inBucketIndex);
                        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                            if (ari == inBucketIndex) {
                                small.add(ari, outputBuckets, outputBucketsStart, outputBucketsEndExclusive, realSievePrime);
                            }
                        }
                    }
                }

                if (prime <= dsp) {
                    if (prime > LARGE_HUGE_THRESHOLD) {
                        const selfTarget210 = SievePrimeMod.firstAdmissibleMultiple210(prime, 0);
                        const selfHugeSievePrime = HugeSievePrime.fromTarget210(selfTarget210, bucketIndex, inBucketIndex);
                        selfHuge.add(selfHugeSievePrime, selfBucketsStart);
                    } else {
                        const selfSievePrime = SievePrime.from(prime, bucketIndex, inBucketIndex, 0);
                        if (prime > LARGE_HEAD_THRESHOLD) {
                            selfPreHuge.add(selfSievePrime, selfBucketsStart);
                        } else if (prime > MEDIUM_LARGE_THRESHOLD) {
                            selfLarge.add(selfSievePrime, selfBucketsStart);
                        } else if (prime > SMALL_MEDIUM_THRESHOLD) {
                            selfMedium.add(selfSievePrime);
                        } else {
                            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                                if (ari == inBucketIndex) {
                                    selfSmall.add(ari, selfBuckets, selfBucketsStart, selfBucketsEndExclusive, selfSievePrime);
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
