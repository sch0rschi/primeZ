const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
// Discovery-facing type (holds a full absolute bucket position). RingEntry
// below is the compact, ring/Block-resident encoding used everywhere else -
// see hugeSievePrimes.zig's own RingEntry for the identical argument, just
// wheel-30 (this tier's own stepping) instead of wheel-210.
const RingEntry = SievePrimeMod.PreHugeRingEntry;

const ringSizeFor = @import("hugeSievePrimes.zig").ringSizeFor;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;
const LARGE_HUGE_THRESHOLD: usize = BuildUtils.LARGE_HUGE_THRESHOLD;

const BLOCK_BYTES: usize = 8 * 1024;
const BLOCK_HEADER_BYTES: usize = @sizeOf([*]RingEntry) + @sizeOf(?*anyopaque);
const BLOCK_LEN: usize = (BLOCK_BYTES - BLOCK_HEADER_BYTES) / @sizeOf(RingEntry);
const BLOCK_PAD_BYTES: usize = BLOCK_BYTES - BLOCK_HEADER_BYTES - BLOCK_LEN * @sizeOf(RingEntry);
const BLOCK_ALIGNMENT = std.mem.Alignment.fromByteUnits(BLOCK_BYTES);

// Mirrors hugeSievePrimes.zig's own Block exactly (see that file for the
// full pointer-arithmetic rationale) - a separate type because this
// tier's ring stores wheel-30 RingEntry, not huge's wheel-210 one (they
// differ in wheelStepIndex width: u3 here, u6 there).
const Block = extern struct {
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

fn isFull(ptr: [*]RingEntry) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

fn blockOf(ptr: [*]RingEntry) *Block {
    var address = @intFromPtr(ptr);
    address -= 1;
    address -= address % BLOCK_BYTES;
    return @ptrFromInt(address);
}

// This tier's whole population, exactly (not just an upper bound) - both
// LARGE_HEAD_PRIME_COUNTS_BY_RESIDUE's endpoints (LARGE_HEAD_THRESHOLD,
// LARGE_HUGE_THRESHOLD) are build-time constants, so build.zig already
// ran a real sieve over this tier's whole range.
const TOTAL_POPULATION: usize = blk: {
    var total: usize = 0;
    for (BuildUtils.LARGE_HEAD_PRIME_COUNTS_BY_RESIDUE) |count| total += count;
    break :blk total;
};

// See hugeSievePrimes.zig's maxBlocksFor for the full derivation - same
// bound and same reasoning apply here (this tier's own apply() has the
// identical "redrain, refile-before-free" transient - see apply()'s own
// doc below).
fn maxBlocksFor(population: usize, ringLen: usize) usize {
    return ringLen + (population + BLOCK_LEN - 1) / BLOCK_LEN + 1;
}

// Primes above LARGE_HEAD_THRESHOLD, up to LARGE_HUGE_THRESHOLD: at most 2
// hits per segment worst case, 1 the overwhelming majority of the time -
// unlike huge, a single wheel step here does NOT always clear a whole
// segment, so an entry can occasionally need re-processing within the
// SAME segment it was just touched in.
//
// Ring-buffer design, structurally identical to HugeSievePrimes' own (see
// that file's struct doc) - the same Block-pool machinery, just keyed by
// wheel-30 RingEntry instead of wheel-210. The one real difference is
// apply() itself: since a hit can still be due again in the CURRENT
// segment (segmentsAhead == 0), draining ring slot `cursor` once is not
// enough - apply() wraps the drain in an outer loop that keeps
// redraining `cursor` until it's genuinely empty, exactly mirroring
// primesieve's own EratBig::crossOff(sieve) outer loop. This keeps
// processOne() itself just as simple and branch-free as huge's own -
// "might still be due this segment" is handled entirely by the outer
// loop noticing `ringWritePos[cursor]` is non-null again, never by
// looping or branching inside the per-entry hot path.
//
// This replaces two earlier, reverted attempts at giving this tier a
// ring (see the huge_tier_ringentry_shrink project memory) - both
// regressed because their per-step hot function became fallible (needed
// an allocator call to grow the ring). That obstacle is gone now:
// maxBlocksFor's proven bound (see hugeSievePrimes.zig) means
// storeSievingPrime/addBlock never allocate at runtime, so apply() can
// call them freely without ever making the hot path fallible.
pub const PreHugeSievePrimes = struct {
    list: std.ArrayList(SievePrime),
    pendingStart: usize,

    ringWritePos: []?[*]RingEntry,
    ringHead: usize,

    freeBlocks: ?*Block,
    blockPool: []align(BLOCK_BYTES) Block,
    nextUnclaimed: usize,

    pub fn init(allocator: std.mem.Allocator) !PreHugeSievePrimes {
        const ringLen = ringSizeFor(LARGE_HUGE_THRESHOLD);
        const ringWritePos = try allocator.alloc(?[*]RingEntry, ringLen);
        @memset(ringWritePos, null);

        const blockCount = maxBlocksFor(TOTAL_POPULATION, ringLen);
        const blockPool = try allocator.alignedAlloc(Block, BLOCK_ALIGNMENT, blockCount);

        return PreHugeSievePrimes{
            .list = try std.ArrayList(SievePrime).initCapacity(allocator, TOTAL_POPULATION),
            .pendingStart = 0,
            .ringWritePos = ringWritePos,
            .ringHead = 0,
            .freeBlocks = null,
            .blockPool = blockPool,
            .nextUnclaimed = 0,
        };
    }

    pub fn deinit(self: *PreHugeSievePrimes, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        allocator.free(self.ringWritePos);
        allocator.free(self.blockPool);
    }

    fn freeBlock(self: *PreHugeSievePrimes, b: *Block) void {
        b.next = self.freeBlocks;
        self.freeBlocks = b;
    }

    fn addBlock(self: *PreHugeSievePrimes, sealedWritePos: ?[*]RingEntry) [*]RingEntry {
        const fresh = if (self.freeBlocks) |fb| blk: {
            self.freeBlocks = fb.next;
            break :blk fb;
        } else blk: {
            std.debug.assert(self.nextUnclaimed < self.blockPool.len);
            const b = &self.blockPool[self.nextUnclaimed];
            self.nextUnclaimed += 1;
            break :blk b;
        };
        fresh.next = null;

        if (sealedWritePos) |wp| {
            const old = blockOf(wp);
            old.end = wp;
            fresh.next = old;
        }
        return fresh.items();
    }

    fn storeSievingPrime(self: *PreHugeSievePrimes, slot: usize, entry: *const RingEntry) void {
        const wp = self.ringWritePos[slot] orelse self.addBlock(null);
        wp[0] = entry.*;
        const next = wp + 1;
        self.ringWritePos[slot] = if (isFull(next)) self.addBlock(next) else next;
    }

    fn toRingEntry(sievePrime: SievePrime, bucketsStart: usize, segmentsAhead: usize) RingEntry {
        const localOffset = sievePrime.currentBucketIndex - bucketsStart - segmentsAhead * SEGMENT_ELEMS;
        return RingEntry{
            .localOffset = @intCast(localOffset),
            .initialBucketIndex = sievePrime.initialBucketIndex,
            .initialInBucketIndex = sievePrime.initialInBucketIndex,
            .wheelStepIndex = sievePrime.wheelStepIndex,
        };
    }

    /// `bucketsStart` must be the position ring[ringHead] currently
    /// represents - see HugeSievePrimes.add's identical argument.
    pub fn add(self: *PreHugeSievePrimes, sievePrime: SievePrime, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        const segmentsAhead = destinationOf(sievePrime, ringLen, bucketsStart);
        if (segmentsAhead < ringLen) {
            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead);
            self.storeSievingPrime(slot, &entry);
        } else {
            self.list.appendAssumeCapacity(sievePrime);
        }
    }

    fn destinationOf(sievePrime: SievePrime, ringLen: usize, bucketsStart: usize) usize {
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
        return if (segmentsAhead < ringLen) segmentsAhead else ringLen;
    }

    pub noinline fn activate(self: *PreHugeSievePrimes, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        while (self.pendingStart < self.list.items.len) {
            const sievePrime = self.list.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
            if (segmentsAhead >= ringLen) break;

            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead);
            self.storeSievingPrime(slot, &entry);
            self.pendingStart += 1;
        }
    }

    pub noinline fn apply(
        self: *PreHugeSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        _ = bucketsEndExclusive;
        _ = bucketsStart; // RingEntry.localOffset is already segment-relative.
        const ringLen = self.ringWritePos.len;
        const cursor = self.ringHead;

        // Outer redrain: unlike huge (a single wheel step always clears a
        // whole segment), a preHuge entry can still be due again in
        // THIS same segment (processOne returns segmentsAhead == 0),
        // landing it right back in slot `cursor`. Resetting
        // ringWritePos[cursor] to null BEFORE walking the detached chain
        // means such a refile lands in a fresh block, and this outer
        // while notices `cursor` is non-null again and redrains it -
        // exactly mirroring primesieve's EratBig::crossOff(sieve) outer
        // loop. processOne itself never needs to know or care whether
        // it's an entry's first, second, or third hit this segment.
        while (self.ringWritePos[cursor]) |wp| {
            const headBlock = blockOf(wp);
            headBlock.end = wp;
            self.ringWritePos[cursor] = null;

            var block: ?*Block = headBlock;
            while (block) |b| {
                const items = b.items();
                const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(RingEntry);

                for (items[0..fill]) |*entry| {
                    const result = processOne(buckets, entry.*);
                    std.debug.assert(result.segmentsAhead < ringLen);
                    const slot = (cursor + result.segmentsAhead) & (ringLen - 1);
                    self.storeSievingPrime(slot, &result.entry);
                }

                const next = b.next;
                self.freeBlock(b);
                block = next;
            }
        }

        self.ringHead = (cursor + 1) & (ringLen - 1);
    }
};

