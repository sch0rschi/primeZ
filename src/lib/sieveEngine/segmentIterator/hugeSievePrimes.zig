const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
// Discovery-facing type (holds a full absolute bucket position). RingEntry
// below is the compact, ring/Block-resident encoding used everywhere else.
const SievePrime = SievePrimeMod.HugeSievePrime;
const RingEntry = SievePrimeMod.HugeSievePrimeSlot;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;

// RingEntry.localOffset is a u23; SEGMENT_ELEMS must never exceed 2^23.
comptime {
    if (SEGMENT_ELEMS > 1 << 23) @compileError("SEGMENT_ELEMS exceeds RingEntry.localOffset's u23 budget - widen that field before raising this bound");
}

// Largest single-step advance (in buckets) any tracked prime can make.
const MAX_WHEEL_STEP_FACTOR: usize = blk: {
    var m: usize = 0;
    for (Comptimes.WHEEL_PATTERNS_210) |row| {
        for (row) |step| {
            m = @max(m, @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend));
        }
    }
    break :blk m;
};

// Rounded up to a power of two so the ring can be indexed with `&
// (ring.len - 1)` instead of a runtime `%`. Reused by LargeSievePrimes.
pub fn ringSizeFor(maxPrime: usize) usize {
    const maxSievingPrime = maxPrime / Comptimes.WHEEL_CIRCUMFERENCE;
    const maxAdvance = maxSievingPrime * MAX_WHEEL_STEP_FACTOR + MAX_WHEEL_STEP_FACTOR;
    const maxMultipleIndexWithinSegment = (SEGMENT_ELEMS - 1) + maxAdvance;
    const minRingLen = maxMultipleIndexWithinSegment / SEGMENT_ELEMS + 1;
    return std.math.ceilPowerOfTwoAssert(usize, minRingLen);
}

const BLOCK_BYTES: usize = 8 * 1024;
const BLOCK_HEADER_BYTES: usize = @sizeOf([*]RingEntry) + @sizeOf(?*anyopaque);
const BLOCK_LEN: usize = (BLOCK_BYTES - BLOCK_HEADER_BYTES) / @sizeOf(RingEntry);
const BLOCK_PAD_BYTES: usize = BLOCK_BYTES - BLOCK_HEADER_BYTES - BLOCK_LEN * @sizeOf(RingEntry);
const BLOCK_ALIGNMENT = std.mem.Alignment.fromByteUnits(BLOCK_BYTES);

// `extern struct`, not a plain struct: isFull/blockOf require `items` to
// be the LAST field, ending exactly on a BLOCK_BYTES boundary - a plain
// struct's field order isn't guaranteed, extern struct pins it.
const Block = extern struct {
    // One past the last valid entry - only meaningful once sealed (see
    // isFull's call sites); a still-filling block's real extent is the
    // live write cursor itself, not this field.
    end: [*]RingEntry,
    next: ?*Block,
    itemsBytes: [BLOCK_LEN * @sizeOf(RingEntry) + BLOCK_PAD_BYTES]u8 align(@alignOf(RingEntry)) = undefined,

    fn items(self: *Block) [*]RingEntry {
        return @ptrCast(&self.itemsBytes);
    }
};

comptime {
    if (@sizeOf(Block) != BLOCK_BYTES) @compileError("Block must be exactly BLOCK_BYTES for the pointer-arithmetic fullness/ownership tricks below to be valid");
    if (!std.math.isPowerOfTwo(BLOCK_BYTES)) @compileError("BLOCK_BYTES must be a power of two");
}

// True once a write cursor has stepped past its Block's last slot. Every
// Block is BLOCK_BYTES-aligned and exactly BLOCK_BYTES large, so this is
// pure pointer arithmetic, no dereference needed.
fn isFull(ptr: [*]RingEntry) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

// Recovers the Block a write cursor belongs to from its address alone.
// Subtracting 1 first is essential: a cursor that just advanced past a
// now-full Block sits exactly on the boundary of what looks like the
// NEXT Block's address.
fn blockOf(ptr: [*]RingEntry) *Block {
    var address = @intFromPtr(ptr);
    address -= 1;
    address -= address % BLOCK_BYTES;
    return @ptrFromInt(address);
}

const INITIAL_POOL_COUNT: usize = 64;
const MAX_POOL_COUNT: usize = 1 << 16;

