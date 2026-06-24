const std = @import("std");
const config = @import("primeZConfig");

const Estimates = @import("estimates.zig");
const Comptimes = @import("comptimes.zig");
const Utils = @import("utils.zig");
const Check = @import("primeCheck.zig");
const Types = @import("types.zig");

const ALIGNMENT = std.mem.Alignment.@"8";
const SEGMENT_ELEMS: usize = 1024 * config.l1_cache_size;

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

        var smallSievePrimesMap: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(Types.SievePrime) = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
            smallSievePrimesMap[ri] = try std.ArrayList(Types.SievePrime).initCapacity(allocator, 0);
        }
        defer for (&smallSievePrimesMap) |*smallSievePrimes| {
            smallSievePrimes.deinit(allocator);
        };
        var largeSievePrimes: std.ArrayList(Types.SievePrime) = try std.ArrayList(Types.SievePrime).initCapacity(allocator, 0);
        defer largeSievePrimes.deinit(allocator);

        var primeCount: usize = 2;

        var smallSievePrimesActiveCounts: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = .{0} ** Comptimes.ADMISSIBLE_RESIDUES.count;
        var largeSievePrimesActiveCount: usize = 0;
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

            var largeSievePrimesReady: [2]*Types.SievePrime = undefined;
            var largeSievePrimesReadyCount: usize = 0;
            for (largeSievePrimes.items[0..largeSievePrimesActiveCount]) |*activeLargeSievePrime| {
                if (activeLargeSievePrime.currentSieveIndex < segmentEnd) {
                    largeSievePrimesReady[largeSievePrimesReadyCount] = activeLargeSievePrime;
                    largeSievePrimesReadyCount += 1;
                    if (largeSievePrimesReadyCount == 2) {
                        apply2SievePrimesIntoSegment(sieve, segmentStart, segmentEnd, largeSievePrimesReady);
                        largeSievePrimesReadyCount = 0;
                    }
                }
            }
            for (largeSievePrimes.items[largeSievePrimesActiveCount..]) |*activeLargeSievePrime| {
                if (activeLargeSievePrime.currentSieveIndex < segmentEnd) {
                    largeSievePrimesActiveCount += 1;
                    largeSievePrimesReady[largeSievePrimesReadyCount] = activeLargeSievePrime;
                    largeSievePrimesReadyCount += 1;
                    if (largeSievePrimesReadyCount == 2) {
                        apply2SievePrimesIntoSegment(sieve, segmentStart, segmentEnd, largeSievePrimesReady);
                        largeSievePrimesReadyCount = 0;
                    }
                } else {
                    break;
                }
            }
            if (largeSievePrimesReadyCount == 1) {
                inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
                    if (largeSievePrimesReady[0].initialInByteIndex == ri) {
                        applySievePrimeIntoSegment(sieve, segmentStart, segmentEnd, largeSievePrimesReady[0], ri);
                    }
                }
            }

            if (segmentStart < rootSieveLimitExclusive) {
                for (segmentStart..@min(rootSieveLimitExclusive, segmentEnd)) |sieveIndex| {
                    var word = sieve[sieveIndex];
                    while (word != 0) {
                        const lsb: u3 = Utils.lsb(word);

                        const prime = Utils.admissibleNumberFromBitIndex(8 * sieveIndex + lsb);
                        const primeSquareBit = Utils.admissibleNumberToBit(prime * prime);
                        const primeSquareSieve = primeSquareBit / 8;

                        const previousPrimeSquareMultipleMod = prime % Comptimes.WHEEL_CIRCUMFERENCE;
                        const previousPrimeSquareWheelStepIndex = Comptimes.ADMISSIBLE_RESIDUES.reverseMap[previousPrimeSquareMultipleMod];

                        if (prime <= SEGMENT_ELEMS / 2) { // the square of large primes must not fall in the same segment
                            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
                                if (ri == lsb) {
                                    try smallSievePrimesMap[ri].append(allocator, .{
                                        .currentSieveIndex = primeSquareSieve,
                                        .initialSieveIndex = @intCast(sieveIndex),
                                        .initialInByteIndex = lsb,
                                        .wheelStepIndex = @intCast(previousPrimeSquareWheelStepIndex),
                                    });
                                    if (primeSquareSieve < segmentEnd) {
                                        applySievePrimeIntoSegment(sieve, segmentStart, segmentEnd, &smallSievePrimesMap[ri].items[smallSievePrimesMap[ri].items.len - 1], ri);
                                    }
                                }
                            }
                        } else {
                            try largeSievePrimes.append(allocator, .{
                                .currentSieveIndex = primeSquareSieve,
                                .initialSieveIndex = @intCast(sieveIndex),
                                .initialInByteIndex = lsb,
                                .wheelStepIndex = @intCast(previousPrimeSquareWheelStepIndex),
                            });
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
    const wheelPattern = Comptimes.WHEEL_PATTERNS[lsb];

    if (sievePrime.currentSieveIndex < segmentEndExclusive) {
        const sieveWindow = segmentEndExclusive - segmentStart;
        const initialSieveIndex = sievePrime.initialSieveIndex;
        const wheelStepIndex = sievePrime.wheelStepIndex;
        var currentSieveIndex = sievePrime.currentSieveIndex - segmentStart;

        var concreteStepSizes: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = undefined;
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |step| {
            concreteStepSizes[step] = initialSieveIndex * wheelPattern[step].divMultiplicator + wheelPattern[step].residueAddend;
        }

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

        var advanceAfter7: usize = 0;
        inline for (concreteStepSizes[0 .. Comptimes.ADMISSIBLE_RESIDUES.count - 1]) |step| {
            advanceAfter7 += step;
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
        }
    }
}

fn apply2SievePrimesIntoSegment(
    sieve: []Types.SIEVE_TYPE,
    segmentStart: usize,
    segmentEndExclusive: usize,
    sievePrimes: [2]*Types.SievePrime,
) void {
    const sievePrime0 = sievePrimes[0];
    const sievePrime1 = sievePrimes[1];
    const wheelPattern0 = &Comptimes.WHEEL_PATTERNS[sievePrime0.initialInByteIndex];
    const wheelPattern1 = &Comptimes.WHEEL_PATTERNS[sievePrime1.initialInByteIndex];

    const sieveWindow = segmentEndExclusive - segmentStart;

    const initialSieveIndex0 = sievePrime0.initialSieveIndex;
    const initialSieveIndex1 = sievePrime1.initialSieveIndex;

    var currentSieveIndex0 = sievePrime0.currentSieveIndex - segmentStart;
    var currentSieveIndex1 = sievePrime1.currentSieveIndex - segmentStart;

    var wheelStepIndex0 = sievePrime0.wheelStepIndex;
    var wheelStepIndex1 = sievePrime1.wheelStepIndex;

    while (currentSieveIndex0 < sieveWindow and currentSieveIndex1 < sieveWindow) {
        const step0 = &wheelPattern0[wheelStepIndex0];
        sieve[currentSieveIndex0] &= step0.bitMask;
        currentSieveIndex0 += initialSieveIndex0 * step0.divMultiplicator + step0.residueAddend;
        wheelStepIndex0 +%= 1;
        const step1 = &wheelPattern1[wheelStepIndex1];
        sieve[currentSieveIndex1] &= step1.bitMask;
        currentSieveIndex1 += initialSieveIndex1 * step1.divMultiplicator + step1.residueAddend;
        wheelStepIndex1 +%= 1;
    }

    while (currentSieveIndex0 < sieveWindow) {
        const step0 = wheelPattern0[wheelStepIndex0];
        sieve[currentSieveIndex0] &= step0.bitMask;
        currentSieveIndex0 += initialSieveIndex0 * step0.divMultiplicator + step0.residueAddend;
        wheelStepIndex0 +%= 1;
    }
    sievePrime0.currentSieveIndex = currentSieveIndex0 + segmentStart;
    sievePrime0.wheelStepIndex = wheelStepIndex0;

    while (currentSieveIndex1 < sieveWindow) {
        const step1 = wheelPattern1[wheelStepIndex1];
        sieve[currentSieveIndex1] &= step1.bitMask;
        currentSieveIndex1 += initialSieveIndex1 * step1.divMultiplicator + step1.residueAddend;
        wheelStepIndex1 +%= 1;
    }
    sievePrime1.currentSieveIndex = currentSieveIndex1 + segmentStart;
    sievePrime1.wheelStepIndex = wheelStepIndex1;
}

fn apply3SievePrimesIntoSegment(
    sieve: []Types.SIEVE_TYPE,
    segmentStart: usize,
    segmentEndExclusive: usize,
    sievePrime0: *Types.SievePrime,
    sievePrime1: *Types.SievePrime,
    sievePrime2: *Types.SievePrime,
) void {
    const wheelPattern0 = Comptimes.WHEEL_PATTERNS[sievePrime0.initialInByteIndex];
    const wheelPattern1 = Comptimes.WHEEL_PATTERNS[sievePrime1.initialInByteIndex];
    const wheelPattern2 = Comptimes.WHEEL_PATTERNS[sievePrime2.initialInByteIndex];

    const sieveWindow = segmentEndExclusive - segmentStart;

    const initialSieveIndex0 = sievePrime0.initialSieveIndex;
    const initialSieveIndex1 = sievePrime1.initialSieveIndex;
    const initialSieveIndex2 = sievePrime2.initialSieveIndex;

    var currentSieveIndex0 = sievePrime0.currentSieveIndex - segmentStart;
    var currentSieveIndex1 = sievePrime1.currentSieveIndex - segmentStart;
    var currentSieveIndex2 = sievePrime2.currentSieveIndex - segmentStart;

    var wheelStepIndex0 = sievePrime0.wheelStepIndex;
    var wheelStepIndex1 = sievePrime1.wheelStepIndex;
    var wheelStepIndex2 = sievePrime2.wheelStepIndex;

    while (currentSieveIndex0 < sieveWindow and
        currentSieveIndex1 < sieveWindow and
        currentSieveIndex2 < sieveWindow)
    {
        const step0 = wheelPattern0[wheelStepIndex0];
        const step1 = wheelPattern1[wheelStepIndex1];
        const step2 = wheelPattern2[wheelStepIndex2];

        sieve[currentSieveIndex0] &= step0.bitMask;
        sieve[currentSieveIndex1] &= step1.bitMask;
        sieve[currentSieveIndex2] &= step2.bitMask;

        currentSieveIndex0 += initialSieveIndex0 * step0.divMultiplicator + step0.residueAddend;
        currentSieveIndex1 += initialSieveIndex1 * step1.divMultiplicator + step1.residueAddend;
        currentSieveIndex2 += initialSieveIndex2 * step2.divMultiplicator + step2.residueAddend;

        wheelStepIndex0 +%= 1;
        wheelStepIndex1 +%= 1;
        wheelStepIndex2 +%= 1;
    }

    while (currentSieveIndex0 < sieveWindow) {
        const step0 = wheelPattern0[wheelStepIndex0];

        sieve[currentSieveIndex0] &= step0.bitMask;
        currentSieveIndex0 += initialSieveIndex0 * step0.divMultiplicator + step0.residueAddend;

        wheelStepIndex0 +%= 1;
    }
    sievePrime0.currentSieveIndex = currentSieveIndex0 + segmentStart;
    sievePrime0.wheelStepIndex = wheelStepIndex0;

    while (currentSieveIndex1 < sieveWindow) {
        const step1 = wheelPattern1[wheelStepIndex1];

        sieve[currentSieveIndex1] &= step1.bitMask;
        currentSieveIndex1 += initialSieveIndex1 * step1.divMultiplicator + step1.residueAddend;

        wheelStepIndex1 +%= 1;
    }
    sievePrime1.currentSieveIndex = currentSieveIndex1 + segmentStart;
    sievePrime1.wheelStepIndex = wheelStepIndex1;

    while (currentSieveIndex2 < sieveWindow) {
        const step2 = wheelPattern2[wheelStepIndex2];

        sieve[currentSieveIndex2] &= step2.bitMask;
        currentSieveIndex2 += initialSieveIndex2 * step2.divMultiplicator + step2.residueAddend;

        wheelStepIndex2 +%= 1;
    }
    sievePrime2.currentSieveIndex = currentSieveIndex2 + segmentStart;
    sievePrime2.wheelStepIndex = wheelStepIndex2;
}
