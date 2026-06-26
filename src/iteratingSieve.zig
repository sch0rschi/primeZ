const std = @import("std");
const config = @import("primeZConfig");

const Estimates = @import("estimates.zig");
const Comptimes = @import("comptimes.zig");
const Utils = @import("utils.zig");
const Types = @import("types.zig");

const ALIGNMENT = std.mem.Alignment.@"8";
const SEGMENT_ELEMS: usize = 1024 * config.l1_cache_size;
const BATCH_SIZE: usize = config.general_purpose_register_count / 5;

const Segment = struct {
    wordStart: usize,
    wordEndExclusive: usize,
    words: []align(8) u64,
};

/// Computes the nth prime, zero indexed.
/// nthPrime(0) = 2.
/// nthPrime(1) = 3.
pub fn nthPrime(allocator: std.mem.Allocator, nth: usize) !Types.PRIME_TYPE {
    if (nth < Comptimes.WHEEL_PRIMES.len) {
        return Comptimes.WHEEL_PRIMES[nth];
    }

    const nthPrimeUpperBound = Estimates.nthPrimeUpperBound(nth);

    var segmentIterator = try SegmentIterator.init(allocator, nthPrimeUpperBound);
    defer segmentIterator.deinit();

    var primeCount: usize = 2;

    while (try segmentIterator.next()) |segment| {
        for (segment.wordStart..segment.wordEndExclusive, segment.words[0..segment.wordEndExclusive-segment.wordStart]) |wordIndex, word| {
            const primesInWordCount = @popCount(word);
            if (primeCount + primesInWordCount < nth) {
                primeCount += primesInWordCount;
            } else {
                var workingWord: u64 = word;
                for (0..nth - primeCount - 1) |_| { // removes all smaller primes from word
                    workingWord &= workingWord - 1;
                }
                const inWordIndex: u6 = @intCast(@ctz(workingWord));
                return Utils.admissibleNumberFromBitIndex(64 * wordIndex + inWordIndex);
            }
        }
    }

    unreachable;
}

/// get all primes with values at most limit.
/// The array is to be freed by the caller.
pub fn getPrimes(allocator: std.mem.Allocator, limit: Types.PRIME_TYPE) ![]Types.PRIME_TYPE {
    if (limit < 2) {
        return try allocator.alloc(Types.PRIME_TYPE, 0);
    } else if (limit < 3) {
        const primes = try allocator.alloc(Types.PRIME_TYPE, 1);
        @memcpy(primes, Comptimes.WHEEL_PRIMES[0..1]);
        return primes;
    } else if (limit < 5) {
        const primes = try allocator.alloc(Types.PRIME_TYPE, 2);
        @memcpy(primes, Comptimes.WHEEL_PRIMES[0..2]);
        return primes;
    } else if (limit < 7) {
        const primes = try allocator.alloc(Types.PRIME_TYPE, 3);
        @memcpy(primes, Comptimes.WHEEL_PRIMES[0..3]);
        return primes;
    }
    const amountUpperBound = Estimates.primeCountUpperBound(limit);
    var primes = try std.ArrayList(Types.PRIME_TYPE).initCapacity(allocator, amountUpperBound);
    try primes.appendSlice(allocator, &Comptimes.WHEEL_PRIMES);

    var segmentIterator = try SegmentIterator.init(allocator, limit);
    defer segmentIterator.deinit();

    outer: while (try segmentIterator.next()) |segment| {
        for (segment.wordStart..segment.wordEndExclusive, segment.words[0..segment.wordEndExclusive-segment.wordStart]) |wordIndex, word| {
            var workingWord: u64 = word;
            while (workingWord > 0) {
                const inWordIndex: u6 = @intCast(@ctz(workingWord));
                const prime = Utils.admissibleNumberFromBitIndex(64 * wordIndex + inWordIndex);
                if (prime > limit) {
                    break :outer;
                }
                try primes.append(allocator, prime);
                workingWord &= workingWord - 1;
            }
        }
    }

    return try primes.toOwnedSlice(allocator);
}

