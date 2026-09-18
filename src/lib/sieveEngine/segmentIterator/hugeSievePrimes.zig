const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.HugeSievePrime;
const RingEntry = SievePrimeMod.HugeSievePrimeSlot;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;
const LARGE_HUGE_THRESHOLD: usize = BuildUtils.LARGE_HUGE_THRESHOLD;

comptime {
    if (SEGMENT_ELEMS > 1 << 23) @compileError("SEGMENT_ELEMS exceeds RingEntry.localOffset's u23 budget - widen that field before raising this bound");
}

const MAX_WHEEL_STEP_FACTOR: usize = blk: {
    var m: usize = 0;
    for (Comptimes.WHEEL_PATTERNS_210) |step| {
        m = @max(m, @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend));
    }
    break :blk m;
};

pub fn ringSizeFor(maxPrime: usize) usize {
    return std.math.ceilPowerOfTwoAssert(usize, tightMinRingLen(maxPrime));
}

fn tightMinRingLen(maxPrime: usize) usize {
    const maxSievingPrime = maxPrime / Comptimes.WHEEL_CIRCUMFERENCE;
    const maxAdvance = maxSievingPrime * MAX_WHEEL_STEP_FACTOR + MAX_WHEEL_STEP_FACTOR;
    const maxMultipleIndexWithinSegment = (SEGMENT_ELEMS - 1) + maxAdvance;
    return maxMultipleIndexWithinSegment / SEGMENT_ELEMS + 1;
}

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

fn populationBoundFor(maxPrime: usize) usize {
    const bound = Estimates.primeCountUpperBound(maxPrime) -| Estimates.primeCountUpperBound(LARGE_HUGE_THRESHOLD);
    return @intCast(bound);
}

fn maxBlocksFor(population: usize, ringLen: usize) usize {
    return ringLen + (population + BLOCK_LEN - 1) / BLOCK_LEN + 1;
}

pub const HugeSievePrimes = struct {
    list: std.ArrayList(SievePrime),
    pendingStart: usize,

    ringWritePos: []?[*]RingEntry,

    freeBlocks: ?*Block,

    blockPool: []align(BLOCK_BYTES) Block,
    nextUnclaimed: usize,

    pub fn init(allocator: std.mem.Allocator, maxPrime: usize) !HugeSievePrimes {
        const ringLen = tightMinRingLen(maxPrime);
        const ringWritePos = try allocator.alloc(?[*]RingEntry, ringLen);
        @memset(ringWritePos, null);

        const population = populationBoundFor(maxPrime);
        const blockCount = maxBlocksFor(population, ringLen);
        const blockPool = try allocator.alignedAlloc(Block, BLOCK_ALIGNMENT, blockCount);

        return HugeSievePrimes{
            .list = try std.ArrayList(SievePrime).initCapacity(allocator, population),
            .pendingStart = 0,
            .ringWritePos = ringWritePos,
            .freeBlocks = null,
            .blockPool = blockPool,
            .nextUnclaimed = 0,
        };
    }

    pub fn deinit(self: *HugeSievePrimes, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        allocator.free(self.ringWritePos);
        allocator.free(self.blockPool);
    }

    fn freeBlock(self: *HugeSievePrimes, b: *Block) void {
        b.next = self.freeBlocks;
        self.freeBlocks = b;
    }

    fn addBlock(self: *HugeSievePrimes, sealedWritePos: ?[*]RingEntry) [*]RingEntry {
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

    fn storeSievingPrime(self: *HugeSievePrimes, slot: usize, entry: *const RingEntry) void {
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
            .wheelIndex210 = @as(u9, sievePrime.initialInBucketIndex) * Comptimes.ADMISSIBLE_RESIDUES_210.count + @as(u9, sievePrime.wheelStepIndex210),
        };
    }

    pub fn add(self: *HugeSievePrimes, sievePrime: SievePrime, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        const segmentsAhead = destinationOf(sievePrime, ringLen, bucketsStart);
        if (segmentsAhead < ringLen) {
            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead);
            self.storeSievingPrime(segmentsAhead, &entry);
        } else {
            self.list.appendAssumeCapacity(sievePrime);
        }
    }

    fn destinationOf(sievePrime: SievePrime, ringLen: usize, bucketsStart: usize) usize {
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
        return if (segmentsAhead < ringLen) segmentsAhead else ringLen;
    }

    pub noinline fn activate(self: *HugeSievePrimes, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        while (self.pendingStart < self.list.items.len) {
            const sievePrime = self.list.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
            if (segmentsAhead >= ringLen) break;

            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead);
            self.storeSievingPrime(segmentsAhead, &entry);
            self.pendingStart += 1;
        }
    }

    pub noinline fn apply(
        self: *HugeSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        _ = bucketsEndExclusive;
        _ = bucketsStart;
        const ringLen = self.ringWritePos.len;

        if (self.ringWritePos[0]) |wp| {
            const headBlock = blockOf(wp);
            headBlock.end = wp;

            var block: ?*Block = headBlock;
            while (block) |b| {
                const items = b.items();
                const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(RingEntry);

                var i: usize = 0;
                while (i + 1 < fill) : (i += 2) {
                    const result0 = processOne(buckets, items[i]);
                    const result1 = processOne(buckets, items[i + 1]);
                    std.debug.assert(result0.segmentsAhead >= 1 and result0.segmentsAhead < ringLen);
                    std.debug.assert(result1.segmentsAhead >= 1 and result1.segmentsAhead < ringLen);
                    self.storeSievingPrime(result0.segmentsAhead, &result0.entry);
                    self.storeSievingPrime(result1.segmentsAhead, &result1.entry);
                }
                if (i < fill) {
                    const result = processOne(buckets, items[i]);
                    std.debug.assert(result.segmentsAhead >= 1 and result.segmentsAhead < ringLen);
                    self.storeSievingPrime(result.segmentsAhead, &result.entry);
                }

                const next = b.next;
                self.freeBlock(b);
                block = next;
            }
            self.ringWritePos[0] = null;
        }

        std.mem.copyForwards(?[*]RingEntry, self.ringWritePos[0 .. ringLen - 1], self.ringWritePos[1..ringLen]);
        self.ringWritePos[ringLen - 1] = null;
    }
};

inline fn processOne(buckets: Types.SIEVE_BUCKETS_TYPE, entry: RingEntry) struct { entry: RingEntry, segmentsAhead: usize } {
    const step = Comptimes.WHEEL_PATTERNS_210[entry.wheelIndex210];

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
            .wheelIndex210 = @intCast(step.nextWheelIndex210),
        },
        .segmentsAhead = segmentsAhead,
    };
}