/// Crosses off one entry's current occurrence and advances it to the
/// next, returning the ADVANCED entry by value (not written back through
/// `entry`) plus how many segments ahead it now lands - 0 means still
/// due THIS segment (see apply()'s outer redrain loop for how that's
/// handled). Deliberately a single cross-off, no internal loop for a
/// possible second hit - unlike this tier's old HEAD/TAIL design, a
/// second hit is just another call to this same function, driven by
/// apply()'s outer loop. Takes `entry` BY VALUE, not `*RingEntry` - see
/// hugeSievePrimes.zig's own processOne for why (perf-confirmed: writing
/// the new fields back through the pointer, then having the caller
/// re-read `entry.*` to pass to storeSievingPrime, forced a genuine
/// store-then-reload the compiler couldn't optimize away, since the
/// intervening addBlock() call also touches the same Block pool).
inline fn processOne(buckets: Types.SIEVE_BUCKETS_TYPE, entry: RingEntry) struct { entry: RingEntry, segmentsAhead: usize } {
    const initialInBucketIndex = entry.initialInBucketIndex;
    const wheelStepIndex = entry.wheelStepIndex;
    const step = Comptimes.WHEEL_PATTERNS[initialInBucketIndex][wheelStepIndex];

    const localOffset: usize = entry.localOffset;
    buckets[localOffset] &= step.bitMask;

    const initialBucketIndex = @as(usize, entry.initialBucketIndex);
    const advance = initialBucketIndex * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
    const newOffset = localOffset + advance;
    const segmentsAhead = newOffset / SEGMENT_ELEMS;

    return .{
        .entry = RingEntry{
            .localOffset = @intCast(newOffset - segmentsAhead * SEGMENT_ELEMS),
            .initialBucketIndex = entry.initialBucketIndex,
            .initialInBucketIndex = initialInBucketIndex,
            // u3 over an 8-long cycle IS a power of two, so a wrapping
            // add is enough (unlike huge's wheel-210 tier, whose u6 over
            // a 48-long cycle needs an explicit wrap).
            .wheelStepIndex = wheelStepIndex +% 1,
        },
        .segmentsAhead = segmentsAhead,
    };
}
