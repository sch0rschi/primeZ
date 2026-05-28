const std = @import("std");

const Comptimes = @import("comptimes.zig");
const Check = @import("prime_check.zig");
const Utils = @import("utils.zig");
const SegmentedSieve = @import("sieve_with_list.zig").SegmentedSieve;

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
    var sieveWithPrimesSmall = try SegmentedSieve.init(std.testing.allocator, 10_000);
    defer sieveWithPrimesSmall.deinit();

    try std.testing.expectEqual(2, sieveWithPrimesSmall.primes[0]);
    try std.testing.expectEqual(3, sieveWithPrimesSmall.primes[1]);
    try std.testing.expectEqual(5, sieveWithPrimesSmall.primes[2]);
    try std.testing.expectEqual(7, sieveWithPrimesSmall.primes[3]);
    try std.testing.expectEqual(11, sieveWithPrimesSmall.primes[4]);
    try std.testing.expectEqual(13, sieveWithPrimesSmall.primes[5]);
    try std.testing.expectEqual(17, sieveWithPrimesSmall.primes[6]);
    try std.testing.expectEqual(19, sieveWithPrimesSmall.primes[7]);
    try std.testing.expectEqual(23, sieveWithPrimesSmall.primes[8]);
    try std.testing.expectEqual(29, sieveWithPrimesSmall.primes[9]);
    try std.testing.expectEqual(31, sieveWithPrimesSmall.primes[10]);
    try std.testing.expectEqual(37, sieveWithPrimesSmall.primes[11]);
    try std.testing.expectEqual(41, sieveWithPrimesSmall.primes[12]);
    try std.testing.expectEqual(43, sieveWithPrimesSmall.primes[13]);
    try std.testing.expectEqual(47, sieveWithPrimesSmall.primes[14]);
    try std.testing.expectEqual(53, sieveWithPrimesSmall.primes[15]);
    try std.testing.expectEqual(59, sieveWithPrimesSmall.primes[16]);
    try std.testing.expectEqual(61, sieveWithPrimesSmall.primes[17]);
    try std.testing.expectEqual(67, sieveWithPrimesSmall.primes[18]);
    try std.testing.expectEqual(71, sieveWithPrimesSmall.primes[19]);
    try std.testing.expectEqual(73, sieveWithPrimesSmall.primes[20]);
    try std.testing.expectEqual(79, sieveWithPrimesSmall.primes[21]);
    try std.testing.expectEqual(83, sieveWithPrimesSmall.primes[22]);
    try std.testing.expectEqual(89, sieveWithPrimesSmall.primes[23]);
    try std.testing.expectEqual(97, sieveWithPrimesSmall.primes[24]);
    try std.testing.expectEqual(101, sieveWithPrimesSmall.primes[25]);
    try std.testing.expectEqual(103, sieveWithPrimesSmall.primes[26]);
    try std.testing.expectEqual(107, sieveWithPrimesSmall.primes[27]);
    try std.testing.expectEqual(109, sieveWithPrimesSmall.primes[28]);
    try std.testing.expectEqual(113, sieveWithPrimesSmall.primes[29]);
    try std.testing.expectEqual(127, sieveWithPrimesSmall.primes[30]);
    try std.testing.expectEqual(131, sieveWithPrimesSmall.primes[31]);
    try std.testing.expectEqual(137, sieveWithPrimesSmall.primes[32]);
    try std.testing.expectEqual(139, sieveWithPrimesSmall.primes[33]);
    try std.testing.expectEqual(149, sieveWithPrimesSmall.primes[34]);
    try std.testing.expectEqual(151, sieveWithPrimesSmall.primes[35]);
    try std.testing.expectEqual(157, sieveWithPrimesSmall.primes[36]);
    try std.testing.expectEqual(163, sieveWithPrimesSmall.primes[37]);
    try std.testing.expectEqual(167, sieveWithPrimesSmall.primes[38]);
    try std.testing.expectEqual(173, sieveWithPrimesSmall.primes[39]);
    try std.testing.expectEqual(179, sieveWithPrimesSmall.primes[40]);
    try std.testing.expectEqual(181, sieveWithPrimesSmall.primes[41]);
    try std.testing.expectEqual(191, sieveWithPrimesSmall.primes[42]);
    try std.testing.expectEqual(193, sieveWithPrimesSmall.primes[43]);
    try std.testing.expectEqual(197, sieveWithPrimesSmall.primes[44]);
    try std.testing.expectEqual(199, sieveWithPrimesSmall.primes[45]);
    try std.testing.expectEqual(211, sieveWithPrimesSmall.primes[46]);
    try std.testing.expectEqual(223, sieveWithPrimesSmall.primes[47]);
    try std.testing.expectEqual(227, sieveWithPrimesSmall.primes[48]);
    try std.testing.expectEqual(229, sieveWithPrimesSmall.primes[49]);
    try std.testing.expectEqual(233, sieveWithPrimesSmall.primes[50]);
    try std.testing.expectEqual(239, sieveWithPrimesSmall.primes[51]);
    try std.testing.expectEqual(241, sieveWithPrimesSmall.primes[52]);
    try std.testing.expectEqual(251, sieveWithPrimesSmall.primes[53]);
    try std.testing.expectEqual(257, sieveWithPrimesSmall.primes[54]);
    try std.testing.expectEqual(263, sieveWithPrimesSmall.primes[55]);
    try std.testing.expectEqual(269, sieveWithPrimesSmall.primes[56]);
    try std.testing.expectEqual(271, sieveWithPrimesSmall.primes[57]);
    try std.testing.expectEqual(277, sieveWithPrimesSmall.primes[58]);
    try std.testing.expectEqual(281, sieveWithPrimesSmall.primes[59]);
    try std.testing.expectEqual(283, sieveWithPrimesSmall.primes[60]);
    try std.testing.expectEqual(293, sieveWithPrimesSmall.primes[61]);
    try std.testing.expectEqual(307, sieveWithPrimesSmall.primes[62]);
    try std.testing.expectEqual(311, sieveWithPrimesSmall.primes[63]);
    try std.testing.expectEqual(313, sieveWithPrimesSmall.primes[64]);
    try std.testing.expectEqual(317, sieveWithPrimesSmall.primes[65]);
    try std.testing.expectEqual(331, sieveWithPrimesSmall.primes[66]);
    try std.testing.expectEqual(337, sieveWithPrimesSmall.primes[67]);
    try std.testing.expectEqual(347, sieveWithPrimesSmall.primes[68]);
    try std.testing.expectEqual(349, sieveWithPrimesSmall.primes[69]);
    try std.testing.expectEqual(353, sieveWithPrimesSmall.primes[70]);
    try std.testing.expectEqual(359, sieveWithPrimesSmall.primes[71]);
    try std.testing.expectEqual(367, sieveWithPrimesSmall.primes[72]);
    try std.testing.expectEqual(373, sieveWithPrimesSmall.primes[73]);
    try std.testing.expectEqual(379, sieveWithPrimesSmall.primes[74]);
    try std.testing.expectEqual(383, sieveWithPrimesSmall.primes[75]);
    try std.testing.expectEqual(389, sieveWithPrimesSmall.primes[76]);
    try std.testing.expectEqual(397, sieveWithPrimesSmall.primes[77]);
    try std.testing.expectEqual(401, sieveWithPrimesSmall.primes[78]);
    try std.testing.expectEqual(409, sieveWithPrimesSmall.primes[79]);
    try std.testing.expectEqual(419, sieveWithPrimesSmall.primes[80]);
    try std.testing.expectEqual(421, sieveWithPrimesSmall.primes[81]);
    try std.testing.expectEqual(431, sieveWithPrimesSmall.primes[82]);
    try std.testing.expectEqual(433, sieveWithPrimesSmall.primes[83]);
    try std.testing.expectEqual(439, sieveWithPrimesSmall.primes[84]);
    try std.testing.expectEqual(443, sieveWithPrimesSmall.primes[85]);
    try std.testing.expectEqual(449, sieveWithPrimesSmall.primes[86]);
    try std.testing.expectEqual(457, sieveWithPrimesSmall.primes[87]);
    try std.testing.expectEqual(461, sieveWithPrimesSmall.primes[88]);
    try std.testing.expectEqual(463, sieveWithPrimesSmall.primes[89]);
    try std.testing.expectEqual(467, sieveWithPrimesSmall.primes[90]);
    try std.testing.expectEqual(479, sieveWithPrimesSmall.primes[91]);
    try std.testing.expectEqual(487, sieveWithPrimesSmall.primes[92]);
    try std.testing.expectEqual(491, sieveWithPrimesSmall.primes[93]);
    try std.testing.expectEqual(499, sieveWithPrimesSmall.primes[94]);
    try std.testing.expectEqual(503, sieveWithPrimesSmall.primes[95]);
    try std.testing.expectEqual(509, sieveWithPrimesSmall.primes[96]);
    try std.testing.expectEqual(521, sieveWithPrimesSmall.primes[97]);
    try std.testing.expectEqual(523, sieveWithPrimesSmall.primes[98]);
    try std.testing.expectEqual(541, sieveWithPrimesSmall.primes[99]);
    try std.testing.expectEqual(1_229, sieveWithPrimesSmall.primes.len);
    try std.testing.expectEqual(9_973, sieveWithPrimesSmall.primes[1_228]);

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

    var sieveWithPrimesLarge = try SegmentedSieve.init(std.testing.allocator, 100_000_000);
    defer sieveWithPrimesLarge.deinit();
}
