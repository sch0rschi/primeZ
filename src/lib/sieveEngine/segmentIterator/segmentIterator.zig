const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const Utils = @import("../utils.zig");
const PreSieve = @import("../preSieve.zig");
const LayoutMod = @import("../layout.zig");
const Layout = LayoutMod.Layout;
const QueryLayouts = LayoutMod.QueryLayouts;

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
const LargeSievePrime = SievePrimeMod.LargeSievePrime;

const SmallStrideSievePrimes = @import("smallStrideSievePrimes.zig").SmallStrideSievePrimes;
const SmallSegmentSievePrimes = @import("smallSegmentSievePrimes.zig").SmallSegmentSievePrimes;
const MediumSievePrimes = @import("mediumSievePrimes.zig").MediumSievePrimes;
const PreLargeSievePrimes = @import("preLargeSievePrimes.zig").PreLargeSievePrimes;
const LargeSievePrimes = @import("largeSievePrimes.zig").LargeSievePrimes;

const ALIGNMENT = std.mem.Alignment.@"8";

const BUCKET_BITS = @bitSizeOf(Types.SIEVE_BUCKET_TYPE);

const Segment = struct {
    containerStart: usize,
    containerEndExclusive: usize,
    containers: []align(8) u64,
};

const Tiers = struct {
    layout: Layout,
    smallL1Stride: SmallStrideSievePrimes,
    smallL2Stride: SmallStrideSievePrimes,
    smallSegment: SmallSegmentSievePrimes,
    medium: MediumSievePrimes,
    preLarge: PreLargeSievePrimes,
    large: LargeSievePrimes,

    fn init(allocator: std.mem.Allocator, layout: Layout, maxPrime: usize) !Tiers {
        return .{
            .layout = layout,
            .smallL1Stride = try SmallStrideSievePrimes.init(allocator, layout.segmentElems, layout.l1StrideElems, 0, @min(maxPrime, layout.smallL1StrideThreshold)),
            .smallL2Stride = try SmallStrideSievePrimes.init(allocator, layout.segmentElems, layout.l2StrideElems, layout.smallL1StrideThreshold, @min(maxPrime, layout.smallL2StrideThreshold)),
            .smallSegment = try SmallSegmentSievePrimes.init(allocator, layout, maxPrime),
            .medium = try MediumSievePrimes.init(allocator, layout, maxPrime),
            .preLarge = try PreLargeSievePrimes.init(allocator, layout, maxPrime),
            .large = try LargeSievePrimes.init(allocator, layout, maxPrime),
        };
    }

    fn deinit(self: *Tiers, allocator: std.mem.Allocator) void {
        self.smallL1Stride.deinit(allocator);
        self.smallL2Stride.deinit(allocator);
        self.smallSegment.deinit(allocator);
        self.medium.deinit(allocator);
        self.preLarge.deinit(allocator);
        self.large.deinit(allocator);
    }

    fn sortByPosition(self: *Tiers) void {
        self.smallL1Stride.sortByPosition();
        self.smallL2Stride.sortByPosition();
    }

    fn crossOff(self: *Tiers, buckets: Types.SIEVE_BUCKETS_TYPE, bucketsStart: usize, bucketsEndExclusive: usize) void {
        self.smallL1Stride.activate(bucketsStart, bucketsEndExclusive);
        self.smallL1Stride.apply(buckets, bucketsStart, bucketsEndExclusive);

        self.smallL2Stride.activate(bucketsStart, bucketsEndExclusive);
        self.smallL2Stride.apply(buckets, bucketsStart, bucketsEndExclusive);

        self.smallSegment.apply(buckets, bucketsStart, bucketsEndExclusive);

        self.medium.activate(bucketsStart);
        self.medium.apply(buckets, bucketsStart, bucketsEndExclusive);

        self.preLarge.activate(bucketsStart);
        self.preLarge.apply(buckets, bucketsStart, bucketsEndExclusive);

        self.large.activate(bucketsStart);
        self.large.apply(buckets, bucketsStart, bucketsEndExclusive);
    }

    fn add(
        self: *Tiers,
        prime: usize,
        bucketIndex: usize,
        inBucketIndex: u3,
        startInclusive: usize,
        bucketsLength: usize,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        const layout = self.layout;
        if (prime > layout.mediumThreshold) {
            const target2310 = SievePrimeMod.firstAdmissibleMultiple2310(prime, startInclusive);
            if (target2310.bucketIndex >= bucketsLength) return;
            const largeSievePrime = LargeSievePrime.fromTarget2310(target2310, bucketIndex, inBucketIndex);
            if (prime > layout.preLargeThreshold) {
                self.large.add(largeSievePrime, bucketsStart);
            } else {
                self.preLarge.add(largeSievePrime, bucketsStart);
            }
            return;
        }

        const sievePrime = SievePrime.fromTarget(SievePrimeMod.firstAdmissibleMultiple(prime, startInclusive), bucketIndex, inBucketIndex);
        if (prime > layout.smallSegmentThreshold) {
            if (sievePrime.currentBucketIndex < bucketsLength) self.medium.add(sievePrime, bucketsStart);
        } else if (prime > layout.smallL2StrideThreshold) {
            self.smallSegment.add(buckets, bucketsStart, bucketsEndExclusive, sievePrime);
        } else {
            const stride = if (prime > layout.smallL1StrideThreshold) &self.smallL2Stride else &self.smallL1Stride;
            switch (inBucketIndex) {
                inline else => |ari| stride.add(ari, buckets, bucketsStart, bucketsEndExclusive, sievePrime),
            }
        }
    }
};

