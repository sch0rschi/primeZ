pub const FALLBACK_L1D_KIB = 32;
pub const FALLBACK_VEC_LEN = 32;

pub const FALLBACK_GROUPS = [_][]const usize{
    &[_]usize{ 17, 73, 101 },
    &[_]usize{ 31, 53, 97 },
    &[_]usize{ 23, 37, 89 },
    &[_]usize{ 43, 61, 83 },
    &[_]usize{ 7, 13, 59, 79 },
    &[_]usize{ 47, 67, 71 },
    &[_]usize{ 11, 19, 29, 41 },
};

pub const GROUP_COUNT = FALLBACK_GROUPS.len;

pub fn periodOf(primes: []const usize) usize {
    var period: usize = 1;
    for (primes) |p| period *= p;
    return period;
}

pub fn parseGroups(comptime text: []const u8) []const []const usize {
    comptime {
        @setEvalBranchQuota(1_000_000);
        const std = @import("std");
        var groups: []const []const usize = &.{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var group: []const usize = &.{};
            var fields = std.mem.tokenizeScalar(u8, line, ',');
            while (fields.next()) |field| {
                const prime = std.fmt.parseInt(usize, std.mem.trim(u8, field, " \t\r"), 10) catch @compileError("invalid prime in presieve groups: " ++ field);
                group = group ++ .{prime};
            }
            if (group.len > 0) groups = groups ++ .{group};
        }
        if (groups.len == 0) @compileError("presieve groups file contains no groups");
        const result = groups;
        return result;
    }
}
