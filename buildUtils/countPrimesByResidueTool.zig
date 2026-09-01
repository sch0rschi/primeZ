const std = @import("std");
const Io = std.Io;

// Plain relative import (not the named "buildUtils" module) -- this file
// runs standalone via a bare `zig run`, with no module map set up for it.
const WheelShape = @import("wheelShape.zig");

const RESIDUE_CLASS_COUNT = WheelShape.RESIDUE_CLASS_COUNT;

const SEGMENT_LEN = 32 * 1024;

fn countPrimesByResidue(
    allocator: std.mem.Allocator,
    lowerExclusive: usize,
    upperInclusive: usize,
) ![RESIDUE_CLASS_COUNT]usize {
    var counts = [_]usize{0} ** RESIDUE_CLASS_COUNT;
    if (upperInclusive <= lowerExclusive) return counts;

    const rootLimit = std.math.sqrt(upperInclusive) + 1;

    const rootIsComposite = try allocator.alloc(bool, rootLimit + 1);
    @memset(rootIsComposite, false);

    const basePrimes = try allocator.alloc(usize, rootLimit + 1);
    var basePrimeCount: usize = 0;

    var p: usize = 2;
    while (p <= rootLimit) : (p += 1) {
        if (!rootIsComposite[p]) {
            basePrimes[basePrimeCount] = p;
            basePrimeCount += 1;

            var multiple = p * p;
            while (multiple <= rootLimit) : (multiple += p) {
                rootIsComposite[multiple] = true;
            }
        }
    }

    var isComposite = [_]bool{false} ** SEGMENT_LEN;

    var segmentStart: usize = lowerExclusive + 1;
    while (segmentStart <= upperInclusive) {
        const segmentEndExclusive = @min(segmentStart + SEGMENT_LEN, upperInclusive + 1);

        for (isComposite[0 .. segmentEndExclusive - segmentStart]) |*c| c.* = false;

        for (basePrimes[0..basePrimeCount]) |bp| {
            var multiple = (segmentStart / bp) * bp;
            if (multiple < segmentStart) multiple += bp;
            if (multiple < bp * bp) multiple = bp * bp;

            while (multiple < segmentEndExclusive) : (multiple += bp) {
                isComposite[multiple - segmentStart] = true;
            }
        }

        var n = segmentStart;
        while (n < segmentEndExclusive) : (n += 1) {
            if (!isComposite[n - segmentStart]) {
                if (WheelShape.RESIDUE_CLASS_INDEX[n % WheelShape.CIRCUMFERENCE]) |idx| {
                    counts[idx] += 1;
                }
            }
        }

        segmentStart = segmentEndExclusive;
    }

    return counts;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: {s} <lowerExclusive> <upperInclusive>\n", .{args[0]});
        std.process.exit(1);
    }

    const lowerExclusive = try std.fmt.parseInt(usize, args[1], 10);
    const upperInclusive = try std.fmt.parseInt(usize, args[2], 10);

    const counts = try countPrimesByResidue(arena, lowerExclusive, upperInclusive);
    for (counts) |c| {
        try stdout.print("{d}\n", .{c});
    }
    try stdout.flush();
}
