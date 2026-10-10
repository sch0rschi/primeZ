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

    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 0, 100);

    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 100, 50);

    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 97, 97);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 98, 98);

    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 1, 100);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 5, 100);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 6, 100);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 7, 100);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 50, 100);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 90000, 100000);

    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 63, 65);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 122_879, 122_881);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 122_880, 245_760);

    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 100_000, 200_000);

    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 999_000, 1_000_000);
    try expectPiSieveCountingMatchesGetPrimesInRange(allocator, 9_990_000, 10_000_000);

}

test "piSieveCounting with a range start reaching the large tier" {
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

const LayoutMod = @import("sieveEngine/layout.zig");

fn expectLayoutsAgree(allocator: std.mem.Allocator, layouts: LayoutMod.QueryLayouts, start: usize, limit: usize) !void {
    const expected = try Primes.piSieveCounting(allocator, start, limit);
    const counted = try Primes.piSieveCountingWithLayouts(allocator, start, limit, layouts);
    if (counted != expected) {
        std.debug.print("segment={} l1Stride={} l2Stride={} selfSegment={} presieve={t} start={} limit={}: counted={} expected={}\n", .{
            layouts.query.segmentElems,
            layouts.query.l1StrideElems,
            layouts.query.l2StrideElems,
            layouts.selfSieve.segmentElems,
            layouts.query.presieve,
            start,
            limit,
            counted,
            expected,
        });
    }
    try std.testing.expectEqual(expected, counted);
}

test "piSieveCounting agrees across explicit layouts and presieves" {
    const allocator = std.testing.allocator;

    const shapes = [_][3]usize{
        .{ 4096, 4096, 4096 },
        .{ 8192, 2048, 4096 },
        .{ 16 * 1024, 1024, 8192 },
        .{ 64 * 1024, 1024, 1024 },
        .{ 64 * 1024, 1024, 16 * 1024 },
    };
    const ranges = [_][2]usize{
        .{ 0, 10_000_000 },
        .{ 999_000_000, 1_000_000_000 },
        .{ 999_999_000_000, 1_000_000_000_000 },
        .{ 3_999_999_000_000, 4_000_000_000_000 },
    };

    for (shapes) |shape| {
        for ([_]LayoutMod.PresieveKind{ .build, .fallback }) |presieve| {
            const layouts = LayoutMod.QueryLayouts.pinned(shape[0], shape[1], shape[2], presieve);
            for (ranges) |range| try expectLayoutsAgree(allocator, layouts, range[0], range[1]);
        }
    }

    const mixed = LayoutMod.QueryLayouts{
        .query = LayoutMod.Layout.pinned(4096, 4096, 4096, .fallback),
        .selfSieve = LayoutMod.Layout.pinned(64 * 1024, 1024, 8192, .fallback),
    };
    for (ranges) |range| try expectLayoutsAgree(allocator, mixed, range[0], range[1]);

    const tiny = LayoutMod.QueryLayouts.pinned(4096, 4096, 4096, .fallback);
    try std.testing.expectEqual(@as(usize, 664_579), try Primes.piSieveCountingWithLayouts(allocator, 0, 10_000_000, tiny));
    try std.testing.expectEqual(@as(usize, 50_847_534), try Primes.piSieveCountingWithLayouts(allocator, 0, 1_000_000_000, LayoutMod.QueryLayouts.pinned(64 * 1024, 1024, 16 * 1024, .build)));
}

test "segment size per query stays within the hardware bounds" {
    const hw = LayoutMod.HardwareProfile.fromKiB(48, 1024, 16 * 1024);
    try std.testing.expectEqual(@as(usize, 512 * 1024), LayoutMod.segmentElemsForQuery(hw, 10_000_000_000));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), LayoutMod.segmentElemsForQuery(hw, 100_000_000_000));
    try std.testing.expectEqual(@as(usize, 2048 * 1024), LayoutMod.segmentElemsForQuery(hw, 1_000_000_000_000));
    try std.testing.expectEqual(@as(usize, 4096 * 1024), LayoutMod.segmentElemsForQuery(hw, 1_000_000_000_000_000_000));

    const noL3 = LayoutMod.HardwareProfile.fromKiB(32, 256, 0);
    try std.testing.expectEqual(@as(usize, 512 * 1024), LayoutMod.segmentElemsForQuery(noL3, 1_000_000_000_000_000_000));
    try std.testing.expectEqual(@as(usize, 128 * 1024), LayoutMod.segmentElemsForQuery(noL3, 100));

    const huge = LayoutMod.HardwareProfile.fromKiB(64, 16 * 1024, 256 * 1024);
    try std.testing.expectEqual(LayoutMod.MAX_SEGMENT_ELEMS, LayoutMod.segmentElemsForQuery(huge, std.math.maxInt(u64)));
}

