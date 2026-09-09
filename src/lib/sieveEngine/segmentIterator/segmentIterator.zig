const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const Utils = @import("../utils.zig");
const PreSieve = @import("../preSieve.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const SmallSievePrimes = @import("smallSievePrimes.zig").SmallSievePrimes;
const MediumSievePrimes = @import("mediumSievePrimes.zig").MediumSievePrimes;
const LargeSievePrimes = @import("largeSievePrimes.zig").LargeSievePrimes;
const HugeSievePrimes = @import("hugeSievePrimes.zig").HugeSievePrimes;

const ALIGNMENT = std.mem.Alignment.@"8";

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;
const SMALL_MEDIUM_THRESHOLD: usize = BuildUtils.SMALL_MEDIUM_THRESHOLD;
const MEDIUM_LARGE_THRESHOLD: usize = BuildUtils.MEDIUM_LARGE_THRESHOLD;
const LARGE_HUGE_THRESHOLD: usize = BuildUtils.LARGE_HUGE_THRESHOLD;

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
    rootBucketIndexExclusive: usize,

    // Where sieving-prime discovery ends and range-start support begins:
    // discovery (findSievePrimesInSegment) is always 0-based and always
    // runs in full up to rootBucketIndexExclusive - it's how sieving primes
    // are found at all, so there's nothing to skip there even when
    // startBucketIndex is astronomically larger. startBucketIndex itself is
    // startInclusive's own bucket, rounded down to a multiple of 8 buckets
    // (one container) so Segment.containerStart/containerEndExclusive
    // below stay valid global container indices - see next()'s one-time
    // jump. Callers that care about exactly startInclusive (not this
    // slightly-earlier, container-aligned point) mask the difference off
    // themselves, the same way callers already mask off the tail beyond
    // limitInclusive (see Primes.piSieveCounting).
    startInclusive: usize,
    startBucketIndex: usize,
    jumped: bool,

    bucketsStart: usize,
    bucketsEndExclusive: usize,
    started: bool,

    small: SmallSievePrimes,
    medium: MediumSievePrimes,
    large: LargeSievePrimes,
    huge: HugeSievePrimes,

    pub fn init(allocator: std.mem.Allocator, startInclusive: usize, limitInclusive: usize) !SegmentIterator {
        const bucketsLength = ALIGNMENT.forward(Utils.getSieveLength(limitInclusive));
        const buckets = try allocator.alignedAlloc(
            Types.SIEVE_BUCKET_TYPE,
            ALIGNMENT,
            @min(SEGMENT_ELEMS, bucketsLength),
        );

        const containers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(buckets));

        PreSieve.fill(buckets, 0);
        @memcpy(buckets[0..PreSieve.OVERRIDE_BUCKET_COUNT], &PreSieve.OVERRIDE_BUCKETS);

        const rootPrime = std.math.sqrt(limitInclusive);
        const rootBucketExclusive = Utils.getSieveLength(rootPrime);

        const startBucketIndex = ALIGNMENT.backward(startInclusive / Comptimes.WHEEL_CIRCUMFERENCE);

        return SegmentIterator{
            .allocator = allocator,

            .buckets = buckets,
            .containers = containers,

            .bucketsLength = bucketsLength,
            .rootBucketIndexExclusive = rootBucketExclusive,

            .startInclusive = startInclusive,
            .startBucketIndex = startBucketIndex,
            .jumped = false,

            .bucketsStart = 0,
            .bucketsEndExclusive = @min(SEGMENT_ELEMS, bucketsLength),
            .started = false,

            .small = try SmallSievePrimes.init(allocator),
            .medium = try MediumSievePrimes.init(allocator),
            .large = try LargeSievePrimes.init(allocator),
            .huge = try HugeSievePrimes.init(allocator),
        };
    }

    pub fn deinit(self: *SegmentIterator) void {
        self.allocator.free(self.buckets);
        self.small.deinit(self.allocator);
        self.medium.deinit(self.allocator);
        self.large.deinit(self.allocator);
        self.huge.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn next(self: *SegmentIterator) !?Segment {
        if (!self.started) {
            if (self.bucketsStart >= self.bucketsLength) {
                return null;
            }
            self.started = true;
        } else {
            var candidateBucketsStart = self.bucketsStart + SEGMENT_ELEMS;

            // One-time jump: once discovery (0-based, up through
            // rootBucketIndexExclusive) is done, and the requested start
            // lies beyond the segment we'd otherwise process next, skip
            // straight to it instead of simulating every segment in
            // between - see fastForwardTo on each tier.
            if (!self.jumped and candidateBucketsStart >= self.rootBucketIndexExclusive) {
                self.jumped = true;
                if (self.startBucketIndex > candidateBucketsStart) {
                    self.small.fastForwardTo(self.startInclusive);
                    self.medium.fastForwardTo(self.startInclusive);
                    self.large.fastForwardTo(self.startInclusive);
                    self.huge.fastForwardTo(self.startInclusive);
                    candidateBucketsStart = self.startBucketIndex;
                }
            }

            if (candidateBucketsStart >= self.bucketsLength) {
                return null;
            }
            self.bucketsStart = candidateBucketsStart;
            self.bucketsEndExclusive = @min(self.bucketsStart + SEGMENT_ELEMS, self.bucketsLength);
            PreSieve.fill(self.buckets, self.bucketsStart);
        }

        self.small.activate(self.bucketsEndExclusive);
        self.small.apply(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        self.medium.apply(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        self.large.activate(self.bucketsEndExclusive);
        self.large.apply(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        self.huge.activate(self.bucketsEndExclusive);
        self.huge.apply(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        if (self.bucketsStart < self.rootBucketIndexExclusive) {
            try self.findSievePrimesInSegment();
        }

        return Segment{
            .containerStart = self.bucketsStart / 8,
            .containerEndExclusive = self.bucketsEndExclusive / 8,
            .containers = self.containers,
        };
    }

    fn findSievePrimesInSegment(self: *SegmentIterator) !void {
        for (self.bucketsStart..@min(self.rootBucketIndexExclusive, self.bucketsEndExclusive)) |bucketIndex| {
            // self.buckets is the reused, segment-local buffer (LOCAL index
            // = GLOBAL bucketIndex - bucketsStart) - this only ever
            // coincided with the global index before because discovery
            // finishing within segment 0 (bucketsStart == 0) was the only
            // case ever exercised; range-start's multi-segment discovery
            // (see next()) is the first thing to reach a later segment here.
            var bucketWorkingCopy = self.buckets[bucketIndex - self.bucketsStart];
            while (bucketWorkingCopy != 0) {
                const inBucketIndex: u3 = Utils.lsb(bucketWorkingCopy);
                const sievePrime = SievePrime.from(bucketIndex, inBucketIndex);
                const prime = Utils.admissibleNumberFromBitIndex(@bitSizeOf(Types.SIEVE_BUCKET_TYPE) * bucketIndex + inBucketIndex);

                if (!PreSieve.isPreSieved(prime)) {
                    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                        if (ari == inBucketIndex) {
                            if (prime <= SMALL_MEDIUM_THRESHOLD) {
                                try self.small.add(self.allocator, ari, self.buckets, self.bucketsStart, self.bucketsEndExclusive, sievePrime);
                            } else if (prime <= MEDIUM_LARGE_THRESHOLD) {
                                try self.medium.add(self.allocator, sievePrime);
                            } else if (prime <= LARGE_HUGE_THRESHOLD) {
                                try self.large.add(self.allocator, sievePrime);
                            } else {
                                try self.huge.add(self.allocator, sievePrime);
                            }
                        }
                    }
                }

                bucketWorkingCopy &= bucketWorkingCopy - 1;
            }
        }
    }
};