pub const SegmentIterator = struct {
    allocator: std.mem.Allocator,
    layout: Layout,

    buckets: []align(8) Types.SIEVE_BUCKET_TYPE,
    containers: []align(8) Types.SIEVE_CONTAINER_TYPE,

    bucketsLength: usize,

    bucketsStart: usize,
    bucketsEndExclusive: usize,
    started: bool,

    tiers: Tiers,

    pub fn initDefault(allocator: std.mem.Allocator, startInclusive: usize, limitInclusive: usize) !SegmentIterator {
        return init(allocator, startInclusive, limitInclusive, LayoutMod.layoutsForQuery(limitInclusive));
    }

    pub noinline fn init(allocator: std.mem.Allocator, startInclusive: usize, limitInclusive: usize, layouts: QueryLayouts) !SegmentIterator {
        std.debug.assert(layouts.query.presieve == layouts.selfSieve.presieve);
        const layout = layouts.query;
        const segmentElems = layout.segmentElems;
        const bucketsLength = ALIGNMENT.forward(Utils.getSieveLength(limitInclusive));
        const buckets = try allocator.alignedAlloc(
            Types.SIEVE_BUCKET_TYPE,
            ALIGNMENT,
            @min(segmentElems, bucketsLength),
        );

        const containers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(buckets));

        const startBucketIndex = ALIGNMENT.backward(startInclusive / Comptimes.WHEEL_CIRCUMFERENCE);
        const bucketsEndExclusive = @min(startBucketIndex + segmentElems, bucketsLength);

        PreSieve.fill(layout.presieve, buckets, startBucketIndex);
        if (startBucketIndex == 0) {
            PreSieve.applyOverride(layout.presieve, buckets);
        }

        const rootPrime = std.math.sqrt(limitInclusive);

        var self = SegmentIterator{
            .allocator = allocator,
            .layout = layout,

            .buckets = buckets,
            .containers = containers,

            .bucketsLength = bucketsLength,

            .bucketsStart = startBucketIndex,
            .bucketsEndExclusive = bucketsEndExclusive,
            .started = false,

            .tiers = try Tiers.init(allocator, layout, rootPrime),
        };

        try discoverSievingPrimes(allocator, layouts.selfSieve, rootPrime, startInclusive, &self.tiers, self.buckets, self.bucketsStart, self.bucketsEndExclusive, self.bucketsLength);
        self.tiers.sortByPosition();

        return self;
    }

    pub fn deinit(self: *SegmentIterator) void {
        self.allocator.free(self.buckets);
        self.tiers.deinit(self.allocator);
        self.* = undefined;
    }

    pub noinline fn next(self: *SegmentIterator) !?Segment {
        if (!self.started) {
            if (self.bucketsStart >= self.bucketsLength) {
                return null;
            }
            self.started = true;
        } else {
            const candidateBucketsStart = self.bucketsStart + self.layout.segmentElems;
            if (candidateBucketsStart >= self.bucketsLength) {
                return null;
            }
            self.bucketsStart = candidateBucketsStart;
            self.bucketsEndExclusive = @min(self.bucketsStart + self.layout.segmentElems, self.bucketsLength);
            PreSieve.fill(self.layout.presieve, self.buckets, self.bucketsStart);
        }

        self.tiers.crossOff(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        return Segment{
            .containerStart = self.bucketsStart / 8,
            .containerEndExclusive = self.bucketsEndExclusive / 8,
            .containers = self.containers,
        };
    }
};

