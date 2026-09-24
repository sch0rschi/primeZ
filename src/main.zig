const std = @import("std");
const primeZ = @import("primeZ");
const LayoutMod = primeZ.Layout;

const DEFAULT_LIMIT: usize = 100_000_000_000;

fn printProfile(label: []const u8, p: LayoutMod.HardwareProfile) void {
    std.debug.print("{s} = L1d {d} KiB, L2 {d} KiB, L3 {d} KiB\n", .{ label, p.l1dBytes / 1024, p.l2Bytes / 1024, p.l3Bytes / 1024 });
}

fn printLayout(label: []const u8, layout: LayoutMod.Layout) void {
    std.debug.print("{s} segment = {d} KiB, stripe = {d} KiB\n", .{ label, layout.segmentElems / 1024, layout.stripeElems / 1024 });
    std.debug.print("{s} tiers = smallStride<={d} smallSegment<={d} medium<={d} preLarge<={d} large>{d}\n", .{
        label,
        layout.smallStrideThreshold,
        layout.smallSegmentThreshold,
        layout.mediumThreshold,
        layout.preLargeThreshold,
        layout.preLargeThreshold,
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var argIter = init.minimal.args.iterate();
    _ = argIter.next();

    var printOnly = false;
    var positional: [2]usize = undefined;
    var positionalCount: usize = 0;
    while (argIter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--print-layout")) {
            printOnly = true;
        } else {
            if (positionalCount == positional.len) return error.TooManyArguments;
            positional[positionalCount] = try std.fmt.parseInt(usize, arg, 10);
            positionalCount += 1;
        }
    }

    var start: usize = 0;
    var limit: usize = DEFAULT_LIMIT;
    switch (positionalCount) {
        0 => {},
        1 => limit = positional[0],
        else => {
            start = positional[0];
            limit = positional[1];
        },
    }

    const layouts = LayoutMod.layoutsForQuery(limit);

    printProfile("Build profile", LayoutMod.BUILD_PROFILE);
    printLayout("Query", layouts.query);
    printLayout("Self-sieve", layouts.selfSieve);
    std.debug.print("Threads = 1\n", .{});
    std.debug.print("Start = {d}\n", .{start});
    std.debug.print("Limit = {d}\n", .{limit});
    if (printOnly) return;

    const t0 = std.Io.Clock.now(.awake, io);
    const primeCount = try primeZ.Primes.piSieveCountingWithLayouts(allocator, start, limit, layouts);
    const t1 = std.Io.Clock.now(.awake, io);

    const durationNs = t0.durationTo(t1).toNanoseconds();

    std.debug.print("Seconds: {d:.3}\n", .{@as(f64, @floatFromInt(durationNs)) / std.time.ns_per_s});
    std.debug.print("Primes: {d}\n", .{primeCount});
}