/// Sums all primes with values at most limit.
pub fn sumPrimesLimit(allocator: std.mem.Allocator, limit: Types.PRIME_TYPE) !Types.PRIME_TYPE {
    if (limit < 2) {
        return 0;
    } else if (limit < 3) {
        return 2;
    } else if (limit < 5) {
        return 5;
    } else if (limit < 7) {
        return 10;
    }
    var sum: Types.PRIME_TYPE = 10; // 2 + 3 + 5

    var segmentIterator = try SegmentIterator.init(allocator, limit);
    defer segmentIterator.deinit();

    outer: while (try segmentIterator.next()) |segment| {
        for (segment.wordStart..segment.wordEndExclusive, segment.words[0..segment.wordEndExclusive-segment.wordStart]) |wordIndex, word| {
            var workingWord: u64 = word;
            while (workingWord > 0) {
                const inWordIndex: u6 = @intCast(@ctz(workingWord));
                const prime = Utils.admissibleNumberFromBitIndex(64 * wordIndex + inWordIndex);
                if (prime > limit) {
                    break :outer;
                }
                sum += prime;
                workingWord &= workingWord - 1;
            }
        }
    }

    return sum;
}

const SegmentIterator = struct {
    allocator: std.mem.Allocator,

    sieve: []align(8) Types.SIEVE_TYPE,
    words: []align(8) u64,

    sieveLength: usize,
    rootSieveLimitExclusive: usize,

    segmentStart: usize,
    segmentEndExclusive: usize,
    started: bool,

    smallSievePrimesMap: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(Types.SievePrime),
    smallSievePrimesActiveCounts: [Comptimes.ADMISSIBLE_RESIDUES.count]usize,

    largeSievePrimes: std.ArrayList(Types.SievePrime),
    largeSievePrimesActiveCount: usize,

    sievePrimes: std.ArrayList(Types.SievePrime),
    sievePrimesActiveCount: usize,

    pub fn init(allocator: std.mem.Allocator, upperBoundInclusive: usize) !SegmentIterator {
        const sieveLength = ALIGNMENT.forward(Utils.getSieveLength(upperBoundInclusive));
        const sieve = try allocator.alignedAlloc(
            Types.SIEVE_TYPE,
            ALIGNMENT,
            @min(SEGMENT_ELEMS, sieveLength),
        );

        const bytes: []align(8) u8 = std.mem.sliceAsBytes(sieve);
        const words: []align(8) u64 = std.mem.bytesAsSlice(u64, bytes);

        @memset(sieve, std.math.maxInt(Types.SIEVE_TYPE));
        sieve[0] = Comptimes.FIRST_PRIME_SIEVE_ELEMENT;

        const rootPrime = std.math.sqrt(upperBoundInclusive);
        const rootSieveLimitExclusive = Utils.getSieveLength(rootPrime);

        var smallSievePrimesMap: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(Types.SievePrime) = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
            smallSievePrimesMap[ri] = try std.ArrayList(Types.SievePrime).initCapacity(allocator, 0);
        }

        return SegmentIterator{
            .allocator = allocator,

            .sieve = sieve,
            .words = words,

            .sieveLength = sieveLength,
            .rootSieveLimitExclusive = rootSieveLimitExclusive,

            .segmentStart = 0,
            .segmentEndExclusive = @min(SEGMENT_ELEMS, sieveLength),
            .started = false,

            .smallSievePrimesMap = smallSievePrimesMap,
            .smallSievePrimesActiveCounts = .{0} ** Comptimes.ADMISSIBLE_RESIDUES.count,

            .largeSievePrimes = try std.ArrayList(Types.SievePrime).initCapacity(allocator, 0),
            .largeSievePrimesActiveCount = 0,

            .sievePrimes = try std.ArrayList(Types.SievePrime).initCapacity(allocator, 0),
            .sievePrimesActiveCount = 0,
        };
    }

    pub fn deinit(self: *SegmentIterator) void {
        self.allocator.free(self.sieve);
        for (&self.smallSievePrimesMap) |*smallSievePrimes| {
            smallSievePrimes.deinit(self.allocator);
        }
        self.largeSievePrimes.deinit(self.allocator);
        self.sievePrimes.deinit(self.allocator);
    }

    /// Computes the next segment and returns a view over it,
    /// or `null` once the sieve range has been reached.
    pub fn next(self: *SegmentIterator) !?Segment {
        if (self.segmentStart >= self.sieveLength) {
            return null;
        }

        if (self.started) {
            self.segmentStart += SEGMENT_ELEMS;
            self.segmentEndExclusive = @min(self.segmentStart + SEGMENT_ELEMS, self.sieveLength);
            if (self.segmentStart >= self.sieveLength) {
                return null;
            }
            @memset(self.sieve, std.math.maxInt(Types.SIEVE_TYPE));
        }
        self.started = true;

        self.applySmallSievePrimes();
        self.applyLargeSievePrimesBatch(BATCH_SIZE, self.sievePrimes, &self.sievePrimesActiveCount);
        self.applyLargeSievePrimesBatch(2, self.largeSievePrimes, &self.largeSievePrimesActiveCount);

        if (self.segmentStart < self.rootSieveLimitExclusive) {
            try self.findSievePrimesInSegment();
        }

        return Segment{
            .wordStart = self.segmentStart / 8,
            .wordEndExclusive = self.segmentEndExclusive / 8,
            .words = self.words,
        };
    }

    fn findSievePrimesInSegment(self: *SegmentIterator) !void {
        for (self.segmentStart..@min(self.rootSieveLimitExclusive, self.segmentEndExclusive)) |sieveIndex| {
            var word = self.sieve[sieveIndex];
            while (word != 0) {
                const inByteIndex: u3 = Utils.lsb(word);
                const sievePrime = Utils.sievePrimeFrom(sieveIndex, inByteIndex);

                if (15 * sieveIndex * 8 <= SEGMENT_ELEMS) { // the square of large primes must not fall in the same segment
                    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
                        if (ri == inByteIndex) {
                            try self.smallSievePrimesMap[ri].append(self.allocator, sievePrime);
                            if (sievePrime.currentSieveIndex < self.segmentEndExclusive) {
                                applySievePrimeIntoSegment(self.sieve, self.segmentStart, self.segmentEndExclusive, &self.smallSievePrimesMap[ri].items[self.smallSievePrimesMap[ri].items.len - 1], ri);
                            }
                        }
                    }
                } else if (3 * sieveIndex < 2 * SEGMENT_ELEMS) {
                    try self.sievePrimes.append(self.allocator, sievePrime);
                } else {
                    try self.largeSievePrimes.append(self.allocator, sievePrime);
                }

                word &= word - 1;
            }
        }
    }

    fn applySmallSievePrimes(self: *SegmentIterator) void {
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
            const smallSievePrimes = self.smallSievePrimesMap[ri];
            for (smallSievePrimes.items[0..self.smallSievePrimesActiveCounts[ri]]) |*activeSmallSievePrime| {
                if (activeSmallSievePrime.currentSieveIndex < self.segmentEndExclusive) {
                    applySievePrimeIntoSegment(self.sieve, self.segmentStart, self.segmentEndExclusive, activeSmallSievePrime, ri);
                }
            }
            for (smallSievePrimes.items[self.smallSievePrimesActiveCounts[ri]..]) |*inactiveSmallSievePrime| {
                if (inactiveSmallSievePrime.currentSieveIndex < self.segmentEndExclusive) {
                    applySievePrimeIntoSegment(self.sieve, self.segmentStart, self.segmentEndExclusive, inactiveSmallSievePrime, ri);
                    self.smallSievePrimesActiveCounts[ri] += 1;
                } else {
                    break;
                }
            }
        }
    }

    fn applyLargeSievePrimesBatch(
        self: *SegmentIterator,
        comptime n: usize,
        largeSievePrimes: std.ArrayList(Types.SievePrime),
        largeSievePrimesActiveCount: *usize,
    ) void {
        var ready: [n]*Types.SievePrime = undefined;
        var readyCount: usize = 0;

        for (largeSievePrimes.items[0..largeSievePrimesActiveCount.*]) |*activePrime| {
            if (activePrime.currentSieveIndex < self.segmentEndExclusive) {
                ready[readyCount] = activePrime;
                readyCount += 1;
                if (readyCount == n) {
                    applyNSievePrimesIntoSegment(n, self.sieve, self.segmentStart, self.segmentEndExclusive, ready);
                    readyCount = 0;
                }
            }
        }

        for (largeSievePrimes.items[largeSievePrimesActiveCount.*..]) |*activePrime| {
            if (activePrime.currentSieveIndex < self.segmentEndExclusive) {
                largeSievePrimesActiveCount.* += 1;
                ready[readyCount] = activePrime;
                readyCount += 1;
                if (readyCount == n) {
                    applyNSievePrimesIntoSegment(n, self.sieve, self.segmentStart, self.segmentEndExclusive, ready);
                    readyCount = 0;
                }
            } else {
                break;
            }
        }

        // Leftover 1..n-1 primes: fall back one at a time.
        for (ready[0..readyCount]) |leftoverPrime| {
            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
                if (leftoverPrime.initialInByteIndex == ri) {
                    applySievePrimeIntoSegment(self.sieve, self.segmentStart, self.segmentEndExclusive, leftoverPrime, ri);
                }
            }
        }
    }

    inline fn applySievePrimeIntoSegment(
        sieve: []Types.SIEVE_TYPE,
        segmentStart: usize,
        segmentEndExclusive: usize,
        sievePrime: *Types.SievePrime,
        comptime lsb: u3,
    ) void {
        const wheelPattern = &Comptimes.WHEEL_PATTERNS[lsb];

        const sieveWindow = segmentEndExclusive - segmentStart;
        const initialSieveIndex = @as(usize, sievePrime.initialSieveIndex);
        const wheelStepIndex = @as(usize, sievePrime.wheelStepIndex);
        var currentSieveIndex = sievePrime.currentSieveIndex - segmentStart;

        var concreteStepSizes: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = undefined;
        var advanceAfter7: usize = 0;
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |step| {
            const stepAdvance = @as(usize, wheelPattern[step].divMultiplicator) * initialSieveIndex +
                @as(usize, wheelPattern[step].residueAddend);
            concreteStepSizes[step] = stepAdvance;
            advanceAfter7 += stepAdvance;
        }
        advanceAfter7 -=
            @as(usize, wheelPattern[Comptimes.ADMISSIBLE_RESIDUES.count - 1].divMultiplicator) * initialSieveIndex +
            @as(usize, wheelPattern[Comptimes.ADMISSIBLE_RESIDUES.count - 1].residueAddend);

        if (wheelStepIndex > 0) {
            inline for (1..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
                if (wheelStepIndex <= ri) {
                    if (currentSieveIndex < sieveWindow) {
                        sieve[currentSieveIndex] &= wheelPattern[ri].bitMask;
                        currentSieveIndex += concreteStepSizes[ri];
                    } else {
                        sievePrime.currentSieveIndex = currentSieveIndex + segmentStart;
                        sievePrime.wheelStepIndex = ri;
                        return;
                    }
                }
            }
        }

        while (currentSieveIndex + advanceAfter7 < sieveWindow) {
            inline for (0.., wheelPattern) |si, wheelStep| {
                sieve[currentSieveIndex] &= wheelStep.bitMask;
                currentSieveIndex += concreteStepSizes[si];
            }
        }

        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
            if (currentSieveIndex < sieveWindow) {
                sieve[currentSieveIndex] &= wheelPattern[ri].bitMask;
                currentSieveIndex += concreteStepSizes[ri];
            } else {
                sievePrime.currentSieveIndex = currentSieveIndex + segmentStart;
                sievePrime.wheelStepIndex = ri;
                return;
            }
        } else {
            unreachable;
        }
    }

    inline fn applyNSievePrimesIntoSegment(
        comptime n: usize,
        sieve: []Types.SIEVE_TYPE,
        segmentStart: usize,
        segmentEndExclusive: usize,
        sievePrimes: [n]*Types.SievePrime,
    ) void {
        const sieveWindow = segmentEndExclusive - segmentStart;

        var wheelPattern: [n]*const [Comptimes.ADMISSIBLE_RESIDUES.count]Types.WheelStep = undefined;
        var initialSieveIndex: [n]usize = undefined;
        var currentSieveIndex: [n]usize = undefined;
        var wheelStepIndex: [n]usize = undefined;

        inline for (0..n) |i| {
            wheelPattern[i] = &Comptimes.WHEEL_PATTERNS[sievePrimes[i].initialInByteIndex];
            initialSieveIndex[i] = @as(usize, sievePrimes[i].initialSieveIndex);
            currentSieveIndex[i] = sievePrimes[i].currentSieveIndex - segmentStart;
            wheelStepIndex[i] = @as(usize, sievePrimes[i].wheelStepIndex);
        }

        // Fast path: all n primes still have room in this segment.
        var allWithinSegment = true;
        while (allWithinSegment) {
            inline for (0..n) |i| {
                const step = &wheelPattern[i][wheelStepIndex[i]];
                sieve[currentSieveIndex[i]] &= step.bitMask;
                currentSieveIndex[i] += initialSieveIndex[i] * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                wheelStepIndex[i] += 1;
                wheelStepIndex[i] %= Comptimes.ADMISSIBLE_RESIDUES.count;
                allWithinSegment &= currentSieveIndex[i] < sieveWindow;
            }
        }

        // Tail: each exhausted prime finishes alone.
        inline for (0..n) |i| {
            while (currentSieveIndex[i] < sieveWindow) {
                const step = wheelPattern[i][wheelStepIndex[i]];
                sieve[currentSieveIndex[i]] &= step.bitMask;
                currentSieveIndex[i] += initialSieveIndex[i] * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                wheelStepIndex[i] += 1;
                wheelStepIndex[i] %= Comptimes.ADMISSIBLE_RESIDUES.count;
            }
            sievePrimes[i].currentSieveIndex = currentSieveIndex[i] + segmentStart;
            sievePrimes[i].wheelStepIndex = @intCast(wheelStepIndex[i]);
        }
    }
};
