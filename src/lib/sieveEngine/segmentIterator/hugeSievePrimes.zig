const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
// Huge tier uses its own record type (wheel-210 stepping, a wider 48-phase
// step index) rather than the shared wheel-30 SievePrime - see
// HugeSievePrime's own docstring. Kept as a local alias `SievePrime` so
// the ring/block plumbing below (written generically against "SievePrime")
// doesn't need touching.
const SievePrime = SievePrimeMod.HugeSievePrime;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;

// The largest single-step advance any tracked prime can ever make, in
// buckets: WHEEL_PATTERNS' own worst-case divMultiplicator/residueAddend,
// applied to the largest prime this tier will ever hold (see ringSize
// below) - mirrors primesieve's EratBig::init exactly (maxSievingPrime *
// maxFactor + maxFactor), just derived from our own comptime wheel table
// instead of a hardcoded constant.
const MAX_WHEEL_STEP_FACTOR: usize = blk: {
    var m: usize = 0;
    for (Comptimes.WHEEL_PATTERNS_210) |row| {
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
// below what the bound above requires - the extra slots this can add cost a
// few empty write-cursor entries, not real storage (see Block below).
// pub: reused by LargeSievePrimes for its own ring, sized against
// LARGE_HUGE_THRESHOLD instead of a query's rootPrime - the same math
// applies to any tier tracking primes up to some maxPrime bound (see its
// own docstring for why).
pub fn ringSizeFor(maxPrime: usize) usize {
    const maxSievingPrime = maxPrime / Comptimes.WHEEL_CIRCUMFERENCE;
    const maxAdvance = maxSievingPrime * MAX_WHEEL_STEP_FACTOR + MAX_WHEEL_STEP_FACTOR;
    const maxMultipleIndexWithinSegment = (SEGMENT_ELEMS - 1) + maxAdvance;
    const minRingLen = maxMultipleIndexWithinSegment / SEGMENT_ELEMS + 1;
    return std.math.ceilPowerOfTwoAssert(usize, minRingLen);
}

// Fixed-capacity, singly-linked block of sieving primes, laid out and
// managed to match primesieve's own Bucket/MemoryPool design exactly (see
// bench/primesieve/include/primesieve/Bucket.hpp and
// bench/primesieve/src/MemoryPool.cpp) rather than just its general shape:
//
// 2026-09-10, three iterations to get here (see project memory
// huge_tier_bucket_list_idea for the full history):
//   1. A first Block design (an explicit `len: usize` field, checked before
//      every write) replaced the old `staging`-scratch-buffer design and
//      cut peak memory ~44% (eliminating a redundant full copy - see
//      `end`'s docstring below for what that copy was), but *regressed*
//      wall-clock ~30-45%: `perf stat` showed branches executed up ~53%,
//      because every append now needed a real "is there room" check that
//      the old design's precomputed-capacity appendAssumeCapacity never
///     paid.
//   2. Moving that fill count out of Block and into a small, hot,
//      ring-indexed array (ringTailLen) avoided dereferencing the (large,
//      likely-cold) Block just to check it, cutting appendToBlockList's
//      self-time roughly in half - but still didn't close the gap.
//   3. This version: no length field anywhere (on Block or in a side
//      array). Every ring slot instead tracks one raw write-cursor pointer
//      (see HugeSievePrimes.ringWritePos). Block is sized to exactly
//      BLOCK_BYTES (a power of 2) and every Block is allocated
///     BLOCK_BYTES-aligned (see allocateBlockPool), so "is the block this
//      cursor points into full" is answered by pure pointer arithmetic on
//      the cursor itself (isFull - a single AND against a comptime mask,
//      no memory access at all), and "which block does this cursor belong
//      to" likewise (blockOf - round the address down to the nearest
//      BLOCK_BYTES boundary, primesieve's Bucket::get). A block's own
//      valid extent (`end`) is written to exactly once, at the moment the
//      block stops being the live write target (isFull fires, or the ring
//      slot is drained mid-fill by apply()) - never touched on every
//      append the way the length field was in the first two iterations.
const BLOCK_BYTES: usize = 8 * 1024; // matches primesieve's own config::BUCKET_BYTES
const BLOCK_HEADER_BYTES: usize = @sizeOf([*]SievePrime) + @sizeOf(?*anyopaque); // end + next
const BLOCK_LEN: usize = (BLOCK_BYTES - BLOCK_HEADER_BYTES) / @sizeOf(SievePrime);
const BLOCK_PAD_BYTES: usize = BLOCK_BYTES - BLOCK_HEADER_BYTES - BLOCK_LEN * @sizeOf(SievePrime);
const BLOCK_ALIGNMENT = std.mem.Alignment.fromByteUnits(BLOCK_BYTES);

// `extern struct`, not a plain struct: the isFull/blockOf arithmetic below
// depends on `items` being the LAST field, ending exactly at the block's
// own BLOCK_BYTES boundary (so "one past the last item" lands exactly on
// a BLOCK_BYTES-aligned address, and nowhere else) - a plain struct's
// layout is NOT guaranteed to preserve declaration order (the compiler is
// free to reorder fields, e.g. grouping same-alignment fields together),
// which silently breaks that assumption. `extern struct` pins the layout
// to C-ABI rules (declaration order, predictable padding), which is what
// this design actually requires. Caught by the correctness sweep (a
// straddle-scale test case at N=2e13), not the plain test suite - see
// project memory huge_tier_bucket_list_idea.
const Block = extern struct {
    // One past the last valid entry in `items()` - set exactly once, when
    // this block stops being a live write target (see isFull's call
    // sites). Meaningless/stale for a block still being written to (its
    // fullness is instead derived on demand from the live write-cursor
    // itself, never stored here until sealing).
    end: [*]SievePrime,
    next: ?*Block,
    // Raw bytes, not `[BLOCK_LEN]SievePrime` directly: SievePrime is a
    // packed struct whose bit width (102 bits) isn't a size extern structs
    // can embed as an array element (Zig rejects it - "unspecified
    // signedness" - since there's no C-ABI-standard integer that width).
    // Reinterpreted through items() instead; explicitly aligned to match
    // SievePrime's own (16, from its 128-bit packed-struct backing integer)
    // since a plain byte array's alignment wouldn't otherwise be enough for
    // that cast.
    itemsBytes: [BLOCK_LEN * @sizeOf(SievePrime) + BLOCK_PAD_BYTES]u8 align(@alignOf(SievePrime)) = undefined,

    fn items(self: *Block) [*]SievePrime {
        return @ptrCast(&self.itemsBytes);
    }
};

comptime {
    if (@sizeOf(Block) != BLOCK_BYTES) @compileError("Block must be exactly BLOCK_BYTES for the pointer-arithmetic fullness/ownership tricks below to be valid");
    if (!std.math.isPowerOfTwo(BLOCK_BYTES)) @compileError("BLOCK_BYTES must be a power of two");
}

// True once `ptr` (always a just-advanced write cursor, one past the entry
// it just wrote) has stepped past the last slot of whichever Block it was
// writing into - i.e. that Block is now full. Pure arithmetic on a pointer
// already held in a register - no dereference, unlike checking a stored
// length field would require. Mirrors primesieve's Bucket::isFull exactly:
// every Block is BLOCK_BYTES-aligned (see allocateBlockPool) and exactly
// BLOCK_BYTES large, so a write cursor lands exactly on a BLOCK_BYTES
// boundary if and only if it has walked off the end of its block.
fn isFull(ptr: [*]SievePrime) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

// Recovers the Block a write cursor belongs to, purely from the cursor's
// own address - mirrors primesieve's Bucket::get. Subtracting 1 before
// rounding down is essential: a cursor that has just advanced past the
// final slot of a now-full Block sits exactly on the boundary of what
// looks like the *next* Block's address - rounding that down naively would
// misidentify the (unrelated, possibly not-yet-allocated) next Block
// instead of the one that was actually just written to.
fn blockOf(ptr: [*]SievePrime) *Block {
    var address = @intFromPtr(ptr);
    address -= 1;
    address -= address % BLOCK_BYTES;
    return @ptrFromInt(address);
}

// Bulk-allocation sizing for the block pool (see poolChunks) - same
// reasoning as primesieve's MemoryPool::updateAllocCount: start modest,
// grow geometrically, cap so one allocation can't run away with an
// unreasonable amount of memory.
const INITIAL_POOL_COUNT: usize = 64;
const MAX_POOL_COUNT: usize = 1 << 16;

// Primes above LARGE_HUGE_THRESHOLD: even a single wheel step already
// exceeds a full segment, regardless of where within the segment the prime
// is currently positioned - see sieveLayoutMath.zig's largeHugeThreshold.
// So a huge sieving prime crosses off at most once per segment: no loop
// (a `while` would run 0 or 1 times, so an `if` suffices), and no benefit
// to batching several primes together the way largeSievePrimes.zig does to
// pipeline a loop's iterations - there is no loop to pipeline.
//
// Storage is a primesieve-EratBig-style ring buffer of buckets, one per
// upcoming segment up to `ringSizeFor(maxPrime)` segments ahead - that
// bound holds for ANY tracked prime's single wheel step (see
// MAX_WHEEL_STEP_FACTOR/ringSizeFor above), so once a prime is filed into
// the ring, apply() only ever touches it on the exact segment it's due to
// fire in - no more scanning every tracked prime every segment regardless
// of whether it's actually ready (see project memory
// huge_tier_bucket_list_idea for the motivation/history). Each ring slot
// is a singly-linked list of Block (see Block's own docstring), but unlike
// a normal linked list, nothing here stores an explicit head/tail pair -
// `ringWritePos[i]` (the live write cursor) is enough to recover
// everything else on demand (see Block's docstring, blockOf, isFull).
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
// of the segment being processed. Unlike the ring, `list` stays a plain
// growable ArrayList - it's proven to stay a thin band (see above), so it
// never needed the Block treatment.
pub const HugeSievePrimes = struct {
    list: std.ArrayList(SievePrime),
    pendingStart: usize,

    // The live write cursor for each ring slot - null means the slot has
    // never been written to since it was last drained (or since init).
    // Everything else about a slot's block list (which Block a cursor
    // belongs to, whether that Block is full, where an earlier, already-
    // sealed Block's valid data ends) is recovered on demand rather than
    // tracked separately - see Block's own docstring for why that matters.
    ringWritePos: []?[*]SievePrime,
    ringHead: usize,

    // Blocks returned here once a ring slot is fully drained by apply()
    // (see freeBlock) - reused by future addBlock() calls instead of
    // freeing and reallocating, and shared across every slot (not just the
    // one that freed them), so memory keeps circulating as the ring wraps
    // around over the course of a long query.
    freeBlocks: ?*Block,

    // Backs freeBlocks: allocating one Block at a time (allocator.create
    // per block) measured as a severe regression (~2x wall-clock) versus
    // the old design it replaced - individual small allocations are slow
    // and scatter blocks across memory, turning apply()'s block-list walk
    // into cache-unfriendly pointer chasing. Fixed by pooling: allocate
    // many Blocks in one bulk, BLOCK_BYTES-aligned allocation (geometrically
    // growing, mirroring primesieve's own MemoryPool - see
    // bench/primesieve/src/MemoryPool.cpp) and link them into freeBlocks up
    // front, so most addBlock() calls cost nothing beyond a pointer bump,
    // and blocks drawn from the same slab stay spatially close. Each slab
    // is tracked here only so deinit can free them; nothing else ever
    // looks a chunk up by index.
    poolChunks: std.ArrayList([]align(BLOCK_BYTES) Block),
    nextPoolCount: usize,

    pub fn init(allocator: std.mem.Allocator, maxPrime: usize) !HugeSievePrimes {
        const ringLen = ringSizeFor(maxPrime);
        const ringWritePos = try allocator.alloc(?[*]SievePrime, ringLen);
        @memset(ringWritePos, null);

        return HugeSievePrimes{
            .list = try std.ArrayList(SievePrime).initCapacity(allocator, 0),
            .pendingStart = 0,
            .ringWritePos = ringWritePos,
            .ringHead = 0,
            .freeBlocks = null,
            .poolChunks = try std.ArrayList([]align(BLOCK_BYTES) Block).initCapacity(allocator, 0),
            .nextPoolCount = INITIAL_POOL_COUNT,
        };
    }

    pub fn deinit(self: *HugeSievePrimes, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        allocator.free(self.ringWritePos);
        for (self.poolChunks.items) |slab| allocator.free(slab);
        self.poolChunks.deinit(allocator);
    }

    fn allocateBlockPool(self: *HugeSievePrimes, allocator: std.mem.Allocator) !void {
        const count = self.nextPoolCount;
        const slab = try allocator.alignedAlloc(Block, BLOCK_ALIGNMENT, count);
        try self.poolChunks.append(allocator, slab);

        for (slab[0 .. count - 1], 0..) |*b, i| {
            b.next = &slab[i + 1];
        }
        slab[count - 1].next = null;
        self.freeBlocks = &slab[0];

        // Geometric growth (+12.5%), matching primesieve's own MemoryPool -
        // fewer, bigger allocations over a long query without permanently
        // committing to a huge chunk size from the very first allocation.
        self.nextPoolCount = @min(count + count / 8, MAX_POOL_COUNT);
    }

    fn freeBlock(self: *HugeSievePrimes, b: *Block) void {
        b.next = self.freeBlocks;
        self.freeBlocks = b;
    }

    /// Draws a fresh block from the pool, and - if `sealedWritePos` is
    /// given - seals off the block it belongs to (recording where its
    /// valid data ends, for apply()'s later read) and links the fresh
    /// block in front of it. Mirrors primesieve's MemoryPool::addBucket.
    fn addBlock(self: *HugeSievePrimes, allocator: std.mem.Allocator, sealedWritePos: ?[*]SievePrime) ![*]SievePrime {
        if (self.freeBlocks == null) try self.allocateBlockPool(allocator);
        const fresh = self.freeBlocks.?;
        self.freeBlocks = fresh.next;
        fresh.next = null;

        if (sealedWritePos) |wp| {
            const old = blockOf(wp);
            old.end = wp;
            fresh.next = old;
        }
        return fresh.items();
    }

    /// Writes one entry into a ring slot's live block, advancing (and, if
    /// the block just filled up, reseating) its write cursor - the only
    /// operation add()/activate()/apply() ever need to place an entry.
    /// Mirrors primesieve's `buckets_[segment]++->set(...); if
    /// (Bucket::isFull(...)) addBucket(...)`.
    fn storeSievingPrime(self: *HugeSievePrimes, allocator: std.mem.Allocator, slot: usize, sievePrime: *const SievePrime) !void {
        const wp = self.ringWritePos[slot] orelse try self.addBlock(allocator, null);
        wp[0] = sievePrime.*;
        const next = wp + 1;
        self.ringWritePos[slot] = if (isFull(next)) try self.addBlock(allocator, next) else next;
    }

    /// Places a freshly-discovered prime directly into its final position -
    /// the ring slot for its computed target (see destinationOf), or the
    /// pending overflow band if that target is still out of the ring's
    /// reach (see the struct docstring). No staging/finalizeDiscovery two-
    /// pass step: this happens immediately, one prime at a time, as each
    /// is discovered - safe because a block-list never needs to know a
    /// slot's eventual population upfront.
    ///
    /// `bucketsStart` must be the position ring[ringHead] (the CURRENT
    /// front of the ring, not necessarily the query's own first segment)
    /// represents at the moment of this call - same convention activate()
    /// already uses. For the top-level query's own huge tier this is
    /// always the query's first segment, because ringHead never advances
    /// (apply() never runs) until discovery is fully done - but
    /// discoverSievingPrimes's self-bootstrapping [0, rootPrime] sieve
    /// calls add() *interleaved* with its own activate()/apply() calls
    /// (which do advance ringHead as that sieve's own segments progress),
    /// so the slot computation must track ringHead's current value rather
    /// than assume it's still 0 - a real bug an earlier version of this
    /// function had (it used destinationOf's result directly as the slot,
    /// silently correct only while ringHead happened to still be 0).
    pub fn add(self: *HugeSievePrimes, allocator: std.mem.Allocator, sievePrime: SievePrime, bucketsStart: usize) !void {
        const ringLen = self.ringWritePos.len;
        const segmentsAhead = destinationOf(sievePrime, ringLen, bucketsStart);
        if (segmentsAhead < ringLen) {
            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            try self.storeSievingPrime(allocator, slot, &sievePrime);
        } else {
            try self.list.append(allocator, sievePrime);
        }
    }

    fn destinationOf(sievePrime: SievePrime, ringLen: usize, bucketsStart: usize) usize {
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
        return if (segmentsAhead < ringLen) segmentsAhead else ringLen;
    }

    /// Drains every pending (not yet in the ring) prime whose position has
    /// finally come within reach of the ring, into its correct bucket.
    /// `list` stays sorted by currentBucketIndex (see the struct
    /// docstring), so like the old activeCount scan this can stop at the
    /// first one still too far out - everything after it is too, and
    /// amortized cost over the whole sieve is O(1) per prime.
    pub noinline fn activate(self: *HugeSievePrimes, allocator: std.mem.Allocator, bucketsStart: usize) !void {
        const ringLen = self.ringWritePos.len;
        while (self.pendingStart < self.list.items.len) {
            const sievePrime = self.list.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
            if (segmentsAhead >= ringLen) break;

            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            try self.storeSievingPrime(allocator, slot, &sievePrime);
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
        const ringLen = self.ringWritePos.len;
        const cursor = self.ringHead;

        if (self.ringWritePos[cursor]) |wp| {
            // Seal the slot's current (still-live) block so its valid
            // extent is on record exactly like every earlier, already-full
            // block in the chain - see Block's own docstring.
            const headBlock = blockOf(wp);
            headBlock.end = wp;

            var block: ?*Block = headBlock;
            while (block) |b| {
                const items = b.items();
                const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(SievePrime);
                for (items[0..fill]) |*sievePrime| {
                    const initialInBucketIndex = sievePrime.initialInBucketIndex;
                    const wheelStepIndex210 = sievePrime.wheelStepIndex210;
                    const step = Comptimes.WHEEL_PATTERNS_210[initialInBucketIndex][wheelStepIndex210];

                    const localBucketIndex = sievePrime.currentBucketIndex - bucketsStart;
                    buckets[localBucketIndex] &= step.bitMask;

                    const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
                    const advance = initialBucketIndex * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                    const newBucketIndex = localBucketIndex + advance + bucketsStart;
                    sievePrime.currentBucketIndex = newBucketIndex;
                    // u6 field over a 48-long cycle: not a power of two,
                    // so (unlike the wheel-30 tiers' u3 +% 1, which wraps
                    // at 8 for free) this needs an explicit wrap.
                    sievePrime.wheelStepIndex210 = if (wheelStepIndex210 == Comptimes.ADMISSIBLE_RESIDUES_210.count - 1) 0 else wheelStepIndex210 + 1;

                    // segmentsAhead is always in [1, ringLen) here (huge
                    // tier hits at most once per segment, and ringSizeFor
                    // bounds the max single-step advance), so this slot is
                    // never `cursor` itself - safe to append into it while
                    // iterating cursor's own block list.
                    const segmentsAhead = (newBucketIndex - bucketsStart) / SEGMENT_ELEMS;
                    std.debug.assert(segmentsAhead >= 1 and segmentsAhead < ringLen);
                    const slot = (cursor + segmentsAhead) & (ringLen - 1);
                    try self.storeSievingPrime(allocator, slot, sievePrime);
                }
                const next = b.next;
                self.freeBlock(b);
                block = next;
            }
            self.ringWritePos[cursor] = null;
        }

        self.ringHead = (cursor + 1) & (ringLen - 1);
    }
};
