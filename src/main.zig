const std = @import("std");
const builtin = @import("builtin");
const primeZ = @import("primeZ");
const LayoutMod = primeZ.Layout;

const DEFAULT_LIMIT: usize = 100_000_000_000;

fn printProfile(label: []const u8, profile: ?LayoutMod.HardwareProfile) void {
    if (profile) |p| {
        std.debug.print("{s} = L1d {d} KiB, L2 {d} KiB, L3 {d} KiB\n", .{ label, p.l1dBytes / 1024, p.l2Bytes / 1024, p.l3Bytes / 1024 });
    } else {
        std.debug.print("{s} = unavailable\n", .{label});
    }
}

fn printLayout(label: []const u8, layout: LayoutMod.Layout) void {
    std.debug.print("{s} segment = {d} KiB, l1Stride = {d} KiB, l2Stride = {d} KiB\n", .{ label, layout.segmentElems / 1024, layout.l1StrideElems / 1024, layout.l2StrideElems / 1024 });
    std.debug.print("{s} tiers = smallL1Stride<={d} smallL2Stride<={d} smallSegment<={d} medium<={d} preLarge<={d} large>{d}\n", .{
        label,
        layout.smallL1StrideThreshold,
        layout.smallL2StrideThreshold,
        layout.smallSegmentThreshold,
        layout.mediumThreshold,
        layout.preLargeThreshold,
        layout.preLargeThreshold,
    });
}

fn printTuning(selection: LayoutMod.Selection) void {
    std.debug.print("Tuning = {t}", .{selection.tuningSource});
    inline for (@typeInfo(LayoutMod.Tuning).@"struct".field_names) |name| {
        const value = @field(selection.tuning, name);
        if (value != @field(LayoutMod.Tuning.DEFAULT, name)) {
            if (@TypeOf(value) == usize) std.debug.print(" {s}={d}", .{ name, value }) else std.debug.print(" {s}={t}", .{ name, value });
        }
    }
    std.debug.print("\n", .{});
}

fn loadTuning(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !LayoutMod.Tuning {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 16));
    defer allocator.free(text);
    return LayoutMod.Tuning.parse(text) catch |err| {
        std.debug.print("error: {s}: {t}\n", .{ path, err });
        return err;
    };
}

fn userTuningPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, profile: LayoutMod.HardwareProfile) !?[]u8 {
    const fileName = try std.fmt.allocPrint(allocator, "tuning-{d}-{d}-{d}.txt", .{ profile.l1dBytes / 1024, profile.l2Bytes / 1024, profile.l3Bytes / 1024 });
    defer allocator.free(fileName);
    if (environ.get("PRIMEZ_TUNING_DIR")) |dir| return try std.fs.path.join(allocator, &.{ dir, fileName });
    if (environ.get("XDG_CONFIG_HOME")) |dir| return try std.fs.path.join(allocator, &.{ dir, "primez", fileName });
    if (builtin.os.tag == .windows) {
        if (environ.get("APPDATA")) |dir| return try std.fs.path.join(allocator, &.{ dir, "primez", fileName });
    }
    if (environ.get("HOME")) |dir| return try std.fs.path.join(allocator, &.{ dir, ".config", "primez", fileName });
    return null;
}

fn loadUserTuning(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?LayoutMod.Tuning {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 16)) catch |err| {
        if (err != error.FileNotFound) std.debug.print("warning: ignoring {s}: {t}\n", .{ path, err });
        return null;
    };
    defer allocator.free(text);
    return LayoutMod.Tuning.parse(text) catch |err| {
        std.debug.print("warning: ignoring {s}: {t} - rerun primez --tune\n", .{ path, err });
        return null;
    };
}

fn runTuner(allocator: std.mem.Allocator, io: std.Io, selection: LayoutMod.Selection, options: primeZ.Tune.Options, outPath: ?[]const u8) !void {
    const result = try primeZ.Tune.tune(allocator, io, selection, options);
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    try primeZ.Tune.writeTuningFile(&text.writer, result, selection.profile);
    if (outPath != null and !std.mem.eql(u8, outPath.?, "-")) {
        const path = outPath.?;
        if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.written() });
        std.debug.print("wrote {s}\n", .{path});
    } else {
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);
        try stdout.interface.writeAll(text.written());
        try stdout.interface.flush();
    }
}

