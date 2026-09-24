const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const LayoutMod = @import("../layout.zig");
const Layout = LayoutMod.Layout;
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.LargeSievePrime;
const RingEntry = SievePrimeMod.LargeSievePrimeSlot;

const WHEEL_INDEX_SHIFT = Comptimes.WHEEL_2310_INDEX_SHIFT;
const LOCAL_OFFSET_MASK: u32 = (1 << WHEEL_INDEX_SHIFT) - 1;
const IN_BUCKET_INDEX_BITS = 3;
const IN_BUCKET_INDEX_MASK: u32 = (1 << IN_BUCKET_INDEX_BITS) - 1;

comptime {
    if (LayoutMod.MAX_SEGMENT_ELEMS > 1 << WHEEL_INDEX_SHIFT) @compileError("MAX_SEGMENT_ELEMS exceeds RingEntry's local-offset bit budget - raise WHEEL_2310_INDEX_SHIFT before raising this bound");
    if (Comptimes.ADMISSIBLE_RESIDUES_2310.count > 1 << (32 - WHEEL_INDEX_SHIFT)) @compileError("ADMISSIBLE_RESIDUES_2310 does not fit RingEntry's wheel-step bit budget");
    if (Comptimes.ADMISSIBLE_RESIDUES.count != 1 << IN_BUCKET_INDEX_BITS) @compileError("RingEntry packs the in-bucket index into IN_BUCKET_INDEX_BITS bits");
}

const MAX_WHEEL_STEP_FACTOR: usize = blk: {
    @setEvalBranchQuota(100_000);
    var m: usize = 0;
    for (Comptimes.WHEEL_PATTERNS_2310) |step| {
        m = @max(m, @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend));
    }
    break :blk m;
};

pub fn ringSizeFor(maxPrime: usize, segmentElems: usize) usize {
    return std.math.ceilPowerOfTwoAssert(usize, tightMinRingLen(maxPrime, segmentElems));
}

fn tightMinRingLen(maxPrime: usize, segmentElems: usize) usize {
    const maxSievingPrime = maxPrime / Comptimes.WHEEL_CIRCUMFERENCE;
    const maxAdvance = maxSievingPrime * MAX_WHEEL_STEP_FACTOR + MAX_WHEEL_STEP_FACTOR;
    const maxMultipleIndexWithinSegment = (segmentElems - 1) + maxAdvance;
    return maxMultipleIndexWithinSegment / segmentElems + 1;
}

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

fn populationBoundFor(minPrimeExclusive: usize, maxPrime: usize) usize {
    return @intCast(Estimates.primeCountInRangeUpperBound(minPrimeExclusive, maxPrime));
}

fn maxBlocksFor(population: usize, ringLen: usize) usize {
    return ringLen + (population + BLOCK_LEN - 1) / BLOCK_LEN + 2;
}

