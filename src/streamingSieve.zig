const std = @import("std");
const config = @import("primeZConfig");

const Estimates = @import("estimates.zig");
const Comptimes = @import("comptimes.zig");
const Utils = @import("utils.zig");
const Types = @import("types.zig");

const ALIGNMENT = std.mem.Alignment.@"8";
const SEGMENT_ELEMS: usize = 1024 * config.l1_cache_size;
const BATCH_SIZE: usize = config.general_purpose_register_count / 5;

pub const StreamingSieve = struct {
    pub fn nthPrime(allocator: std.mem.Allocator, nth: usize) !Types.PRIME_TYPE {
        if (nth < Comptimes.WHEEL_PRIMES.len) {
            return Comptimes.WHEEL_PRIMES[nth];
        }

        const upperBound = Estimates.nthPrimeUpperBound(nth);
        const sieveLength = ALIGNMENT.forward(Utils.getSieveLength(upperBound));

        const sieve = try allocator.alignedAlloc(
            Types.SIEVE_TYPE,
            ALIGNMENT,
            @min(SEGMENT_ELEMS, sieveLength),
        );
        defer allocator.free(sieve);
        const bytes = std.mem.sliceAsBytes(sieve);
        const words = std.mem.bytesAsSlice(u64, bytes);

        @memset(sieve, std.math.maxInt(Types.SIEVE_TYPE));
        sieve[0] = Comptimes.FIRST_PRIME_SIEVE_ELEMENT;

        const rootPrime = std.math.sqrt(upperBound);
        const rootSieveLimitExclusive = Utils.getSieveLength(rootPrime);
        var segmentStart: usize = 0;
        var segmentEnd: usize = @min(SEGMENT_ELEMS, sieveLength);

        var primeCount: usize = 2;

        var smallSievePrimesMap: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(Types.SievePrime) = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
            smallSievePrimesMap[ri] = try std.ArrayList(Types.SievePrime).initCapacity(allocator, 0);
        }
        defer for (&smallSievePrimesMap) |*smallSievePrimes| {
            smallSievePrimes.deinit(allocator);
        };
        var smallSievePrimesActiveCounts: [Comptimes.ADMISSIBLE_RESIDUES.count]usize =
            .{0} ** Comptimes.ADMISSIBLE_RESIDUES.count;

        var largeSievePrimes: std.ArrayList(Types.SievePrime) =
            try std.ArrayList(Types.SievePrime).initCapacity(allocator, 0);
        defer largeSievePrimes.deinit(allocator);
        var largeSievePrimesActiveCount: usize = 0;

        var sievePrimes: std.ArrayList(Types.SievePrime) =
            try std.ArrayList(Types.SievePrime).initCapacity(allocator, 0);
        defer sievePrimes.deinit(allocator);
        var sievePrimesActiveCount: usize = 0;

        while (segmentStart < sieveLength) : ({
            segmentStart += SEGMENT_ELEMS;
            segmentEnd = @min(segmentStart + SEGMENT_ELEMS, sieveLength);
            @memset(sieve, std.math.maxInt(Types.SIEVE_TYPE));
        }) {
            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
                const smallSievePrimes = smallSievePrimesMap[ri];
                for (smallSievePrimes.items[0..smallSievePrimesActiveCounts[ri]]) |*activeSmallSievePrime| {
                    if (activeSmallSievePrime.currentSieveIndex < segmentEnd) {
                        applySievePrimeIntoSegment(sieve, segmentStart, segmentEnd, activeSmallSievePrime, ri);
                    }
                }
                for (smallSievePrimes.items[smallSievePrimesActiveCounts[ri]..]) |*inactiveSmallSievePrime| {
                    if (inactiveSmallSievePrime.currentSieveIndex < segmentEnd) {
                        applySievePrimeIntoSegment(sieve, segmentStart, segmentEnd, inactiveSmallSievePrime, ri);
                        smallSievePrimesActiveCounts[ri] += 1;
                    } else {
                        break;
                    }
                }
            }

            applyLargeSievePrimesBatch(BATCH_SIZE, sieve, segmentStart, segmentEnd, &sievePrimes, &sievePrimesActiveCount);
            applyLargeSievePrimesBatch(2, sieve, segmentStart, segmentEnd, &largeSievePrimes, &largeSievePrimesActiveCount);

            if (segmentStart < rootSieveLimitExclusive) {
                for (segmentStart..@min(rootSieveLimitExclusive, segmentEnd)) |sieveIndex| {
                    var word = sieve[sieveIndex];
                    while (word != 0) {
                        const inByteIndex: u3 = Utils.lsb(word);
                        const sievePrime= Utils.sievePrimeFrom(sieveIndex, inByteIndex);

                        if (15 * sieveIndex * 8 <= SEGMENT_ELEMS) { // the square of large primes must not fall in the same segment
                            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
                                if (ri == inByteIndex) {
                                    try smallSievePrimesMap[ri].append(allocator, sievePrime);
                                    if (sievePrime.currentSieveIndex < segmentEnd) {
                                        applySievePrimeIntoSegment(sieve, segmentStart, segmentEnd, &smallSievePrimesMap[ri].items[smallSievePrimesMap[ri].items.len - 1], ri);
                                    }
                                }
                            }
                        } else if (3 * sieveIndex < 2 * SEGMENT_ELEMS) {
                            try sievePrimes.append(allocator, sievePrime);
                        } else {
                            try largeSievePrimes.append(allocator, sievePrime);
                        }

                        word &= word - 1;
                    }
                }
            }
            for (segmentStart / 8..segmentEnd / 8) |sieveIndex| {
                primeCount += @popCount(words[sieveIndex % (SEGMENT_ELEMS / 8)]);
                if (primeCount >= nth) {
                    primeCount -= @popCount(words[sieveIndex % (SEGMENT_ELEMS / 8)]);
                    var word: u64 = words[sieveIndex % (SEGMENT_ELEMS / 8)];
                    while (word != 0) {
                        const lsb: u6 = @as(u6, @intCast(@ctz(word)));

                        primeCount += 1;
                        if (primeCount == nth) {
                            return Utils.admissibleNumberFromBitIndex(8 * 8 * sieveIndex + lsb);
                        }

                        word &= word - 1;
                    }
                }
            }
        }
        unreachable;
    }
};

