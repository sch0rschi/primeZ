const std = @import("std");
const Types = @import("../types.zig");
const LayoutMod = @import("../layout.zig");
const Layout = LayoutMod.Layout;
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.LargeSievePrime;
const RingEntry = SievePrimeMod.LargeSievePrimeSlot;

const LargeSievePrimesMod = @import("largeSievePrimes.zig");
const ringSizeFor = LargeSievePrimesMod.ringSizeFor;
const toRingEntry = LargeSievePrimesMod.LargeSievePrimes.toRingEntry;
const processOne = LargeSievePrimesMod.processOne;

const BLOCK_BYTES: usize = 16 * 1024;
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

fn maxBlocksFor(population: usize, ringLen: usize) usize {
    return ringLen + (population + BLOCK_LEN - 1) / BLOCK_LEN + 2;
}

pub const PreLargeSievePrimes = struct {
    list: std.ArrayList(SievePrime),
    pendingStart: usize,

    ringWritePos: [][*]RingEntry,
    ringHead: usize,
    segmentShift: std.math.Log2Int(usize),

    freeBlocks: ?*Block,
    blockPool: []align(BLOCK_BYTES) Block,
    nextUnclaimed: usize,

    pub fn init(allocator: std.mem.Allocator, layout: Layout, maxPrime: usize) !PreLargeSievePrimes {
        const ringLen = ringSizeFor(layout.preLargeThreshold, layout.segmentElems);
        const ringWritePos = try allocator.alloc([*]RingEntry, ringLen);

        const population: usize = @intCast(Estimates.primeCountInRangeUpperBound(layout.mediumThreshold, @min(maxPrime, layout.preLargeThreshold)));
        const blockCount = maxBlocksFor(population, ringLen);
        const blockPool = try allocator.alignedAlloc(Block, BLOCK_ALIGNMENT, blockCount);

        var self = PreLargeSievePrimes{
            .list = try std.ArrayList(SievePrime).initCapacity(allocator, population),
            .pendingStart = 0,
            .ringWritePos = ringWritePos,
            .ringHead = 0,
            .segmentShift = layout.segmentShift,
            .freeBlocks = null,
            .blockPool = blockPool,
            .nextUnclaimed = 0,
        };
        for (ringWritePos) |*wp| wp.* = self.addBlock(null);
        return self;
    }

    pub fn deinit(self: *PreLargeSievePrimes, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        allocator.free(self.ringWritePos);
        allocator.free(self.blockPool);
    }

    fn freeBlock(self: *PreLargeSievePrimes, b: *Block) void {
        b.next = self.freeBlocks;
        self.freeBlocks = b;
    }

    noinline fn addBlock(self: *PreLargeSievePrimes, sealedWritePos: ?[*]RingEntry) [*]RingEntry {
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

    inline fn storeSievingPrime(self: *PreLargeSievePrimes, ringWritePos: [][*]RingEntry, slot: usize, entry: *const RingEntry) void {
        const wp = ringWritePos[slot];
        wp[0] = entry.*;
        const next = wp + 1;
        ringWritePos[slot] = if (isFull(next)) self.addBlock(next) else next;
    }

    pub fn add(self: *PreLargeSievePrimes, sievePrime: SievePrime, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        const segmentsAhead = self.destinationOf(sievePrime, bucketsStart);
        if (segmentsAhead < ringLen) {
            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead, self.segmentShift);
            self.storeSievingPrime(self.ringWritePos, slot, &entry);
        } else {
            self.list.appendAssumeCapacity(sievePrime);
        }
    }

    fn destinationOf(self: *const PreLargeSievePrimes, sievePrime: SievePrime, bucketsStart: usize) usize {
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const remaining = sievePrime.currentBucketIndex - bucketsStart;
        return remaining >> self.segmentShift;
    }

    pub noinline fn activate(self: *PreLargeSievePrimes, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        while (self.pendingStart < self.list.items.len) {
            const sievePrime = self.list.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const remaining = sievePrime.currentBucketIndex - bucketsStart;
            const segmentsAhead = remaining >> self.segmentShift;
            if (segmentsAhead >= ringLen) break;

            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead, self.segmentShift);
            self.storeSievingPrime(self.ringWritePos, slot, &entry);
            self.pendingStart += 1;
        }
    }

    pub fn apply(
        self: *PreLargeSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        _ = bucketsEndExclusive;
        _ = bucketsStart;
        switch (self.segmentShift) {
            inline LayoutMod.MIN_SEGMENT_SHIFT...LayoutMod.MAX_SEGMENT_SHIFT => |segmentShift| self.applyWithSegmentShift(segmentShift, buckets),
            else => unreachable,
        }
    }

    noinline fn applyWithSegmentShift(self: *PreLargeSievePrimes, comptime segmentShift: std.math.Log2Int(usize), buckets: Types.SIEVE_BUCKETS_TYPE) void {
        const ringWritePos = self.ringWritePos;
        const ringLen = ringWritePos.len;
        const cursor = self.ringHead;

        const wp = ringWritePos[cursor];
        const headBlock = blockOf(wp);
        headBlock.end = wp;

        var block: ?*Block = headBlock;
        while (block) |b| {
            const items = b.items();
            const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(RingEntry);

            for (items[0..fill]) |entry| {
                var result = processOne(buckets, entry, segmentShift);
                while (result.segmentsAhead == 0) result = processOne(buckets, result.entry, segmentShift);
                std.debug.assert(result.segmentsAhead < ringLen);
                const slot = (cursor + result.segmentsAhead) & (ringLen - 1);
                self.storeSievingPrime(ringWritePos, slot, &result.entry);
            }

            const next = b.next;
            self.freeBlock(b);
            block = next;
        }

        ringWritePos[cursor] = self.addBlock(null);
        self.ringHead = (cursor + 1) & (ringLen - 1);
    }
};
