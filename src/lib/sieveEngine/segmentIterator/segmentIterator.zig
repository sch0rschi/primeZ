const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const Utils = @import("../utils.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const SmallSievePrimes = @import("smallSievePrimes.zig").SmallSievePrimes;
const MediumSievePrimes = @import("mediumSievePrimes.zig").MediumSievePrimes;
const LargeSievePrimes = @import("largeSievePrimes.zig").LargeSievePrimes;

const ALIGNMENT = std.mem.Alignment.@"8";

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;
const SMALL_MEDIUM_THRESHOLD: usize = BuildUtils.SMALL_MEDIUM_THRESHOLD;
const MEDIUM_LARGE_THRESHOLD: usize = BuildUtils.MEDIUM_LARGE_THRESHOLD;

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

    bucketsStart: usize,
    bucketsEndExclusive: usize,
    started: bool,

    small: SmallSievePrimes,
    medium: MediumSievePrimes,
    large: LargeSievePrimes,

    pub fn init(allocator: std.mem.Allocator, lowerLimitInclusive: usize) !SegmentIterator {
        const bucketsLength = ALIGNMENT.forward(Utils.getSieveLength(lowerLimitInclusive));
        const buckets = try allocator.alignedAlloc(
            Types.SIEVE_BUCKET_TYPE,
            ALIGNMENT,
            @min(SEGMENT_ELEMS, bucketsLength),
        );

        const containers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(buckets));

        @memset(buckets, std.math.maxInt(Types.SIEVE_BUCKET_TYPE));
        buckets[0] = Comptimes.FIRST_BUCKET;

        const rootPrime = std.math.sqrt(lowerLimitInclusive);
        const rootBucketExclusive = Utils.getSieveLength(rootPrime);

        return SegmentIterator{
            .allocator = allocator,

            .buckets = buckets,
            .containers = containers,

            .bucketsLength = bucketsLength,
            .rootBucketIndexExclusive = rootBucketExclusive,

            .bucketsStart = 0,
            .bucketsEndExclusive = @min(SEGMENT_ELEMS, bucketsLength),
            .started = false,

            .small = try SmallSievePrimes.init(allocator),
            .medium = try MediumSievePrimes.init(allocator),
            .large = try LargeSievePrimes.init(allocator),
        };
    }

    pub fn deinit(self: *SegmentIterator) void {
        self.allocator.free(self.buckets);
        self.small.deinit(self.allocator);
        self.medium.deinit(self.allocator);
        self.large.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn next(self: *SegmentIterator) !?Segment {
        if (self.bucketsStart >= self.bucketsLength) {
            return null;
        }

        if (self.started) {
            self.bucketsStart += SEGMENT_ELEMS;
            self.bucketsEndExclusive = @min(self.bucketsStart + SEGMENT_ELEMS, self.bucketsLength);
            if (self.bucketsStart >= self.bucketsLength) {
                return null;
            }
            @memset(self.buckets, std.math.maxInt(Types.SIEVE_BUCKET_TYPE));
        }
        self.started = true;

        self.small.activate(self.bucketsEndExclusive);
        self.small.apply(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        self.medium.apply(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        self.large.activate(self.bucketsEndExclusive);
        self.large.apply(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

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
            var bucketWorkingCopy = self.buckets[bucketIndex];
            while (bucketWorkingCopy != 0) {
                const inBucketIndex: u3 = Utils.lsb(bucketWorkingCopy);
                const sievePrime = SievePrime.from(bucketIndex, inBucketIndex);
                const prime = Utils.admissibleNumberFromBitIndex(@bitSizeOf(Types.SIEVE_BUCKET_TYPE) * bucketIndex + inBucketIndex);

                inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                    if (ari == inBucketIndex) {
                        if (prime <= SMALL_MEDIUM_THRESHOLD) {
                            try self.small.add(self.allocator, ari, self.buckets, self.bucketsStart, self.bucketsEndExclusive, sievePrime);
                        } else if (prime <= MEDIUM_LARGE_THRESHOLD) {
                            try self.medium.add(self.allocator, sievePrime);
                        } else {
                            try self.large.add(self.allocator, sievePrime);
                        }
                    }
                }

                bucketWorkingCopy &= bucketWorkingCopy - 1;
            }
        }
    }
};