noinline fn discoverSievingPrimes(
    allocator: std.mem.Allocator,
    selfLayout: Layout,
    rootPrime: usize,
    startInclusive: usize,
    tiers: *Tiers,
    outputBuckets: Types.SIEVE_BUCKETS_TYPE,
    outputBucketsStart: usize,
    outputBucketsEndExclusive: usize,
    queryBucketsLength: usize,
) !void {
    if (rootPrime < 2) return;

    const dsp = std.math.sqrt(rootPrime);

    const selfSegmentElems = selfLayout.segmentElems;
    const selfBucketsLength = ALIGNMENT.forward(Utils.getSieveLength(rootPrime));
    const selfBuckets = try allocator.alignedAlloc(
        Types.SIEVE_BUCKET_TYPE,
        ALIGNMENT,
        @min(selfSegmentElems, selfBucketsLength),
    );
    defer allocator.free(selfBuckets);
    const selfContainers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(selfBuckets));

    var selfTiers = try Tiers.init(allocator, selfLayout, dsp);
    defer selfTiers.deinit(allocator);

    PreSieve.fill(selfLayout.presieve, selfBuckets, 0);
    PreSieve.applyOverride(selfLayout.presieve, selfBuckets);

    var selfBucketsStart: usize = 0;
    var selfBucketsEndExclusive: usize = @min(selfSegmentElems, selfBucketsLength);
    var started = false;

    outer: while (true) {
        if (!started) {
            if (selfBucketsStart >= selfBucketsLength) break;
            started = true;
        } else {
            const candidate = selfBucketsStart + selfSegmentElems;
            if (candidate >= selfBucketsLength) break;
            selfBucketsStart = candidate;
            selfBucketsEndExclusive = @min(selfBucketsStart + selfSegmentElems, selfBucketsLength);
            PreSieve.fill(selfLayout.presieve, selfBuckets, selfBucketsStart);
        }

        selfTiers.crossOff(selfBuckets, selfBucketsStart, selfBucketsEndExclusive);

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
                if (PreSieve.isPreSieved(selfLayout.presieve, prime)) continue;

                const bucketIndex = bitIndex / BUCKET_BITS;
                const inBucketIndex: u3 = @intCast(bitIndex % BUCKET_BITS);

                tiers.add(prime, bucketIndex, inBucketIndex, startInclusive, queryBucketsLength, outputBuckets, outputBucketsStart, outputBucketsEndExclusive);

                if (prime <= dsp) {
                    selfTiers.add(prime, bucketIndex, inBucketIndex, 0, std.math.maxInt(usize), selfBuckets, selfBucketsStart, selfBucketsEndExclusive);
                    containerWorkingCopy &= selfContainers[localContainerIndex];
                }
            }
        }
    }
}
