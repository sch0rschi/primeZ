const std = @import("std");

const StreamingSieve = @import("streamingSieve.zig").StreamingSieve;

const LIMIT = 22_801_763_489;
const NTH = 1_000_000_000;
const RUNS = 1;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const t0 = std.Io.Clock.now(.awake, io);
    for (0..RUNS) |_| {
        _ = try StreamingSieve.nthPrime(allocator, NTH);
    }
    const t1 = std.Io.Clock.now(.awake, io);

    std.debug.print("Looking up {}-th Prime, average runtime: {}ms\n", .{ NTH, @as(f64, @floatFromInt(t0.durationTo(t1).toMilliseconds())) / RUNS });
}

