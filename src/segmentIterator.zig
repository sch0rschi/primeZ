const std = @import("std");
const Types = @import("types.zig");
const Comptimes = @import("comptimes.zig");
const Utils = @import("utils.zig");
const config = @import("primeZConfig");

const ALIGNMENT = std.mem.Alignment.@"8";
const SEGMENT_ELEMS: usize = 1024 * config.l1_cache_size;
const BATCH_SIZE: usize = config.general_purpose_register_count / 5;

const Segment = struct {
    containerStart: usize,
    containerEndExclusive: usize,
    containers: []align(8) u64,
};

pub const SievePrime = struct {
    currentBucketIndex: usize,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex: u3,

    pub fn from(bucketIndex: usize, inBucketIndex: u3) SievePrime {
        const prime =
            Utils.admissibleNumberFromBitIndex(@bitSizeOf(Types.SIEVE_BUCKET_TYPE) * bucketIndex + inBucketIndex);
        const primeSquareBitIndex = Utils.admissibleNumberToBitIndex(prime * prime);
        const primeSquareBucketIndex = primeSquareBitIndex / 8;

        const previousPrimeSquareMultipleMod = prime % Comptimes.WHEEL_CIRCUMFERENCE;
        const previousPrimeSquareWheelStepIndex =
            Comptimes.ADMISSIBLE_RESIDUES.reverseMap[previousPrimeSquareMultipleMod];

        return SievePrime{
            .currentBucketIndex = primeSquareBucketIndex,
            .initialBucketIndex = @intCast(bucketIndex),
            .initialInBucketIndex = inBucketIndex,
            .wheelStepIndex = @intCast(previousPrimeSquareWheelStepIndex),
        };
    }
};