fn applySievePrimeIntoSegment(
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

inline fn applyLargeSievePrimesBatch(
    comptime n: usize,
    sieve: []Types.SIEVE_TYPE,
    segmentStart: usize,
    segmentEnd: usize,
    largeSievePrimes: *std.ArrayList(Types.SievePrime),
    largeSievePrimesActiveCount: *usize,
) void {
    var ready: [n]*Types.SievePrime = undefined;
    var readyCount: usize = 0;

    for (largeSievePrimes.items[0..largeSievePrimesActiveCount.*]) |*activePrime| {
        if (activePrime.currentSieveIndex < segmentEnd) {
            ready[readyCount] = activePrime;
            readyCount += 1;
            if (readyCount == n) {
                applyNSievePrimesIntoSegment(n, sieve, segmentStart, segmentEnd, ready);
                readyCount = 0;
            }
        }
    }

    for (largeSievePrimes.items[largeSievePrimesActiveCount.*..]) |*activePrime| {
        if (activePrime.currentSieveIndex < segmentEnd) {
            largeSievePrimesActiveCount.* += 1;
            ready[readyCount] = activePrime;
            readyCount += 1;
            if (readyCount == n) {
                applyNSievePrimesIntoSegment(n, sieve, segmentStart, segmentEnd, ready);
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
                applySievePrimeIntoSegment(sieve, segmentStart, segmentEnd, leftoverPrime, ri);
            }
        }
    }
}

fn applyNSievePrimesIntoSegment(
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
