const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const ringSizeFor = @import("hugeSievePrimes.zig").ringSizeFor;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;

const BATCH_SIZE: usize = BuildUtils.GENERAL_PURPOSE_REGISTER_COUNT / 5;

const BLOCK_BYTES: usize = 8 * 1024;
const BLOCK_HEADER_BYTES: usize = @sizeOf([*]SievePrime) + @sizeOf(?*anyopaque);
const BLOCK_LEN: usize = (BLOCK_BYTES - BLOCK_HEADER_BYTES) / @sizeOf(SievePrime);
const BLOCK_PAD_BYTES: usize = BLOCK_BYTES - BLOCK_HEADER_BYTES - BLOCK_LEN * @sizeOf(SievePrime);
const BLOCK_ALIGNMENT = std.mem.Alignment.fromByteUnits(BLOCK_BYTES);

// Mirrors hugeSievePrimes.zig's own Block exactly (see that file for the
// full pointer-arithmetic rationale) - a separate type because this
// tier's ring stores full SievePrime (16 bytes), not huge's compact
// RingEntry (8 bytes): a large-tier ring entry is promoted into `active`
// unchanged once drained, never re-encoded, so there's no equivalent
// local-offset trick to shrink it with here.
const Block = extern struct {
    end: [*]SievePrime,
    next: ?*Block,
    itemsBytes: [BLOCK_LEN * @sizeOf(SievePrime) + BLOCK_PAD_BYTES]u8 align(@alignOf(SievePrime)) = undefined,

    fn items(self: *Block) [*]SievePrime {
        return @ptrCast(&self.itemsBytes);
    }
};

comptime {
    if (@sizeOf(Block) != BLOCK_BYTES) @compileError("Block must be exactly BLOCK_BYTES for the pointer-arithmetic fullness/ownership tricks below to be valid");
    if (!std.math.isPowerOfTwo(BLOCK_BYTES)) @compileError("BLOCK_BYTES must be a power of two");
}

fn isFull(ptr: [*]SievePrime) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

fn blockOf(ptr: [*]SievePrime) *Block {
    var address = @intFromPtr(ptr);
    address -= 1;
    address -= address % BLOCK_BYTES;
    return @ptrFromInt(address);
}

// See hugeSievePrimes.zig's maxBlocksFor for the full derivation - same
// bound applies here. The +1 transient margin isn't strictly required
// for THIS tier (a large-tier entry is written to a block exactly once
// and only ever copied OUT into `active`, never rewritten to a
// different block while its source block is still live - unlike huge's
// ring, which continuously refiles entries between blocks every
// apply()) but costs one spare 8KB block, so kept for symmetry with
// hugeSievePrimes.zig's own bound and defense in depth against a future
// change to this tier's activate()/add() ordering.
fn maxBlocksFor(population: usize, ringLen: usize) usize {
    return ringLen + (population + BLOCK_LEN - 1) / BLOCK_LEN + 1;
}