pub const SegmentIterator = struct {
    allocator: std.mem.Allocator,

    buckets: []align(8) Types.SIEVE_BUCKET_TYPE,
    containers: []align(8) Types.SIEVE_CONTAINER_TYPE,

    bucketsLength: usize,
    rootBucketIndexExclusive: usize,

    bucketsStart: usize,
    bucketsEndExclusive: usize,
    started: bool,

    smallSievePrimesMap: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime),
    smallSievePrimesActiveCounts: [Comptimes.ADMISSIBLE_RESIDUES.count]usize,

    sievePrimes: std.ArrayList(SievePrime),
    sievePrimesActiveCount: usize,

    largeSievePrimes: std.ArrayList(SievePrime),
    largeSievePrimesActiveCount: usize,

    pub fn init(allocator: std.mem.Allocator, primeInclusive: usize) !SegmentIterator {
        const bucketsLength = ALIGNMENT.forward(Utils.getSieveLength(primeInclusive));
        const buckets = try allocator.alignedAlloc(
            Types.SIEVE_BUCKET_TYPE,
            ALIGNMENT,
            @min(SEGMENT_ELEMS, bucketsLength),
        );

        const containers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(buckets));

        @memset(buckets, std.math.maxInt(Types.SIEVE_BUCKET_TYPE));
        buckets[0] = Comptimes.FIRST_BUCKET;

        const rootPrime = std.math.sqrt(primeInclusive);
        const rootBucketExclusive = Utils.getSieveLength(rootPrime);

        var smallSievePrimesMap: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime) = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            smallSievePrimesMap[ari] = try std.ArrayList(SievePrime).initCapacity(allocator, 0);
        }

        return SegmentIterator{
            .allocator = allocator,

            .buckets = buckets,
            .containers = containers,

            .bucketsLength = bucketsLength,
            .rootBucketIndexExclusive = rootBucketExclusive,

            .bucketsStart = 0,
            .bucketsEndExclusive = @min(SEGMENT_ELEMS, bucketsLength),
            .started = false,

            .smallSievePrimesMap = smallSievePrimesMap,
            .smallSievePrimesActiveCounts = .{0} ** Comptimes.ADMISSIBLE_RESIDUES.count,

            .largeSievePrimes = try std.ArrayList(SievePrime).initCapacity(allocator, 0),
            .largeSievePrimesActiveCount = 0,

            .sievePrimes = try std.ArrayList(SievePrime).initCapacity(allocator, 0),
            .sievePrimesActiveCount = 0,
        };
    }

    pub fn deinit(self: *SegmentIterator) void {
        self.allocator.free(self.buckets);
        for (&self.smallSievePrimesMap) |*smallSievePrimes| {
            smallSievePrimes.deinit(self.allocator);
        }
        self.largeSievePrimes.deinit(self.allocator);
        self.sievePrimes.deinit(self.allocator);
    }

    /// Computes the next segment and returns a view over it,
    /// or `null` once the sieve range has been reached.
    pub fn next(self: *SegmentIterator) !?Segment {
        if (self.bucketsStart >= self.bucketsLength) {
            return null;
        }

        if (self.started) {
            self.bucketsStart += SEGMENT_ELEMS;
            self.bucketsEndExclusive = @min(self.bucketsStart + SEGMENT_ELEMS, self.bucketsLength);
            if (self.bucketsStart >= self.bucketsLength) {
                return null;
            }
            @memset(self.buckets, std.math.maxInt(Types.SIEVE_BUCKET_TYPE));
        }
        self.started = true;

        self.applySmallSievePrimes();
        applyLargeSievePrimesBatch(BATCH_SIZE, self.buckets, self.bucketsStart, self.bucketsEndExclusive, self.sievePrimes, &self.sievePrimesActiveCount);
        applyLargeSievePrimesBatch(2, self.buckets, self.bucketsStart, self.bucketsEndExclusive, self.largeSievePrimes, &self.largeSievePrimesActiveCount);

        if (self.bucketsStart < self.rootBucketIndexExclusive) {
            try self.findSievePrimesInSegment();
        }

        return Segment{
            .containerStart = self.bucketsStart / 8,
            .containerEndExclusive = self.bucketsEndExclusive / 8,
            .containers = self.containers,
        };
    }

    fn findSievePrimesInSegment(self: *SegmentIterator) !void {
        for (self.bucketsStart..@min(self.rootBucketIndexExclusive, self.bucketsEndExclusive)) |bucketIndex| {
            var bucketWorkingCopy = self.buckets[bucketIndex];
            while (bucketWorkingCopy != 0) {
                const inBucketIndex: u3 = Utils.lsb(bucketWorkingCopy);
                const sievePrime = SievePrime.from(bucketIndex, inBucketIndex);

                if (15 * bucketIndex * 8 <= SEGMENT_ELEMS) { // the square of large primes must not fall in the same segment
                    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                        if (ari == inBucketIndex) {
                            try self.smallSievePrimesMap[ari].append(self.allocator, sievePrime);
                            if (sievePrime.currentBucketIndex < self.bucketsEndExclusive) {
                                applySievePrimeIntoSegment(ari, self.buckets, self.bucketsStart, self.bucketsEndExclusive, &self.smallSievePrimesMap[ari].items[self.smallSievePrimesMap[ari].items.len - 1]);
                            }
                        }
                    }
                } else if (3 * bucketIndex < 2 * SEGMENT_ELEMS) {
                    try self.sievePrimes.append(self.allocator, sievePrime);
                } else {
                    try self.largeSievePrimes.append(self.allocator, sievePrime);
                }

                bucketWorkingCopy &= bucketWorkingCopy - 1;
            }
        }
    }

    fn applySmallSievePrimes(self: *SegmentIterator) void {
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            const smallSievePrimes = self.smallSievePrimesMap[ari];
            for (smallSievePrimes.items[0..self.smallSievePrimesActiveCounts[ari]]) |*activeSmallSievePrime| {
                if (activeSmallSievePrime.currentBucketIndex < self.bucketsEndExclusive) {
                    applySievePrimeIntoSegment(ari, self.buckets, self.bucketsStart, self.bucketsEndExclusive, activeSmallSievePrime);
                }
            }
            for (smallSievePrimes.items[self.smallSievePrimesActiveCounts[ari]..]) |*inactiveSmallSievePrime| {
                if (inactiveSmallSievePrime.currentBucketIndex < self.bucketsEndExclusive) {
                    applySievePrimeIntoSegment(ari, self.buckets, self.bucketsStart, self.bucketsEndExclusive, inactiveSmallSievePrime);
                    self.smallSievePrimesActiveCounts[ari] += 1;
                } else {
                    break;
                }
            }
        }
    }

    fn applyLargeSievePrimesBatch(
        comptime n: usize,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        largeSievePrimes: std.ArrayList(SievePrime),
        largeSievePrimesActiveCount: *usize,
    ) void {
        var readySievePrimes: [n]*SievePrime = undefined;
        var readySievePrimesCount: usize = 0;

        for (largeSievePrimes.items[0..largeSievePrimesActiveCount.*]) |*activeSievePrime| {
            if (activeSievePrime.currentBucketIndex < bucketsEndExclusive) {
                readySievePrimes[readySievePrimesCount] = activeSievePrime;
                readySievePrimesCount += 1;
                if (readySievePrimesCount == n) {
                    applyNSievePrimesIntoSegment(n, buckets, bucketsStart, bucketsEndExclusive, &readySievePrimes);
                    readySievePrimesCount = 0;
                }
            }
        }

        for (largeSievePrimes.items[largeSievePrimesActiveCount.*..]) |*inactiveSievePrime| {
            if (inactiveSievePrime.currentBucketIndex < bucketsEndExclusive) {
                readySievePrimes[readySievePrimesCount] = inactiveSievePrime;
                readySievePrimesCount += 1;
                largeSievePrimesActiveCount.* += 1;
                if (readySievePrimesCount == n) {
                    applyNSievePrimesIntoSegment(n, buckets, bucketsStart, bucketsEndExclusive, &readySievePrimes);
                    readySievePrimesCount = 0;
                }
            } else {
                break;
            }
        }

        if (readySievePrimesCount > 0) { // Leftover 1..n-1 primes: fall back to smaller batch.
            inline for (0..BATCH_SIZE) |leftoverCount| {
                if (leftoverCount == readySievePrimesCount) {
                    applyNSievePrimesIntoSegment(leftoverCount, buckets, bucketsStart, bucketsEndExclusive, readySievePrimes[0..leftoverCount]);
                    break;
                }
            }
        }
    }

    inline fn applySievePrimeIntoSegment(
        comptime inBucketIndex: u3,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrime: *SievePrime,
    ) void {
        const wheelPattern = &Comptimes.WHEEL_PATTERNS[inBucketIndex];

        const bucketCount = bucketsEndExclusive - bucketsStart;
        const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
        const wheelStepIndex = @as(usize, sievePrime.wheelStepIndex);
        var currentBucketIndex = sievePrime.currentBucketIndex - bucketsStart;

        var concreteBucketAdvance: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = undefined;
        var bucketAdvance7: usize = 0;
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |step| {
            const stepAdvance = @as(usize, wheelPattern[step].divMultiplicator) * initialBucketIndex +
                @as(usize, wheelPattern[step].residueAddend);
            concreteBucketAdvance[step] = stepAdvance;
            bucketAdvance7 += stepAdvance;
        }
        bucketAdvance7 -=
            @as(usize, wheelPattern[Comptimes.ADMISSIBLE_RESIDUES.count - 1].divMultiplicator) * initialBucketIndex +
            @as(usize, wheelPattern[Comptimes.ADMISSIBLE_RESIDUES.count - 1].residueAddend);

        if (wheelStepIndex > 0) {
            inline for (1..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                if (wheelStepIndex <= ari) {
                    if (currentBucketIndex < bucketCount) {
                        buckets[currentBucketIndex] &= wheelPattern[ari].bitMask;
                        currentBucketIndex += concreteBucketAdvance[ari];
                    } else {
                        sievePrime.currentBucketIndex = currentBucketIndex + bucketsStart;
                        sievePrime.wheelStepIndex = ari;
                        return;
                    }
                }
            }
        }

        while (currentBucketIndex + bucketAdvance7 < bucketCount) {
            inline for (0.., wheelPattern) |si, wheelStep| {
                buckets[currentBucketIndex] &= wheelStep.bitMask;
                currentBucketIndex += concreteBucketAdvance[si];
            }
        }

        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            if (currentBucketIndex < bucketCount) {
                buckets[currentBucketIndex] &= wheelPattern[ari].bitMask;
                currentBucketIndex += concreteBucketAdvance[ari];
            } else {
                sievePrime.currentBucketIndex = currentBucketIndex + bucketsStart;
                sievePrime.wheelStepIndex = ari;
                return;
            }
        } else {
            unreachable;
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

        // Fast path: all n primes still have room in this segment.
        var allWithinBucketEndExclusive = true;
        while (allWithinBucketEndExclusive) {
            inline for (0..n) |spi| {
                const step = &wheelPatterns[spi][wheelStepIndex[spi]];
                buckets[currentBucketIndices[spi]] &= step.bitMask;
                currentBucketIndices[spi] += initialBucketIndices[spi] * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                wheelStepIndex[spi] += 1;
                wheelStepIndex[spi] %= Comptimes.ADMISSIBLE_RESIDUES.count;
                allWithinBucketEndExclusive &= currentBucketIndices[spi] < bucketCount;
            }
        }

        // Tail: each non exhausted sieve prime finishes alone.
        inline for (0..n) |spi| {
            while (currentBucketIndices[spi] < bucketCount) {
                const step = wheelPatterns[spi][wheelStepIndex[spi]];
                buckets[currentBucketIndices[spi]] &= step.bitMask;
                currentBucketIndices[spi] += initialBucketIndices[spi] * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                wheelStepIndex[spi] += 1;
                wheelStepIndex[spi] %= Comptimes.ADMISSIBLE_RESIDUES.count;
            }
            sievePrimes[spi].currentBucketIndex = currentBucketIndices[spi] + bucketsStart;
            sievePrimes[spi].wheelStepIndex = @intCast(wheelStepIndex[spi]);
        }
    }
};
