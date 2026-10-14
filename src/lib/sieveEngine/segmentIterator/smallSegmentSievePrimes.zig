const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const LayoutMod = @import("../layout.zig");
const Layout = LayoutMod.Layout;
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const WHEEL_STEP_COUNT = @bitSizeOf(Types.SIEVE_BUCKET_TYPE);
const RESIDUE_COUNT = Comptimes.ADMISSIBLE_RESIDUES.count;
const CELL_COUNT = RESIDUE_COUNT * WHEEL_STEP_COUNT;

/// Compact bucket record: the (initialInBucketIndex, wheelStepIndex) pair is
/// implied by the grid cell the record lives in, so only the two fields the
/// kernel actually reads are stored. 8 bytes is the largest record size that
/// divides the block items region exactly (see BUCKET_PAD_BYTES below).
const SmallSegmentBucketEntry = struct {
    /// Offset from the segment the record's grid is read with. Never exceeds
    /// 2^32: entries further ahead wait in `pending` until they come within
    /// the horizon.
    localOffset: u32,
    /// p/30 of the entry's prime (<= 2^22 at MAX_SEGMENT_ELEMS).
    initialBucketIndex: u32,
};

/// Absolute-position record for entries whose first multiple is more than
/// 2^32 buckets ahead of the current segment. Drained into the grid (with the
/// then-current base) once it comes within the horizon.
const SmallSegmentPendingEntry = struct {
    bucketIndex: usize,
    initialBucketIndex: u32,
    /// initialInBucketIndex * WHEEL_STEP_COUNT + wheelStepIndex.
    cell: u8,
};

fn lessThanByBucketIndex(_: void, a: SmallSegmentPendingEntry, b: SmallSegmentPendingEntry) bool {
    return a.bucketIndex < b.bucketIndex;
}

const PENDING_HORIZON_BUCKETS: usize = 1 << 32;

const BucketCursorGrid = [RESIDUE_COUNT][WHEEL_STEP_COUNT]?[*]SmallSegmentBucketEntry;

const BLOCK_BYTES: usize = 8 * 1024;
const BLOCK_ALIGNMENT = std.mem.Alignment.fromByteUnits(BLOCK_BYTES);
const BUCKET_HEADER_BYTES: usize = @sizeOf([*]SmallSegmentBucketEntry) + @sizeOf(?*anyopaque);
const BUCKET_LEN: usize = (BLOCK_BYTES - BUCKET_HEADER_BYTES) / @sizeOf(SmallSegmentBucketEntry);
const BUCKET_PAD_BYTES: usize = BLOCK_BYTES - BUCKET_HEADER_BYTES - BUCKET_LEN * @sizeOf(SmallSegmentBucketEntry);

const Bucket = extern struct {
    end: [*]SmallSegmentBucketEntry,
    next: ?*Bucket,
    itemsBytes: [BUCKET_LEN * @sizeOf(SmallSegmentBucketEntry) + BUCKET_PAD_BYTES]u8 align(@alignOf(SmallSegmentBucketEntry)) = undefined,

    fn items(self: *Bucket) [*]SmallSegmentBucketEntry {
        return @ptrCast(&self.itemsBytes);
    }
};

comptime {
    if (@sizeOf(Bucket) != BLOCK_BYTES) @compileError("Bucket must be exactly BLOCK_BYTES for the pointer-arithmetic fullness/ownership tricks below to be valid");
    if (!std.math.isPowerOfTwo(BLOCK_BYTES)) @compileError("BLOCK_BYTES must be a power of two");
    if (BUCKET_PAD_BYTES != 0) @compileError("record size must divide the block items region exactly, or the write pointer skips the block boundary");
    if (@sizeOf(SmallSegmentBucketEntry) != 8) @compileError("the compact record must be 8 bytes");
}

fn isFullBucket(ptr: [*]SmallSegmentBucketEntry) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

