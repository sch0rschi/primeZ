const std = @import("std");

pub const Comptimes = @import("sieveEngine/comptimes.zig");
pub const PrimeCheck = @import("primeCheck.zig");

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
    var primeStore = try PrimeStore.initForQueries(std.testing.allocator, 1_000_000);
    defer primeStore.deinit();

    var failCount: u8 = 0;
    for (0..10_000) |n| {
        if (PrimeCheck.isPrime(n) != primeStore.isPrime(n)) {
            std.debug.print("Number: {}, expected: {}, actual: {}.\n", .{ n, PrimeCheck.isPrime(n), primeStore.isPrime(n) });
            failCount += 1;
            if (failCount >= 10) {
                break;
            }
        }
    }
    for (999_000..1_000_000) |n| {
        if (PrimeCheck.isPrime(n) != primeStore.isPrime(n)) {
            std.debug.print("Number: {}, expected: {}, actual: {}.\n", .{ n, PrimeCheck.isPrime(n), primeStore.isPrime(n) });
            failCount += 1;
            if (failCount >= 10) {
                break;
            }
        }
    }
    try std.testing.expectEqual(0, failCount);
}

test "Sieve and list of primes" {
    var primeStoreLongerPrimesThanSieve = try PrimeStore.initForQueriesAndPrimes(std.testing.allocator, 100, 1000);
    defer primeStoreLongerPrimesThanSieve.deinit();

    try std.testing.expectEqual(168, (try primeStoreLongerPrimesThanSieve.getPrimes()).len);

    var primeStoreLongerSieveThanPrimes = try PrimeStore.initForQueriesAndPrimes(std.testing.allocator, 1000, 100);
    defer primeStoreLongerSieveThanPrimes.deinit();

    try std.testing.expectEqual(25, (try primeStoreLongerSieveThanPrimes.getPrimes()).len);

    var primeStoreForQueries = try PrimeStore.initForQueriesAndPrimes(std.testing.allocator, 1_000_000, 0);
    defer primeStoreForQueries.deinit();

    var failCount: u8 = 0;
    for (999_000..1_000_000) |n| {
        if (PrimeCheck.isPrime(n) != primeStoreForQueries.isPrime(n)) {
            std.debug.print("Number: {}, expected: {}, actual: {}.\n", .{ n, PrimeCheck.isPrime(n), primeStoreForQueries.isPrime(n) });
            failCount += 1;
            if (failCount >= 10) {
                break;
            }
        }
    }
    try std.testing.expectEqual(0, failCount);
}

test "oeis A014233 strong pseudoprimes" {
    const A014233 = [_]u64{
        2047,
        1373653,
        25326001,
        3215031751,
        2152302898747,
        3474749660383,
        341550071728321,
        3825123056546413051,
    };
    for (A014233) |p| {
        try std.testing.expect(!PrimeCheck.isPrime(p));
    }
}

fn expectPiSieveCountingMatchesGetPrimes(allocator: std.mem.Allocator, limit: usize) !void {
    const counted = try Primes.piSieveCounting(allocator, 0, limit);
    const primes = try Primes.getPrimes(allocator, limit);
    defer allocator.free(primes);
    if (counted != primes.len) {
        std.debug.print("limit={}: piSieveCounting={} getPrimes.len={}\n", .{ limit, counted, primes.len });
    }
    try std.testing.expectEqual(primes.len, counted);
}

test "piSieveCounting matches getPrimes length at container boundaries" {
    const allocator = std.testing.allocator;

    const smallLimits = [_]usize{ 7, 8, 9, 10, 11, 29, 30, 31, 100 };
    for (smallLimits) |limit| {
        try expectPiSieveCountingMatchesGetPrimes(allocator, limit);
    }

    var boundary: usize = 240;
    while (boundary <= 2400) : (boundary += 240) {
        try expectPiSieveCountingMatchesGetPrimes(allocator, boundary - 1);
        try expectPiSieveCountingMatchesGetPrimes(allocator, boundary);
        try expectPiSieveCountingMatchesGetPrimes(allocator, boundary + 1);
    }
}

