const std = @import("std");

const PresieveGroups = @import("buildUtils/presieveGroups.zig");
const CacheInfo = @import("buildUtils/cacheInfo.zig");

const GENERAL_PURPOSE_REGISTER_COUNT = "general_purpose_register_count";

const SOLVED_PRESIEVE_GROUPS_PATH = "zig-out/presieve-groups.txt";

const DETECTION_FALLBACK = 32;

const BuildProfile = struct {
    l1dKiB: usize,
    l2KiB: usize,
    l3KiB: usize,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseFast).",
    ) orelse .ReleaseFast;

    const profile = resolveBuildProfile(b, target);

    const pinned_segment_kib =
        b.option(usize, "opt_segment_size_in_kb", "Pin the segment size in KiB (power of two) instead of choosing it per query from the cache sizes.") orelse
        b.option(usize, "segsz", "Short alias for opt_segment_size_in_kb.") orelse 0;
    if (pinned_segment_kib != 0 and (!std.math.isPowerOfTwo(pinned_segment_kib) or pinned_segment_kib > 8192)) {
        std.debug.print("error: -Dsegsz must be a power of two <= 8192 KiB, got {d}\n", .{pinned_segment_kib});
        std.process.exit(1);
    }

    const general_purpose_register_count =
        b.option(
            usize,
            GENERAL_PURPOSE_REGISTER_COUNT,
            "Architectural GPR count hint.",
        ) orelse b.option(
            usize,
            "gprc",
            "Short alias for general_purpose_register_count.",
        ) orelse generalPurposeRegisterCount(target.result.cpu.arch);

    const presieve_groups = resolvePresieveGroups(b);
    const presieve_patterns_blob = computePreSievePatternsBlob(b, presieve_groups);

    const options = b.addOptions();
    options.addOption(usize, "build_l1d_kib", profile.l1dKiB);
    options.addOption(usize, "build_l2_kib", profile.l2KiB);
    options.addOption(usize, "build_l3_kib", profile.l3KiB);
    options.addOption(usize, "pinned_segment_kib", pinned_segment_kib);
    options.addOption(usize, GENERAL_PURPOSE_REGISTER_COUNT, general_purpose_register_count);
    options.addOption([]const []const usize, "presieve_groups", presieve_groups);
    options.addOption([]const u8, "presieve_patterns_blob", presieve_patterns_blob);

    const primeZ = b.addModule("primeZ", .{
        .root_source_file = b.path("src/lib/root.zig"),
    });
    primeZ.addOptions("primeZConfig", options);
    wireBuildUtils(b, primeZ, options);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    test_mod.addOptions("primeZConfig", options);
    wireBuildUtils(b, test_mod, options);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.installArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primeZ", .module = primeZ },
        },
    });

    const cli_exe = b.addExecutable(.{
        .name = "primez",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    wireRegenPresieveGroups(b);
}

fn resolveBuildProfile(b: *std.Build, target: std.Build.ResolvedTarget) BuildProfile {
    const l1 = b.option(usize, "l1_cache_size_in_kb", "L1 data cache size in KiB the build is optimized for. Auto-detected on native builds; cross builds default to 32 KiB.") orelse
        b.option(usize, "l1cs", "Short alias for l1_cache_size_in_kb.");
    const l2 = b.option(usize, "l2_cache_size_in_kb", "L2 cache size in KiB the build is optimized for (0 if none).") orelse
        b.option(usize, "l2cs", "Short alias for l2_cache_size_in_kb.");
    const l3 = b.option(usize, "l3_cache_size_in_kb", "L3 cache size in KiB the build is optimized for (0 if none).") orelse
        b.option(usize, "l3cs", "Short alias for l3_cache_size_in_kb.");

    const fallbackKiB = CacheInfo.HardwareProfile{
        .l1dBytes = CacheInfo.FALLBACK.l1dBytes / 1024,
        .l2Bytes = CacheInfo.FALLBACK.l2Bytes / 1024,
        .l3Bytes = CacheInfo.FALLBACK.l3Bytes / 1024,
    };
    const detectedKiB: ?CacheInfo.HardwareProfile = if (target.query.isNative() and (l1 == null or l2 == null or l3 == null))
        if (CacheInfo.detect()) |hw| .{ .l1dBytes = hw.l1dBytes / 1024, .l2Bytes = hw.l2Bytes / 1024, .l3Bytes = hw.l3Bytes / 1024 } else null
    else
        null;
    const defaults = detectedKiB orelse blk: {
        if (l1 == null or l2 == null or l3 == null) {
            std.debug.print(
                "warning: cache sizes not given and not detectable for this target; building for the default profile ({d}/{d}/{d} KiB). Pass -Dl1cs/-Dl2cs/-Dl3cs to override.\n",
                .{ fallbackKiB.l1dBytes, fallbackKiB.l2Bytes, fallbackKiB.l3Bytes },
            );
        }
        break :blk fallbackKiB;
    };

    return .{
        .l1dKiB = l1 orelse defaults.l1dBytes,
        .l2KiB = l2 orelse defaults.l2Bytes,
        .l3KiB = l3 orelse defaults.l3Bytes,
    };
}

fn wireRegenPresieveGroups(b: *std.Build) void {
    const force_resolve = b.option(
        bool,
        "force-resolve-presieve-groups",
        "For `zig build regen-presieve-groups`: wipe presieveOpt's solve cache first, forcing a fresh MILP solve even if every parameter is unchanged (default: false - reuses a cached solve when available).",
    ) orelse false;

    const venv = b.addSystemCommand(&.{ "make", "-C", "presieveOpt", "venv" });

    const solve = b.addSystemCommand(&.{
        b.pathFromRoot("presieveOpt/.venv/bin/python"),
        b.pathFromRoot("presieveOpt/solve.py"),
        "--objective",
        "costmodel",
        "--write-groups-to",
        b.pathFromRoot(SOLVED_PRESIEVE_GROUPS_PATH),
    });
    solve.step.dependOn(&venv.step);
    if (force_resolve) solve.addArg("--clear-cache");

    const step = b.step(
        "regen-presieve-groups",
        "Re-solve presieveOpt's costmodel MILP with this build's parameters and write the result to " ++ SOLVED_PRESIEVE_GROUPS_PATH ++ " (cached - see solve_cost_model_cached; pass -Dforce-resolve-presieve-groups=true to force a fresh solve; the next `zig build` picks up the result automatically)",
    );
    step.dependOn(&solve.step);
}

fn wireBuildUtils(b: *std.Build, lib: *std.Build.Module, options: *std.Build.Step.Options) void {
    const buildUtils = b.createModule(.{
        .root_source_file = b.path("buildUtils/sieveLayout.zig"),
    });
    buildUtils.addOptions("primeZConfig", options);
    lib.addImport("buildUtils", buildUtils);
}

fn resolvePresieveGroups(b: *std.Build) []const []const usize {
    const path = b.pathFromRoot(SOLVED_PRESIEVE_GROUPS_PATH);
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &PresieveGroups.GROUPS,
        else => {
            std.debug.print("error: failed to read {s}: {t}\n", .{ path, err });
            std.process.exit(1);
        },
    };

    var groups: std.ArrayList([]const usize) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var group: std.ArrayList(usize) = .empty;
        var fields = std.mem.tokenizeScalar(u8, line, ',');
        while (fields.next()) |field| {
            const prime = std.fmt.parseInt(usize, std.mem.trim(u8, field, " \t\r"), 10) catch {
                std.debug.print("error: {s}: invalid prime {s}\n", .{ path, field });
                std.process.exit(1);
            };
            group.append(b.allocator, prime) catch @panic("OOM");
        }
        if (group.items.len > 0) groups.append(b.allocator, group.items) catch @panic("OOM");
    }
    if (groups.items.len == 0) {
        std.debug.print("error: {s} exists but contains no groups\n", .{path});
        std.process.exit(1);
    }
    std.debug.print("using solved presieve groups from {s} ({d} groups)\n", .{ path, groups.items.len });
    return groups.items;
}