test "divCeil matches exact ceiling division, including near the top of u64" {
    const Utils = @import("sieveEngine/utils.zig");
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const edgeNumerators = [_]u64{ 0, 1, 29, 30, 31, (1 << 53) - 1, 1 << 53, (1 << 53) + 1, std.math.maxInt(u64) - 1, std.math.maxInt(u64) };
    const edgeDivisors = [_]u64{ 1, 2, 30, (1 << 16) - 1, 1 << 16, (1 << 16) + 1, 4_294_967_291, 4_294_967_311, (1 << 53) + 1, std.math.maxInt(u64) };
    for (edgeNumerators) |a| {
        for (edgeDivisors) |b| {
            try std.testing.expectEqual(@as(u64, @intCast((@as(u128, a) + b - 1) / b)), Utils.divCeil(a, b));
        }
    }
    for (0..200_000) |_| {
        const a = random.int(u64);
        const b = switch (random.uintLessThan(u8, 3)) {
            0 => random.intRangeAtMost(u64, 1, 1 << 20),
            1 => random.intRangeAtMost(u64, 1 << 16, 1 << 33),
            else => random.int(u64) | 1,
        };
        try std.testing.expectEqual(@as(u64, @intCast((@as(u128, a) + b - 1) / b)), Utils.divCeil(a, b));
    }
}

test "piSieveCounting agrees across tuning extremes" {
    const allocator = std.testing.allocator;
    const hw = LayoutMod.HardwareProfile.fromKiB(32, 256, 1024);
    const tunings = [_]LayoutMod.Tuning{
        .{ .smallL1StrideDivisor = 2, .smallL2StrideDivisor = 2, .smallSegmentPercent = 200, .mediumSegmentFactor = 12 },
        .{ .smallL1StrideDivisor = 16, .smallL2StrideDivisor = 16, .smallSegmentPercent = 25, .mediumSegmentFactor = 2 },
        .{ .smallSegmentPercent = 10, .mediumSegmentFactor = 1 },
        .{ .smallSegmentPercent = 400, .mediumSegmentFactor = 64 },
        .{ .segmentMinKiB = 16, .segmentMaxKiB = 16, .l1StrideKiB = 1, .l2StrideKiB = 2, .presieve = .fallback },
        .{ .segmentMinKiB = 512, .segmentMaxKiB = 512, .l1StrideKiB = 64, .l2StrideKiB = 1024, .presieve = .build },
        .{ .segmentMinKiB = 16, .segmentMaxKiB = 16, .l1StrideKiB = 16, .l2StrideKiB = 16, .smallL1StrideDivisor = 1, .smallL2StrideDivisor = 1, .smallSegmentPercent = 10, .mediumSegmentFactor = 1 },
    };
    const ranges = [_][2]usize{
        .{ 0, 10_000_000 },
        .{ 999_000_000, 1_000_000_000 },
        .{ 999_999_000_000, 1_000_000_000_000 },
        .{ 99_999_999_000_000, 100_000_000_000_000 },
    };
    const base = LayoutMod.Selection{ .profile = hw, .presieve = .build, .detected = null };
    for (tunings) |tuning| {
        try tuning.validate();
        const selection = base.withTuning(tuning, .file);
        for (ranges) |range| try expectLayoutsAgree(allocator, LayoutMod.QueryLayouts.forSelection(selection, range[1]), range[0], range[1]);
    }
}

