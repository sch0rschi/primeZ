const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const Layout = @import("../layout.zig").Layout;
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
const MediumBucketSievePrime = SievePrimeMod.MediumBucketSievePrime;

const ringSizeFor = @import("largeSievePrimes.zig").ringSizeFor;

const RESIDUE_COUNT = Comptimes.ADMISSIBLE_RESIDUES.count;
const WHEEL_INDEX_COUNT = RESIDUE_COUNT * RESIDUE_COUNT;

const BLOCK_BYTES: usize = 16 * 1024;
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

const BUCKET_HEADER_BYTES: usize = @sizeOf([*]MediumBucketSievePrime) + @sizeOf(?*anyopaque);
const BUCKET_LEN: usize = (BLOCK_BYTES - BUCKET_HEADER_BYTES) / @sizeOf(MediumBucketSievePrime);
const BUCKET_PAD_BYTES: usize = BLOCK_BYTES - BUCKET_HEADER_BYTES - BUCKET_LEN * @sizeOf(MediumBucketSievePrime);

const Bucket = extern struct {
    end: [*]MediumBucketSievePrime,
    next: ?*Bucket,
    itemsBytes: [BUCKET_LEN * @sizeOf(MediumBucketSievePrime) + BUCKET_PAD_BYTES]u8 align(@alignOf(MediumBucketSievePrime)) = undefined,

    fn items(self: *Bucket) [*]MediumBucketSievePrime {
        return @ptrCast(&self.itemsBytes);
    }
};

comptime {
    if (@sizeOf(Bucket) != BLOCK_BYTES) @compileError("Bucket must be exactly BLOCK_BYTES for the pointer-arithmetic fullness/ownership tricks below to be valid");
}

fn isFullBucket(ptr: [*]MediumBucketSievePrime) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

fn bucketOf(ptr: [*]MediumBucketSievePrime) *Bucket {
    var address = @intFromPtr(ptr);
    address -= 1;
    address -= address % BLOCK_BYTES;
    return @ptrFromInt(address);
}

fn maxBucketsFor(population: usize) usize {
    return 2 * WHEEL_INDEX_COUNT + (population + BUCKET_LEN - 1) / BUCKET_LEN + 1;
}

