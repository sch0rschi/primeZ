const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
const RingEntry = SievePrimeMod.PreHugeRingEntry;

const ringSizeFor = @import("hugeSievePrimes.zig").ringSizeFor;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;
const LARGE_HUGE_THRESHOLD: usize = BuildUtils.LARGE_HUGE_THRESHOLD;

const BLOCK_BYTES: usize = 8 * 1024;
const BLOCK_HEADER_BYTES: usize = @sizeOf([*]RingEntry) + @sizeOf(?*anyopaque);
const BLOCK_LEN: usize = (BLOCK_BYTES - BLOCK_HEADER_BYTES) / @sizeOf(RingEntry);
const BLOCK_PAD_BYTES: usize = BLOCK_BYTES - BLOCK_HEADER_BYTES - BLOCK_LEN * @sizeOf(RingEntry);
const BLOCK_ALIGNMENT = std.mem.Alignment.fromByteUnits(BLOCK_BYTES);

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

const TOTAL_POPULATION: usize = blk: {
    var total: usize = 0;
    for (BuildUtils.LARGE_HEAD_PRIME_COUNTS_BY_RESIDUE) |count| total += count;
    break :blk total;
};

fn maxBlocksFor(population: usize, ringLen: usize) usize {
    return ringLen + (population + BLOCK_LEN - 1) / BLOCK_LEN + 1;
}

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
        _ = ringLen;
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const remaining = sievePrime.currentBucketIndex - bucketsStart;
        return remaining / SEGMENT_ELEMS;
    }

    pub noinline fn activate(self: *PreHugeSievePrimes, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        while (self.pendingStart < self.list.items.len) {
            const sievePrime = self.list.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const remaining = sievePrime.currentBucketIndex - bucketsStart;
            const segmentsAhead = remaining / SEGMENT_ELEMS;
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
        _ = bucketsStart;
        const ringLen = self.ringWritePos.len;
        const cursor = self.ringHead;

        if (self.ringWritePos[cursor]) |wp| {
            const headBlock = blockOf(wp);
            headBlock.end = wp;
            self.ringWritePos[cursor] = null;

            var block: ?*Block = headBlock;
            while (block) |b| {
                const items = b.items();
                const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(RingEntry);

                for (items[0..fill]) |*entry| {
                    const result1 = processOne(buckets, entry.*);
                    const final = if (result1.segmentsAhead == 0) blk: {
                        const result2 = processOne(buckets, result1.entry);
                        std.debug.assert(result2.segmentsAhead >= 1);
                        break :blk result2;
                    } else result1;
                    std.debug.assert(final.segmentsAhead >= 1 and final.segmentsAhead < ringLen);
                    const slot = (cursor + final.segmentsAhead) & (ringLen - 1);
                    self.storeSievingPrime(slot, &final.entry);
                }

                const next = b.next;
                self.freeBlock(b);
                block = next;
            }
        }

        self.ringHead = (cursor + 1) & (ringLen - 1);
    }
};

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
            .localOffset = @intCast(newOffset % SEGMENT_ELEMS),
            .initialBucketIndex = entry.initialBucketIndex,
            .initialInBucketIndex = initialInBucketIndex,
            .wheelStepIndex = wheelStepIndex +% 1,
        },
        .segmentsAhead = segmentsAhead,
    };
}
