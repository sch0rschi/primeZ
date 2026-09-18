const std = @import("std");
const primeZ = @import("primeZ");
const config = @import("cliConfig");

const DEFAULT_LIMIT: usize = 100_000_000_000;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var argIter = init.minimal.args.iterate();
    _ = argIter.next();

    var start: usize = 0;
    var limit: usize = DEFAULT_LIMIT;
    if (argIter.next()) |firstArg| {
        if (argIter.next()) |secondArg| {
            start = try std.fmt.parseInt(usize, firstArg, 10);
            limit = try std.fmt.parseInt(usize, secondArg, 10);
        } else {
            limit = try std.fmt.parseInt(usize, firstArg, 10);
        }
    }

    const t0 = std.Io.Clock.now(.awake, io);
    const primeCount = try primeZ.Primes.piSieveCounting(allocator, start, limit);
    const t1 = std.Io.Clock.now(.awake, io);

    const durationNs = t0.durationTo(t1).toNanoseconds();

    std.debug.print("Sieve size = {d} KiB\n", .{config.opt_segment_size_in_kb});
    std.debug.print("L1 stripe size = {d} KiB\n", .{config.l1_cache_size_in_kb});
    std.debug.print("Threads = 1\n", .{});
    std.debug.print("Start = {d}\n", .{start});
    std.debug.print("Limit = {d}\n", .{limit});
    std.debug.print("Seconds: {d:.3}\n", .{@as(f64, @floatFromInt(durationNs)) / std.time.ns_per_s});
    std.debug.print("Primes: {d}\n", .{primeCount});
}
