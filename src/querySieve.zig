const std = @import("std");
const config = @import("primeZConfig");

const Estimates = @import("estimates.zig");
const Comptimes = @import("comptimes.zig");
const Utils = @import("utils.zig");
const Check = @import("primeCheck.zig");
const Types = @import("types.zig");

const ALIGNMENT = std.mem.Alignment.@"8";
const SEGMENT_ELEMS: usize = 1024 * config.l1_cache_size;

pub const CollectError = error{LimitTooHigh};

pub const QuerySieve = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    limitInclusive: usize,
    sieve: []align(ALIGNMENT.toByteUnits()) Types.SIEVE_TYPE,

    pub fn init(allocator: std.mem.Allocator, limitInclusive: usize) !QuerySieve {
        const sieveLength = Utils.getSieveLength(limitInclusive);
        const sieveLengthAligned = ALIGNMENT.forward(sieveLength);

        const sieve = try allocator.alignedAlloc(
            Types.SIEVE_TYPE,
            ALIGNMENT,
            sieveLengthAligned,
        );
        try runSegmentedSieve(allocator, sieve, limitInclusive);

        return QuerySieve{
            .allocator = allocator,
            .limitInclusive = limitInclusive,
            .sieve = sieve,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.sieve);
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

    pub fn iter(self: Self) SieveIterator {
        const bytes = std.mem.sliceAsBytes(self.sieve);
        const words = std.mem.bytesAsSlice(u64, bytes);

        return .{
            .sieve = words,
            .limitInclusive = self.limitInclusive,
            .phase = IteratorPhase.TWO,
            .currentSieveWordIndex = 0,
            .lastSieveWordIndex = words.len -| 1,
            .workingWord = if (words.len > 0) words[0] else 0,
        };
    }

    pub fn getPrimes(self: QuerySieve, allocator: std.mem.Allocator) ![]Types.PRIME_TYPE {
        return getPrimesToLimit(self, allocator, self.limitInclusive);
    }

    pub fn getPrimesToLimit(
        self: Self,
        allocator: std.mem.Allocator,
        limitInclusive: usize,
    ) ![]Types.PRIME_TYPE {
        if (limitInclusive > self.limitInclusive) {
            return error.LimitTooHigh;
        }

        const estimatePrimeCount = Estimates.primeCountUpperBound(limitInclusive);
        var primes = try allocator.alloc(usize, estimatePrimeCount);

        var primeCount: usize = 0;
        inline for (Comptimes.WHEEL_PRIMES) |p| {
            if (p <= limitInclusive) {
                primes[primeCount] = p;
                primeCount += 1;
            }
        }

        const bytes = std.mem.sliceAsBytes(self.sieve);
        const words = std.mem.bytesAsSlice(u64, bytes);
        for (0..words.len - 1, words[0 .. words.len - 1]) |sieveWordIndex, sieveWord| {
            @prefetch(&words[@min(sieveWordIndex + 1, words.len - 1)], .{ .rw = .read, .locality = 0, .cache = .data });
            addPrimesForSieveWord(sieveWord, sieveWordIndex, &primes, &primeCount, limitInclusive, false);
        }

        addPrimesForSieveWord(words[words.len - 1], words.len - 1, &primes, &primeCount, limitInclusive, true);
        primes = try allocator.realloc(primes, primeCount);
        return primes;
    }
};

