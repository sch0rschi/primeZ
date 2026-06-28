const std = @import("std");

const Comptimes = @import("comptimes.zig");
const Check = @import("primeCheck.zig");
const Utils = @import("utils.zig");
const Primes = @import("primes.zig");
const Estimates = @import("estimates.zig");
const PrimeStore = @import("primeStore.zig").PrimeStore;

test "Comptime WHEEL_CIRCUMFERENCE" {
    try std.testing.expectEqual(30, Comptimes.WHEEL_CIRCUMFERENCE);
}

test "Comptime ADMISSIBLE_RESIDUES" {
    try std.testing.expectEqual(8, Comptimes.ADMISSIBLE_RESIDUES.count);
    try std.testing.expectEqual(8, Comptimes.ADMISSIBLE_RESIDUES.list.len);

    const expectedList: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = .{ 1, 7, 11, 13, 17, 19, 23, 29 };
    var actualList: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = undefined;
    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |i| {
        actualList[i] = Comptimes.ADMISSIBLE_RESIDUES.list[i];
    }
    for (expectedList, actualList) |e, a| {
        try std.testing.expectEqual(e, a);
    }

    const expectedCheck: [Comptimes.WHEEL_CIRCUMFERENCE]bool = .{ false, true, false, false, false, false, false, true, false, false, false, true, false, true, false, false, false, true, false, true, false, false, false, true, false, false, false, false, false, true };
    var actualCheck: [Comptimes.WHEEL_CIRCUMFERENCE]bool = undefined;
    inline for (0..Comptimes.WHEEL_CIRCUMFERENCE) |i| {
        actualCheck[i] = Comptimes.ADMISSIBLE_RESIDUES.check[i];
    }
    for (expectedCheck, actualCheck) |e, a| {
        try std.testing.expectEqual(e, a);
    }

    const expectedReverseMap: [Comptimes.WHEEL_CIRCUMFERENCE]usize = .{ 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7 };
    var actual_ReverseMap: [Comptimes.WHEEL_CIRCUMFERENCE]usize = undefined;
    inline for (0..Comptimes.WHEEL_CIRCUMFERENCE) |i| {
        actual_ReverseMap[i] = Comptimes.ADMISSIBLE_RESIDUES.reverseMap[i];
    }
    for (expectedReverseMap, actual_ReverseMap) |e, a| {
        try std.testing.expectEqual(e, a);
    }
}

test "nth Prime" {
    const firstPrime = try Primes.nthPrime(std.testing.allocator, 0);
    try std.testing.expectEqual(2, firstPrime);
    const secondPrime = try Primes.nthPrime(std.testing.allocator, 1);
    try std.testing.expectEqual(3, secondPrime);
    const thirdPrime = try Primes.nthPrime(std.testing.allocator, 2);
    try std.testing.expectEqual(5, thirdPrime);
    const fourthPrime = try Primes.nthPrime(std.testing.allocator, 3);
    try std.testing.expectEqual(7, fourthPrime);
    const nthPrime = try Primes.nthPrime(std.testing.allocator, 10_000);
    try std.testing.expectEqual(104_743, nthPrime);
    const tenMillionthPrime = try Primes.nthPrime(std.testing.allocator, 10_000_000);
    try std.testing.expectEqual(179_424_691, tenMillionthPrime);
    const hundredMillionthPrime = try Primes.nthPrime(std.testing.allocator, 100_000_000);
    try std.testing.expectEqual(2_038_074_751, hundredMillionthPrime);
}

test "getPrimes" {
    const allocator = std.testing.allocator;

    const primesUpTo1 = try Primes.getPrimes(std.testing.allocator, 1);
    defer allocator.free(primesUpTo1);

    try std.testing.expectEqual(0, primesUpTo1.len);

    const primes = try Primes.getPrimes(std.testing.allocator, Estimates.nthPrimeUpperBound(10_000_000));
    defer allocator.free(primes);

    try std.testing.expectEqual(2, primes[0]);
    try std.testing.expectEqual(3, primes[1]);
    try std.testing.expectEqual(5, primes[2]);
    try std.testing.expectEqual(7, primes[3]);
    try std.testing.expectEqual(104_743, primes[10_000]);
    try std.testing.expectEqual(179_424_691, primes[10_000_000]);
}

test "sumPrimes" {
    const sum1 = try Primes.sumPrimes(std.testing.allocator, 1);
    try std.testing.expectEqual(0, sum1);
    const sum5 = try Primes.sumPrimes(std.testing.allocator, 5);
    try std.testing.expectEqual(10, sum5);
    const sum6 = try Primes.sumPrimes(std.testing.allocator, 6);
    try std.testing.expectEqual(10, sum6);
    const sum7 = try Primes.sumPrimes(std.testing.allocator, 7);
    try std.testing.expectEqual(17, sum7);
    const sum8 = try Primes.sumPrimes(std.testing.allocator, 8);
    try std.testing.expectEqual(17, sum8);
    const sumTwoMillion = try Primes.sumPrimes(std.testing.allocator, 2_000_000);
    try std.testing.expectEqual(142913828922, sumTwoMillion);
}

test "Sieve with primes" {
    const primeStore = try PrimeStore.initForQueries(std.testing.allocator, 1_000_000);
    defer primeStore.deinit();

    var failCount: u8 = 0;
    for (0..10_000) |n| {
        if (Check.isPrime(n) != primeStore.isPrime(n)) {
            std.debug.print("Number: {}, expected: {}, actual: {}.\n", .{ n, Check.isPrime(n), primeStore.isPrime(n) });
            failCount += 1;
            if (failCount >= 10) {
                break;
            }
        }
    }
    for (900_000..1_000_000) |n| {
        if (Check.isPrime(n) != primeStore.isPrime(n)) {
            std.debug.print("Number: {}, expected: {}, actual: {}.\n", .{ n, Check.isPrime(n), primeStore.isPrime(n) });
            failCount += 1;
            if (failCount >= 10) {
                break;
            }
        }
    }
    try std.testing.expectEqual(0, failCount);
}

test "Sieve and list of primes" {
    const primeStoreLongerPrimesThanSieve = try PrimeStore.initForQueriesAndPrimes(std.testing.allocator, 100, 1000);
    defer primeStoreLongerPrimesThanSieve.deinit();

    try std.testing.expectEqual(168, (try primeStoreLongerPrimesThanSieve.getPrimes()).len);

    const primeStoreLongerSieveThanPrimes = try PrimeStore.initForQueriesAndPrimes(std.testing.allocator, 1000, 100);
    defer primeStoreLongerSieveThanPrimes.deinit();

    try std.testing.expectEqual(25, (try primeStoreLongerSieveThanPrimes.getPrimes()).len);

    const primeStoreForQueries = try PrimeStore.initForQueriesAndPrimes(std.testing.allocator, 1_000_000, 0);
    defer primeStoreForQueries.deinit();

    var failCount: u8 = 0;
    for (900_000..1_000_000) |n| {
        if (Check.isPrime(n) != primeStoreForQueries.isPrime(n)) {
            std.debug.print("Number: {}, expected: {}, actual: {}.\n", .{ n, Check.isPrime(n), primeStoreForQueries.isPrime(n) });
            failCount += 1;
            if (failCount >= 10) {
                break;
            }
        }
    }
    try std.testing.expectEqual(0, failCount);
}
