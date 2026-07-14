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

    mediumSievePrimes: std.ArrayList(SievePrime),
    mediumSievePrimesActiveCount: usize,
    mediumSievePrimesMaps: [Comptimes.ADMISSIBLE_RESIDUES.count][@bitSizeOf(Types.SIEVE_BUCKET_TYPE)]std.ArrayList(SievePrime),
    mediumSievePrimesMapsSwap: [Comptimes.ADMISSIBLE_RESIDUES.count][@bitSizeOf(Types.SIEVE_BUCKET_TYPE)]std.ArrayList(SievePrime),

    largeSievePrimes: std.ArrayList(SievePrime),
    largeSievePrimesActiveCount: usize,

    pub fn init(allocator: std.mem.Allocator, lowerLimitInclusive: usize) !SegmentIterator {
        const bucketsLength = ALIGNMENT.forward(Utils.getSieveLength(lowerLimitInclusive));
        const buckets = try allocator.alignedAlloc(
            Types.SIEVE_BUCKET_TYPE,
            ALIGNMENT,
            @min(SEGMENT_ELEMS, bucketsLength),
        );

        const containers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(buckets));

        @memset(buckets, std.math.maxInt(Types.SIEVE_BUCKET_TYPE));
        buckets[0] = Comptimes.FIRST_BUCKET;

        const rootPrime = std.math.sqrt(lowerLimitInclusive);
        const rootBucketExclusive = Utils.getSieveLength(rootPrime);

        var smallSievePrimesMap: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime) = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            smallSievePrimesMap[ari] = try std.ArrayList(SievePrime).initCapacity(allocator, 0);
        }

        var mediumSievePrimesMap: [Comptimes.ADMISSIBLE_RESIDUES.count][@bitSizeOf(Types.SIEVE_BUCKET_TYPE)]std.ArrayList(SievePrime) = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            for (0..@bitSizeOf(Types.SIEVE_BUCKET_TYPE)) |wsi| {
                mediumSievePrimesMap[ari][wsi] = try std.ArrayList(SievePrime).initCapacity(allocator, 0);
            }
        }

        var mediumSievePrimesMapsSwap: [Comptimes.ADMISSIBLE_RESIDUES.count][@bitSizeOf(Types.SIEVE_BUCKET_TYPE)]std.ArrayList(SievePrime) = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            for (0..@bitSizeOf(Types.SIEVE_BUCKET_TYPE)) |wsi| {
                mediumSievePrimesMapsSwap[ari][wsi] = try std.ArrayList(SievePrime).initCapacity(allocator, 0);
            }
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

            .mediumSievePrimes = try std.ArrayList(SievePrime).initCapacity(allocator, 0),
            .mediumSievePrimesActiveCount = 0,
            .mediumSievePrimesMaps = mediumSievePrimesMap,
            .mediumSievePrimesMapsSwap = mediumSievePrimesMapsSwap,

            .largeSievePrimes = try std.ArrayList(SievePrime).initCapacity(allocator, 0),
            .largeSievePrimesActiveCount = 0,
        };
    }

    pub fn deinit(self: *SegmentIterator) void {
        self.allocator.free(self.buckets);
        for (&self.smallSievePrimesMap) |*smallSievePrimes| {
            smallSievePrimes.deinit(self.allocator);
        }
        self.mediumSievePrimes.deinit(self.allocator);
        for (&self.mediumSievePrimesMaps) |*mediumSievePrimesMap| {
            for (mediumSievePrimesMap) |*mediumSievePrimes| {
                mediumSievePrimes.deinit(self.allocator);
            }
        }
        for (&self.mediumSievePrimesMapsSwap) |*mediumSievePrimesMapSwpap| {
            for (mediumSievePrimesMapSwpap) |*mediumSievePrimesSwap| {
                mediumSievePrimesSwap.deinit(self.allocator);
            }
        }
        self.largeSievePrimes.deinit(self.allocator);
        self.* = undefined;
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
        try self.activateMediumSievePrimes();
        try self.applyMediumSievePrimes();
        applyLargeSievePrimesBatch(
            2,
            self.buckets,
            self.bucketsStart,
            self.bucketsEndExclusive,
            self.largeSievePrimes,
            &self.largeSievePrimesActiveCount,
        );

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
                var sievePrime = SievePrime.from(bucketIndex, inBucketIndex);

                if (120 * bucketIndex < SEGMENT_ELEMS) {
                    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                        if (ari == inBucketIndex) {
                            if (sievePrime.currentBucketIndex < self.bucketsEndExclusive) {
                                applySmallSievePrimeIntoSegment(
                                    ari,
                                    self.buckets,
                                    self.bucketsStart,
                                    self.bucketsEndExclusive,
                                    &sievePrime,
                                );
                            }
                            try self.smallSievePrimesMap[ari].append(self.allocator, sievePrime);
                        }
                    }
                } else if (true) {
                    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                        if (ari == inBucketIndex) {
                            if (sievePrime.currentBucketIndex < self.bucketsEndExclusive) {
                                applySmallSievePrimeIntoSegment(
                                    ari,
                                    self.buckets,
                                    self.bucketsStart,
                                    self.bucketsEndExclusive,
                                    &sievePrime,
                                );
                            }
                        }
                    }
                    try self.mediumSievePrimes.append(self.allocator, sievePrime);
                } else {
                    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                        if (ari == inBucketIndex) {
                            if (sievePrime.currentBucketIndex < self.bucketsEndExclusive) {
                                applySmallSievePrimeIntoSegment(
                                    ari,
                                    self.buckets,
                                    self.bucketsStart,
                                    self.bucketsEndExclusive,
                                    &sievePrime,
                                );
                            }
                        }
                    }
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
                    applySmallSievePrimeIntoSegment(
                        ari,
                        self.buckets,
                        self.bucketsStart,
                        self.bucketsEndExclusive,
                        activeSmallSievePrime,
                    );
                }
            }
            for (smallSievePrimes.items[self.smallSievePrimesActiveCounts[ari]..]) |*inactiveSmallSievePrime| {
                if (inactiveSmallSievePrime.currentBucketIndex < self.bucketsEndExclusive) {
                    applySmallSievePrimeIntoSegment(
                        ari,
                        self.buckets,
                        self.bucketsStart,
                        self.bucketsEndExclusive,
                        inactiveSmallSievePrime,
                    );
                    self.smallSievePrimesActiveCounts[ari] += 1;
                } else {
                    break;
                }
            }
        }
    }

    fn activateMediumSievePrimes(self: *SegmentIterator) !void {
        for (self.mediumSievePrimes.items[self.mediumSievePrimesActiveCount..]) |mediumSievePrime| {
            if (true or mediumSievePrime.currentBucketIndex >= self.bucketsEndExclusive) {
                try self.mediumSievePrimesMaps[mediumSievePrime.initialInBucketIndex][mediumSievePrime.wheelStepIndex].append(self.allocator, mediumSievePrime);
                self.mediumSievePrimesActiveCount += 1;
            } else {
                break;
            }
        }
    }

    fn applyMediumSievePrimes(self: *SegmentIterator) !void {
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            inline for (0..@bitSizeOf(Types.SIEVE_BUCKET_TYPE)) |wsi| {
                for (self.mediumSievePrimesMaps[ari][wsi].items) |*mediumSievePrime| {
                    applyMediumSievePrimeIntoSegment(
                        ari,
                        wsi,
                        self.buckets,
                        self.bucketsStart,
                        self.bucketsEndExclusive,
                        mediumSievePrime,
                    );
                    try self.mediumSievePrimesMapsSwap[ari][mediumSievePrime.wheelStepIndex].append(
                        self.allocator,
                        mediumSievePrime.*,
                    );
                }
                self.mediumSievePrimesMaps[ari][wsi].clearRetainingCapacity();
            }
        }

        std.mem.swap(
            [Comptimes.ADMISSIBLE_RESIDUES.count][@bitSizeOf(Types.SIEVE_BUCKET_TYPE)]std.ArrayList(SievePrime),
            &self.mediumSievePrimesMaps,
            &self.mediumSievePrimesMapsSwap,
        );
    }

    fn applyLargeSievePrimesBatch(
        comptime batchSize: usize,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        largeSievePrimes: std.ArrayList(SievePrime),
        largeSievePrimesActiveCount: *usize,
    ) void {
        var readySievePrimes: [batchSize]*SievePrime = undefined;
        var readySievePrimesCount: usize = 0;

        for (largeSievePrimes.items[0..largeSievePrimesActiveCount.*]) |*activeSievePrime| {
            if (activeSievePrime.currentBucketIndex < bucketsEndExclusive) {
                readySievePrimes[readySievePrimesCount] = activeSievePrime;
                readySievePrimesCount += 1;
                if (readySievePrimesCount == batchSize) {
                    applyNSievePrimesIntoSegment(
                        batchSize,
                        buckets,
                        bucketsStart,
                        bucketsEndExclusive,
                        &readySievePrimes,
                    );
                    readySievePrimesCount = 0;
                }
            }
        }

        for (largeSievePrimes.items[largeSievePrimesActiveCount.*..]) |*inactiveSievePrime| {
            if (inactiveSievePrime.currentBucketIndex < bucketsEndExclusive) {
                readySievePrimes[readySievePrimesCount] = inactiveSievePrime;
                readySievePrimesCount += 1;
                largeSievePrimesActiveCount.* += 1;
                if (readySievePrimesCount == batchSize) {
                    applyNSievePrimesIntoSegment(
                        batchSize,
                        buckets,
                        bucketsStart,
                        bucketsEndExclusive,
                        &readySievePrimes,
                    );
                    readySievePrimesCount = 0;
                }
            } else {
                break;
            }
        }

        if (readySievePrimesCount > 0) { // Leftover 1..n-1 primes: fall back to smaller batch.
            inline for (0..batchSize) |leftoverCount| {
                if (leftoverCount == readySievePrimesCount) {
                    applyNSievePrimesIntoSegment(
                        leftoverCount,
                        buckets,
                        bucketsStart,
                        bucketsEndExclusive,
                        readySievePrimes[0..leftoverCount],
                    );
                    break;
                }
            }
        }
    }

    inline fn applySmallSievePrimeIntoSegment(
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
        @setEvalBranchQuota(1 << 20);
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

    inline fn applyMediumSievePrimeIntoSegment(
        comptime initialInBucketIndex: u3,
        comptime wheelStepIndex: u3,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrime: *SievePrime,
    ) void {
        const bucketCount = bucketsEndExclusive - bucketsStart;
        const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
        var currentBucketIndex = sievePrime.currentBucketIndex - bucketsStart;

        @setEvalBranchQuota(1 << 20);
        const wheelPattern: [Comptimes.ADMISSIBLE_RESIDUES.count]Comptimes.WheelStep = comptime blk: {
            var wheelPattern_ = Comptimes.WHEEL_PATTERNS[initialInBucketIndex];
            std.mem.rotate(Comptimes.WheelStep, wheelPattern_[0..], wheelStepIndex);
            break :blk wheelPattern_;
        };
        const accumulatedWheelPattern: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]Comptimes.WheelStep = comptime blk: {
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

        const concreteAccumulatedWheelPattern: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]usize = blk: {
            var concreteAccumulatedWheelPattern: [Comptimes.ADMISSIBLE_RESIDUES.count + 1]usize = undefined;
            for (
                0..Comptimes.ADMISSIBLE_RESIDUES.count + 1,
                accumulatedWheelPattern,
            ) |stepIndex, accumulatedWheelStep| {
                concreteAccumulatedWheelPattern[stepIndex] =
                    initialBucketIndex * accumulatedWheelStep.divMultiplicator + accumulatedWheelStep.residueAddend;
            }
            break :blk concreteAccumulatedWheelPattern;
        };

        while (currentBucketIndex + concreteAccumulatedWheelPattern[7] < bucketCount) {
            inline for (
                concreteAccumulatedWheelPattern[0..Comptimes.ADMISSIBLE_RESIDUES.count],
                wheelPattern[0..Comptimes.ADMISSIBLE_RESIDUES.count],
            ) |concreteAccumulatedWheelStep, wheelStep| {
                buckets[currentBucketIndex + concreteAccumulatedWheelStep] &= wheelStep.bitMask;
            }
            currentBucketIndex += concreteAccumulatedWheelPattern[8];
        }

        inline for (
            0..Comptimes.ADMISSIBLE_RESIDUES.count,
            concreteAccumulatedWheelPattern[0..Comptimes.ADMISSIBLE_RESIDUES.count],
            wheelPattern[0..Comptimes.ADMISSIBLE_RESIDUES.count],
        ) |ari, concreteAccumulatedWheelStep, wheelStep| {
            if (currentBucketIndex + concreteAccumulatedWheelStep < bucketCount) {
                buckets[currentBucketIndex + concreteAccumulatedWheelStep] &= wheelStep.bitMask;
            } else {
                sievePrime.currentBucketIndex = currentBucketIndex + concreteAccumulatedWheelStep + bucketsStart;
                sievePrime.wheelStepIndex = wheelStepIndex +% @as(u3, ari);
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
                currentBucketIndices[spi] +=
                    initialBucketIndices[spi] * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
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