fn bucketOf(ptr: [*]SmallSegmentBucketEntry) *Bucket {
    var address = @intFromPtr(ptr);
    address -= 1;
    address -= address % BLOCK_BYTES;
    return @ptrFromInt(address);
}

fn maxBucketsFor(population: usize) usize {
    return 2 * CELL_COUNT + (population + BUCKET_LEN - 1) / BUCKET_LEN + 1;
}

pub const SmallSegmentSievePrimes = struct {
    maps: BucketCursorGrid,
    mapsSwap: BucketCursorGrid,

    bucketFreeBlocks: ?*Bucket,
    bucketPool: []align(BLOCK_BYTES) Bucket,
    bucketNextUnclaimed: usize,

    pending: []SmallSegmentPendingEntry,
    pendingStart: usize,
    pendingCount: usize,
    pendingSorted: bool,

    pub fn init(allocator: std.mem.Allocator, layout: Layout, maxPrime: usize) !SmallSegmentSievePrimes {
        const emptyRow: [WHEEL_STEP_COUNT]?[*]SmallSegmentBucketEntry = @splat(null);
        const maps: BucketCursorGrid = @splat(emptyRow);

        const population: usize = @intCast(Estimates.primeCountInRangeUpperBound(layout.smallL2StrideThreshold, @min(maxPrime, layout.smallSegmentThreshold)));
        const bucketPool = try allocator.alignedAlloc(Bucket, BLOCK_ALIGNMENT, maxBucketsFor(population));
        errdefer allocator.free(bucketPool);
        const pending = try allocator.alloc(SmallSegmentPendingEntry, population);

        // The kernel's wrap-around store is bounded by one wheel-30 advance of
        // the tier's largest prime; the other stores are bounded by the
        // PENDING_HORIZON_BUCKETS checks in add()/apply(). Pin the first here.
        std.debug.assert(LayoutMod.maxWheel30Advance(layout.smallSegmentThreshold) < PENDING_HORIZON_BUCKETS);

        return SmallSegmentSievePrimes{
            .maps = maps,
            .mapsSwap = maps,
            .bucketFreeBlocks = null,
            .bucketPool = bucketPool,
            .bucketNextUnclaimed = 0,
            .pending = pending,
            .pendingStart = 0,
            .pendingCount = 0,
            .pendingSorted = false,
        };
    }

    pub fn deinit(self: *SmallSegmentSievePrimes, allocator: std.mem.Allocator) void {
        allocator.free(self.bucketPool);
        if (self.pending.len != 0) allocator.free(self.pending);
    }

    fn freeBucket(self: *SmallSegmentSievePrimes, b: *Bucket) void {
        b.next = self.bucketFreeBlocks;
        self.bucketFreeBlocks = b;
    }

    noinline fn addBucket(self: *SmallSegmentSievePrimes, sealedWritePos: ?[*]SmallSegmentBucketEntry) [*]SmallSegmentBucketEntry {
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

    inline fn storeInBucket(self: *SmallSegmentSievePrimes, cursor: *?[*]SmallSegmentBucketEntry, entry: SmallSegmentBucketEntry) void {
        const wp = cursor.* orelse self.addBucket(null);
        wp[0] = entry;
        const next = wp + 1;
        cursor.* = if (isFullBucket(next)) self.addBucket(next) else next;
    }

    pub fn add(
        self: *SmallSegmentSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrime: SievePrime,
        storeForNextSegment: bool,
    ) void {
        const position = sievePrime.currentBucketIndex;
        // The grid this add's record will be read with: the query's adds run
        // before the first apply (same segment base), the self-sieve's adds
        // run after its crossOff (next segment base).
        const nextBase = if (storeForNextSegment) bucketsEndExclusive else bucketsStart;

        if (position < bucketsEndExclusive) {
            // Due in this segment: sieve now. The self-sieve's discovery scan
            // reads the segment right after each add.
            var entry = SmallSegmentBucketEntry{
                .localOffset = @intCast(position - bucketsStart),
                .initialBucketIndex = sievePrime.initialBucketIndex,
            };
            switch (sievePrime.initialInBucketIndex) {
                inline else => |ari| switch (sievePrime.wheelStepIndex) {
                    inline else => |wsi| applySievePrimeIntoSegmentSmallSegment(
                        ari,
                        wsi,
                        buckets,
                        bucketsStart,
                        bucketsEndExclusive,
                        &entry,
                        self,
                        if (storeForNextSegment) &self.maps else &self.mapsSwap,
                    ),
                },
            }
            return;
        }

        std.debug.assert(position >= nextBase);
        if (position - nextBase >= PENDING_HORIZON_BUCKETS) {
            std.debug.assert(self.pendingCount < self.pending.len);
            self.pending[self.pendingCount] = .{
                .bucketIndex = position,
                .initialBucketIndex = sievePrime.initialBucketIndex,
                .cell = @as(u8, sievePrime.initialInBucketIndex) * WHEEL_STEP_COUNT + sievePrime.wheelStepIndex,
            };
            self.pendingCount += 1;
            return;
        }

        self.storeInBucket(&self.maps[sievePrime.initialInBucketIndex][sievePrime.wheelStepIndex], .{
            .localOffset = @intCast(position - nextBase),
            .initialBucketIndex = sievePrime.initialBucketIndex,
        });
    }

    pub noinline fn apply(
        self: *SmallSegmentSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        const bucketCount = bucketsEndExclusive - bucketsStart;

        // Drain the pending prefix that has come within u32 range. The list is
        // sorted once: start>0 queries can be non-monotone, while the
        // self-sieve appends p^2 first multiples in order.
        if (!self.pendingSorted) {
            var sorted = true;
            var index: usize = 1;
            while (index < self.pendingCount) : (index += 1) {
                if (self.pending[index].bucketIndex < self.pending[index - 1].bucketIndex) {
                    sorted = false;
                    break;
                }
            }
            if (!sorted) std.mem.sort(SmallSegmentPendingEntry, self.pending[0..self.pendingCount], {}, lessThanByBucketIndex);
            self.pendingSorted = true;
        }
        const horizon = bucketsStart + PENDING_HORIZON_BUCKETS;
        while (self.pendingStart < self.pendingCount and self.pending[self.pendingStart].bucketIndex < horizon) {
            const pendingEntry = self.pending[self.pendingStart];
            self.pendingStart += 1;
            std.debug.assert(pendingEntry.bucketIndex >= bucketsStart);
            self.storeInBucket(
                &self.maps[pendingEntry.cell / WHEEL_STEP_COUNT][pendingEntry.cell % WHEEL_STEP_COUNT],
                .{
                    .localOffset = @intCast(pendingEntry.bucketIndex - bucketsStart),
                    .initialBucketIndex = pendingEntry.initialBucketIndex,
                },
            );
        }

        inline for (0..RESIDUE_COUNT) |ari| {
            inline for (0..WHEEL_STEP_COUNT) |wsi| {
                if (self.maps[ari][wsi]) |wp| {
                    const bucket = bucketOf(wp);
                    bucket.end = wp;
                    self.maps[ari][wsi] = null;

                    var block: ?*Bucket = bucket;
                    while (block) |b| {
                        const items = b.items();
                        const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(SmallSegmentBucketEntry);

                        for (items[0..fill]) |*sievePrime| {
                            if (sievePrime.localOffset < bucketCount) {
                                applySievePrimeIntoSegmentSmallSegment(
                                    ari,
                                    wsi,
                                    buckets,
                                    bucketsStart,
                                    bucketsEndExclusive,
                                    sievePrime,
                                    self,
                                    &self.mapsSwap,
                                );
                            } else {
                                self.storeInBucket(&self.mapsSwap[ari][wsi], .{
                                    .localOffset = sievePrime.localOffset - @as(u32, @intCast(bucketCount)),
                                    .initialBucketIndex = sievePrime.initialBucketIndex,
                                });
                            }
                        }

                        const next = b.next;
                        self.freeBucket(b);
                        block = next;
                    }
                }
            }
        }

        std.mem.swap(BucketCursorGrid, &self.maps, &self.mapsSwap);
    }

    inline fn applySievePrimeIntoSegmentSmallSegment(
        comptime initialInBucketIndex: u3,
        comptime wheelStepIndex: u3,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrime: *SmallSegmentBucketEntry,
        self: *SmallSegmentSievePrimes,
        nextSegmentGrid: *BucketCursorGrid,
    ) void {
        const bucketCount = bucketsEndExclusive - bucketsStart;
        const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
        var currentBucketIndex: usize = sievePrime.localOffset;

        @setEvalBranchQuota(1 << 20);
        const accumulatedWheelPattern: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]Comptimes.WheelStep = comptime blk: {
            var wheelPattern = Comptimes.WHEEL_PATTERNS[initialInBucketIndex];
            std.mem.rotate(Comptimes.WheelStep, wheelPattern[0..], wheelStepIndex);
            var accumulatedWheelPattern_: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]Comptimes.WheelStep = undefined;
            accumulatedWheelPattern_[0].divMultiplicator = 0;
            accumulatedWheelPattern_[0].residueAddend = 0;
            for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |stepIndex| {
                accumulatedWheelPattern_[stepIndex + 1].divMultiplicator =
                    accumulatedWheelPattern_[stepIndex].divMultiplicator + wheelPattern[stepIndex].divMultiplicator;
                accumulatedWheelPattern_[stepIndex + 1].residueAddend =
                    accumulatedWheelPattern_[stepIndex].residueAddend + wheelPattern[stepIndex].residueAddend;
                accumulatedWheelPattern_[stepIndex].bitMask = wheelPattern[stepIndex].bitMask;
            }
            break :blk accumulatedWheelPattern_;
        };

        var accumulatedBucketIndexAdvance: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]usize = undefined;
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count + 1, accumulatedWheelPattern) |stepIndex, accumulatedWheelStep| {
            accumulatedBucketIndexAdvance[stepIndex] =
                initialBucketIndex * accumulatedWheelStep.divMultiplicator + accumulatedWheelStep.residueAddend;
        }

        while (currentBucketIndex + accumulatedBucketIndexAdvance[7] < bucketCount) {
            inline for (
                accumulatedBucketIndexAdvance[0..Comptimes.ADMISSIBLE_RESIDUES.count],
                accumulatedWheelPattern[0..Comptimes.ADMISSIBLE_RESIDUES.count],
            ) |abia, ws| {
                buckets[currentBucketIndex + abia] &= ws.bitMask;
            }
            currentBucketIndex += accumulatedBucketIndexAdvance[8];
        }

        const exitStep: usize = blk: {
            inline for (
                0..Comptimes.ADMISSIBLE_RESIDUES.count,
                accumulatedBucketIndexAdvance[0..Comptimes.ADMISSIBLE_RESIDUES.count],
                accumulatedWheelPattern[0..Comptimes.ADMISSIBLE_RESIDUES.count],
            ) |wsi, abia, ws| {
                if (currentBucketIndex + abia < bucketCount) {
                    buckets[currentBucketIndex + abia] &= ws.bitMask;
                } else {
                    break :blk wsi;
                }
            }
            unreachable;
        };

        const newWheelStepIndex = wheelStepIndex +% @as(u3, @intCast(exitStep));
        const updated = SmallSegmentBucketEntry{
            .localOffset = @intCast(currentBucketIndex + accumulatedBucketIndexAdvance[exitStep] - bucketCount),
            .initialBucketIndex = sievePrime.initialBucketIndex,
        };
        self.storeInBucket(&nextSegmentGrid[initialInBucketIndex][newWheelStepIndex], updated);
    }
};
