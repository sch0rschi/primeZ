// Computes preSieve.zig's per-group AND-pattern buffers as plain runtime
// code (compiled with -OReleaseFast, run via build.zig's
// computePreSievePatternsBlob), instead of the same logic in a comptime
// block: the interpreted comptime VM was the dominant cost of a full
// `zig build` (a few minutes vs. well under a second here). Its stdout
// (raw bytes, one group's pattern after another) becomes the
// `presieve_patterns_blob` build option. Takes the groups to use as argv
// (one per group, primes comma-separated) rather than importing
// PresieveGroups.GROUPS, since which groups to use is build.zig's own
// decision (see resolvePresieveGroups).
//
// Plain relative imports, not the named "buildUtils" module: this file
// runs standalone via a bare `zig run`.
const std = @import("std");
const Io = std.Io;

const PresieveGroups = @import("presieveGroups.zig");
const WheelShape = @import("wheelShape.zig");

// Duplicated from src/lib/sieveEngine/types.zig's SIEVE_BUCKET_TYPE (no
// reachable import path from a bare `zig run`) - keep in sync.
const SIEVE_BUCKET_TYPE = u8;
const SIEVE_TYPE_SHIFT_TYPE = std.math.Log2Int(SIEVE_BUCKET_TYPE);

fn computeGroupPattern(allocator: std.mem.Allocator, primes: []const usize, period: usize) ![]SIEVE_BUCKET_TYPE {
    const pattern = try allocator.alloc(SIEVE_BUCKET_TYPE, period);
    @memset(pattern, std.math.maxInt(SIEVE_BUCKET_TYPE));

    for (primes) |p| {
        var multiple = p * p;
        const sweepEnd = multiple + WheelShape.CIRCUMFERENCE * (period + p);
        while (multiple < sweepEnd) : (multiple += p) {
            if (WheelShape.RESIDUE_CLASS_INDEX[multiple % WheelShape.CIRCUMFERENCE]) |inBucketIndex| {
                const bucketIndex = multiple / WheelShape.CIRCUMFERENCE;
                pattern[bucketIndex % period] &=
                    ~(@as(SIEVE_BUCKET_TYPE, 1) << @as(SIEVE_TYPE_SHIFT_TYPE, @intCast(inBucketIndex)));
            }
        }
    }

    return pattern;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |group_spec| {
        var primes: std.ArrayList(usize) = .empty;
        var fields = std.mem.tokenizeScalar(u8, group_spec, ',');
        while (fields.next()) |field| {
            try primes.append(arena, try std.fmt.parseInt(usize, field, 10));
        }
        const period = PresieveGroups.periodOf(primes.items);
        const pattern = try computeGroupPattern(arena, primes.items, period);
        try stdout.writeAll(pattern);
    }
    try stdout.flush();
}