// Above LARGE_HUGE_THRESHOLD a single wheel step already exceeds a full
// segment, so a huge sieving prime crosses off at most once per segment.
//
// Storage is a ring buffer of buckets, one per upcoming segment up to
// `ringSizeFor(maxPrime)` segments ahead - that bound holds for any
// tracked prime's single wheel step, so once filed into the ring, apply()
// only ever touches an entry on the exact segment it's due. Each ring
// slot is a singly-linked list of Block; `ringWritePos[i]` (the live
// write cursor) is enough to recover everything else on demand.
//
// Ring/Block storage uses RingEntry (a local offset within its eventual
// segment - see HugeSievePrimeSlot's own docstring), not SievePrime
// (which stores a full absolute position): which ring slot/Block an
// entry lives in already tells you its segment, so storing that again
// would be pure waste. `list`/`pendingStart` below still uses SievePrime,
// since a pending entry has no segment assignment yet.
//
// The ring can't hold a prime whose first target is still arbitrarily
// far from bucketsStart: `firstAdmissibleMultiple(prime, start)` lands
// within the ring's reach whenever start > prime^2, but for a prime close
// to sqrt(limit), prime^2 can be >= start, landing arbitrarily far away.
// `list`/`pendingStart` bridges that thin band (kept sorted by
// currentBucketIndex - discovery order already gives that for free);
// activate() drains its front into the ring once a prime's position
// comes within reach.
pub const HugeSievePrimes = struct {
    list: std.ArrayList(SievePrime),
    pendingStart: usize,

    // null means the slot has never been written to since it was last
    // drained. Everything else about a slot's block list is recovered on
    // demand from this cursor (see blockOf/isFull).
    ringWritePos: []?[*]RingEntry,
    ringHead: usize,

    // Blocks returned here once a ring slot is fully drained by apply(),
    // reused by future addBlock() calls instead of freeing/reallocating.
    freeBlocks: ?*Block,

    // Backs freeBlocks: allocated in bulk (BLOCK_BYTES-aligned slabs,
    // geometric growth) rather than one Block at a time - individual
    // small allocations scatter blocks across memory and were measured
    // as a severe regression.
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

        self.nextPoolCount = @min(count + count / 8, MAX_POOL_COUNT);
    }

    fn freeBlock(self: *HugeSievePrimes, b: *Block) void {
        b.next = self.freeBlocks;
        self.freeBlocks = b;
    }

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

    fn storeSievingPrime(self: *HugeSievePrimes, allocator: std.mem.Allocator, slot: usize, entry: *const RingEntry) !void {
        const wp = self.ringWritePos[slot] orelse try self.addBlock(allocator, null);
        wp[0] = entry.*;
        const next = wp + 1;
        self.ringWritePos[slot] = if (isFull(next)) try self.addBlock(allocator, next) else next;
    }

    fn toRingEntry(sievePrime: SievePrime, bucketsStart: usize, segmentsAhead: usize) RingEntry {
        const localOffset = sievePrime.currentBucketIndex - bucketsStart - segmentsAhead * SEGMENT_ELEMS;
        return RingEntry{
            .localOffset = @intCast(localOffset),
            .initialBucketIndex = sievePrime.initialBucketIndex,
            .initialInBucketIndex = sievePrime.initialInBucketIndex,
            .wheelStepIndex210 = sievePrime.wheelStepIndex210,
        };
    }

    /// `bucketsStart` must be the position ring[ringHead] currently
    /// represents (not necessarily the query's own first segment) -
    /// discoverSievingPrimes's self-bootstrapping sieve calls add()
    /// interleaved with its own activate()/apply(), which advance
    /// ringHead, so this can't assume ringHead is still 0.
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
        _ = bucketsEndExclusive;
        _ = bucketsStart; // RingEntry.localOffset is already segment-relative.
        const ringLen = self.ringWritePos.len;
        const cursor = self.ringHead;

        if (self.ringWritePos[cursor]) |wp| {
            const headBlock = blockOf(wp);
            headBlock.end = wp;

            var block: ?*Block = headBlock;
            while (block) |b| {
                const items = b.items();
                const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(RingEntry);

                for (items[0..fill]) |*entry| {
                    const segmentsAhead = processOne(buckets, entry);
                    // Never `cursor` itself: a huge prime advances at
                    // least one segment ahead, always < ringLen.
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

/// Crosses off one entry's current occurrence and advances it to the
/// next, returning how many segments ahead that lands.
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
    // u6 over a 48-long cycle isn't a power of two, so this needs an
    // explicit wrap (unlike the wheel-30 tiers' u3 +% 1).
    entry.wheelStepIndex210 = if (wheelStepIndex210 == Comptimes.ADMISSIBLE_RESIDUES_210.count - 1) 0 else wheelStepIndex210 + 1;

    return segmentsAhead;
}
