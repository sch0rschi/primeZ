const std = @import("std");

const Utils = @import("utils.zig");
const Check = @import("primeCheck.zig");
const Types = @import("types.zig");

pub const WHEEL_PRIMES = [_]Types.PRIME_TYPE{ 2, 3, 5 };

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

pub const WHEEL_PATTERNS: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]Types.WheelStep = buildWheelPatterns();

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

fn buildWheelPatterns() [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]Types.WheelStep {
    var wheelPatterns: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]Types.WheelStep = undefined;

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
                .bitMask = ~@as(Types.SIEVE_TYPE, 1 << ADMISSIBLE_RESIDUES.reverseMap[startNumber % WHEEL_CIRCUMFERENCE]),
                .divMultiplicator = steps,
                .residueAddend = (number / WHEEL_CIRCUMFERENCE) - (startNumber / WHEEL_CIRCUMFERENCE),
                .dummy = 0,
            };
        }
    }

    return wheelPatterns;
}
