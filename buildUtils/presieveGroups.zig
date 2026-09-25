pub const FALLBACK_GROUPS = [_][]const usize{
    &[_]usize{ 7, 67, 71 },
    &[_]usize{ 11, 41, 73 },
    &[_]usize{ 13, 43, 59 },
    &[_]usize{ 17, 37, 53 },
    &[_]usize{ 19, 29, 61 },
    &[_]usize{ 23, 31, 47 },
    &[_]usize{ 79, 97 },
    &[_]usize{ 83, 89 },
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