test "tuning files round-trip" {
    const tuning = LayoutMod.Tuning{ .segmentMaxKiB = 2048, .l2StrideKiB = 384, .smallL1StrideDivisor = 3, .mediumSegmentFactor = 8, .presieve = .fallback };
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tuning.write(&writer);
    try std.testing.expect(tuning.eql(try LayoutMod.Tuning.parse(writer.buffered())));
    try std.testing.expect(LayoutMod.Tuning.DEFAULT.eql(try LayoutMod.Tuning.parse("# only a comment\n\n")));
    try std.testing.expectError(error.UnknownKey, LayoutMod.Tuning.parse("segmentSize = 1\n"));
    try std.testing.expectError(error.OutOfRange, LayoutMod.Tuning.parse("segmentMaxKiB = 3\n"));
}

test "tuned layouts keep every tier within the primes it can handle" {
    const profiles = [_]LayoutMod.HardwareProfile{
        LayoutMod.HardwareProfile.fromKiB(32, 256, 0),
        LayoutMod.HardwareProfile.fromKiB(48, 1024, 32 * 1024),
        LayoutMod.HardwareProfile.fromKiB(128, 16 * 1024, 64 * 1024),
    };
    const strideKiBs = [_]usize{ 0, 1, 8, 64, 1024, LayoutMod.Tuning.MAX_SEGMENT_KIB };
    const divisors = [_]usize{ 1, 2, 5, 64 };
    const percents = [_]usize{ 10, 100, 400 };
    const factors = [_]usize{ 1, 5, 64 };
    for (profiles) |hw| {
        var segmentKiB: usize = LayoutMod.Tuning.MIN_SEGMENT_KIB;
        while (segmentKiB <= LayoutMod.Tuning.MAX_SEGMENT_KIB) : (segmentKiB *= 2) {
            for (strideKiBs) |l1| for (strideKiBs) |l2| for (divisors) |d| for (percents) |pct| for (factors) |f| {
                const tuning = LayoutMod.Tuning{ .segmentMinKiB = segmentKiB, .segmentMaxKiB = segmentKiB, .l1StrideKiB = l1, .l2StrideKiB = l2, .smallL1StrideDivisor = d, .smallL2StrideDivisor = d, .smallSegmentPercent = pct, .mediumSegmentFactor = f };
                try tuning.validate();
                const layout = LayoutMod.Layout.forQueryTuned(hw, 1_000_000_000_000, .fallback, tuning);
                try std.testing.expect(layout.isSound());
            };
        }
    }
    try std.testing.expect(LayoutMod.maxWheel30Advance(LayoutMod.maxPrimeAdvancingAtMost(4096)) <= 4096);
    try std.testing.expect(LayoutMod.maxWheel30Advance(LayoutMod.maxPrimeAdvancingAtMost(4096) + 1) > 4096);
}

test "a short last stride does not cross off an entry a second time" {
    const allocator = std.testing.allocator;
    const tuning = LayoutMod.Tuning{ .smallL1StrideDivisor = 1, .smallL2StrideDivisor = 1 };
    const layout = LayoutMod.Layout.tuned(16 * 1024, 7 * 1024, 15 * 1024, .fallback, tuning);
    const layouts = LayoutMod.QueryLayouts{ .query = layout, .selfSieve = layout };
    try std.testing.expectEqual(@as(usize, 482_449), try Primes.piSieveCountingWithLayouts(allocator, 1_000_000_000, 1_010_000_000, layouts));
}

const Tune = @import("tune.zig");

