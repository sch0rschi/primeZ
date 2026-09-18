const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

const WHEEL_STEP_COUNT = @bitSizeOf(Types.SIEVE_BUCKET_TYPE);
const RESIDUE_COUNT = Comptimes.ADMISSIBLE_RESIDUES.count;
const CELL_COUNT = RESIDUE_COUNT * WHEEL_STEP_COUNT;

const BucketCursorGrid = [RESIDUE_COUNT][WHEEL_STEP_COUNT]?[*]SievePrime;

const BLOCK_BYTES: usize = 8 * 1024;
const BLOCK_ALIGNMENT = std.mem.Alignment.fromByteUnits(BLOCK_BYTES);
const BUCKET_HEADER_BYTES: usize = @sizeOf([*]SievePrime) + @sizeOf(?*anyopaque);
const BUCKET_LEN: usize = (BLOCK_BYTES - BUCKET_HEADER_BYTES) / @sizeOf(SievePrime);
const BUCKET_PAD_BYTES: usize = BLOCK_BYTES - BUCKET_HEADER_BYTES - BUCKET_LEN * @sizeOf(SievePrime);

// Same pointer-alignment fullness/ownership trick as largeSievePrimes.zig's
// own Bucket - a separate copy because this tier's cells store the wide
// SievePrime (16 bytes), not large's compact bucket-resident type.
const Bucket = extern struct {
    end: [*]SievePrime,
    next: ?*Bucket,
    itemsBytes: [BUCKET_LEN * @sizeOf(SievePrime) + BUCKET_PAD_BYTES]u8 align(@alignOf(SievePrime)) = undefined,

    fn items(self: *Bucket) [*]SievePrime {
        return @ptrCast(&self.itemsBytes);
    }
};

comptime {
    if (@sizeOf(Bucket) != BLOCK_BYTES) @compileError("Bucket must be exactly BLOCK_BYTES for the pointer-arithmetic fullness/ownership tricks below to be valid");
    if (!std.math.isPowerOfTwo(BLOCK_BYTES)) @compileError("BLOCK_BYTES must be a power of two");
}

fn isFullBucket(ptr: [*]SievePrime) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

fn bucketOf(ptr: [*]SievePrime) *Bucket {
    var address = @intFromPtr(ptr);
    address -= 1;
    address -= address % BLOCK_BYTES;
    return @ptrFromInt(address);
}

// This tier's whole population, exactly (not just an upper bound) - both
// SMALL_MEDIUM_THRESHOLD and MEDIUM_LARGE_THRESHOLD are build-time
// constants, so build.zig already ran a real sieve over this tier's whole
// range to produce PRIME_COUNTS_BY_RESIDUE.
const TOTAL_POPULATION: usize = blk: {
    var total: usize = 0;
    for (BuildUtils.PRIME_COUNTS_BY_RESIDUE) |count| total += count;
    break :blk total;
};

// See largeSievePrimes.zig's maxBucketsFor for the identical derivation:
// every apply() call has CELL_COUNT cells just sealed from last round
// (each may end in one under-full block) AND CELL_COUNT cells concurrently
// being written this round (each has at most one open under-full block),
// so up to 2*CELL_COUNT blocks can sit under-full at once, on top of the
// population bound's worth of fully-packed blocks, plus one transient
// margin bucket.
fn maxBucketsFor(population: usize) usize {
    return 2 * CELL_COUNT + (population + BUCKET_LEN - 1) / BUCKET_LEN + 1;
}

