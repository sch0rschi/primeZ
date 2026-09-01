const std = @import("std");

const L1_CACHE_SIZE = "l1_cache_size";
const L1_CACHE_SIZE_IN_KB = "l1_cache_size_in_kb";
const GENERAL_PURPOSE_REGISTER_COUNT = "general_purpose_register_count";

const DETECTION_FALLBACK = 32;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const l1_cache_size =
        b.option(
            usize,
            L1_CACHE_SIZE,
            "L1 data cache size in KiB. Auto-detected on native Linux/macOS builds.",
        ) orelse b.option(
            usize,
            "l1cs",
            "Short alias for l1_cache_size.",
        ) orelse detectL1CacheSizeKiB(b, target);

    const l1_cache_size_in_kb =
        b.option(
            usize,
            L1_CACHE_SIZE_IN_KB,
            "Sieve segment size in KiB. Defaults to min(8x L1, L2/2), like primesieve's sieve size.",
        ) orelse b.option(
            usize,
            "l1kb",
            "Short alias for l1_cache_size_in_kb.",
        ) orelse detectSegmentSizeKiB(b, target, l1_cache_size);

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
    options.addOption(usize, L1_CACHE_SIZE, l1_cache_size);
    options.addOption(usize, L1_CACHE_SIZE_IN_KB, l1_cache_size_in_kb);
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
    test_options.addOption(usize, L1_CACHE_SIZE, 4);
    test_options.addOption(usize, L1_CACHE_SIZE_IN_KB, 4);
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
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "primeZ", .module = primeZ },
        },
    });
    const cli_options = b.addOptions();
    cli_options.addOption(usize, L1_CACHE_SIZE_IN_KB, l1_cache_size_in_kb);
    cli_mod.addOptions("cliConfig", cli_options);

    const cli_exe = b.addExecutable(.{
        .name = "primez",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);
}

fn detectL1CacheSizeKiB(b: *std.Build, target: std.Build.ResolvedTarget) usize {
    if (!target.query.isNative()) {
        std.debug.print(
            "warning: L1 cache size auto-detection needs a native build (not cross-compiling); using fallback of {d} KiB. Pass -D{s}=<KiB> to override.\n",
            .{ DETECTION_FALLBACK, L1_CACHE_SIZE },
        );
        return DETECTION_FALLBACK;
    }

    const argv: []const []const u8 = switch (target.result.os.tag) {
        .linux => &.{ "getconf", "LEVEL1_DCACHE_SIZE" },
        .macos => &.{ "sysctl", "-n", "hw.l1dcachesize" },
        else => |os| {
            std.debug.print(
                "warning: L1 cache size auto-detection is not supported on {t}; using fallback of {d} KiB. Pass -D{s}=<KiB> to override.\n",
                .{ os, DETECTION_FALLBACK, L1_CACHE_SIZE },
            );
            return DETECTION_FALLBACK;
        },
    };

    var code: u8 = undefined;
    const stdout = b.runAllowFail(argv, &code, .inherit) catch |err| {
        std.debug.print(
            "warning: failed to auto-detect L1 cache size via `{s}` ({t}); using fallback of {d} KiB. Pass -D{s}=<KiB> to override.\n",
            .{ argv[0], err, DETECTION_FALLBACK, L1_CACHE_SIZE },
        );
        return DETECTION_FALLBACK;
    };

    const bytes = std.fmt.parseInt(usize, std.mem.trim(u8, stdout, " \t\r\n"), 10) catch {
        std.debug.print(
            "warning: could not parse `{s}` output {s}; using fallback of {d} KiB. Pass -D{s}=<KiB> to override.\n",
            .{ argv[0], stdout, DETECTION_FALLBACK, L1_CACHE_SIZE },
        );
        return DETECTION_FALLBACK;
    };

    return bytes / 1024;
}

/// Mimics primesieve's default sieve size (see get_sieve_size() in
/// primesieve's api.cpp): a segment length of up to 8x the L1 cache size,
/// capped at half the L2 cache size, floored to a power of two. This is why
/// primesieve mostly avoids its "large sieving primes" phase on modern CPUs
/// with a sizeable L2 cache - the segment is big enough that few sieving
/// primes exceed the medium-prime threshold. We mimic the same bounds so
/// primeZ's small/medium/large split lines up with primesieve's. Despite the
/// name, this is usually larger than the raw L1_CACHE_SIZE value above.
fn detectSegmentSizeKiB(b: *std.Build, target: std.Build.ResolvedTarget, l1CacheSizeKiB: usize) usize {
    const l2CacheSizeKiB = detectL2CacheSizeKiB(b, target) orelse
        return floorPow2Clamped(l1CacheSizeKiB);

    const maxFromL2 = l2CacheSizeKiB / 2;
    const maxSize = @max(l1CacheSizeKiB, maxFromL2);
    const size = @min(l1CacheSizeKiB * 8, maxSize);
    return floorPow2Clamped(size);
}

/// Best-effort L2 cache size query; unlike L1 this has no hard failure mode
/// since some machines genuinely have no (or no queryable) L2 cache -
/// primesieve itself falls back to an L1-only sieve size in that case.
fn detectL2CacheSizeKiB(b: *std.Build, target: std.Build.ResolvedTarget) ?usize {
    if (!target.query.isNative()) return null;

    const argv: []const []const u8 = switch (target.result.os.tag) {
        .linux => &.{ "getconf", "LEVEL2_CACHE_SIZE" },
        .macos => &.{ "sysctl", "-n", "hw.l2cachesize" },
        else => return null,
    };

    var code: u8 = undefined;
    const stdout = b.runAllowFail(argv, &code, .inherit) catch return null;
    const bytes = std.fmt.parseInt(usize, std.mem.trim(u8, stdout, " \t\r\n"), 10) catch return null;
    if (bytes == 0) return null;
    return bytes / 1024;
}

fn floorPow2Clamped(kib: usize) usize {
    const clamped = std.math.clamp(kib, 16, 8192);
    return @as(usize, 1) << std.math.log2_int(usize, clamped);
}

/// Architectural GPR count. This is a fixed property of the target ISA (not
/// something a specific machine reports), so it is derived from the target
/// arch rather than queried from the OS.
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