fn parseProfile(text: []const u8) !LayoutMod.HardwareProfile {
    var fields = std.mem.tokenizeScalar(u8, text, ',');
    const l1 = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidProfile, 10);
    const l2 = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidProfile, 10);
    const l3 = try std.fmt.parseInt(usize, fields.next() orelse "0", 10);
    return LayoutMod.HardwareProfile.fromKiB(l1, l2, l3);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var argIter = try init.minimal.args.iterateAllocator(allocator);
    defer argIter.deinit();
    _ = argIter.next();

    var printOnly = false;
    var forceFallback = false;
    var emulated: ?LayoutMod.HardwareProfile = null;
    var tuningPath: ?[]const u8 = null;
    var noTuning = false;
    var tune = false;
    var tuneOut: ?[]const u8 = null;
    var tuneOptions: primeZ.Tune.Options = .{};
    var tuneCpu: ?usize = null;
    var positional: [2]usize = undefined;
    var positionalCount: usize = 0;
    while (argIter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--print-layout")) {
            printOnly = true;
        } else if (std.mem.eql(u8, arg, "--fallback")) {
            forceFallback = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            emulated = try parseProfile(argIter.next() orelse return error.MissingProfile);
        } else if (std.mem.eql(u8, arg, "--tuning")) {
            tuningPath = argIter.next() orelse return error.MissingTuningPath;
        } else if (std.mem.eql(u8, arg, "--no-tuning")) {
            noTuning = true;
        } else if (std.mem.eql(u8, arg, "--tune")) {
            tune = true;
        } else if (std.mem.eql(u8, arg, "--tune-out")) {
            tune = true;
            tuneOut = argIter.next() orelse return error.MissingTuneOutPath;
        } else if (std.mem.eql(u8, arg, "--tune-seconds")) {
            tuneOptions.targetSeconds = try std.fmt.parseFloat(f64, argIter.next() orelse return error.MissingTuneSeconds);
        } else if (std.mem.eql(u8, arg, "--tune-cpu")) {
            tuneCpu = try std.fmt.parseInt(usize, argIter.next() orelse return error.MissingTuneCpu, 10);
        } else if (std.mem.eql(u8, arg, "--tune-anyway")) {
            tuneOptions.allowNoisy = true;
        } else if (std.mem.eql(u8, arg, "--tune-max-passes")) {
            tuneOptions.maxPasses = @max(1, try std.fmt.parseInt(usize, argIter.next() orelse return error.MissingTuneMaxPasses, 10));
        } else if (std.mem.eql(u8, arg, "--tune-max-rounds")) {
            tuneOptions.maxRounds = @max(1, try std.fmt.parseInt(usize, argIter.next() orelse return error.MissingTuneMaxRounds, 10));
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

    var selection = if (tune) LayoutMod.untunedSelection() else LayoutMod.activeSelection();
    if (emulated) |hw| {
        selection = .{
            .profile = hw,
            .presieve = if (hw.eql(LayoutMod.BUILD_PROFILE)) .build else .fallback,
            .detected = selection.detected,
        };
    }
    const userPath = try userTuningPath(allocator, init.environ_map, selection.profile);
    defer if (userPath) |path| allocator.free(path);

    if (tune) {
        if (forceFallback) selection.presieve = .fallback;
        printProfile("Tuning for   ", selection.profile);
        const outPath = tuneOut orelse userPath orelse {
            std.debug.print("error: no HOME/XDG_CONFIG_HOME/PRIMEZ_TUNING_DIR to save the tuning in; pass --tune-out <file> or --tune-out - for stdout\n", .{});
            return error.NoTuningDirectory;
        };
        if (noTuning) {
            tuneOptions.start = LayoutMod.Tuning.DEFAULT;
        } else if (tuningPath) |path| {
            tuneOptions.start = try loadTuning(allocator, io, path);
            std.debug.print("Starting from {s}\n", .{path});
        } else if (if (userPath) |path| loadUserTuning(allocator, io, path) else null) |tuning| {
            tuneOptions.start = tuning;
            std.debug.print("Starting from {s}\n", .{userPath.?});
        } else if (LayoutMod.BUILD_TUNING != null and selection.profile.eql(LayoutMod.BUILD_PROFILE)) {
            tuneOptions.start = LayoutMod.BUILD_TUNING.?;
            std.debug.print("Starting from the build tuning\n", .{});
        }
        if (tuneCpu) |cpu| {
            primeZ.Tune.pinToCpu(cpu) catch |err| {
                std.debug.print("error: cannot pin to CPU {d}: {t}\n", .{ cpu, err });
                return err;
            };
            std.debug.print("Pinned to CPU {d}\n", .{cpu});
        }
        return runTuner(allocator, io, selection, tuneOptions, outPath);
    }
    if (noTuning) {
        selection = selection.withTuning(LayoutMod.Tuning.DEFAULT, .default);
    } else if (tuningPath) |path| {
        selection = selection.withTuning(try loadTuning(allocator, io, path), .file);
    } else if (userPath) |path| {
        if (loadUserTuning(allocator, io, path)) |tuning| selection = selection.withTuning(tuning, .user);
    }
    if (forceFallback) selection.presieve = .fallback;

    LayoutMod.overrideSelection(selection);

    const layouts = LayoutMod.layoutsForQuery(limit);

    printProfile("Build profile", LayoutMod.BUILD_PROFILE);
    printProfile("Detected     ", selection.detected);
    if (emulated != null) printProfile("Emulated     ", emulated);
    std.debug.print("Presieve = {t}{s}\n", .{ selection.presieve, if (primeZ.PreSieve.BUILD_IS_FALLBACK) " (build presieve is the fallback presieve)" else "" });
    const presieveKinds = if (primeZ.PreSieve.BUILD_IS_FALLBACK) .{LayoutMod.PresieveKind.fallback} else .{ LayoutMod.PresieveKind.build, LayoutMod.PresieveKind.fallback };
    inline for (presieveKinds) |kind| {
        const P = primeZ.PreSieve.of(kind);
        std.debug.print("  {s} {t} groups ({d}):", .{ if (kind == selection.presieve or primeZ.PreSieve.BUILD_IS_FALLBACK) "*" else " ", kind, P.GROUP_COUNT });
        inline for (P.GROUP_LIST) |group| std.debug.print(" {any}", .{group});
        std.debug.print("\n", .{});
    }
    printTuning(selection);
    if (userPath) |path| std.debug.print("User tuning file = {s}{s}\n", .{ path, if (selection.tuningSource == .user) "" else " (not used)" });
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
