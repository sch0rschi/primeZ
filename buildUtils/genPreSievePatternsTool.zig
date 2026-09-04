// Computes preSieve.zig's per-group AND-pattern buffers - the same crossing-
// off logic preSieve.zig used to run itself, inside a comptime block bounded
// by @setEvalBranchQuota(1 << 24). That interpreted comptime loop was the
// dominant cost of a full `zig build` (a few minutes): Zig's comptime VM
// walks the AST node-by-node with branch-quota bookkeeping on every
// iteration, which is dramatically slower per-op than compiled native code
// for a crossing-off sweep touching millions of positions across ~15 groups.
// This tool does the identical computation as plain runtime code, compiled
// once with -OReleaseFast and executed by build.zig (see
// computePreSievePatternsBlob there) via the same `zig run` pattern already
// used by countPrimesByResidueTool.zig - typically well under a second here
// versus minutes for the comptime version. Its stdout (raw bytes, one
// group's full pattern after another, in the same order as its argv)
// becomes the `presieve_patterns_blob` build option; preSieve.zig just
// slices that already-computed byte string at comptime (cheap: pointer/
// length arithmetic over a compile-time-known array, no interpretation)
// instead of recomputing it.
//
// Which GROUPS to use is a build.zig-level decision (resolvePresieveGroups
// there: a solved config if present, else PresieveGroups.GROUPS as a
// fallback) - not this tool's to make, so it takes the chosen groups as
// argv instead of importing PresieveGroups.GROUPS itself: one argument per
// group, primes comma-separated (e.g. `-- 7,67,71 11,41,73`).
//
// Plain relative imports (not the named "buildUtils" module) - this file
// runs standalone via a bare `zig run`, with no module map set up for it,
// same as countPrimesByResidueTool.zig.
const std = @import("std");
const Io = std.Io;

const PresieveGroups = @import("presieveGroups.zig");
const WheelShape = @import("wheelShape.zig");

// Duplicated from src/lib/sieveEngine/types.zig's SIEVE_BUCKET_TYPE: this
// tool has no reachable import path to that module-graph file from a bare
// `zig run`, and the byte layout this tool emits must match it exactly. If
// that type ever changes, update it here too.
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
