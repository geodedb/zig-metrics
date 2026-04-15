// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Thread pool dependency (structured concurrency)
    const tp_dep = b.dependency("thread_pool", .{
        .target = target,
        .optimize = optimize,
    });
    const tp_module = tp_dep.module("thread_pool");

    // Main library module
    const module = b.addModule("metrics", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "thread_pool", .module = tp_module },
        },
    });

    // Unit tests (run tests defined in the module itself)
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "thread_pool", .module = tp_module },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests (separate test file with module import)
    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "metrics", .module = module },
                .{ .name = "thread_pool", .module = tp_module },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_step.dependOn(&run_integration_tests.step);

    // Benchmark executable
    const bench_step = b.step("bench", "Run variance benchmark");
    const bench_exe = b.addExecutable(.{
        .name = "benchmark-variance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/variance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "metrics", .module = module },
                .{ .name = "thread_pool", .module = tp_module },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // Scale benchmark (multi-tier performance suite with JSON output)
    const scale_bench_step = b.step("scale-bench", "Run multi-tier scale benchmark");
    const scale_bench_exe = b.addExecutable(.{
        .name = "benchmark-scale",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/scale_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "metrics", .module = module },
                .{ .name = "thread_pool", .module = tp_module },
            },
        }),
    });
    const run_scale_bench = b.addRunArtifact(scale_bench_exe);
    if (b.args) |args| run_scale_bench.addArgs(args);
    scale_bench_step.dependOn(&run_scale_bench.step);

    // Baseline comparison tool
    const compare_bench_step = b.step("compare-bench", "Compare benchmark results against baseline");
    const compare_bench_exe = b.addExecutable(.{
        .name = "benchmark-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/compare.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_compare_bench = b.addRunArtifact(compare_bench_exe);
    if (b.args) |args| run_compare_bench.addArgs(args);
    compare_bench_step.dependOn(&run_compare_bench.step);

    // Check step for IDE integration (fast syntax validation)
    const check_step = b.step("check", "Check for compilation errors");
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "thread_pool", .module = tp_module },
            },
        }),
    });
    check_step.dependOn(&check.step);
}