pub const MediumSievePrimes = struct {
    maps: BucketCursorGrid,
    mapsSwap: BucketCursorGrid,

    bucketFreeBlocks: ?*Bucket,
    bucketPool: []align(BLOCK_BYTES) Bucket,
    bucketNextUnclaimed: usize,

    pub fn init(allocator: std.mem.Allocator) !MediumSievePrimes {
        const emptyRow = [_]?[*]SievePrime{null} ** WHEEL_STEP_COUNT;
        const maps: BucketCursorGrid = [_][WHEEL_STEP_COUNT]?[*]SievePrime{emptyRow} ** RESIDUE_COUNT;

        const bucketPool = try allocator.alignedAlloc(Bucket, BLOCK_ALIGNMENT, maxBucketsFor(TOTAL_POPULATION));

        return MediumSievePrimes{
            .maps = maps,
            .mapsSwap = maps,
            .bucketFreeBlocks = null,
            .bucketPool = bucketPool,
            .bucketNextUnclaimed = 0,
        };
    }

    pub fn deinit(self: *MediumSievePrimes, allocator: std.mem.Allocator) void {
        allocator.free(self.bucketPool);
    }

    fn freeBucket(self: *MediumSievePrimes, b: *Bucket) void {
        b.next = self.bucketFreeBlocks;
        self.bucketFreeBlocks = b;
    }

    fn addBucket(self: *MediumSievePrimes, sealedWritePos: ?[*]SievePrime) [*]SievePrime {
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

    inline fn storeInBucket(self: *MediumSievePrimes, cursor: *?[*]SievePrime, sievePrime: SievePrime) void {
        const wp = cursor.* orelse self.addBucket(null);
        wp[0] = sievePrime;
        const next = wp + 1;
        cursor.* = if (isFullBucket(next)) self.addBucket(next) else next;
    }

    // A medium prime's square is never within the segment where it was
    // discovered, so unlike SmallSievePrimes.add() there's nothing to
    // cross off yet.
    pub fn add(
        self: *MediumSievePrimes,
        sievePrime: SievePrime,
    ) void {
        self.storeInBucket(&self.maps[sievePrime.initialInBucketIndex][sievePrime.wheelStepIndex], sievePrime);
    }

    pub noinline fn apply(
        self: *MediumSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        inline for (0..RESIDUE_COUNT) |ari| {
            inline for (0..WHEEL_STEP_COUNT) |wsi| {
                if (self.maps[ari][wsi]) |wp| {
                    const bucket = bucketOf(wp);
                    bucket.end = wp;
                    self.maps[ari][wsi] = null;

                    var block: ?*Bucket = bucket;
                    while (block) |b| {
                        const items = b.items();
                        const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(SievePrime);

                        for (items[0..fill]) |*sievePrime| {
                            if (sievePrime.currentBucketIndex < bucketsEndExclusive) {
                                applySievePrimeIntoSegmentMedium(
                                    ari,
                                    wsi,
                                    buckets,
                                    bucketsStart,
                                    bucketsEndExclusive,
                                    sievePrime,
                                    self,
                                );
                            } else {
                                self.storeInBucket(&self.mapsSwap[ari][wsi], sievePrime.*);
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

    inline fn applySievePrimeIntoSegmentMedium(
        comptime initialInBucketIndex: u3,
        comptime wheelStepIndex: u3,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrime: *SievePrime,
        self: *MediumSievePrimes,
    ) void {
        const bucketCount = bucketsEndExclusive - bucketsStart;
        const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
        var currentBucketIndex = sievePrime.currentBucketIndex - bucketsStart;

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

        inline for (
            0..Comptimes.ADMISSIBLE_RESIDUES.count,
            accumulatedBucketIndexAdvance[0..Comptimes.ADMISSIBLE_RESIDUES.count],
            accumulatedWheelPattern[0..Comptimes.ADMISSIBLE_RESIDUES.count],
        ) |wsi, abia, ws| {
            if (currentBucketIndex + abia < bucketCount) {
                buckets[currentBucketIndex + abia] &= ws.bitMask;
            } else {
                const newWheelStepIndex = wheelStepIndex +% @as(u3, wsi);
                sievePrime.currentBucketIndex = currentBucketIndex + abia + bucketsStart;
                sievePrime.wheelStepIndex = newWheelStepIndex;
                self.storeInBucket(&self.mapsSwap[initialInBucketIndex][newWheelStepIndex], sievePrime.*);
                return;
            }
        } else {
            unreachable;
        }
    }
};
