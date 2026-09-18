const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
const LargeBucketSievePrime = SievePrimeMod.LargeBucketSievePrime;

const ringSizeFor = @import("hugeSievePrimes.zig").ringSizeFor;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;

const RESIDUE_COUNT = Comptimes.ADMISSIBLE_RESIDUES.count;
const WHEEL_INDEX_COUNT = RESIDUE_COUNT * RESIDUE_COUNT;

const BLOCK_BYTES: usize = 8 * 1024;
const BLOCK_ALIGNMENT = std.mem.Alignment.fromByteUnits(BLOCK_BYTES);

const RING_BLOCK_HEADER_BYTES: usize = @sizeOf([*]SievePrime) + @sizeOf(?*anyopaque);
const RING_BLOCK_LEN: usize = (BLOCK_BYTES - RING_BLOCK_HEADER_BYTES) / @sizeOf(SievePrime);
const RING_BLOCK_PAD_BYTES: usize = BLOCK_BYTES - RING_BLOCK_HEADER_BYTES - RING_BLOCK_LEN * @sizeOf(SievePrime);

const RingBlock = extern struct {
    end: [*]SievePrime,
    next: ?*RingBlock,
    itemsBytes: [RING_BLOCK_LEN * @sizeOf(SievePrime) + RING_BLOCK_PAD_BYTES]u8 align(@alignOf(SievePrime)) = undefined,

    fn items(self: *RingBlock) [*]SievePrime {
        return @ptrCast(&self.itemsBytes);
    }
};

comptime {
    if (@sizeOf(RingBlock) != BLOCK_BYTES) @compileError("RingBlock must be exactly BLOCK_BYTES for the pointer-arithmetic fullness/ownership tricks below to be valid");
    if (!std.math.isPowerOfTwo(BLOCK_BYTES)) @compileError("BLOCK_BYTES must be a power of two");
}

fn isFullRing(ptr: [*]SievePrime) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

fn ringBlockOf(ptr: [*]SievePrime) *RingBlock {
    var address = @intFromPtr(ptr);
    address -= 1;
    address -= address % BLOCK_BYTES;
    return @ptrFromInt(address);
}

fn maxBlocksFor(population: usize, ringLen: usize) usize {
    return ringLen + (population + RING_BLOCK_LEN - 1) / RING_BLOCK_LEN + 1;
}

const BUCKET_HEADER_BYTES: usize = @sizeOf([*]LargeBucketSievePrime) + @sizeOf(?*anyopaque);
const BUCKET_LEN: usize = (BLOCK_BYTES - BUCKET_HEADER_BYTES) / @sizeOf(LargeBucketSievePrime);
const BUCKET_PAD_BYTES: usize = BLOCK_BYTES - BUCKET_HEADER_BYTES - BUCKET_LEN * @sizeOf(LargeBucketSievePrime);

const Bucket = extern struct {
    end: [*]LargeBucketSievePrime,
    next: ?*Bucket,
    itemsBytes: [BUCKET_LEN * @sizeOf(LargeBucketSievePrime) + BUCKET_PAD_BYTES]u8 align(@alignOf(LargeBucketSievePrime)) = undefined,

    fn items(self: *Bucket) [*]LargeBucketSievePrime {
        return @ptrCast(&self.itemsBytes);
    }
};

comptime {
    if (@sizeOf(Bucket) != BLOCK_BYTES) @compileError("Bucket must be exactly BLOCK_BYTES for the pointer-arithmetic fullness/ownership tricks below to be valid");
}

fn isFullBucket(ptr: [*]LargeBucketSievePrime) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

fn bucketOf(ptr: [*]LargeBucketSievePrime) *Bucket {
    var address = @intFromPtr(ptr);
    address -= 1;
    address -= address % BLOCK_BYTES;
    return @ptrFromInt(address);
}

fn maxBucketsFor(population: usize) usize {
    return 2 * WHEEL_INDEX_COUNT + (population + BUCKET_LEN - 1) / BUCKET_LEN + 1;
}