pub const MediumSievePrimes = struct {
    ringWritePos: []?[*]SievePrime,
    ringHead: usize,
    segmentShift: std.math.Log2Int(usize),

    ringFreeBlocks: ?*RingBlock,
    ringBlockPool: []align(BLOCK_BYTES) RingBlock,
    ringNextUnclaimed: usize,

    pending: std.ArrayList(SievePrime),
    pendingStart: usize,

    buckets: [WHEEL_INDEX_COUNT]?[*]MediumBucketSievePrime,
    currentBuckets: [WHEEL_INDEX_COUNT]?[*]MediumBucketSievePrime,

    bucketFreeBlocks: ?*Bucket,
    bucketPool: []align(BLOCK_BYTES) Bucket,
    bucketNextUnclaimed: usize,

    pub fn init(allocator: std.mem.Allocator, layout: Layout, maxPrime: usize) !MediumSievePrimes {
        const ringLen = ringSizeFor(layout.mediumThreshold, layout.segmentElems);
        const ringWritePos = try allocator.alloc(?[*]SievePrime, ringLen);
        @memset(ringWritePos, null);

        const capacity: usize = @intCast(Estimates.primeCountInRangeUpperBound(layout.smallSegmentThreshold, @min(maxPrime, layout.mediumThreshold)));
        const ringBlockCount = maxBlocksFor(capacity, ringLen);
        const ringBlockPool = try allocator.alignedAlloc(RingBlock, BLOCK_ALIGNMENT, ringBlockCount);
        const bucketCount = maxBucketsFor(capacity);
        const bucketPool = try allocator.alignedAlloc(Bucket, BLOCK_ALIGNMENT, bucketCount);

        return MediumSievePrimes{
            .ringWritePos = ringWritePos,
            .ringHead = 0,
            .segmentShift = layout.segmentShift,
            .ringFreeBlocks = null,
            .ringBlockPool = ringBlockPool,
            .ringNextUnclaimed = 0,
            .pending = try std.ArrayList(SievePrime).initCapacity(allocator, capacity),
            .pendingStart = 0,
            .buckets = [_]?[*]MediumBucketSievePrime{null} ** WHEEL_INDEX_COUNT,
            .currentBuckets = [_]?[*]MediumBucketSievePrime{null} ** WHEEL_INDEX_COUNT,
            .bucketFreeBlocks = null,
            .bucketPool = bucketPool,
            .bucketNextUnclaimed = 0,
        };
    }

    pub fn deinit(self: *MediumSievePrimes, allocator: std.mem.Allocator) void {
        allocator.free(self.ringWritePos);
        allocator.free(self.ringBlockPool);
        self.pending.deinit(allocator);
        allocator.free(self.bucketPool);
    }

    fn freeRingBlock(self: *MediumSievePrimes, b: *RingBlock) void {
        b.next = self.ringFreeBlocks;
        self.ringFreeBlocks = b;
    }

    fn addRingBlock(self: *MediumSievePrimes, sealedWritePos: ?[*]SievePrime) [*]SievePrime {
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

    fn storeSievingPrime(self: *MediumSievePrimes, slot: usize, sievePrime: SievePrime) void {
        const wp = self.ringWritePos[slot] orelse self.addRingBlock(null);
        wp[0] = sievePrime;
        const next = wp + 1;
        self.ringWritePos[slot] = if (isFullRing(next)) self.addRingBlock(next) else next;
    }

    pub fn add(self: *MediumSievePrimes, sievePrime: SievePrime, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        const segmentsAhead = self.destinationOf(sievePrime, bucketsStart);
        if (segmentsAhead < ringLen) {
            const slot = (self.ringHead + segmentsAhead) & (ringLen - 1);
            self.storeSievingPrime(slot, sievePrime);
        } else {
            self.pending.appendAssumeCapacity(sievePrime);
        }
    }

    fn destinationOf(self: *const MediumSievePrimes, sievePrime: SievePrime, bucketsStart: usize) usize {
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const remaining = sievePrime.currentBucketIndex - bucketsStart;
        return remaining >> self.segmentShift;
    }

    fn freeBucket(self: *MediumSievePrimes, b: *Bucket) void {
        b.next = self.bucketFreeBlocks;
        self.bucketFreeBlocks = b;
    }

    fn addBucket(self: *MediumSievePrimes, sealedWritePos: ?[*]MediumBucketSievePrime) [*]MediumBucketSievePrime {
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

    inline fn storeInBucket(self: *MediumSievePrimes, wheelIndex: usize, entry: MediumBucketSievePrime) void {
        const wp = self.buckets[wheelIndex] orelse self.addBucket(null);
        wp[0] = entry;
        const next = wp + 1;
        self.buckets[wheelIndex] = if (isFullBucket(next)) self.addBucket(next) else next;
    }

    pub noinline fn activate(self: *MediumSievePrimes, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;

        while (self.pendingStart < self.pending.items.len) {
            const sievePrime = self.pending.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const remaining = sievePrime.currentBucketIndex - bucketsStart;
            const segmentsAhead = remaining >> self.segmentShift;
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
        self: *MediumSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        std.mem.swap([WHEEL_INDEX_COUNT]?[*]MediumBucketSievePrime, &self.buckets, &self.currentBuckets);
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
    self: *MediumSievePrimes,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    bucketCount: usize,
    bucket: *Bucket,
    startPhase: u3,
) void {
    var block: ?*Bucket = bucket;
    while (block) |b| {
        const items = b.items();
        const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(MediumBucketSievePrime);

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
