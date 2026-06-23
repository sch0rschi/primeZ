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

        var sievePrimesMap: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(Types.SievePrime) = undefined;
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
            sievePrimesMap[ri] = try std.ArrayList(Types.SievePrime).initCapacity(allocator, Estimates.primeCountUpperBound(rootPrime) / 7);
        }
        defer for (&sievePrimesMap) |*list| {
            list.deinit(allocator);
        };

        var primeCount: usize = 2;

        var sievePrimesActive: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = .{0} ** Comptimes.ADMISSIBLE_RESIDUES.count;
        while (segmentStart < sieveLength) : ({
            segmentStart += SEGMENT_ELEMS;
            segmentEnd = @min(segmentStart + SEGMENT_ELEMS, sieveLength);
            @memset(sieve, std.math.maxInt(Types.SIEVE_TYPE));
        }) {
            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
                const sievePrimes = sievePrimesMap[ri];
                for (sievePrimes.items[0..sievePrimesActive[ri]]) |*sievePrime| {
                    if (sievePrime.currentSieveIndex < segmentEnd) {
                        applySievePrimeIntoSegment(sieve, segmentStart, segmentEnd, sievePrime, ri);
                    }
                }
                for (sievePrimes.items[sievePrimesActive[ri]..]) |*sievePrime| {
                    if (sievePrime.currentSieveIndex < segmentEnd) {
                        applySievePrimeIntoSegment(sieve, segmentStart, segmentEnd, sievePrime, ri);
                        sievePrimesActive[ri] += 1;
                    } else {
                        break;
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

                        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ri| {
                            if (ri == lsb) {
                                try sievePrimesMap[ri].append(allocator, .{
                                    .currentSieveIndex = primeSquareSieve,
                                    .initialSieveIndex = @as(u32, @intCast(sieveIndex)),
                                    .lsb = lsb,
                                    .wheelStepIndex = @as(u3, @intCast(previousPrimeSquareWheelStepIndex)),
                                });
                                applySievePrimeIntoSegment(sieve, segmentStart, segmentEnd, &sievePrimesMap[ri].items[sievePrimesMap[ri].items.len - 1], ri);
                            }
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
