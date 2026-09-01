const std = @import("std");

const L1_CACHE_SIZE_IN_KB = "l1_cache_size_in_kb";
const L2_CACHE_SIZE_IN_KB = "l2_cache_size_in_kb";
const OPT_SEGMENT_SIZE_IN_KB = "opt_segment_size_in_kb";
const GENERAL_PURPOSE_REGISTER_COUNT = "general_purpose_register_count";

const DETECTION_FALLBACK = 32;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseFast).",
    ) orelse .ReleaseFast;

    const l1_cache_size_in_kb =
        b.option(
            usize,
            L1_CACHE_SIZE_IN_KB,
            "L1 data cache size in KiB. Auto-detected on native Linux/macOS builds.",
        ) orelse b.option(
            usize,
            "l1cs",
            "Short alias for l1_cache_size_in_kb.",
        ) orelse detectL1CacheSizeKiB(b, target);

    const l2_cache_size_in_kb =
        b.option(
            usize,
            L2_CACHE_SIZE_IN_KB,
            "L2 cache size in KiB, 0 if none/undetected. Auto-detected on native Linux/macOS builds.",
        ) orelse b.option(
            usize,
            "l2cs",
            "Short alias for l2_cache_size_in_kb.",
        ) orelse detectL2CacheSizeKiB(b, target) orelse 0;

    const opt_segment_size_in_kb = computeOptSegmentSizeKiB(l1_cache_size_in_kb, l2_cache_size_in_kb);

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

    const options = b.addOptions();
    options.addOption(usize, L1_CACHE_SIZE_IN_KB, l1_cache_size_in_kb);
    options.addOption(usize, OPT_SEGMENT_SIZE_IN_KB, opt_segment_size_in_kb);
    options.addOption(usize, GENERAL_PURPOSE_REGISTER_COUNT, general_purpose_register_count);

    const primeZ = b.addModule("primeZ", .{
        .root_source_file = b.path("src/lib/root.zig"),
    });
    primeZ.addOptions("primeZConfig", options);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const test_options = b.addOptions();
    test_options.addOption(usize, L1_CACHE_SIZE_IN_KB, 4);
    test_options.addOption(usize, OPT_SEGMENT_SIZE_IN_KB, 4);
    test_options.addOption(usize, GENERAL_PURPOSE_REGISTER_COUNT, 16);
    test_mod.addOptions("primeZConfig", test_options);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.installArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primeZ", .module = primeZ },
        },
    });
    const cli_options = b.addOptions();
    cli_options.addOption(usize, L1_CACHE_SIZE_IN_KB, l1_cache_size_in_kb);
    cli_options.addOption(usize, OPT_SEGMENT_SIZE_IN_KB, opt_segment_size_in_kb);
    cli_mod.addOptions("cliConfig", cli_options);

    const cli_exe = b.addExecutable(.{
        .name = "primez",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);
}

fn detectL1CacheSizeKiB(b: *std.Build, target: std.Build.ResolvedTarget) usize {
    return detectCacheSizeKiB(b, target, "LEVEL1_DCACHE_SIZE", "hw.l1dcachesize") orelse {
        std.debug.print(
            "warning: L1 cache size auto-detection failed or is unsupported on this target; using fallback of {d} KiB. Pass -D{s}=<KiB> to override.\n",
            .{ DETECTION_FALLBACK, L1_CACHE_SIZE_IN_KB },
        );
        return DETECTION_FALLBACK;
    };
}

fn detectL2CacheSizeKiB(b: *std.Build, target: std.Build.ResolvedTarget) ?usize {
    return detectCacheSizeKiB(b, target, "LEVEL2_CACHE_SIZE", "hw.l2cachesize");
}

fn detectCacheSizeKiB(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    linuxGetconfKey: []const u8,
    macosSysctlKey: []const u8,
) ?usize {
    if (!target.query.isNative()) return null;

    const argv: []const []const u8 = switch (target.result.os.tag) {
        .linux => &.{ "getconf", linuxGetconfKey },
        .macos => &.{ "sysctl", "-n", macosSysctlKey },
        else => return null,
    };

    var code: u8 = undefined;
    const stdout = b.runAllowFail(argv, &code, .inherit) catch return null;
    const bytes = std.fmt.parseInt(usize, std.mem.trim(u8, stdout, " \t\r\n"), 10) catch return null;
    if (bytes == 0) return null;
    return bytes / 1024;
}

fn computeOptSegmentSizeKiB(l1CacheSizeKiB: usize, l2CacheSizeKiB: usize) usize {
    if (l2CacheSizeKiB == 0) return floorPow2Clamped(l1CacheSizeKiB);

    const maxFromL2 = l2CacheSizeKiB / 2;
    const maxSize = @max(l1CacheSizeKiB, maxFromL2);
    const size = @min(l1CacheSizeKiB * 8, maxSize);
    return floorPow2Clamped(size);
}

fn floorPow2Clamped(kib: usize) usize {
    const clamped = std.math.clamp(kib, 16, 8192);
    return @as(usize, 1) << std.math.log2_int(usize, clamped);
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
