const std = @import("std");

const Comptimes = @import("comptimes.zig");
const Check = @import("primeCheck.zig");
const Utils = @import("utils.zig");
const StreamingSieve = @import("streamingSieve.zig").StreamingSieve;

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

test "nth Prime" {
    const firstPrime = try StreamingSieve.nthPrime(std.testing.allocator, 0);
    try std.testing.expectEqual(2, firstPrime);
    const secondPrime = try StreamingSieve.nthPrime(std.testing.allocator, 1);
    try std.testing.expectEqual(3, secondPrime);
    const thirdPrime = try StreamingSieve.nthPrime(std.testing.allocator, 2);
    try std.testing.expectEqual(5, thirdPrime);
    const fourthPrime = try StreamingSieve.nthPrime(std.testing.allocator, 3);
    try std.testing.expectEqual(7, fourthPrime);
    const nthPrime = try StreamingSieve.nthPrime(std.testing.allocator, 10_000);
    try std.testing.expectEqual(104_743, nthPrime);
    const tenMillionthPrime = try StreamingSieve.nthPrime(std.testing.allocator, 10_000_000);
    try std.testing.expectEqual(179_424_691, tenMillionthPrime);
    const hundredMillionthPrime = try StreamingSieve.nthPrime(std.testing.allocator, 100_000_000);
    try std.testing.expectEqual(2_038_074_751, hundredMillionthPrime);
    //const billionthPrime = try StreamingSieve.nthPrime(std.testing.allocator, 1_000_000_000);
    //try std.testing.expectEqual(22_801_763_513, billionthPrime);
}
