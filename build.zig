const std = @import("std");

pub fn build(b: *std.Build) void {
    const l1_cache_size =
        b.option(usize, "l1-cache-size", "L1 cache size in KiB") orelse
        b.option(usize, "l1cs", "L1 cache size in KiB (alias)") orelse
        32;

    const options = b.addOptions();
    options.addOption(usize, "l1_cache_size", l1_cache_size);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    test_mod.addOptions("primeZConfig", options);

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
