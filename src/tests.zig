const std = @import("std");

const Comptimes = @import("comptimes.zig");
const Check = @import("primeCheck.zig");
const Utils = @import("utils.zig");
const QuerySieve = @import("querySieve.zig").QuerySieve;

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

test "Comptime GAP_PATTERN" {
    const expectedGapPattern: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = .{ 6, 4, 2, 4, 2, 4, 6, 2 };
    var actualGapPattern: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = undefined;
    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |i| {
        actualGapPattern[i] = Comptimes.GAP_PATTERN[i];
    }
    for (expectedGapPattern, actualGapPattern) |e, a| {
        try std.testing.expectEqual(e, a);
    }
}

test "Sieve with primes" {
    var sieveWithPrimesSmall = try QuerySieve.init(std.testing.allocator, 10_000);
    defer sieveWithPrimesSmall.deinit();

    const primesFromSmallSieve = try sieveWithPrimesSmall.getPrimes(std.testing.allocator);
    defer std.testing.allocator.free(primesFromSmallSieve);

    try std.testing.expectEqual(2, primesFromSmallSieve[0]);
    try std.testing.expectEqual(3, primesFromSmallSieve[1]);
    try std.testing.expectEqual(5, primesFromSmallSieve[2]);
    try std.testing.expectEqual(7, primesFromSmallSieve[3]);
    try std.testing.expectEqual(11, primesFromSmallSieve[4]);
    try std.testing.expectEqual(13, primesFromSmallSieve[5]);
    try std.testing.expectEqual(17, primesFromSmallSieve[6]);
    try std.testing.expectEqual(19, primesFromSmallSieve[7]);
    try std.testing.expectEqual(23, primesFromSmallSieve[8]);
    try std.testing.expectEqual(29, primesFromSmallSieve[9]);
    try std.testing.expectEqual(31, primesFromSmallSieve[10]);
    try std.testing.expectEqual(37, primesFromSmallSieve[11]);
    try std.testing.expectEqual(41, primesFromSmallSieve[12]);
    try std.testing.expectEqual(43, primesFromSmallSieve[13]);
    try std.testing.expectEqual(47, primesFromSmallSieve[14]);
    try std.testing.expectEqual(53, primesFromSmallSieve[15]);
    try std.testing.expectEqual(59, primesFromSmallSieve[16]);
    try std.testing.expectEqual(61, primesFromSmallSieve[17]);
    try std.testing.expectEqual(67, primesFromSmallSieve[18]);
    try std.testing.expectEqual(71, primesFromSmallSieve[19]);
    try std.testing.expectEqual(73, primesFromSmallSieve[20]);
    try std.testing.expectEqual(79, primesFromSmallSieve[21]);
    try std.testing.expectEqual(83, primesFromSmallSieve[22]);
    try std.testing.expectEqual(89, primesFromSmallSieve[23]);
    try std.testing.expectEqual(97, primesFromSmallSieve[24]);
    try std.testing.expectEqual(101, primesFromSmallSieve[25]);
    try std.testing.expectEqual(103, primesFromSmallSieve[26]);
    try std.testing.expectEqual(107, primesFromSmallSieve[27]);
    try std.testing.expectEqual(109, primesFromSmallSieve[28]);
    try std.testing.expectEqual(113, primesFromSmallSieve[29]);
    try std.testing.expectEqual(127, primesFromSmallSieve[30]);
    try std.testing.expectEqual(131, primesFromSmallSieve[31]);
    try std.testing.expectEqual(137, primesFromSmallSieve[32]);
    try std.testing.expectEqual(139, primesFromSmallSieve[33]);
    try std.testing.expectEqual(149, primesFromSmallSieve[34]);
    try std.testing.expectEqual(151, primesFromSmallSieve[35]);
    try std.testing.expectEqual(157, primesFromSmallSieve[36]);
    try std.testing.expectEqual(163, primesFromSmallSieve[37]);
    try std.testing.expectEqual(167, primesFromSmallSieve[38]);
    try std.testing.expectEqual(173, primesFromSmallSieve[39]);
    try std.testing.expectEqual(179, primesFromSmallSieve[40]);
    try std.testing.expectEqual(181, primesFromSmallSieve[41]);
    try std.testing.expectEqual(191, primesFromSmallSieve[42]);
    try std.testing.expectEqual(193, primesFromSmallSieve[43]);
    try std.testing.expectEqual(197, primesFromSmallSieve[44]);
    try std.testing.expectEqual(199, primesFromSmallSieve[45]);
    try std.testing.expectEqual(211, primesFromSmallSieve[46]);
    try std.testing.expectEqual(223, primesFromSmallSieve[47]);
    try std.testing.expectEqual(227, primesFromSmallSieve[48]);
    try std.testing.expectEqual(229, primesFromSmallSieve[49]);
    try std.testing.expectEqual(233, primesFromSmallSieve[50]);
    try std.testing.expectEqual(239, primesFromSmallSieve[51]);
    try std.testing.expectEqual(241, primesFromSmallSieve[52]);
    try std.testing.expectEqual(251, primesFromSmallSieve[53]);
    try std.testing.expectEqual(257, primesFromSmallSieve[54]);
    try std.testing.expectEqual(263, primesFromSmallSieve[55]);
    try std.testing.expectEqual(269, primesFromSmallSieve[56]);
    try std.testing.expectEqual(271, primesFromSmallSieve[57]);
    try std.testing.expectEqual(277, primesFromSmallSieve[58]);
    try std.testing.expectEqual(281, primesFromSmallSieve[59]);
    try std.testing.expectEqual(283, primesFromSmallSieve[60]);
    try std.testing.expectEqual(293, primesFromSmallSieve[61]);
    try std.testing.expectEqual(307, primesFromSmallSieve[62]);
    try std.testing.expectEqual(311, primesFromSmallSieve[63]);
    try std.testing.expectEqual(313, primesFromSmallSieve[64]);
    try std.testing.expectEqual(317, primesFromSmallSieve[65]);
    try std.testing.expectEqual(331, primesFromSmallSieve[66]);
    try std.testing.expectEqual(337, primesFromSmallSieve[67]);
    try std.testing.expectEqual(347, primesFromSmallSieve[68]);
    try std.testing.expectEqual(349, primesFromSmallSieve[69]);
    try std.testing.expectEqual(353, primesFromSmallSieve[70]);
    try std.testing.expectEqual(359, primesFromSmallSieve[71]);
    try std.testing.expectEqual(367, primesFromSmallSieve[72]);
    try std.testing.expectEqual(373, primesFromSmallSieve[73]);
    try std.testing.expectEqual(379, primesFromSmallSieve[74]);
    try std.testing.expectEqual(383, primesFromSmallSieve[75]);
    try std.testing.expectEqual(389, primesFromSmallSieve[76]);
    try std.testing.expectEqual(397, primesFromSmallSieve[77]);
    try std.testing.expectEqual(401, primesFromSmallSieve[78]);
    try std.testing.expectEqual(409, primesFromSmallSieve[79]);
    try std.testing.expectEqual(419, primesFromSmallSieve[80]);
    try std.testing.expectEqual(421, primesFromSmallSieve[81]);
    try std.testing.expectEqual(431, primesFromSmallSieve[82]);
    try std.testing.expectEqual(433, primesFromSmallSieve[83]);
    try std.testing.expectEqual(439, primesFromSmallSieve[84]);
    try std.testing.expectEqual(443, primesFromSmallSieve[85]);
    try std.testing.expectEqual(449, primesFromSmallSieve[86]);
    try std.testing.expectEqual(457, primesFromSmallSieve[87]);
    try std.testing.expectEqual(461, primesFromSmallSieve[88]);
    try std.testing.expectEqual(463, primesFromSmallSieve[89]);
    try std.testing.expectEqual(467, primesFromSmallSieve[90]);
    try std.testing.expectEqual(479, primesFromSmallSieve[91]);
    try std.testing.expectEqual(487, primesFromSmallSieve[92]);
    try std.testing.expectEqual(491, primesFromSmallSieve[93]);
    try std.testing.expectEqual(499, primesFromSmallSieve[94]);
    try std.testing.expectEqual(503, primesFromSmallSieve[95]);
    try std.testing.expectEqual(509, primesFromSmallSieve[96]);
    try std.testing.expectEqual(521, primesFromSmallSieve[97]);
    try std.testing.expectEqual(523, primesFromSmallSieve[98]);
    try std.testing.expectEqual(541, primesFromSmallSieve[99]);
    try std.testing.expectEqual(1_229, primesFromSmallSieve.len);
    try std.testing.expectEqual(9_973, primesFromSmallSieve[1_228]);

    var failCount: u8 = 0;
    for (0..10_000) |n| {
        if (Check.isPrime(n) != sieveWithPrimesSmall.isPrime(n)) {
            std.debug.print("Number: {}, expected: {}, actual: {}.\n", .{ n, Check.isPrime(n), sieveWithPrimesSmall.isPrime(n) });
            failCount += 1;
            if (failCount >= 10) {
                break;
            }
        }
    }
    try std.testing.expectEqual(0, failCount);

    var sieveWithPrimesLarge = try QuerySieve.init(std.testing.allocator, 100_000_000);
    defer sieveWithPrimesLarge.deinit();
}
