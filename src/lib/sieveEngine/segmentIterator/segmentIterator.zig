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
const LargeHeadSievePrimes = @import("largeHeadSievePrimes.zig").LargeHeadSievePrimes;
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
    largeHead: LargeHeadSievePrimes,
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
            .largeHead = try LargeHeadSievePrimes.init(allocator),
            .huge = try HugeSievePrimes.init(allocator, rootPrime),
        };

        // Sieving-prime discovery is fully decoupled from the output walk
        // (see discoverSievingPrimes): every prime up to rootPrime is found
        // via a single, non-recursive, self-bootstrapping sieve of its own
        // (see that function's docstring), and filed directly at its true
        // target position relative to startInclusive - no "discover
        // relative to 0, then jump/re-seed relative to the real start"
        // two-step (see project memory huge_tier_bucket_list_idea). Must
        // run after buckets/PreSieve above are ready: small-tier filing
        // crosses off immediately when a prime's target lands within this
        // very first output segment.
        try discoverSievingPrimes(
            allocator,
            rootPrime,
            startInclusive,
            &self.small,
            &self.medium,
            &self.large,
            &self.largeHead,
            &self.huge,
            self.buckets,
            self.bucketsStart,
            self.bucketsEndExclusive,
            self.bucketsLength,
        );
        // Discovery files primes in increasing prime-value order, not
        // increasing target-position order - restore the sorted-by-
        // currentBucketIndex invariant SmallSievePrimes.activate() depends
        // on before the first next() call. Medium has no such invariant
        // (its apply() always walks every tracked prime, see its own
        // docstring) and neither huge nor large need one either now (both
        // use a ring buffer instead - see their own struct docstrings).
        self.small.sortByPosition();

        return self;
    }

    pub fn deinit(self: *SegmentIterator) void {
        self.allocator.free(self.buckets);
        self.small.deinit(self.allocator);
        self.medium.deinit(self.allocator);
        self.large.deinit(self.allocator);
        self.largeHead.deinit(self.allocator);
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

        try crossOffSegment(self.allocator, &self.small, &self.medium, &self.large, &self.largeHead, &self.huge, self.buckets, self.bucketsStart, self.bucketsEndExclusive);

        return Segment{
            .containerStart = self.bucketsStart / 8,
            .containerEndExclusive = self.bucketsEndExclusive / 8,
            .containers = self.containers,
        };
    }
};

/// Crosses off composites in [bucketsStart, bucketsEndExclusive) using
/// every sieving prime already registered in small/medium/large/huge -
/// shared between SegmentIterator.next() (the real output walk) and
/// discoverSievingPrimes (which runs the exact same per-segment cross-off
/// step against its own, disposable tiers - see that function's
/// docstring).
fn crossOffSegment(
    allocator: std.mem.Allocator,
    small: *SmallSievePrimes,
    medium: *MediumSievePrimes,
    large: *LargeSievePrimes,
    largeHead: *LargeHeadSievePrimes,
    huge: *HugeSievePrimes,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    bucketsStart: usize,
    bucketsEndExclusive: usize,
) !void {
    small.activate(bucketsEndExclusive);
    small.apply(buckets, bucketsStart, bucketsEndExclusive);

    medium.apply(buckets, bucketsStart, bucketsEndExclusive);

    try large.activate(allocator, bucketsStart);
    large.apply(buckets, bucketsStart, bucketsEndExclusive);

    // No activate() - like medium, this tier is a bucket-and-refile design
    // (not ring-based), so a not-yet-due entry just sits until apply()'s own
    // readiness check lets it through - see largeHeadSievePrimes.zig.
    largeHead.apply(buckets, bucketsStart, bucketsEndExclusive);

    try huge.activate(allocator, bucketsStart);
    try huge.apply(allocator, buckets, bucketsStart, bucketsEndExclusive);
}