fn runSegmentedSieve(allocator: std.mem.Allocator, sieve: []Types.SIEVE_TYPE, limitInclusive: usize) !void {
    @memset(sieve, std.math.maxInt(Types.SIEVE_TYPE));
    sieve[0] = Comptimes.FIRST_PRIME_SIEVE_ELEMENT;

    const rootPrime = std.math.sqrt(limitInclusive);
    const rootSieveLimit = Utils.getSieveLength(rootPrime);
    var segmentStart: usize = 0;
    var segmentEnd: usize = @min(SEGMENT_ELEMS, sieve.len);

    var sievePrimes = try std.ArrayList(Types.SievePrime).initCapacity(allocator, Estimates.primeCountUpperBound(rootPrime));
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

                    const prime = Utils.admissibleNumberFromBitIndex(8 * sieveIndex + lsb);
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
    sievePrime: *Types.SievePrime,
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
    sievePrime: *Types.SievePrime,
    comptime lsb: u3,
) void {
    const wheelPattern = Comptimes.CUMULATIVE_WHEEL_PATTERNS[lsb];
    const initialSieveIndex = sievePrime.initialSieveIndex;
    const sieveAdvance = sievePrime.initialSieveIndex * Comptimes.WHEEL_CIRCUMFERENCE + Comptimes.ADMISSIBLE_RESIDUES.list[lsb];
    var startSieveIndex = sievePrime.currentSieveIndex;
    var wheelStepIndex = sievePrime.wheelStepIndex;

    var concreteStepSizes: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = undefined;
    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |step| {
        concreteStepSizes[step] = initialSieveIndex * wheelPattern[step].divMultiplicator + wheelPattern[step].residueAddend;
    }

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
        inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count, wheelPattern) |step, ws| {
            const idx = startSieveIndex + concreteStepSizes[step];
            sieve[idx] &= ws.bitMask;
        }
        startSieveIndex = endSieveIndex;
        endSieveIndex += sieveAdvance;
    }

    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |step| {
        const ws = wheelPattern[step];
        const idx = startSieveIndex + concreteStepSizes[step];
        if (idx >= segmentEnd) {
            sievePrime.currentSieveIndex = startSieveIndex;
            sievePrime.wheelStepIndex = @as(u3, @intCast(step));
            return;
        }
        sieve[idx] &= ws.bitMask;
    }

    sievePrime.currentSieveIndex = startSieveIndex + sieveAdvance;
    sievePrime.wheelStepIndex = 0;
}

fn addPrimesForSieveWord(workingWord: u64, sieveWordIndex: usize, primes: *[]Types.PRIME_TYPE, primeCount: *usize, limitInclusive: Types.PRIME_TYPE, comptime addLimitCheck: bool) void {
    var workingWord_ = workingWord;
    while (workingWord_ != 0) {
        const lsb = @ctz(workingWord_);
        const div = lsb / Comptimes.ADMISSIBLE_RESIDUES.count;
        const rem = lsb % Comptimes.ADMISSIBLE_RESIDUES.count;
        const prime = (8 * sieveWordIndex + div) * Comptimes.WHEEL_CIRCUMFERENCE + Comptimes.ADMISSIBLE_RESIDUES.list[rem];
        if (addLimitCheck and prime > limitInclusive) {
            break;
        }
        primes.*[primeCount.*] = prime;
        primeCount.* += 1;
        workingWord_ &= workingWord_ - 1;
    }
}

const IteratorPhase = enum { TWO, THREE, FIVE, SIEVE };

const SieveIterator = struct {
    sieve: []u64,
    limitInclusive: Types.PRIME_TYPE,
    phase: IteratorPhase,
    currentSieveWordIndex: usize,
    lastSieveWordIndex: usize,
    workingWord: u64,

    pub fn init(sieve: []u64, limitInclusive: Types.PRIME_TYPE) SieveIterator {
        return .{
            .sieve = sieve,
            .limitInclusive = limitInclusive,
            .phase = IteratorPhase.TWO,
            .currentSieveWordIndex = 0,
            .lastSieveWordIndex = sieve.len -| 1,
            .workingWord = if (sieve.len > 0) sieve[0] else 0,
        };
    }

    pub fn next(self: *SieveIterator) ?Types.PRIME_TYPE {
        if (self.phase == IteratorPhase.SIEVE) {
            return self.nextFromSieve();
        }
        return self.nextSmallPrime();
    }

    inline fn nextFromSieve(self: *SieveIterator) ?Types.PRIME_TYPE {
        while (self.workingWord == 0) {
            if (self.currentSieveWordIndex >= self.lastSieveWordIndex) return null;
            self.currentSieveWordIndex += 1;
            self.workingWord = self.sieve[self.currentSieveWordIndex];
        }

        const lsb = @ctz(self.workingWord);
        self.workingWord &= self.workingWord - 1;

        const count = comptime Comptimes.ADMISSIBLE_RESIDUES.count;
        const div = lsb / count;
        const rem = lsb % count;
        const prime = (8 * self.currentSieveWordIndex + div) *
            Comptimes.WHEEL_CIRCUMFERENCE +
            Comptimes.ADMISSIBLE_RESIDUES.list[rem];

        if (prime <= self.limitInclusive) return prime;
        return null;
    }

    fn nextSmallPrime(self: *SieveIterator) ?Types.PRIME_TYPE {
        switch (self.phase) {
            .TWO => {
                self.phase = .THREE;
                if (self.limitInclusive >= 2) return 2;
            },
            .THREE => {
                self.phase = .FIVE;
                if (self.limitInclusive >= 3) return 3;
            },
            .FIVE => {
                self.phase = .SIEVE;
                if (self.limitInclusive >= 5) return 5;
            },
            else => unreachable,
        }
        return null;
    }
};