pub const LargeSievePrimes = struct {
    list: std.ArrayList(SievePrime),
    pendingStart: usize,

    ringWritePos: [][*]RingEntry,
    segmentShift: std.math.Log2Int(usize),

    freeBlocks: ?*Block,

    blockPool: []align(BLOCK_BYTES) Block,
    nextUnclaimed: usize,

    pub fn init(allocator: std.mem.Allocator, layout: Layout, maxPrime: usize) !LargeSievePrimes {
        const ringLen = tightMinRingLen(maxPrime, layout.segmentElems);
        const ringWritePos = try allocator.alloc([*]RingEntry, ringLen);

        const population = populationBoundFor(layout.preLargeThreshold, maxPrime);
        const blockCount = maxBlocksFor(population, ringLen);
        const blockPool = try allocator.alignedAlloc(Block, BLOCK_ALIGNMENT, blockCount);

        var self = LargeSievePrimes{
            .list = try std.ArrayList(SievePrime).initCapacity(allocator, population),
            .pendingStart = 0,
            .ringWritePos = ringWritePos,
            .segmentShift = layout.segmentShift,
            .freeBlocks = null,
            .blockPool = blockPool,
            .nextUnclaimed = 0,
        };
        for (ringWritePos) |*wp| wp.* = self.addBlock(null);
        return self;
    }

    pub fn deinit(self: *LargeSievePrimes, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        allocator.free(self.ringWritePos);
        allocator.free(self.blockPool);
    }

    fn freeBlock(self: *LargeSievePrimes, b: *Block) void {
        b.next = self.freeBlocks;
        self.freeBlocks = b;
    }

    noinline fn addBlock(self: *LargeSievePrimes, sealedWritePos: ?[*]RingEntry) [*]RingEntry {
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

    inline fn storeSievingPrime(self: *LargeSievePrimes, ringWritePos: [][*]RingEntry, slot: usize, entry: *const RingEntry) void {
        const wp = ringWritePos[slot];
        wp[0] = entry.*;
        const next = wp + 1;
        ringWritePos[slot] = if (isFull(next)) self.addBlock(next) else next;
    }

    pub fn toRingEntry(sievePrime: SievePrime, bucketsStart: usize, segmentsAhead: usize, segmentShift: std.math.Log2Int(usize)) RingEntry {
        const localOffset = sievePrime.currentBucketIndex - bucketsStart - (segmentsAhead << segmentShift);
        std.debug.assert(sievePrime.initialBucketIndex < 1 << (32 - IN_BUCKET_INDEX_BITS));
        return RingEntry{
            .localOffsetAndWheelStepIndex2310 = @as(u32, @intCast(localOffset)) | (@as(u32, sievePrime.wheelStepIndex2310) << WHEEL_INDEX_SHIFT),
            .initialBucketIndexAndInBucketIndex = (sievePrime.initialBucketIndex << IN_BUCKET_INDEX_BITS) | sievePrime.initialInBucketIndex,
        };
    }

    pub fn add(self: *LargeSievePrimes, sievePrime: SievePrime, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        const segmentsAhead = self.destinationOf(sievePrime, bucketsStart);
        if (segmentsAhead < ringLen) {
            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead, self.segmentShift);
            self.storeSievingPrime(self.ringWritePos, segmentsAhead, &entry);
        } else {
            self.list.appendAssumeCapacity(sievePrime);
        }
    }

    fn destinationOf(self: *const LargeSievePrimes, sievePrime: SievePrime, bucketsStart: usize) usize {
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const remaining = sievePrime.currentBucketIndex - bucketsStart;
        return remaining >> self.segmentShift;
    }

    pub noinline fn activate(self: *LargeSievePrimes, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        while (self.pendingStart < self.list.items.len) {
            const sievePrime = self.list.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const remaining = sievePrime.currentBucketIndex - bucketsStart;
            const segmentsAhead = remaining >> self.segmentShift;
            if (segmentsAhead >= ringLen) break;

            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead, self.segmentShift);
            self.storeSievingPrime(self.ringWritePos, segmentsAhead, &entry);
            self.pendingStart += 1;
        }
    }

    pub fn apply(
        self: *LargeSievePrimes,
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

    noinline fn applyWithSegmentShift(self: *LargeSievePrimes, comptime segmentShift: std.math.Log2Int(usize), buckets: Types.SIEVE_BUCKETS_TYPE) void {
        const ringWritePos = self.ringWritePos;
        const ringLen = ringWritePos.len;

        const wp = ringWritePos[0];
        const headBlock = blockOf(wp);
        headBlock.end = wp;

        var block: ?*Block = headBlock;
        while (block) |b| {
            const items = b.items();
            const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(RingEntry);

            for (items[0..fill]) |entry| {
                const result = processOne(buckets, entry, segmentShift);
                std.debug.assert(result.segmentsAhead >= 1 and result.segmentsAhead < ringLen);
                self.storeSievingPrime(ringWritePos, result.segmentsAhead, &result.entry);
            }

            const next = b.next;
            self.freeBlock(b);
            block = next;
        }

        std.mem.copyForwards([*]RingEntry, ringWritePos[0 .. ringLen - 1], ringWritePos[1..ringLen]);
        ringWritePos[ringLen - 1] = self.addBlock(null);
    }
};

pub inline fn processOne(buckets: Types.SIEVE_BUCKETS_TYPE, entry: RingEntry, comptime segmentShift: std.math.Log2Int(usize)) struct { entry: RingEntry, segmentsAhead: usize } {
    const wheelStepIndex = entry.localOffsetAndWheelStepIndex2310 >> WHEEL_INDEX_SHIFT;
    const inBucketIndex = entry.initialBucketIndexAndInBucketIndex & IN_BUCKET_INDEX_MASK;
    const step = &Comptimes.WHEEL_PATTERNS_2310[(wheelStepIndex << IN_BUCKET_INDEX_BITS) | inBucketIndex];

    const localOffset: usize = entry.localOffsetAndWheelStepIndex2310 & LOCAL_OFFSET_MASK;
    buckets[localOffset] &= step.bitMask;

    const initialBucketIndex = @as(usize, entry.initialBucketIndexAndInBucketIndex >> IN_BUCKET_INDEX_BITS);
    const advance = initialBucketIndex * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
    const newOffset = localOffset + advance;
    const segmentsAhead = newOffset >> segmentShift;

    return .{
        .entry = RingEntry{
            .localOffsetAndWheelStepIndex2310 = @as(u32, @intCast(newOffset & ((1 << segmentShift) - 1))) | step.nextWheelStepIndex2310Bits,
            .initialBucketIndexAndInBucketIndex = entry.initialBucketIndexAndInBucketIndex,
        },
        .segmentsAhead = segmentsAhead,
    };
}
