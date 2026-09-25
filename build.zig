const std = @import("std");

const PresieveGroups = @import("buildUtils/presieveGroups.zig");
const CacheInfo = @import("buildUtils/cacheInfo.zig");

const GENERAL_PURPOSE_REGISTER_COUNT = "general_purpose_register_count";

const DETECTION_FALLBACK = 32;

const BuildProfile = struct {
    l1dKiB: usize,
    l2KiB: usize,
    l3KiB: usize,
    vecLen: usize,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.lang.Optimize,
        "optimize",
        "Prioritize performance, safety, or binary size (default: fast).",
    ) orelse .fast;

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

    const presieve_groups_fallback = writeGroupsFile(b, "presieve-groups-fallback.txt", &PresieveGroups.FALLBACK_GROUPS);
    const presieve_groups_build = solvePresieveGroups(b, profile);
    const presieve_patterns_tool = b.addExecutable(.{
        .name = "genPreSievePatterns",
        .root_module = b.createModule(.{
            .root_source_file = b.path("buildUtils/genPreSievePatternsTool.zig"),
            .target = b.graph.host,
            .optimize = .fast,
        }),
    });
    const presieve_patterns = PresievePatterns{
        .buildGroups = presieve_groups_build,
        .build = if (presieve_groups_build) |groups| computePreSievePatternsBlob(b, presieve_patterns_tool, groups) else null,
        .fallback = computePreSievePatternsBlob(b, presieve_patterns_tool, presieve_groups_fallback),
    };

    const options = b.addOptions();
    options.addOption(usize, "build_l1d_kib", profile.l1dKiB);
    options.addOption(usize, "build_l2_kib", profile.l2KiB);
    options.addOption(usize, "build_l3_kib", profile.l3KiB);
    options.addOption(usize, "pinned_segment_kib", pinned_segment_kib);
    options.addOption(bool, "build_presieve_is_fallback", presieve_groups_build == null);
    options.addOption(usize, GENERAL_PURPOSE_REGISTER_COUNT, general_purpose_register_count);

    const primeZ = b.addModule("primeZ", .{
        .root_source_file = b.path("src/lib/root.zig"),
    });
    primeZ.addOptions("primeZConfig", options);
    wireBuildUtils(b, primeZ, options, presieve_patterns);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/tests.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    test_mod.addOptions("primeZConfig", options);
    wireBuildUtils(b, test_mod, options, presieve_patterns);

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
}

fn resolveBuildProfile(b: *std.Build, target: std.Build.ResolvedTarget) BuildProfile {
    const l1 = b.option(usize, "l1_cache_size_in_kb", "L1 data cache size in KiB the build is optimized for. Auto-detected on native builds; cross builds default to the fallback profile.") orelse
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
    const needsDetection = target.query.isNative() and (l1 == null or l2 == null or l3 == null);
    if (needsDetection) b.graph.poisonCache();
    const detectedKiB: ?CacheInfo.HardwareProfile = if (needsDetection)
        if (CacheInfo.detect()) |hw| .{ .l1dBytes = hw.l1dBytes / 1024, .l2Bytes = hw.l2Bytes / 1024, .l3Bytes = hw.l3Bytes / 1024 } else null
    else
        null;
    const defaults = detectedKiB orelse blk: {
        if (l1 == null or l2 == null or l3 == null) {
            std.debug.print(
                "warning: cache sizes not given and not detectable for this target; building for the fallback profile ({d}/{d}/{d} KiB). Pass -Dl1cs/-Dl2cs/-Dl3cs to override.\n",
                .{ fallbackKiB.l1dBytes, fallbackKiB.l2Bytes, fallbackKiB.l3Bytes },
            );
        }
        break :blk fallbackKiB;
    };

    return .{
        .l1dKiB = l1 orelse defaults.l1dBytes,
        .l2KiB = l2 orelse defaults.l2Bytes,
        .l3KiB = l3 orelse defaults.l3Bytes,
        .vecLen = vectorLengthBytes(target.result),
    };
}