pub const LargeSievePrimes = struct {
    ringWritePos: []?[*]SievePrime,
    ringHead: usize,

    ringFreeBlocks: ?*RingBlock,
    ringBlockPool: []align(BLOCK_BYTES) RingBlock,
    ringNextUnclaimed: usize,

    pending: std.ArrayList(SievePrime),
    pendingStart: usize,

    buckets: [WHEEL_INDEX_COUNT]?[*]LargeBucketSievePrime,
    currentBuckets: [WHEEL_INDEX_COUNT]?[*]LargeBucketSievePrime,

    bucketFreeBlocks: ?*Bucket,
    bucketPool: []align(BLOCK_BYTES) Bucket,
    bucketNextUnclaimed: usize,

    pub fn init(allocator: std.mem.Allocator) !LargeSievePrimes {
        const ringLen = ringSizeFor(BuildUtils.LARGE_HEAD_THRESHOLD);
        const ringWritePos = try allocator.alloc(?[*]SievePrime, ringLen);
        @memset(ringWritePos, null);

        const capacity = Estimates.primeCountUpperBound(BuildUtils.LARGE_HEAD_THRESHOLD);
        const ringBlockCount = maxBlocksFor(capacity, ringLen);
        const ringBlockPool = try allocator.alignedAlloc(RingBlock, BLOCK_ALIGNMENT, ringBlockCount);
        const bucketCount = maxBucketsFor(capacity);
        const bucketPool = try allocator.alignedAlloc(Bucket, BLOCK_ALIGNMENT, bucketCount);

        return LargeSievePrimes{
            .ringWritePos = ringWritePos,
            .ringHead = 0,
            .ringFreeBlocks = null,
            .ringBlockPool = ringBlockPool,
            .ringNextUnclaimed = 0,
            .pending = try std.ArrayList(SievePrime).initCapacity(allocator, capacity),
            .pendingStart = 0,
            .buckets = [_]?[*]LargeBucketSievePrime{null} ** WHEEL_INDEX_COUNT,
            .currentBuckets = [_]?[*]LargeBucketSievePrime{null} ** WHEEL_INDEX_COUNT,
            .bucketFreeBlocks = null,
            .bucketPool = bucketPool,
            .bucketNextUnclaimed = 0,
        };
    }

    pub fn deinit(self: *LargeSievePrimes, allocator: std.mem.Allocator) void {
        allocator.free(self.ringWritePos);
        allocator.free(self.ringBlockPool);
        self.pending.deinit(allocator);
        allocator.free(self.bucketPool);
    }

    fn freeRingBlock(self: *LargeSievePrimes, b: *RingBlock) void {
        b.next = self.ringFreeBlocks;
        self.ringFreeBlocks = b;
    }

    fn addRingBlock(self: *LargeSievePrimes, sealedWritePos: ?[*]SievePrime) [*]SievePrime {
        const fresh = if (self.ringFreeBlocks) |fb| blk: {
            self.ringFreeBlocks = fb.next;
            break :blk fb;
        } else blk: {
            std.debug.assert(self.ringNextUnclaimed < self.ringBlockPool.len);
            const b = &self.ringBlockPool[self.ringNextUnclaimed];
            self.ringNextUnclaimed += 1;
            break :blk b;
        };
        fresh.next = null;

        if (sealedWritePos) |wp| {
            const old = ringBlockOf(wp);
            old.end = wp;
            fresh.next = old;
        }
        return fresh.items();
    }

    fn storeSievingPrime(self: *LargeSievePrimes, slot: usize, sievePrime: SievePrime) void {
        const wp = self.ringWritePos[slot] orelse self.addRingBlock(null);
        wp[0] = sievePrime;
        const next = wp + 1;
        self.ringWritePos[slot] = if (isFullRing(next)) self.addRingBlock(next) else next;
    }

    pub fn add(self: *LargeSievePrimes, sievePrime: SievePrime, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        const segmentsAhead = destinationOf(sievePrime, ringLen, bucketsStart);
        if (segmentsAhead < ringLen) {
            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            self.storeSievingPrime(slot, sievePrime);
        } else {
            self.pending.appendAssumeCapacity(sievePrime);
        }
    }

    fn destinationOf(sievePrime: SievePrime, ringLen: usize, bucketsStart: usize) usize {
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
        return if (segmentsAhead < ringLen) segmentsAhead else ringLen;
    }

    fn freeBucket(self: *LargeSievePrimes, b: *Bucket) void {
        b.next = self.bucketFreeBlocks;
        self.bucketFreeBlocks = b;
    }

    fn addBucket(self: *LargeSievePrimes, sealedWritePos: ?[*]LargeBucketSievePrime) [*]LargeBucketSievePrime {
        const fresh = if (self.bucketFreeBlocks) |fb| blk: {
            self.bucketFreeBlocks = fb.next;
            break :blk fb;
        } else blk: {
            std.debug.assert(self.bucketNextUnclaimed < self.bucketPool.len);
            const b = &self.bucketPool[self.bucketNextUnclaimed];
            self.bucketNextUnclaimed += 1;
            break :blk b;
        };
        fresh.next = null;

        if (sealedWritePos) |wp| {
            const old = bucketOf(wp);
            old.end = wp;
            fresh.next = old;
        }
        return fresh.items();
    }

    inline fn storeInBucket(self: *LargeSievePrimes, wheelIndex: usize, entry: LargeBucketSievePrime) void {
        const wp = self.buckets[wheelIndex] orelse self.addBucket(null);
        wp[0] = entry;
        const next = wp + 1;
        self.buckets[wheelIndex] = if (isFullBucket(next)) self.addBucket(next) else next;
    }

    pub noinline fn activate(self: *LargeSievePrimes, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;

        while (self.pendingStart < self.pending.items.len) {
            const sievePrime = self.pending.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
            if (segmentsAhead >= ringLen) break;

            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            self.storeSievingPrime(slot, sievePrime);
            self.pendingStart += 1;
        }

        const cursor = self.ringHead;
        if (self.ringWritePos[cursor]) |wp| {
            const headBlock = ringBlockOf(wp);
            headBlock.end = wp;

            var block: ?*RingBlock = headBlock;
            while (block) |b| {
                const items = b.items();
                const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(SievePrime);

                for (items[0..fill]) |sievePrime| {
                    const wheelIndex: usize = @as(usize, sievePrime.initialInBucketIndex) * RESIDUE_COUNT + sievePrime.wheelStepIndex;
                    std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
                    self.storeInBucket(wheelIndex, .{
                        .localOffset = @intCast(sievePrime.currentBucketIndex - bucketsStart),
                        .initialBucketIndex = sievePrime.initialBucketIndex,
                    });
                }

                const next = b.next;
                self.freeRingBlock(b);
                block = next;
            }
            self.ringWritePos[cursor] = null;
        }

        self.ringHead = (cursor + 1) & (ringLen - 1);
    }

    pub fn apply(
        self: *LargeSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        std.mem.swap([WHEEL_INDEX_COUNT]?[*]LargeBucketSievePrime, &self.buckets, &self.currentBuckets);
        const bucketCount = bucketsEndExclusive - bucketsStart;

        for (0..WHEEL_INDEX_COUNT) |wheelIndex| {
            if (self.currentBuckets[wheelIndex]) |wp| {
                const bucket = bucketOf(wp);
                bucket.end = wp;
                self.currentBuckets[wheelIndex] = null;
                const ari = wheelIndex / RESIDUE_COUNT;
                const startPhase: u3 = @intCast(wheelIndex % RESIDUE_COUNT);
                inline for (0..RESIDUE_COUNT) |comptimeAri| {
                    if (comptimeAri == ari) {
                        crossOffGroup(comptimeAri, self, buckets, bucketCount, bucket, startPhase);
                    }
                }
            }
        }
    }
};

noinline fn crossOffGroup(
    comptime ari: usize,
    self: *LargeSievePrimes,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    bucketCount: usize,
    bucket: *Bucket,
    startPhase: u3,
) void {
    var block: ?*Bucket = bucket;
    while (block) |b| {
        const items = b.items();
        const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(LargeBucketSievePrime);

        for (items[0..fill]) |entry| {
            var i: usize = entry.localOffset;
            const sievingPrime: usize = entry.initialBucketIndex;

            sw: switch (startPhase) {
                inline 0...(RESIDUE_COUNT - 1) => |phase| {
                    if (i >= bucketCount) {
                        self.storeInBucket(ari * RESIDUE_COUNT + phase, .{
                            .localOffset = @intCast(i - bucketCount),
                            .initialBucketIndex = entry.initialBucketIndex,
                        });
                        break :sw;
                    }
                    const step = comptime Comptimes.WHEEL_PATTERNS[ari][phase];
                    buckets[i] &= step.bitMask;
                    i += sievingPrime * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                    continue :sw comptime @as(u3, (@as(usize, phase) + 1) % RESIDUE_COUNT);
                },
            }
        }

        const next = b.next;
        self.freeBucket(b);
        block = next;
    }
}
