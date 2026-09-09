const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;

// The largest single-step advance any tracked prime can ever make, in
// buckets: WHEEL_PATTERNS' own worst-case divMultiplicator/residueAddend,
// applied to the largest prime this tier will ever hold (see ringSize
// below) - mirrors primesieve's EratBig::init exactly (maxSievingPrime *
// maxFactor + maxFactor), just derived from our own comptime wheel table
// instead of a hardcoded constant.
const MAX_WHEEL_STEP_FACTOR: usize = blk: {
    var m: usize = 0;
    for (Comptimes.WHEEL_PATTERNS) |row| {
        for (row) |step| {
            m = @max(m, @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend));
        }
    }
    break :blk m;
};

// Rounded up to a power of two so activate()/apply() can index the ring
// with `& (ring.len - 1)` instead of `% ring.len`: ring.len is a runtime
// value (it depends on maxPrime, which varies per query), so the compiler
// can't fold a general modulo by it into the cheap constant-divisor tricks
// firstAdmissibleMultiple's fix relies on - it would stay a real division.
// Only ever grows the ring (ceilPowerOfTwo rounds up), never shrinks it
// below what the bound above requires, and each bucket's own capacity is
// still sized to its actual population in finalizeDiscovery - the extra
// slots this can add cost a few empty ArrayList structs, not real storage.
fn ringSizeFor(maxPrime: usize) usize {
    const maxSievingPrime = maxPrime / Comptimes.WHEEL_CIRCUMFERENCE;
    const maxAdvance = maxSievingPrime * MAX_WHEEL_STEP_FACTOR + MAX_WHEEL_STEP_FACTOR;
    const maxMultipleIndexWithinSegment = (SEGMENT_ELEMS - 1) + maxAdvance;
    const minRingLen = maxMultipleIndexWithinSegment / SEGMENT_ELEMS + 1;
    return std.math.ceilPowerOfTwoAssert(usize, minRingLen);
}