fn vectorLengthBytes(t: std.Target) usize {
    if (t.cpu.arch.isX86()) {
        if (std.Target.x86.featureSetHas(t.cpu.features, .avx512bw)) return 64;
        if (std.Target.x86.featureSetHas(t.cpu.features, .avx2)) return 32;
        return 16;
    }
    return 16;
}

const PresievePatterns = struct {
    buildGroups: ?std.Build.LazyPath,
    build: ?std.Build.LazyPath,
    fallback: std.Build.LazyPath,
};

fn writeGroupsFile(b: *std.Build, name: []const u8, groups: []const []const usize) std.Build.LazyPath {
    var text: std.ArrayList(u8) = .empty;
    for (groups) |group| {
        for (group, 0..) |prime, i| {
            if (i > 0) text.append(b.allocator, ',') catch @panic("OOM");
            text.print(b.allocator, "{d}", .{prime}) catch @panic("OOM");
        }
        text.append(b.allocator, '\n') catch @panic("OOM");
    }
    return b.addWriteFiles().add(name, text.items);
}

fn solvePresieveGroups(b: *std.Build, profile: BuildProfile) ?std.Build.LazyPath {
    const solve_enabled = b.option(bool, "presieve_solver", "Solve the build-optimal presieve groups for the build profile with presieveOpt's MILP (needs python3 and make; default: false). When false or unavailable, only the fallback presieve is built in.") orelse false;
    if (!solve_enabled) return null;

    if (b.graph.host.result.os.tag == .windows or b.findProgram(.{ .names = &.{"python3"} }) == null or b.findProgram(.{ .names = &.{"make"} }) == null) {
        std.debug.print("warning: python3 or make not available; only the fallback presieve is built in. Pass -Dpresieve_solver=false to silence this.\n", .{});
        return null;
    }

    const force_resolve = b.option(
        bool,
        "force-resolve-presieve-groups",
        "Wipe presieveOpt's solve cache first, forcing a fresh MILP solve even if every parameter is unchanged (default: false - reuses a cached solve when available).",
    ) orelse false;

    const venv = b.addSystemCommand(&.{ "make", "-C", "presieveOpt", "venv" });
    venv.setCwd(b.path("."));

    const solve = b.addSystemCommand(&.{
        "presieveOpt/.venv/bin/python",
        "presieveOpt/solve.py",
        "--objective",
        "costmodel",
        "--cache-target-kib",
        b.fmt("{d}", .{profile.l1dKiB}),
        "--vec-len",
        b.fmt("{d}", .{profile.vecLen}),
    });
    solve.setName(b.fmt("solve presieve groups (L1d {d} KiB, {d}-byte SIMD)", .{ profile.l1dKiB, profile.vecLen }));
    solve.setCwd(b.path("."));
    solve.addFileInput(b.path("presieveOpt/solve.py"));
    solve.addFileInput(b.path("presieveOpt/requirements.txt"));
    if (force_resolve) solve.addArg("--clear-cache");
    solve.addArg("--write-groups-to");
    const groups = solve.addOutputFileArg("presieve-groups.txt");
    _ = solve.captureStdOut(.{});
    solve.step.dependOn(&venv.step);
    return groups;
}

fn wireBuildUtils(b: *std.Build, lib: *std.Build.Module, options: *std.Build.Step.Options, presievePatterns: PresievePatterns) void {
    const buildUtils = b.createModule(.{
        .root_source_file = b.path("buildUtils/sieveLayout.zig"),
    });
    buildUtils.addOptions("primeZConfig", options);
    if (presievePatterns.buildGroups) |groups| buildUtils.addAnonymousImport("presieve_groups_build", .{ .root_source_file = groups });
    if (presievePatterns.build) |patterns| buildUtils.addAnonymousImport("presieve_patterns_build", .{ .root_source_file = patterns });
    buildUtils.addAnonymousImport("presieve_patterns_fallback", .{ .root_source_file = presievePatterns.fallback });
    lib.addImport("buildUtils", buildUtils);
}

fn computePreSievePatternsBlob(b: *std.Build, tool: *std.Build.Step.Compile, groups: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.addFileArg(groups);
    return run.captureStdOut(.{});
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
