const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
// Huge tier uses its own record type (wheel-210 stepping, a wider 48-phase
// step index) rather than the shared wheel-30 SievePrime - see
// HugeSievePrime's own docstring. Kept as a local alias `SievePrime` so
// the discovery-facing API (add()'s parameter, `list`'s element type)
// doesn't need touching.
const SievePrime = SievePrimeMod.HugeSievePrime;
// Ring/Block-resident encoding (localOffset instead of a full absolute
// position) - see its own docstring in sievePrime.zig and this file's own
// struct docstring below for why storage uses this, not SievePrime,
// everywhere except `list`.
const RingEntry = SievePrimeMod.HugeSievePrimeSlot;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;

// RingEntry.localOffset is a u23 - safe only as long as SEGMENT_ELEMS
// never exceeds 2^23 (see that field's own docstring for the derivation).
// build.zig's floorPow2Clamped already caps opt_segment_size_in_kb at
// 8192 KiB (SEGMENT_ELEMS <= 2^23) today, but that cap lives in a
// different file with no compile-time link to this one - this assertion
// is the tripwire if it's ever loosened without updating this field width
// too, catching it at compile time instead of a silent, catastrophic
// wraparound in release builds.
comptime {
    if (SEGMENT_ELEMS > 1 << 23) @compileError("SEGMENT_ELEMS exceeds RingEntry.localOffset's u23 budget - widen that field before raising this bound");
}

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
const BLOCK_HEADER_BYTES: usize = @sizeOf([*]RingEntry) + @sizeOf(?*anyopaque); // end + next
const BLOCK_LEN: usize = (BLOCK_BYTES - BLOCK_HEADER_BYTES) / @sizeOf(RingEntry);
const BLOCK_PAD_BYTES: usize = BLOCK_BYTES - BLOCK_HEADER_BYTES - BLOCK_LEN * @sizeOf(RingEntry);
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
    end: [*]RingEntry,
    next: ?*Block,
    // Raw bytes, not `[BLOCK_LEN]RingEntry` directly: RingEntry is a
    // packed struct whose bit width (64 bits) IS a size extern structs can
    // embed directly, but keeping the same raw-bytes-plus-items()-cast
    // shape as before (rather than special-casing this one) costs nothing
    // and stays consistent if a future field addition ever pushes it back
    // off a byte boundary. Explicitly aligned to match RingEntry's own (8,
    // from its 64-bit packed-struct backing integer) since a plain byte
    // array's alignment wouldn't otherwise be enough for that cast.
    itemsBytes: [BLOCK_LEN * @sizeOf(RingEntry) + BLOCK_PAD_BYTES]u8 align(@alignOf(RingEntry)) = undefined,

    fn items(self: *Block) [*]RingEntry {
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
fn isFull(ptr: [*]RingEntry) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

// Recovers the Block a write cursor belongs to, purely from the cursor's
// own address - mirrors primesieve's Bucket::get. Subtracting 1 before
// rounding down is essential: a cursor that has just advanced past the
// final slot of a now-full Block sits exactly on the boundary of what
// looks like the *next* Block's address - rounding that down naively would
// misidentify the (unrelated, possibly not-yet-allocated) next Block
// instead of the one that was actually just written to.
fn blockOf(ptr: [*]RingEntry) *Block {
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
// pipeline a loop's iterations - there is no loop to pipeline. Tried
// pairing 2 entries per apply() iteration anyway (primesieve's own
// EratBig::crossOff does exactly this, "to increase instruction level
// parallelism") - measured no real win, see apply()'s own comment for the
// numbers; reverted.
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
// 2026-09-14: Block/ring storage uses RingEntry (sievePrime.zig's
// HugeSievePrimeSlot), not SievePrime itself - found by comparing directly
// against primesieve's own EratBig/SievingPrime (Bucket.hpp) after a user
// question about a wide-window benchmark gap: their SievingPrime is 8
// bytes (two plain u32 words), ours was 16 (a packed struct whose
// currentBucketIndex stores a full 64-bit ABSOLUTE position). The
// realization: exactly like primesieve, which ring slot/Block an entry
// lives in already tells you which segment it's due in - so storing that
// again, as an absolute position, inside the entry itself is pure waste
// for anything already placed in the ring. RingEntry stores only the
// LOCAL offset within its eventual segment instead (u23, safely covers any
// buildable SEGMENT_ELEMS - see this file's own comptime assertion),
// shrinking the ring-resident record to 64 bits exactly - one native word,
// matching primesieve's size precisely. SievePrime itself (the wide,
// absolute-position type) is unchanged and still used for the discovery-
// time API surface and `list` (the pending overflow band below - its
// entries have no segment assignment yet, so still need the full
// position); toRingEntry() converts to RingEntry at the one point a
// segment assignment (and thus a ring slot) becomes known, in add() and
// activate(). See project memory large_tier_head_batch_split (or a
// successor memory covering this specific investigation) for the
// before/after comparison against primesieve.
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
    ringWritePos: []?[*]RingEntry,
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
        const ringWritePos = try allocator.alloc(?[*]RingEntry, ringLen);
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
    fn addBlock(self: *HugeSievePrimes, allocator: std.mem.Allocator, sealedWritePos: ?[*]RingEntry) ![*]RingEntry {
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
    fn storeSievingPrime(self: *HugeSievePrimes, allocator: std.mem.Allocator, slot: usize, entry: *const RingEntry) !void {
        const wp = self.ringWritePos[slot] orelse try self.addBlock(allocator, null);
        wp[0] = entry.*;
        const next = wp + 1;
        self.ringWritePos[slot] = if (isFull(next)) try self.addBlock(allocator, next) else next;
    }

    /// Converts an already-placed (segment assignment known) sievePrime
    /// into its ring/Block-resident encoding - see RingEntry's own
    /// docstring. `segmentsAhead` is always the caller's already-computed
    /// `(sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS`
    /// (destinationOf's result, or activate()'s equivalent inline
    /// computation) - passed in rather than recomputed, since every call
    /// site already has it on hand from deciding which ring slot to use.
    fn toRingEntry(sievePrime: SievePrime, bucketsStart: usize, segmentsAhead: usize) RingEntry {
        const localOffset = sievePrime.currentBucketIndex - bucketsStart - segmentsAhead * SEGMENT_ELEMS;
        return RingEntry{
            .localOffset = @intCast(localOffset),
            .initialBucketIndex = sievePrime.initialBucketIndex,
            .initialInBucketIndex = sievePrime.initialInBucketIndex,
            .wheelStepIndex210 = sievePrime.wheelStepIndex210,
        };
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
            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead);
            try self.storeSievingPrime(allocator, slot, &entry);
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
            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead);
            try self.storeSievingPrime(allocator, slot, &entry);
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
        // RingEntry.localOffset already IS the position within THIS
        // segment - unlike the old absolute-position encoding, nothing
        // here ever needs bucketsStart (see RingEntry's own docstring and
        // toRingEntry): buckets[] is indexed directly, and the next
        // segment assignment falls out of localOffset+advance divided by
        // SEGMENT_ELEMS, exactly mirroring primesieve's own EratBig::crossOff
        // (`segment = multipleIndex >> log2SieveSize; multipleIndex &=
        // moduloSieveSize;`).
        _ = bucketsStart;
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
                const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(RingEntry);

                // 2026-09-14: tried pairing 2 entries per iteration here
                // (mirroring primesieve's own EratBig::crossOff, "Process
                // 2 sieving primes per loop iteration to increase
                // instruction level parallelism") after comparing directly
                // against primesieve's source. Measured flat-to-very-
                // slightly-worse (perf: HugeSievePrimes.apply's self-time
                // share and absolute cycle count both ~unchanged, within
                // noise; 5-rep wall-clock min unchanged) at the same 1e19/
                // 4.4B-wide-window benchmark this session's other huge-tier
                // change (RingEntry - see this file's own struct
                // docstring) measured a real ~28% win on. Reverted the
                // pairing; kept the single-entry extraction (processOne)
                // below since it's equivalent, cleaner code either way.
                // Consistent with a prior finding in this project's history
                // (project memory huge_tier_bucket_list_idea's "radical
                // mode" round): this CPU's out-of-order execution already
                // extracts good ILP from primeZ's serial per-entry loops
                // without an explicit batching hint, unlike primesieve's
                // apparent target hardware - don't re-attempt this specific
                // idea without new evidence the loop is actually ILP-
                // starved here.
                for (items[0..fill]) |*entry| {
                    const segmentsAhead = processOne(buckets, entry);
                    // segmentsAhead is always in [1, ringLen) here (huge
                    // tier hits at most once per segment, and ringSizeFor
                    // bounds the max single-step advance), so this slot is
                    // never `cursor` itself - safe to append into it while
                    // iterating cursor's own block list.
                    std.debug.assert(segmentsAhead >= 1 and segmentsAhead < ringLen);
                    const slot = (cursor + segmentsAhead) & (ringLen - 1);
                    try self.storeSievingPrime(allocator, slot, entry);
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

/// Crosses off one entry's current occurrence and advances it to its next
/// one (localOffset + wheelStepIndex210), returning how many segments
/// ahead that next occurrence falls - the caller still owns placing it
/// into the right ring slot (see apply()'s two call sites: a batched pair
/// and a single leftover). Split out so apply()'s paired loop can call it
/// twice back to back with no data dependency between the two calls,
/// rather than duplicating this body by hand the way primesieve's own
/// crossOff does - `inline` makes the two calls flatten into the same
/// straight-line shape either way.
inline fn processOne(buckets: Types.SIEVE_BUCKETS_TYPE, entry: *RingEntry) usize {
    const initialInBucketIndex = entry.initialInBucketIndex;
    const wheelStepIndex210 = entry.wheelStepIndex210;
    const step = Comptimes.WHEEL_PATTERNS_210[initialInBucketIndex][wheelStepIndex210];

    const localOffset: usize = entry.localOffset;
    buckets[localOffset] &= step.bitMask;

    const initialBucketIndex = @as(usize, entry.initialBucketIndex);
    const advance = initialBucketIndex * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
    const newOffset = localOffset + advance;
    const segmentsAhead = newOffset / SEGMENT_ELEMS;

    entry.localOffset = @intCast(newOffset - segmentsAhead * SEGMENT_ELEMS);
    // u6 field over a 48-long cycle: not a power of two, so (unlike the
    // wheel-30 tiers' u3 +% 1, which wraps at 8 for free) this needs an
    // explicit wrap.
    entry.wheelStepIndex210 = if (wheelStepIndex210 == Comptimes.ADMISSIBLE_RESIDUES_210.count - 1) 0 else wheelStepIndex210 + 1;

    return segmentsAhead;
}
