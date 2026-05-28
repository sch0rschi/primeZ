const std = @import("std");
const config = @import("primeZConfig");

const Estimates = @import("estimates.zig");
const Comptimes = @import("comptimes.zig");
const Utils = @import("utils.zig");
const Check = @import("prime_check.zig");
const Types = @import("types.zig");

const ALIGNMENT = std.mem.Alignment.@"64";
const SEGMENT_ELEMS: usize = 1024 * config.l1_cache_size;

const SievePrime = struct {
    currentSieveIndex: usize,
    initialSieveIndex: u32,
    lsb: u3,
    wheelStepIndex: u3,
};

pub const SegmentedSieve = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    limitInclusive: usize,
    sieve: []align(ALIGNMENT.toByteUnits()) Types.SIEVE_TYPE,
    primes: []usize,

    pub fn init(allocator: std.mem.Allocator, limitInclusive: usize) !SegmentedSieve {
        const sieveLength = Utils.getSieveLength(limitInclusive);
        const sieveLengthAligned = ALIGNMENT.forward(sieveLength);

        const sieve = try allocator.alignedAlloc(
            Types.SIEVE_TYPE,
            ALIGNMENT,
            sieveLengthAligned,
        );
        try runSegmentedSieve(allocator, sieve, limitInclusive);

        const estimatePrimeCount = Estimates.primeCountUpperBound(sieveLengthAligned * Comptimes.WHEEL_CIRCUMFERENCE);
        var primes = try allocator.alloc(usize, estimatePrimeCount);
        try collectPrimes(allocator, sieve, &primes, limitInclusive);

        return SegmentedSieve{
            .allocator = allocator,
            .limitInclusive = limitInclusive,
            .sieve = sieve,
            .primes = primes,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.sieve);
        self.allocator.free(self.primes);
    }

    pub fn isPrime(self: Self, n: usize) bool {
        if (self.limitInclusive < n or n < Comptimes.LARGEST_WHEEL_PRIME + 1) {
            return Check.isPrime(n);
        }
        const div = n / Comptimes.WHEEL_CIRCUMFERENCE;
        const mod = n % Comptimes.WHEEL_CIRCUMFERENCE;
        if (!Comptimes.ADMISSIBLE_RESIDUES.check[mod]) return false;
        return self.sieve[div] >>
            @as(u3, @intCast(Comptimes.ADMISSIBLE_RESIDUES.reverseMap[mod])) & 1 != 0;
    }
};

fn runSegmentedSieve(allocator: std.mem.Allocator, sieve: []Types.SIEVE_TYPE, limitInclusive: usize) !void {
    @memset(sieve, std.math.maxInt(Types.SIEVE_TYPE));
    sieve[0] = Comptimes.FIRST_PRIME_SIEVE_ELEMENT;

    const rootPrime = std.math.sqrt(limitInclusive);
    const rootSieveLimit = Utils.getSieveLength(rootPrime);
    var segmentStart: usize = 0;
    var segmentEnd: usize = @min(SEGMENT_ELEMS, sieve.len);

    var sievePrimes = try std.ArrayList(SievePrime).initCapacity(allocator, Estimates.primeCountUpperBound(rootPrime));
    defer sievePrimes.deinit(allocator);

    while (segmentStart < sieve.len) : ({
        segmentStart += SEGMENT_ELEMS;
        segmentEnd = @min(segmentStart + SEGMENT_ELEMS, sieve.len);
    }) {
        for (sievePrimes.items) |*sievePrime| {
            applySievePrimeIntoSegment(sieve, segmentEnd, sievePrime);
        }
        if (segmentStart < rootSieveLimit) {
            for (segmentStart..@min(rootSieveLimit + 1, segmentEnd)) |sieveIndex| {
                @prefetch(&sieve[@min(sieveIndex + 1, segmentEnd - 1)], .{ .rw = .read, .locality = 0, .cache = .data });
                var word = sieve[sieveIndex];
                while (word != 0) {
                    const lsb: u3 = Utils.lsb(word);

                    const prime = Utils.admissibleNumberFromBitIndex(8*sieveIndex+lsb);
                    var previousPrimeSquare = prime * prime - prime;
                    while (Utils.isMultipleOfWheelPrime(previousPrimeSquare)) {
                        previousPrimeSquare -= prime;
                    }


                    const previousPrimeSquareMultiple = previousPrimeSquare / prime;
                    const previousPrimeSquareMultipleMod = previousPrimeSquareMultiple % Comptimes.WHEEL_CIRCUMFERENCE;
                    const previousPrimeSquareWheelStepIndex = Comptimes.ADMISSIBLE_RESIDUES.reverseMap[previousPrimeSquareMultipleMod];

                    const sieveAdvance = sieveIndex * Comptimes.WHEEL_CIRCUMFERENCE + Comptimes.ADMISSIBLE_RESIDUES.list[lsb];
                    const start = previousPrimeSquareMultiple / Comptimes.WHEEL_CIRCUMFERENCE;

                    try sievePrimes.append(allocator, .{
                        .currentSieveIndex = sieveIndex + sieveAdvance * start,
                        .initialSieveIndex = @as(u32, @intCast(sieveIndex)),
                        .lsb = lsb,
                        .wheelStepIndex = @as(u3, @intCast(previousPrimeSquareWheelStepIndex)),
                    });
                    applySievePrimeIntoSegment(sieve, segmentEnd, &sievePrimes.items[sievePrimes.items.len - 1]);

                    word -= @as(Types.SIEVE_TYPE, 1) << lsb;
                }
            }
        }
    }
}