// Primes above MEDIUM_LARGE_THRESHOLD, up to LARGE_HEAD_THRESHOLD (the
// denser, multi-hit end of the large tier - see preHugeSievePrimes.zig
// for the sparser sub-range above that). Steps BATCH_SIZE primes together
// one wheel-step at a time in lockstep so their independent loads/stores
// can overlap, instead of serializing per prime - worthwhile only where
// a prime can hit a segment more than once, which is what this sub-range
// (below largeHeadThreshold's "at most 2 hits" cutoff) guarantees.
pub const LargeSievePrimes = struct {
    active: std.ArrayList(SievePrime),

    // Ring slots, Block-backed exactly like HugeSievePrimes' own - see
    // that file's struct doc for why per-slot Block dedication (not just
    // preallocation) is what keeps a drained slot's scan sequential.
    ringWritePos: []?[*]SievePrime,
    ringHead: usize,

    freeBlocks: ?*Block,
    blockPool: []align(BLOCK_BYTES) Block,
    nextUnclaimed: usize,

    // Overflow band for primes whose first occurrence is still beyond the
    // ring's reach at add() time (see HugeSievePrimes' struct docstring
    // for the identical argument).
    pending: std.ArrayList(SievePrime),
    pendingStart: usize,

    pub fn init(allocator: std.mem.Allocator) !LargeSievePrimes {
        const ringLen = ringSizeFor(BuildUtils.LARGE_HEAD_THRESHOLD);
        const ringWritePos = try allocator.alloc(?[*]SievePrime, ringLen);
        @memset(ringWritePos, null);

        // Same bound backs active/pending/the block pool: in the worst
        // case every registered prime ends up in exactly one of
        // active/pending/ring at once (ring's own worst case is bounded
        // via maxBlocksFor, not this capacity directly), so sizing each
        // independently to this bound is safe.
        const capacity = Estimates.primeCountUpperBound(BuildUtils.LARGE_HEAD_THRESHOLD);
        const blockCount = maxBlocksFor(capacity, ringLen);
        const blockPool = try allocator.alignedAlloc(Block, BLOCK_ALIGNMENT, blockCount);

        return LargeSievePrimes{
            .active = try std.ArrayList(SievePrime).initCapacity(allocator, capacity),
            .ringWritePos = ringWritePos,
            .ringHead = 0,
            .freeBlocks = null,
            .blockPool = blockPool,
            .nextUnclaimed = 0,
            .pending = try std.ArrayList(SievePrime).initCapacity(allocator, capacity),
            .pendingStart = 0,
        };
    }

    pub fn deinit(self: *LargeSievePrimes, allocator: std.mem.Allocator) void {
        self.active.deinit(allocator);
        allocator.free(self.ringWritePos);
        allocator.free(self.blockPool);
        self.pending.deinit(allocator);
    }

    fn freeBlock(self: *LargeSievePrimes, b: *Block) void {
        b.next = self.freeBlocks;
        self.freeBlocks = b;
    }

    fn addBlock(self: *LargeSievePrimes, sealedWritePos: ?[*]SievePrime) [*]SievePrime {
        // maxBlocksFor(...) bounds total simultaneously-live Blocks, so
        // one of these two sources always has room.
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

    fn storeSievingPrime(self: *LargeSievePrimes, slot: usize, sievePrime: SievePrime) void {
        const wp = self.ringWritePos[slot] orelse self.addBlock(null);
        wp[0] = sievePrime;
        const next = wp + 1;
        self.ringWritePos[slot] = if (isFull(next)) self.addBlock(next) else next;
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
            const headBlock = blockOf(wp);
            headBlock.end = wp;

            var block: ?*Block = headBlock;
            while (block) |b| {
                const items = b.items();
                const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(SievePrime);
                self.active.appendSliceAssumeCapacity(items[0..fill]);

                const next = b.next;
                self.freeBlock(b);
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
        applyBatch(BATCH_SIZE, buckets, bucketsStart, bucketsEndExclusive, self.active.items);
    }

    noinline fn applyBatch(
        comptime batchSize: usize,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        activeSievePrimes: []SievePrime,
    ) void {
        var readySievePrimes: [batchSize]*SievePrime = undefined;
        var readySievePrimesCount: usize = 0;

        for (activeSievePrimes) |*sievePrime| {
            if (sievePrime.currentBucketIndex < bucketsEndExclusive) {
                readySievePrimes[readySievePrimesCount] = sievePrime;
                readySievePrimesCount += 1;
                if (readySievePrimesCount == batchSize) {
                    applyNSievePrimesIntoSegment(batchSize, buckets, bucketsStart, bucketsEndExclusive, &readySievePrimes);
                    readySievePrimesCount = 0;
                }
            }
        }

        if (readySievePrimesCount > 0) {
            inline for (0..batchSize) |leftoverCount| {
                if (leftoverCount == readySievePrimesCount) {
                    applyNSievePrimesIntoSegment(leftoverCount, buckets, bucketsStart, bucketsEndExclusive, readySievePrimes[0..leftoverCount]);
                    break;
                }
            }
        }
    }

    inline fn applyNSievePrimesIntoSegment(
        comptime n: usize,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrimes: *[n]*SievePrime,
    ) void {
        const bucketCount = bucketsEndExclusive - bucketsStart;

        var wheelPatterns: [n]*const [Comptimes.ADMISSIBLE_RESIDUES.count]Comptimes.WheelStep = undefined;
        var initialBucketIndices: [n]usize = undefined;
        var currentBucketIndices: [n]usize = undefined;
        var wheelStepIndex: [n]usize = undefined;

        inline for (0..n) |i| {
            wheelPatterns[i] = &Comptimes.WHEEL_PATTERNS[sievePrimes[i].initialInBucketIndex];
            initialBucketIndices[i] = @as(usize, sievePrimes[i].initialBucketIndex);
            currentBucketIndices[i] = sievePrimes[i].currentBucketIndex - bucketsStart;
            wheelStepIndex[i] = @as(usize, sievePrimes[i].wheelStepIndex);
        }

        var allWithinBucketEndExclusive = true;
        while (allWithinBucketEndExclusive) {
            inline for (0..n) |spi| {
                const step = &wheelPatterns[spi][wheelStepIndex[spi]];
                buckets[currentBucketIndices[spi]] &= step.bitMask;
                currentBucketIndices[spi] +=
                    initialBucketIndices[spi] * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                wheelStepIndex[spi] += 1;
                wheelStepIndex[spi] %= Comptimes.ADMISSIBLE_RESIDUES.count;
                allWithinBucketEndExclusive &= currentBucketIndices[spi] < bucketCount;
            }
        }

        inline for (0..n) |spi| {
            while (currentBucketIndices[spi] < bucketCount) {
                const step = wheelPatterns[spi][wheelStepIndex[spi]];
                buckets[currentBucketIndices[spi]] &= step.bitMask;
                currentBucketIndices[spi] +=
                    initialBucketIndices[spi] * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                wheelStepIndex[spi] += 1;
                wheelStepIndex[spi] %= Comptimes.ADMISSIBLE_RESIDUES.count;
            }
            sievePrimes[spi].currentBucketIndex = currentBucketIndices[spi] + bucketsStart;
            sievePrimes[spi].wheelStepIndex = @intCast(wheelStepIndex[spi]);
        }
    }
};