test "piSieveCounting matches getPrimes length at a segment boundary" {
    const allocator = std.testing.allocator;

    const segmentBoundary: usize = 122_880;
    try expectPiSieveCountingMatchesGetPrimes(allocator, segmentBoundary - 1);
    try expectPiSieveCountingMatchesGetPrimes(allocator, segmentBoundary);
    try expectPiSieveCountingMatchesGetPrimes(allocator, segmentBoundary + 1);
}

fn expectPiSieveCountingMatchesGetPrimesInRange(allocator: std.mem.Allocator, start: usize, limit: usize) !void {
    const counted = try Primes.piSieveCounting(allocator, start, limit);

    const primes = try Primes.getPrimes(allocator, limit);
    defer allocator.free(primes);

    var expected: usize = 0;
    for (primes) |p| {
        if (p >= start) expected += 1;
    }

    if (counted != expected) {
        std.debug.print("start={} limit={}: piSieveCounting={} expected={}\n", .{ start, limit, counted, expected });
    }
    try std.testing.expectEqual(expected, counted);
}

test "piSieveCounting with a range start" {
    const allocator = std.testing.allocator;

    // start == 0 (matches the limit-only behavior)
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 0, 100);

    // start > limit
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 100, 50);

    // start == limit, on and off a prime
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 97, 97);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 98, 98);

    // small ranges, various offsets into the wheel
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 1, 100);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 5, 100);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 6, 100);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 7, 100);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 50, 100);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 90000, 100000);

    // range around container/segment boundaries
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 63, 65);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 122_879, 122_881);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 122_880, 245_760);

    // start well beyond a single segment's worth of numbers, but before
    // sieving-prime discovery (sqrt(limit)) finishes - no jump
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 100_000, 200_000);

    // start far beyond sqrt(limit) - triggers SegmentIterator's jump, and
    // exercises small/medium/large tier fastForwardTo (see sievePrime.zig)
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 999_000, 1_000_000);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 9_990_000, 10_000_000);

}

// getPrimes would need to materialize every prime up to limit, far too slow
// at the scale needed to populate the huge tier (LARGE_HUGE_THRESHOLD =
// 61_440 in this test config, so sqrt(limit) must exceed that) - compare
// against the difference of two piSieveCounting(0, ...) calls instead.
test "piSieveCounting with a range start reaching the huge tier" {
    const allocator = std.testing.allocator;

    const start: usize = 3_999_990_000;
    const limit: usize = 4_000_000_000;

    const inRange = try Primes.piSieveCounting(allocator, start, limit);
    const upToLimit = try Primes.piSieveCounting(allocator, 0, limit);
    const belowStart = try Primes.piSieveCounting(allocator, 0, start - 1);

    try std.testing.expectEqual(upToLimit - belowStart, inRange);
}

test "Primes.pi small values" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(@as(usize, 0), try Primes.pi(allocator, 0));
    try std.testing.expectEqual(@as(usize, 0), try Primes.pi(allocator, 1));
    try std.testing.expectEqual(@as(usize, 1), try Primes.pi(allocator, 2));
    try std.testing.expectEqual(@as(usize, 2), try Primes.pi(allocator, 3));
    try std.testing.expectEqual(@as(usize, 4), try Primes.pi(allocator, 9));
    try std.testing.expectEqual(@as(usize, 4), try Primes.pi(allocator, 10));
    try std.testing.expectEqual(@as(usize, 25), try Primes.pi(allocator, 100));
    try std.testing.expectEqual(@as(usize, 168), try Primes.pi(allocator, 1_000));
    try std.testing.expectEqual(@as(usize, 1229), try Primes.pi(allocator, 10_000));
    try std.testing.expectEqual(@as(usize, 9592), try Primes.pi(allocator, 100_000));
}