fn applySievePrimeIntoSegment(
    sieve: []Types.SIEVE_TYPE,
    segmentEnd: usize,
    sievePrime: *SievePrime,
) void {
    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |lsb| {
        if (sievePrime.lsb == lsb) {
            return applySievePrimeForResidue(sieve, segmentEnd, sievePrime, lsb);
        }
    }
}

fn applySievePrimeForResidue(
    sieve: []Types.SIEVE_TYPE,
    segmentEnd: usize,
    sievePrime: *SievePrime,
    comptime lsb: usize,
) void {
    const wheelPattern = Comptimes.CUMULATIVE_WHEEL_PATTERNS[lsb];
    const initialSieveIndex = sievePrime.initialSieveIndex;
    const sieveAdvance = sievePrime.initialSieveIndex * Comptimes.WHEEL_CIRCUMFERENCE + Comptimes.ADMISSIBLE_RESIDUES.list[lsb];
    var startSieveIndex = sievePrime.currentSieveIndex;
    var wheelStepIndex = sievePrime.wheelStepIndex;

    if (wheelStepIndex != 0) {
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |step| {
            if (step >= wheelStepIndex) {
                const wheelStep = wheelPattern[step];
                const sieveIndex = startSieveIndex + initialSieveIndex * wheelStep.divMultiplicator + wheelStep.residueAddend;
                if (sieveIndex >= segmentEnd) {
                    sievePrime.currentSieveIndex = startSieveIndex;
                    sievePrime.wheelStepIndex = step;
                    return;
                }
                sieve[sieveIndex] &= wheelStep.bitMask;
            }
        }
        startSieveIndex += sieveAdvance;
        wheelStepIndex = 0;
    }

    var endSieveIndex = startSieveIndex + sieveAdvance;
    while (endSieveIndex < segmentEnd) {
        inline for (wheelPattern) |ws| {
            sieve[startSieveIndex + initialSieveIndex * ws.divMultiplicator + ws.residueAddend] &= ws.bitMask;
        }
        startSieveIndex = endSieveIndex;
        endSieveIndex += sieveAdvance;
    }

    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |step| {
        const ws = wheelPattern[step];
        const idx = startSieveIndex + initialSieveIndex * ws.divMultiplicator + ws.residueAddend;
        if (idx >= segmentEnd) {
            sievePrime.currentSieveIndex = startSieveIndex;
            sievePrime.wheelStepIndex = step;
            return;
        }
        sieve[idx] &= ws.bitMask;
    }

    sievePrime.currentSieveIndex = startSieveIndex + sieveAdvance;
    sievePrime.wheelStepIndex = 0;
}

pub fn collectPrimes(
    allocator: std.mem.Allocator,
    sieve: []const Types.SIEVE_TYPE,
    primes: *[]usize,
    limitInclusive: usize,
) !void {
    var primeCount: usize = 0;

    // wheel primes
    inline for (Comptimes.WHEEL_PRIMES) |p| {
        if (p <= limitInclusive) {
            primes.*[primeCount] = p;
            primeCount += 1;
        }
    }

    const bytes = std.mem.sliceAsBytes(sieve);
    const words = std.mem.bytesAsSlice(u64, bytes);
    for (words, 0..) |sieveWord, idx| {
        @prefetch(&words[@min(idx + 1, words.len - 1)], .{ .rw = .read, .locality = 0, .cache = .data });
        var workingWord = sieveWord;

        while (workingWord != 0) {
            const lsb = @ctz(workingWord);
            const div = lsb / Comptimes.ADMISSIBLE_RESIDUES.count;
            const rem = lsb % Comptimes.ADMISSIBLE_RESIDUES.count;
            // TODO: make general
            const prime = (8 * idx + div) * Comptimes.WHEEL_CIRCUMFERENCE + Comptimes.ADMISSIBLE_RESIDUES.list[rem];

            primes.*[primeCount] = prime;
            primeCount += 1;

            workingWord &= workingWord - 1;
        }
    }

    while (primes.*[primeCount - 1] > limitInclusive) {
        primeCount -= 1;
    }

    primes.* = try allocator.realloc(primes.*, primeCount);
}
