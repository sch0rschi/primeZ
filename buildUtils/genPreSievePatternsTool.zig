const std = @import("std");
const Io = std.Io;

const PresieveGroups = @import("presieveGroups.zig");
const WheelShape = @import("wheelShape.zig");

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
