// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dwith_otel=<bool> compiles in the otel observability seam. When
    // false (the default), the otel dependency is never resolved and no
    // otel symbols are imported — the verifier
    // `otel/scripts/verify-consumer-noop.sh` confirms zero
    // `otel`/`observability` symbols leak into the disabled-build
    // artifacts. metrics is build-flag-only: the seam exists for forward
    // compatibility and consumer wiring, but no metrics source file
    // calls into it (instrumenting counter/gauge/histogram increments
    // would be too high-volume and would create a feedback loop, since
    // otel itself depends on metrics under `-Dotel_use_devnw_metrics=true`).
    const with_otel = false; // 2026-05-02: hardcoded after removing the lazy otel dep — see build.zig.zon header note.

    // Shared `build_options` module surfaced as `@import("build_options")`
    // in src/observability.zig (and src/root.zig's gated
    // `observability_init` import). Reaching the same source file via
    // two distinct module instances is a hard compile error in Zig, so
    // every artifact that touches the seam (the metrics module, every
    // test, the check step) reuses this single instance.
    const build_options = b.addOptions();
    build_options.addOption(bool, "with_otel", with_otel);
    const build_options_module = build_options.createModule();

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
            .{ .name = "build_options", .module = build_options_module },
        },
    });

    // Named `observability` module — exposed both as a re-export from
    // src/root.zig (`metrics.observability`) AND as a standalone named
    // module so consumers can `dep.module("observability")` directly if
    // they prefer the seam without pulling in the rest of metrics. Per
    // the otel rollout RECIPE the named-module pattern is required.
    const observability_module = b.addModule("observability", .{
        .root_source_file = b.path("src/observability.zig"),
        .target = target,
        .optimize = optimize,
    });
    observability_module.addImport("build_options", build_options_module);

    // When -Dwith_otel=true, resolve the otel dependency lazily and
    // surface it to both the metrics module and the standalone
    // observability module so `src/observability.zig` can pull
    // `@import("otel")` from either entry point. The lazy() call only
    // triggers a fetch when the flag is true; the disabled build never
    // reaches the dependency resolver, so the otel package never shows
    // up on disk. metrics itself does not call any seam function — the
    // seam is exposed for consumer-side wiring and forward compatibility.
    const otel_module: ?*std.Build.Module = if (with_otel) blk: {
        const otel_dep = b.lazyDependency("otel", .{
            .target = target,
            .optimize = optimize,
        }) orelse break :blk null;
        const m = otel_dep.module("otel");
        module.addImport("otel", m);
        observability_module.addImport("otel", m);
        break :blk m;
    } else null;

    // Unit tests (run tests defined in the module itself)
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "thread_pool", .module = tp_module },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    if (otel_module) |om| unit_tests.root_module.addImport("otel", om);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Observability disabled-no-op test. Asserts the with_otel flag
    // exists and defaults to false, that observability.enabled tracks
    // it, and that the seam's no-op fallbacks compile cleanly. Wired
    // into the default `test` step so a plain `zig build test` exercises
    // it without an extra invocation.
    const observability_disabled_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_disabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "metrics", .module = module },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    if (otel_module) |om| observability_disabled_tests.root_module.addImport("otel", om);
    const run_observability_disabled_tests = b.addRunArtifact(observability_disabled_tests);
    test_step.dependOn(&run_observability_disabled_tests.step);

    // Observability enabled-mode smoke test. Skips when -Dwith_otel=false
    // (the default) and asserts the in-memory recorder captures exactly
    // one span when -Dwith_otel=true. Wired into the default `test` step
    // so the same `zig build test -Dwith_otel=true` invocation that
    // builds the enabled tree also runs this assertion.
    const observability_enabled_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_enabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "metrics", .module = module },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    if (otel_module) |om| observability_enabled_tests.root_module.addImport("otel", om);
    const run_observability_enabled_tests = b.addRunArtifact(observability_enabled_tests);
    test_step.dependOn(&run_observability_enabled_tests.step);

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

    // Compile-only gate for all benchmark executables. CI runs this so
    // benchmark bit-rot (e.g. stdlib API removals) is caught at merge
    // time without paying the cost of running the benchmarks (GAP-005).
    const bench_check_step = b.step("bench-check", "Compile all benchmarks without running");
    bench_check_step.dependOn(&bench_exe.step);
    bench_check_step.dependOn(&scale_bench_exe.step);
    bench_check_step.dependOn(&compare_bench_exe.step);

    // Check step for IDE integration (fast syntax validation)
    const check_step = b.step("check", "Check for compilation errors");
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "thread_pool", .module = tp_module },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    if (otel_module) |om| check.root_module.addImport("otel", om);
    check_step.dependOn(&check.step);
}