fn computePreSievePatternsBlob(b: *std.Build, groups: []const []const usize) []const u8 {
    const tool_path = b.pathFromRoot("buildUtils/genPreSievePatternsTool.zig");

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(b.allocator, &.{ b.graph.zig_exe, "run", "-OReleaseFast", tool_path, "--" }) catch @panic("OOM");
    for (groups) |group| {
        var spec: std.ArrayList(u8) = .empty;
        for (group, 0..) |prime, i| {
            if (i > 0) spec.append(b.allocator, ',') catch @panic("OOM");
            spec.print(b.allocator, "{d}", .{prime}) catch @panic("OOM");
        }
        argv.append(b.allocator, spec.items) catch @panic("OOM");
    }

    const io = b.graph.io;
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &b.graph.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("error: failed to spawn {s} to compute presieve pattern buffers: {s}\n", .{ tool_path, @errorName(err) });
        std.process.exit(1);
    };

    var stdout_reader = child.stdout.?.readerStreaming(io, &.{});
    const stdout = stdout_reader.interface.allocRemaining(b.allocator, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("error: failed to read {s}'s output: {s}\n", .{ tool_path, @errorName(err) });
        std.process.exit(1);
    };

    const term = child.wait(io) catch |err| {
        std.debug.print("error: failed to wait on {s}: {s}\n", .{ tool_path, @errorName(err) });
        std.process.exit(1);
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("error: {s} exited with code {d}\n", .{ tool_path, code });
            std.process.exit(1);
        },
        else => {
            std.debug.print("error: {s} terminated abnormally: {t}\n", .{ tool_path, term });
            std.process.exit(1);
        },
    }

    return stdout;
}

fn generalPurposeRegisterCount(arch: std.Target.Cpu.Arch) usize {
    return switch (arch) {
        .aarch64, .aarch64_be => 31,
        .x86_64 => 16,
        .riscv64, .powerpc64, .powerpc64le => 32,
        else => blk: {
            std.debug.print(
                "warning: no known GPR count for architecture {t}; using fallback of {d}. Pass -D{s}=<count> to override.\n",
                .{ arch, DETECTION_FALLBACK, GENERAL_PURPOSE_REGISTER_COUNT },
            );
            break :blk DETECTION_FALLBACK;
        },
    };
}
