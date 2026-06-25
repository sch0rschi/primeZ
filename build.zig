const std = @import("std");

const L1_CACHE_SIZE = "l1_cache_size";
const GENERAL_PURPOSE_REGISTER_COUNT = "general_purpose_register_count";

const DefaultBuildParameters = struct {
    l1_cache_size: usize,
    general_purpose_register_count: usize,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const default_build_parameters = computeDefaults(target.result);

    const l1_cache_size =
        b.option(
            usize,
            L1_CACHE_SIZE,
            "L1 data cache size in KiB.",
        ) orelse b.option(
            usize,
            "l1cs",
            "Short alias for l1_cache_size.",
        ) orelse default_build_parameters.l1_cache_size;

    const general_purpose_register_count =
        b.option(
            usize,
            GENERAL_PURPOSE_REGISTER_COUNT,
            "Architectural GPR count hint.",
        ) orelse b.option(
            usize,
            "gprc",
            "Short alias for general_purpose_register_count.",
        ) orelse default_build_parameters.general_purpose_register_count;

    const options = b.addOptions();
    options.addOption(usize, L1_CACHE_SIZE, l1_cache_size);
    options.addOption(usize, GENERAL_PURPOSE_REGISTER_COUNT, general_purpose_register_count);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const test_options = b.addOptions();
    test_options.addOption(usize, L1_CACHE_SIZE, 4);
    test_options.addOption(usize, GENERAL_PURPOSE_REGISTER_COUNT, 16);
    test_mod.addOptions("primeZConfig", test_options);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.installArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });

    benchmark_mod.addOptions("primeZConfig", options);

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = benchmark_mod,
    });

    const run_benchmark_exe = b.addRunArtifact(benchmark_exe);
    b.installArtifact(benchmark_exe);
    const benchmark_step = b.step("benchmark", "Run benchmarks");
    benchmark_step.dependOn(&run_benchmark_exe.step);

    const primeZ = b.addModule("primeZ", .{
        .root_source_file = b.path("src/root.zig"),
    });
    primeZ.addOptions("primeZConfig", options);
}

fn computeDefaults(target: std.Target) DefaultBuildParameters {
    const arch = target.cpu.arch;
    const os = target.os.tag;

    if (arch == .aarch64 or arch == .aarch64_be) {
        if (os == .macos) {
            return .{
                .l1_cache_size = 128,
                .general_purpose_register_count = 31,
            };
        }
        return .{
            .l1_cache_size = 64,
            .general_purpose_register_count = 31,
        };
    }

    if (arch == .x86_64) {
        return .{
            .l1_cache_size = 32,
            .general_purpose_register_count = 16,
        };
    }

    if (arch == .riscv64 or arch == .powerpc64 or arch == .powerpc64le) {
        return .{
            .l1_cache_size = 32,
            .general_purpose_register_count = 32,
        };
    }

    return .{
        .l1_cache_size = 32,
        .general_purpose_register_count = 16,
    };
}
