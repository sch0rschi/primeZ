const std = @import("std");

const Utils = @import("utils.zig");
const Check = @import("primeCheck.zig");
const Types = @import("types.zig");

pub const WHEEL_PRIMES = [_]Types.PRIME_TYPE{ 2, 3, 5 };

pub const LARGEST_WHEEL_PRIME = WHEEL_PRIMES[WHEEL_PRIMES.len - 1];

pub const WHEEL_CIRCUMFERENCE = computeWheelCircumference();

const ADMISSIBLE_RESIDUES_COUNT: comptime_int = computeAdmissibleResiduesCount();

pub const AdmissibleResidues = struct {
    count: comptime_int,
    check: [WHEEL_CIRCUMFERENCE]bool,
    list: [ADMISSIBLE_RESIDUES_COUNT]usize,
    reverseMap: [WHEEL_CIRCUMFERENCE]usize,
};

pub const ADMISSIBLE_RESIDUES: AdmissibleResidues = buildAdmissibleResidues();

pub const FIRST_PRIME_SIEVE_ELEMENT: Types.SIEVE_TYPE = buildFirstPrimeSieveElement();

pub const FIRST_PRIMES_COUNT: usize = @popCount(FIRST_PRIME_SIEVE_ELEMENT);

pub const FIRST_PRIMES: [FIRST_PRIMES_COUNT]Types.PRIME_TYPE = buildFirstPrimes();

pub const GAP_PATTERN: [ADMISSIBLE_RESIDUES.count]usize = buildGapPattern();

pub const WheelStep = struct {
    bitMask: u8,
    divMultiplicator: usize,
    residueAddend: usize,
};

pub const WHEEL_PATTERNS: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]WheelStep = buildWheelPatterns();

pub const CUMULATIVE_WHEEL_PATTERNS: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]WheelStep = buildCumulativeWheelPatterns();

fn computeWheelCircumference() usize {
    var product = 1;
    for (WHEEL_PRIMES) |p| product *= p;
    return product;
}

fn computeAdmissibleResiduesCount() usize {
    var count: usize = 0;
    for (0..WHEEL_CIRCUMFERENCE) |r| {
        for (WHEEL_PRIMES) |p| {
            if (r % p == 0) break;
        } else {
            count += 1;
        }
    }
    return count;
}

fn buildFirstPrimeSieveElement() Types.SIEVE_TYPE {
    var firstPrimesSieveElement = 0;
    var admissibleResiduesCount: Types.SIEVE_TYPE_SHIFT_TYPE = 0;
    var pp = 1;
    while (true) : (pp += 1) {
        if (ADMISSIBLE_RESIDUES.check[pp % WHEEL_CIRCUMFERENCE]) {
            if (Check.isPrime(pp)) {
                firstPrimesSieveElement |= 1 << admissibleResiduesCount;
            }
            if (admissibleResiduesCount == @bitSizeOf(Types.SIEVE_TYPE) - 1) {
                break;
            }
            admissibleResiduesCount += 1;
        }
    }

    return firstPrimesSieveElement;
}

fn buildFirstPrimes() [FIRST_PRIMES_COUNT]Types.PRIME_TYPE {
    var firstPrimes: [FIRST_PRIMES_COUNT]Types.PRIME_TYPE = undefined;
    var firstPrimesCount = 0;
    var firstPrimesSieveElement = FIRST_PRIME_SIEVE_ELEMENT;
    while (firstPrimesSieveElement > 0) {
        const lsb = Utils.lsb(firstPrimesSieveElement);
        firstPrimes[firstPrimesCount] = Utils.admissibleNumberFromBitIndex(lsb);
        firstPrimesCount += 1;
        firstPrimesSieveElement &= firstPrimesSieveElement - 1;
    }
    return firstPrimes;
}

fn buildGapPattern() [ADMISSIBLE_RESIDUES.count]usize {
    var gapPattern: [ADMISSIBLE_RESIDUES.count]usize = undefined;
    for (0..ADMISSIBLE_RESIDUES.count) |i| {
        const nextIndex = @mod(i + 1, ADMISSIBLE_RESIDUES.count);
        const difference: isize = @as(isize, ADMISSIBLE_RESIDUES.list[nextIndex]) - @as(isize, ADMISSIBLE_RESIDUES.list[i]);
        const gap = @mod(difference, WHEEL_CIRCUMFERENCE);
        gapPattern[i] = @as(usize, gap);
    }
    return gapPattern;
}

fn buildAdmissibleResidues() AdmissibleResidues {
    var position: usize = 0;
    var admissibleCheck: [WHEEL_CIRCUMFERENCE]bool = [_]bool{false} ** WHEEL_CIRCUMFERENCE;
    var admissibleList: [ADMISSIBLE_RESIDUES_COUNT]usize = undefined;
    var reverseMap: [WHEEL_CIRCUMFERENCE]usize = undefined;

    for (0..WHEEL_CIRCUMFERENCE) |r| {
        for (WHEEL_PRIMES) |p| {
            if (r % p == 0) {
                reverseMap[r] = position;
                break;
            }
        } else {
            admissibleCheck[r] = true;
            admissibleList[position] = r;
            reverseMap[r] = position;
            position += 1;
        }
    }

    return AdmissibleResidues{
        .count = ADMISSIBLE_RESIDUES_COUNT,
        .check = admissibleCheck,
        .list = admissibleList,
        .reverseMap = reverseMap,
    };
}

fn buildWheelPatterns() [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]WheelStep {
    var wheelPatterns: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]WheelStep = undefined;

    for (ADMISSIBLE_RESIDUES.list, &wheelPatterns) |ar, *wp| {
        var number = ar;
        @setEvalBranchQuota(100_000);
        for (wp) |*step| {
            const startNumber = number;
            number += ar;
            var steps = 1;
            while (!ADMISSIBLE_RESIDUES.check[number % WHEEL_CIRCUMFERENCE]) {
                number += ar;
                steps += 1;
            }
            step.* = .{
                .bitMask = ~@as(Types.SIEVE_TYPE, 1 << ADMISSIBLE_RESIDUES.reverseMap[number % WHEEL_CIRCUMFERENCE]),
                .divMultiplicator = steps,
                .residueAddend = (number / WHEEL_CIRCUMFERENCE) - (startNumber / WHEEL_CIRCUMFERENCE),
            };
        }
    }

    return wheelPatterns;
}

fn buildCumulativeWheelPatterns() [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]WheelStep {
    var cumulativeWheelPatterns = WHEEL_PATTERNS;

    for (&cumulativeWheelPatterns) |*cumulativeWheelPattern| {
        for (cumulativeWheelPattern[0..cumulativeWheelPattern.len-1], cumulativeWheelPattern[1..]) |*previous, *actual| {
            actual.divMultiplicator += previous.divMultiplicator;
            actual.residueAddend += previous.residueAddend;
        }
    }

    return cumulativeWheelPatterns;
}