// Primes above LARGE_HUGE_THRESHOLD: even a single wheel step already
// exceeds a full segment, regardless of where within the segment the prime
// is currently positioned - see sieveLayoutMath.zig's largeHugeThreshold.
// So a huge sieving prime crosses off at most once per segment: no loop
// (a `while` would run 0 or 1 times, so an `if` suffices), and no benefit
// to batching several primes together the way largeSievePrimes.zig does to
// pipeline a loop's iterations - there is no loop to pipeline.
//
// Storage is a primesieve-EratBig-style ring buffer of buckets (`ring`),
// one per upcoming segment up to `ringSizeFor(maxPrime)` segments ahead -
// that bound holds for ANY tracked prime's single wheel step (see
// MAX_WHEEL_STEP_FACTOR/ringSizeFor above), so once a prime is filed into
// the ring, apply() only ever touches it on the exact segment it's due to
// fire in - no more scanning every tracked prime every segment regardless
// of whether it's actually ready (see project memory
// huge_tier_bucket_list_idea for the motivation/history).
//
// The one thing the ring can't hold is a prime whose first target is still
// arbitrarily far from bucketsStart: every SievePrime is already targeting
// its first admissible multiple >= the real requested start (see
// SievePrime.from and SegmentIterator's nested sieving-prime discovery) -
// firstAdmissibleMultiple(prime, start) lands within ringSizeFor()'s reach
// of bucketsStart whenever start > prime^2 (the gap from the ceil-division
// alone is < prime, plus at most one wheel step more - the same property
// that lets primesieve's Wheel::addSievingPrime file straight into
// EratBig's bucket list with no sort). But for a prime close to
// sqrt(limit), prime^2 can be >= start, so firstAdmissibleMultiple falls
// back to plain prime^2 - arbitrarily far from bucketsStart. `list`/
// `pendingStart` is the bridge for that thin band (primes with prime >
// sqrt(start)): such primes land there (kept sorted by currentBucketIndex
// - for this band that's just prime^2, and discovery proceeds in
// increasing prime order, so discovery order already gives that for free,
// no explicit sort ever needed), and activate() drains its front into the
// ring once a prime's position finally comes within ringSizeFor()'s reach
// of the segment being processed.
//
// add() itself doesn't decide ring-vs-pending though - see `staging` and
// finalizeDiscovery below for why that's deferred.
pub const HugeSievePrimes = struct {
    list: std.ArrayList(SievePrime),
    pendingStart: usize,

    ring: []std.ArrayList(SievePrime),
    ringHead: usize,

    // Discovery scratch: add() only ever appends here (via
    // appendAssumeCapacity - no capacity check, no possible realloc, unlike
    // growable `.append()`), deliberately deferring the ring-vs-pending
    // decision to finalizeDiscovery() once every prime up to maxPrime is
    // known. Sized once via Estimates.primeCountUpperBound(maxPrime) - a
    // proven upper bound on primes up to maxPrime, hence also a safe (if
    // slightly generous, since small/medium/large take a sliver of that
    // range too) bound on how many of them land in this tier specifically.
    // Freed by finalizeDiscovery, empty and unused after that.
    staging: std.ArrayList(SievePrime),

    pub fn init(allocator: std.mem.Allocator, maxPrime: usize) !HugeSievePrimes {
        const ring = try allocator.alloc(std.ArrayList(SievePrime), ringSizeFor(maxPrime));
        for (ring) |*bucket| bucket.* = .empty;

        return HugeSievePrimes{
            .list = try std.ArrayList(SievePrime).initCapacity(allocator, 0),
            .pendingStart = 0,
            .ring = ring,
            .ringHead = 0,
            .staging = try std.ArrayList(SievePrime).initCapacity(allocator, Estimates.primeCountUpperBound(maxPrime)),
        };
    }

    pub fn deinit(self: *HugeSievePrimes, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        self.staging.deinit(allocator);
        for (self.ring) |*bucket| bucket.deinit(allocator);
        allocator.free(self.ring);
    }

    /// Stages a freshly-discovered prime - see finalizeDiscovery for where
    /// it actually lands (ring vs. the thin pending overflow band).
    pub fn add(self: *HugeSievePrimes, sievePrime: SievePrime) void {
        self.staging.appendAssumeCapacity(sievePrime);
    }

    /// Called once, after every sieving prime up to maxPrime has been
    /// add()-ed: now that the exact population is known, counts how many
    /// land in each ring slot (or pending) and allocates each at exactly
    /// that capacity, so the actual placement pass can use
    /// appendAssumeCapacity instead of paying a capacity check (and
    /// possible realloc) on every one of what can be tens of millions of
    /// entries - same two-pass counting-sort idea the old (now-removed)
    /// reseedTo used, just run once at discovery time instead of again
    /// later. `bucketsStart` is the position ring[ringHead] (still 0,
    /// nothing has been applied yet) represents - the real query's first
    /// output segment, see SegmentIterator.init.
    pub fn finalizeDiscovery(self: *HugeSievePrimes, allocator: std.mem.Allocator, bucketsStart: usize) !void {
        const ringLen = self.ring.len;

        const counts = try allocator.alloc(usize, ringLen + 1); // counts[ringLen] == pending
        defer allocator.free(counts);
        @memset(counts, 0);

        for (self.staging.items) |sievePrime| {
            counts[destinationOf(sievePrime, ringLen, bucketsStart)] += 1;
        }

        for (self.ring, counts[0..ringLen]) |*bucket, count| {
            bucket.* = try std.ArrayList(SievePrime).initCapacity(allocator, count);
        }
        self.list = try std.ArrayList(SievePrime).initCapacity(allocator, counts[ringLen]);

        for (self.staging.items) |sievePrime| {
            place(self.ring, &self.list, sievePrime, ringLen, bucketsStart);
        }

        self.staging.deinit(allocator);
        self.staging = .empty;
        self.pendingStart = 0;
    }

    fn destinationOf(sievePrime: SievePrime, ringLen: usize, bucketsStart: usize) usize {
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
        return if (segmentsAhead < ringLen) segmentsAhead else ringLen;
    }

    fn place(
        ring: []std.ArrayList(SievePrime),
        pending: *std.ArrayList(SievePrime),
        sievePrime: SievePrime,
        ringLen: usize,
        bucketsStart: usize,
    ) void {
        const d = destinationOf(sievePrime, ringLen, bucketsStart);
        if (d < ringLen) {
            ring[d].appendAssumeCapacity(sievePrime);
        } else {
            pending.appendAssumeCapacity(sievePrime);
        }
    }

    /// Drains every pending (not yet in the ring) prime whose position has
    /// finally come within reach of the ring, into its correct bucket.
    /// `list` stays sorted by currentBucketIndex (see the struct
    /// docstring), so like the old activeCount scan this can stop at the
    /// first one still too far out - everything after it is too, and
    /// amortized cost over the whole sieve is O(1) per prime.
    pub noinline fn activate(self: *HugeSievePrimes, allocator: std.mem.Allocator, bucketsStart: usize) !void {
        while (self.pendingStart < self.list.items.len) {
            const sievePrime = self.list.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
            if (segmentsAhead >= self.ring.len) break;

            const slot = (self.ringHead + segmentsAhead) & (self.ring.len - 1);
            try self.ring[slot].append(allocator, sievePrime);
            self.pendingStart += 1;
        }
    }

    pub noinline fn apply(
        self: *HugeSievePrimes,
        allocator: std.mem.Allocator,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) !void {
        _ = bucketsEndExclusive; // every prime in this ring slot is already known to fire this exact segment.
        const current = &self.ring[self.ringHead];
        for (current.items) |*sievePrime| {
            const initialInBucketIndex = sievePrime.initialInBucketIndex;
            const wheelStepIndex = sievePrime.wheelStepIndex;
            const step = Comptimes.WHEEL_PATTERNS[initialInBucketIndex][wheelStepIndex];

            const localBucketIndex = sievePrime.currentBucketIndex - bucketsStart;
            buckets[localBucketIndex] &= step.bitMask;

            const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
            const advance = initialBucketIndex * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
            const newBucketIndex = localBucketIndex + advance + bucketsStart;
            sievePrime.currentBucketIndex = newBucketIndex;
            sievePrime.wheelStepIndex = wheelStepIndex +% 1;

            // segmentsAhead is always in [1, ring.len) here (huge tier
            // hits at most once per segment, and ringSizeFor bounds the
            // max single-step advance), so this slot is never `ringHead`
            // itself - safe to append while iterating `current.items`.
            const segmentsAhead = (newBucketIndex - bucketsStart) / SEGMENT_ELEMS;
            std.debug.assert(segmentsAhead >= 1 and segmentsAhead < self.ring.len);
            const slot = (self.ringHead + segmentsAhead) & (self.ring.len - 1);
            try self.ring[slot].append(allocator, sievePrime.*);
        }
        current.clearRetainingCapacity();
        self.ringHead = (self.ringHead + 1) & (self.ring.len - 1);
    }
};
