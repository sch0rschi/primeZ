const std = @import("std");

const Primes = @import("primes.zig");

const LIMIT = 10_000_000_000;

// Rust primal
// 100:         541             5.25 µs
// 1000:        7919            9.17 µs
// 10000:       104729          12.2 µs
// 100000:      1299709         93.3 µs
// 1000000:     15485863        838  µs
// 10000000:    179424673       13.6 ms
// 100000000:   2038074743      228  ms
// 1000000000:  22801763489     3.65 s
// 10000000000: 252097800623    61.1 s
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var limit: usize = 100;
    while (limit <= LIMIT / 100) {
        _ = try Primes.pi(allocator, limit);
        limit *= 10;
    }

    limit = 1;
    while (limit <= 1) {
        const t0 = std.Io.Clock.now(.awake, io);
        const nthPrime = try Primes.nthPrime(allocator, 1_000_000_000);
        const t1 = std.Io.Clock.now(.awake, io);

        const duration = try formatDuration(allocator, t0.durationTo(t1).toNanoseconds());
        defer allocator.free(duration);

        std.debug.print("{}: {} {s}\n", .{ limit,  nthPrime, duration });
        limit *= 10;
    }
}

pub fn formatDuration(allocator: std.mem.Allocator, ns: i96) ![]u8 {
    const us = 1000;
    const ms = us * 1000;
    const s  = ms * 1000;

    if (ns < us) {
        return std.fmt.allocPrint(allocator, "{d}ns", .{ns});
    } else if (ns < ms) {
        return std.fmt.allocPrint(
            allocator,
            "{d:.2}µs",
            .{@as(f64, @floatFromInt(ns)) / us},
        );
    } else if (ns < s) {
        return std.fmt.allocPrint(
            allocator,
            "{d:.2}ms",
            .{@as(f64, @floatFromInt(ns)) / ms},
        );
    } else {
        return std.fmt.allocPrint(
            allocator,
            "{d:.2}s",
            .{@as(f64, @floatFromInt(ns)) / s},
        );
    }
}