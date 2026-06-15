const std = @import("std");

const QuerySieve = @import("querySieve.zig").QuerySieve;

const LIMIT = 100_000_000;
const RUNS = 100;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const t0 = std.Io.Clock.now(.awake, io);
    for (0..RUNS) |_| {
        var segmentedSieve = try QuerySieve.init(allocator, LIMIT);
        const primes = try segmentedSieve.getPrimes(allocator);
        defer allocator.free(primes);
        iterator(segmentedSieve);
        defer segmentedSieve.deinit();
    }
    const t1 = std.Io.Clock.now(.awake, io);

    std.debug.print("Sieve limit: {}, average runtime: {}ms\n", .{LIMIT, @as(f64, @floatFromInt(t0.durationTo(t1).toMilliseconds())) / RUNS });
}

fn iterator(segmentedSieve: QuerySieve) void {
    var it = segmentedSieve.iter();
    var sum: usize = 0;
    while (it.next()) |p| {
        sum += p;
    }
}
