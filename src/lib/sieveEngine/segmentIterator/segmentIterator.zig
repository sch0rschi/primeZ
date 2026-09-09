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
    huge: HugeSievePrimes,

    // Explicit error set (rather than inferred `!SegmentIterator`) because
    // init() and discoverSievingPrimes() call each other recursively -
    // Zig can't infer an error set across a genuine call cycle.
    pub noinline fn init(allocator: std.mem.Allocator, startInclusive: usize, limitInclusive: usize) std.mem.Allocator.Error!SegmentIterator {
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
        // OVERRIDE_BUCKETS fixes up the presieve pattern's own base primes
        // (which the pattern otherwise zeroes out as "multiples of
        // themselves") - only valid for the segment actually containing
        // position 0, since it's computed in absolute (0-based) terms.
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
            .huge = try HugeSievePrimes.init(allocator, rootPrime),
        };

        // Sieving-prime discovery is fully decoupled from the output walk
        // (see discoverSievingPrimes): every prime up to rootPrime is found
        // via its own, always-0-based nested sieve, and filed directly at
        // its true target position relative to startInclusive - no
        // "discover relative to 0, then jump/re-seed relative to the real
        // start" two-step (see project memory huge_tier_bucket_list_idea).
        // Must run after buckets/PreSieve above are ready: small-tier
        // filing crosses off immediately when a prime's target lands
        // within this very first output segment.
        try discoverSievingPrimes(
            allocator,
            rootPrime,
            startInclusive,
            &self.small,
            &self.medium,
            &self.large,
            &self.huge,
            self.buckets,
            self.bucketsStart,
            self.bucketsEndExclusive,
        );
        // Discovery files primes in increasing prime-value order, not
        // increasing target-position order (see sortByPosition) - restore
        // the sorted-by-currentBucketIndex invariant activate() depends on
        // before the first next() call. Medium has no such invariant (its
        // apply() always walks every tracked prime, see its own docstring)
        // and huge's ring/pending never needed one either (see its struct
        // docstring), so only small/large need this.
        self.small.sortByPosition();
        self.large.sortByPosition();

        return self;
    }

    pub fn deinit(self: *SegmentIterator) void {
        self.allocator.free(self.buckets);
        self.small.deinit(self.allocator);
        self.medium.deinit(self.allocator);
        self.large.deinit(self.allocator);
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

        self.small.activate(self.bucketsEndExclusive);
        self.small.apply(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        self.medium.apply(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        self.large.activate(self.bucketsEndExclusive);
        self.large.apply(self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        try self.huge.activate(self.allocator, self.bucketsStart);
        try self.huge.apply(self.allocator, self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        return Segment{
            .containerStart = self.bucketsStart / 8,
            .containerEndExclusive = self.bucketsEndExclusive / 8,
            .containers = self.containers,
        };
    }
};

/// Finds every sieving prime up to and including rootPrime, via its own
/// always-0-based nested SegmentIterator (bottoms out fast: rootPrime's own
/// discovery needs primes only up to sqrt(rootPrime), and so on - this
/// shrinks below 2 within a handful of levels for any u64 input, mirroring
/// primesieve's tinySieve/SievingPrimes bootstrap), and files each one
/// directly into the real (startInclusive-relative) tiers - see
/// SievePrime.from and HugeSievePrimes' struct docstring for why this
/// lands correctly (and cheaply) without a separate re-seed pass.
noinline fn discoverSievingPrimes(
    allocator: std.mem.Allocator,
    rootPrime: usize,
    startInclusive: usize,
    small: *SmallSievePrimes,
    medium: *MediumSievePrimes,
    large: *LargeSievePrimes,
    huge: *HugeSievePrimes,
    outputBuckets: Types.SIEVE_BUCKETS_TYPE,
    outputBucketsStart: usize,
    outputBucketsEndExclusive: usize,
) std.mem.Allocator.Error!void {
    if (rootPrime < 2) return;

    var nested = try SegmentIterator.init(allocator, 0, rootPrime);
    defer nested.deinit();

    outer: while (try nested.next()) |segment| {
        for (segment.containerStart..segment.containerEndExclusive, segment.containers[0 .. segment.containerEndExclusive - segment.containerStart]) |containerIndex, container| {
            var containerWorkingCopy: u64 = container;
            while (containerWorkingCopy != 0) {
                const inContainerIndex: u6 = @intCast(@ctz(containerWorkingCopy));
                containerWorkingCopy &= containerWorkingCopy - 1;

                const bitIndex = 64 * containerIndex + inContainerIndex;
                const prime = Utils.admissibleNumberFromBitIndex(bitIndex);
                if (prime > rootPrime) break :outer;
                if (PreSieve.isPreSieved(prime)) continue;

                const bucketIndex = bitIndex / BUCKET_BITS;
                const inBucketIndex: u3 = @intCast(bitIndex % BUCKET_BITS);
                const sievePrime = SievePrime.from(bucketIndex, inBucketIndex, startInclusive);

                inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                    if (ari == inBucketIndex) {
                        if (prime <= SMALL_MEDIUM_THRESHOLD) {
                            small.add(ari, outputBuckets, outputBucketsStart, outputBucketsEndExclusive, sievePrime);
                        } else if (prime <= MEDIUM_LARGE_THRESHOLD) {
                            medium.add(sievePrime);
                        } else if (prime <= LARGE_HUGE_THRESHOLD) {
                            large.add(sievePrime);
                        } else {
                            huge.add(sievePrime);
                        }
                    }
                }
            }
        }
    }

    // Every sieving prime is staged (see HugeSievePrimes.add) rather than
    // placed directly - now that the exact population is known, this picks
    // exact per-ring-slot capacities and does the real placement with
    // appendAssumeCapacity instead of tens of millions of growable
    // `.append()` calls (profiled as the dominant cost of a huge-magnitude
    // range-start query once firstAdmissibleMultiple's own scan loop was
    // fixed - see project memory huge_tier_bucket_list_idea).
    try huge.finalizeDiscovery(allocator, outputBucketsStart);
}