/// Finds every sieving prime up to and including rootPrime, and files each
/// one directly into the real (startInclusive-relative) tiers - see
/// SievePrime.from and HugeSievePrimes' struct docstring for why this
/// lands correctly (and cheaply) without a separate re-seed pass.
///
/// This is a single, non-recursive, self-bootstrapping sieve of [0,
/// rootPrime] - not a nested SegmentIterator calling this same function
/// again for its own needs (an earlier version worked that way; see
/// project memory huge_tier_bucket_list_idea for the "why are we doing it
/// like this" discussion that led to this rewrite). The classical Sieve of
/// Eratosthenes doesn't need its sieving primes precomputed at all: scan
/// candidates in increasing order, and whenever an unmarked position is
/// reached it must be prime (its smallest possible factor, being <= its
/// own square root, would already have been discovered - and had its own
/// multiples crossed off - earlier in the very same scan, by induction).
/// So this sieve bootstraps its own sieving primes as it goes: any
/// discovered prime <= dsp (= sqrt(rootPrime), the largest prime this
/// sieve could ever still need against itself) is registered into this
/// function's own, disposable small/medium/large/huge tiers (selfSmall
/// etc.) so it takes effect on the rest of this same sieve - including,
/// via SmallSievePrimes.add()'s existing same-segment-immediate-apply
/// path, within the very segment it was just discovered in. Every
/// discovered prime (regardless of whether it's <= dsp) is additionally,
/// unconditionally forwarded to the real query's own tiers, exactly as
/// before.
///
/// primesieve's own bootstrap (SievingPrimes::tinySieve, see
/// bench/primesieve/src/SievingPrimes.cpp) uses this same "self-discovery"
/// principle via a flat, non-segmented array for an even smaller bound
/// (stop^(1/4)) before switching to its own segmented Erat machinery for
/// [~13, sqrt(stop)] - a separate step we don't need: SmallSievePrimes.add()
/// already provides the "apply within the segment it was just discovered
/// in" primitive tinySieve exists to bootstrap, so a single segmented,
/// self-discovering sieve suffices here for the whole [0, rootPrime] range.
///
/// dsp is always far below rootPrime (it's rootPrime's own square root),
/// so this bottoms out immediately - no further recursion of any kind, for
/// any u64 input.
noinline fn discoverSievingPrimes(
    allocator: std.mem.Allocator,
    rootPrime: usize,
    startInclusive: usize,
    small: *SmallSievePrimes,
    medium: *MediumSievePrimes,
    large: *LargeSievePrimes,
    largeHead: *LargeHeadSievePrimes,
    huge: *HugeSievePrimes,
    outputBuckets: Types.SIEVE_BUCKETS_TYPE,
    outputBucketsStart: usize,
    outputBucketsEndExclusive: usize,
    queryBucketsLength: usize,
) !void {
    if (rootPrime < 2) return;

    // The largest prime this sieve could ever need against itself - see
    // this function's own docstring for why nothing bigger is ever
    // relevant to sieving [0, rootPrime] correctly.
    const dsp = std.math.sqrt(rootPrime);

    const selfBucketsLength = ALIGNMENT.forward(Utils.getSieveLength(rootPrime));
    const selfBuckets = try allocator.alignedAlloc(
        Types.SIEVE_BUCKET_TYPE,
        ALIGNMENT,
        @min(SEGMENT_ELEMS, selfBucketsLength),
    );
    defer allocator.free(selfBuckets);
    const selfContainers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(selfBuckets));

    // This sieve's own, disposable tiers - population bounded by dsp, not
    // rootPrime, so these stay small regardless of how large the real
    // query's own rootPrime is (HugeSievePrimes.init(allocator, dsp) sizes
    // its ring accordingly). Discovery order here is strictly increasing
    // in prime value, and every target is prime^2 (self-registration always
    // passes minRawNumberInclusive=0) - strictly increasing in prime too -
    // so unlike the real query's small/large tiers, these never need
    // sortByPosition(): the sorted-by-position invariant holds for free.
    var selfSmall = try SmallSievePrimes.init(allocator);
    defer selfSmall.deinit(allocator);
    var selfMedium = try MediumSievePrimes.init(allocator);
    defer selfMedium.deinit(allocator);
    var selfLarge = try LargeSievePrimes.init(allocator);
    defer selfLarge.deinit(allocator);
    var selfLargeHead = try LargeHeadSievePrimes.init(allocator);
    defer selfLargeHead.deinit(allocator);
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

        try crossOffSegment(allocator, &selfSmall, &selfMedium, &selfLarge, &selfLargeHead, &selfHuge, selfBuckets, selfBucketsStart, selfBucketsEndExclusive);

        const containerStart = selfBucketsStart / 8;
        const containerEndExclusive = selfBucketsEndExclusive / 8;

        // containerIndex is the segment's ABSOLUTE container position
        // (needed below to compute each bit's real numeric value); the
        // array access itself must go through localContainerIndex, since
        // selfContainers/selfBuckets is a single reused, segment-sized
        // buffer (refilled by PreSieve.fill each segment), not one big
        // array spanning [0, rootPrime].
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

                // Forward to the real query, unconditionally - see this
                // function's docstring. Computes only the plain (unpacked)
                // target position first, deliberately not yet the packed
                // SievePrime itself: for a huge-magnitude range-start
                // query, the huge/large filters below discard the large
                // majority of targets outside the query's own range (see
                // their own comments), and assembling the packed bit
                // layout (SievePrime.fromTarget) is real, measurable work
                // (`perf annotate` showed it materializing to a stack slot
                // in this same loop) - worth paying only for a target
                // that's actually going to be kept.
                //
                // Checked most-likely-first rather than in threshold
                // order: for a huge-magnitude range-start query, the
                // overwhelming majority of discovered primes land in the
                // huge tier (everything above LARGE_HUGE_THRESHOLD, up to
                // rootPrime - a far wider span than the other three tiers
                // combined), so this lets that common case fall out after
                // a single comparison instead of always evaluating all
                // three.
                // Huge tier gets its own wheel-210 target/type (see
                // HugeSievePrime), computed separately from the wheel-30
                // target the other three tiers share below - its
                // discard-out-of-range filter must be checked against the
                // wheel-210 landing itself (the position this prime will
                // actually first cross off under wheel-210 stepping), not
                // the wheel-30 one: a prime whose wheel-30 target is
                // in-range but lands on a multiple of 7 (already
                // redundant, see WHEEL_PATTERNS_210's docstring) may have
                // its true first wheel-210 landing fall outside the query
                // entirely, in which case it's correctly discarded here
                // too.
                //
                // Checked most-likely-first rather than in threshold
                // order: for a huge-magnitude range-start query, the
                // overwhelming majority of discovered primes land in the
                // huge tier (everything above LARGE_HUGE_THRESHOLD, up to
                // rootPrime - a far wider span than the other three tiers
                // combined), so this lets that common case fall out after
                // a single comparison instead of always evaluating all
                // three.
                if (prime > LARGE_HUGE_THRESHOLD) {
                    // Mirrors primesieve's own Wheel::addSievingPrime ("if
                    // (multiple > stop_) return" - see
                    // bench/primesieve/include/primesieve/Wheel.hpp): a
                    // huge-tier prime hits at most once per segment (see
                    // HugeSievePrimes' own docstring), so if its computed
                    // target already lies at or past the query's own end,
                    // it will NEVER cross off anything in this query -
                    // don't spend a ring/pending slot tracking it at all.
                    // For a narrow window near a huge start, this is the
                    // overwhelming majority of huge-tier primes (their
                    // step size vastly exceeds the window width) - found
                    // via `perf`/memory profiling showing primez using
                    // ~900MB vs primesieve's ~20-90MB for the same query;
                    // see project memory huge_tier_bucket_list_idea for
                    // the full investigation.
                    const target210 = SievePrimeMod.firstAdmissibleMultiple210(prime, startInclusive);
                    if (target210.bucketIndex < queryBucketsLength) {
                        const realHugeSievePrime = HugeSievePrime.fromTarget210(target210, bucketIndex, inBucketIndex);
                        try huge.add(allocator, realHugeSievePrime, outputBucketsStart);
                    }
                } else {
                    // Computes only the plain (unpacked) target position
                    // first, deliberately not yet the packed SievePrime
                    // itself: for a huge-magnitude range-start query, the
                    // large filter below discards the large majority of
                    // targets outside the query's own range (see its own
                    // comment), and assembling the packed bit layout
                    // (SievePrime.fromTarget) is real, measurable work
                    // (`perf annotate` showed it materializing to a stack
                    // slot in this same loop) - worth paying only for a
                    // target that's actually going to be kept.
                    const target = SievePrimeMod.firstAdmissibleMultiple(prime, startInclusive);
                    if (prime > LARGE_HEAD_THRESHOLD) {
                        // largeHead covers the sub-range closest to huge
                        // (LARGE_HEAD_THRESHOLD..LARGE_HUGE_THRESHOLD - see
                        // largeHeadSievePrimes.zig's own top comment). Its
                        // bucket-and-refile design needs no discard-out-of-
                        // range filter: an entry not yet due just gets
                        // refiled unchanged next segment instead of
                        // spending a bounded ring/pending slot the way
                        // large/huge's own filters exist to protect.
                        const realSievePrime = SievePrime.fromTarget(target, bucketIndex, inBucketIndex);
                        largeHead.add(realSievePrime);
                    } else if (prime > MEDIUM_LARGE_THRESHOLD) {
                        // large/batch covers the sub-range closest to
                        // medium (MEDIUM_LARGE_THRESHOLD..LARGE_HEAD_THRESHOLD
                        // - see largeSievePrimes.zig's own top comment).
                        // Same discard-out-of-range reasoning as the
                        // huge-tier filter above: a ring-based tier's
                        // first target already lying at or past the
                        // query's own end will never cross off anything in
                        // this query.
                        if (target.bucketIndex < queryBucketsLength) {
                            const realSievePrime = SievePrime.fromTarget(target, bucketIndex, inBucketIndex);
                            try large.add(allocator, realSievePrime, outputBucketsStart);
                        }
                    } else if (prime > SMALL_MEDIUM_THRESHOLD) {
                        medium.add(SievePrime.fromTarget(target, bucketIndex, inBucketIndex));
                    } else {
                        // Only SmallSievePrimes.add() needs inBucketIndex
                        // as a comptime value (for its own comptime-
                        // specialized wheel unrolling) - medium/large.add()
                        // just take the already-runtime sievePrime, so the
                        // comptime `ari` dispatch (8 unrolled copies) is
                        // scoped to only the small branch instead of
                        // wrapping both and forcing every large/medium
                        // prime through it too.
                        const realSievePrime = SievePrime.fromTarget(target, bucketIndex, inBucketIndex);
                        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                            if (ari == inBucketIndex) {
                                small.add(ari, outputBuckets, outputBucketsStart, outputBucketsEndExclusive, realSievePrime);
                            }
                        }
                    }
                }

                // Self-register into this sieve's own tiers if this prime
                // is small enough to still matter for sieving the rest of
                // [0, rootPrime] - see this function's docstring.
                if (prime <= dsp) {
                    if (prime > LARGE_HUGE_THRESHOLD) {
                        const selfTarget210 = SievePrimeMod.firstAdmissibleMultiple210(prime, 0);
                        const selfHugeSievePrime = HugeSievePrime.fromTarget210(selfTarget210, bucketIndex, inBucketIndex);
                        try selfHuge.add(allocator, selfHugeSievePrime, selfBucketsStart);
                    } else {
                        const selfSievePrime = SievePrime.from(prime, bucketIndex, inBucketIndex, 0);
                        if (prime > LARGE_HEAD_THRESHOLD) {
                            selfLargeHead.add(selfSievePrime);
                        } else if (prime > MEDIUM_LARGE_THRESHOLD) {
                            try selfLarge.add(allocator, selfSievePrime, selfBucketsStart);
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
                    // Re-sync the local snapshot: self-registration may
                    // have just crossed off a bit within the SAME
                    // container currently being scanned (e.g. discovering
                    // 7 whose square 49 falls in the very first container)
                    // via SmallSievePrimes.add()'s same-segment-immediate-
                    // apply path - containerWorkingCopy was snapshotted
                    // before that write, so without this it could re-
                    // surface an already-composite bit as a false "prime".
                    // ANDing with the live value is always safe: it can
                    // only clear bits (never set ones we haven't already
                    // consumed via the `&= x-1` above), and it's a no-op
                    // whenever the write landed in a different container.
                    containerWorkingCopy &= selfContainers[localContainerIndex];
                }
            }
        }
    }
}