const FakeBench = struct {
    random: std.Random.DefaultPrng,
    noise: f64,
    gains: []const FakeGain,
    calls: usize = 0,

    const FakeGain = struct { mediumSegmentFactor: ?usize = null, smallL1StrideDivisor: ?usize = null, segmentMaxKiB: ?usize = null, l2StrideKiB: ?usize = null, smallL2StrideDivisor: ?usize = null, gain: f64 };

    fn bench(self: *FakeBench, scenarioCount: usize) Tune.Bench {
        return .{ .ptr = self, .scenarioCount = scenarioCount, .measureFn = measure };
    }

    fn measure(ptr: *anyopaque, tuning: LayoutMod.Tuning, scenario: usize) anyerror!?f64 {
        _ = scenario;
        const self: *FakeBench = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        var cost: f64 = 1;
        for (self.gains) |g| {
            const hit = (g.mediumSegmentFactor == null or g.mediumSegmentFactor.? == tuning.mediumSegmentFactor) and
                (g.smallL1StrideDivisor == null or g.smallL1StrideDivisor.? == tuning.smallL1StrideDivisor) and
                (g.segmentMaxKiB == null or g.segmentMaxKiB.? == tuning.segmentMaxKiB) and
                (g.l2StrideKiB == null or g.l2StrideKiB.? == tuning.l2StrideKiB) and
                (g.smallL2StrideDivisor == null or g.smallL2StrideDivisor.? == tuning.smallL2StrideDivisor);
            if (hit) cost *= 1 - g.gain;
        }
        return cost * (1 + self.noise * self.random.random().float(f64));
    }
};

const FAKE_PROFILE = LayoutMod.HardwareProfile.fromKiB(48, 1024, 16 * 1024);

test "the tuner finds planted gains and ignores parameters that do not matter" {
    const gains = [_]FakeBench.FakeGain{
        .{ .mediumSegmentFactor = 8, .gain = 0.10 },
        .{ .smallL1StrideDivisor = 3, .gain = 0.05 },
    };
    var fake = FakeBench{ .random = .init(1), .noise = 0.005, .gains = &gains };
    const result = try Tune.tuneWith(std.testing.allocator, fake.bench(4), FAKE_PROFILE, .{ .verbose = false });
    var expected = LayoutMod.Tuning.DEFAULT;
    expected.mediumSegmentFactor = 8;
    expected.smallL1StrideDivisor = 3;
    try std.testing.expect(result.tuning.eql(expected));
}

test "the tuner refuses a machine that is too noisy" {
    var fake = FakeBench{ .random = .init(2), .noise = 0.5, .gains = &.{} };
    try std.testing.expectError(error.TooNoisy, Tune.tuneWith(std.testing.allocator, fake.bench(4), FAKE_PROFILE, .{ .verbose = false }));
}

test "the tuner does not mistake noise for a gain" {
    for (1..6) |seed| {
        var fake = FakeBench{ .random = .init(seed), .noise = 0.03, .gains = &.{} };
        const result = try Tune.tuneWith(std.testing.allocator, fake.bench(4), FAKE_PROFILE, .{ .verbose = false, .seed = seed });
        try std.testing.expect(result.tuning.eql(LayoutMod.Tuning.DEFAULT));
    }
}

test "races drop equal candidates after the minimum rounds" {
    var fake = FakeBench{ .random = .init(3), .noise = 0.001, .gains = &.{} };
    _ = try Tune.tuneWith(std.testing.allocator, fake.bench(4), FAKE_PROFILE, .{ .verbose = false });
    try std.testing.expect(fake.calls < 3200);
}

test "confidence intervals narrow with consistent ratios" {
    const tight = Tune.Stats.of(&.{ -0.05, -0.05, -0.05, -0.05 });
    try std.testing.expectApproxEqAbs(@as(f64, -0.05), tight.highLog, 1e-12);
    const loose = Tune.Stats.of(&.{ -0.10, 0.02, -0.08, 0.01 });
    try std.testing.expect(loose.lowLog < -0.1 and loose.highLog > 0);
}

test "pair moves find gains that need two parameters to change together" {
    const gains = [_]FakeBench.FakeGain{
        .{ .l2StrideKiB = 256, .gain = -0.05 },
        .{ .smallL2StrideDivisor = 8, .gain = -0.05 },
        .{ .l2StrideKiB = 256, .smallL2StrideDivisor = 8, .gain = 0.25 },
    };
    var fake = FakeBench{ .random = .init(4), .noise = 0.005, .gains = &gains };
    const result = try Tune.tuneWith(std.testing.allocator, fake.bench(4), FAKE_PROFILE, .{ .verbose = false });
    try std.testing.expectEqual(@as(usize, 256), result.tuning.l2StrideKiB);
    try std.testing.expectEqual(@as(usize, 8), result.tuning.smallL2StrideDivisor);
}
