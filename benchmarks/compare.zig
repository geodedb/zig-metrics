// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Benchmark baseline comparison tool.
//!
//! Reads two JSON result files produced by scale_bench and compares each metric
//! per tier. Prints a human-readable table and exits with code 1 if any metric
//! regresses beyond the configured threshold.
//!
//! Usage:
//!   zig build compare-bench -- baseline.json current.json         # 20% default
//!   zig build compare-bench -- baseline.json current.json 15      # 15% threshold

const std = @import("std");

const DEFAULT_THRESHOLD: f64 = 20.0; // percent

// ---------------------------------------------------------------------------
// Metric classification
// ---------------------------------------------------------------------------

const MetricDir = enum { higher_is_better, lower_is_better };

const MetricDef = struct {
    name: []const u8,
    dir: MetricDir,
    unit: []const u8,
};

const metric_defs = [_]MetricDef{
    .{ .name = "counter_ops_sec", .dir = .higher_is_better, .unit = "ops/s" },
    .{ .name = "gauge_ops_sec", .dir = .higher_is_better, .unit = "ops/s" },
    .{ .name = "histogram_ops_sec", .dir = .higher_is_better, .unit = "ops/s" },
    .{ .name = "timer_ops_sec", .dir = .higher_is_better, .unit = "ops/s" },
    .{ .name = "registration_ns", .dir = .lower_is_better, .unit = "ns" },
    .{ .name = "snapshot_ms", .dir = .lower_is_better, .unit = "ms" },
    .{ .name = "parallel_snapshot_ms", .dir = .lower_is_better, .unit = "ms" },
    .{ .name = "prometheus_ms", .dir = .lower_is_better, .unit = "ms" },
    .{ .name = "mixed_ops_sec", .dir = .higher_is_better, .unit = "ops/s" },
};

// ---------------------------------------------------------------------------
// JSON data types
// ---------------------------------------------------------------------------

const TierData = struct {
    name: []const u8 = "",
    metric_count: f64 = 0,
    thread_count: f64 = 0,
    counter_ops_sec: f64 = 0,
    gauge_ops_sec: f64 = 0,
    histogram_ops_sec: f64 = 0,
    timer_ops_sec: f64 = 0,
    registration_ns: f64 = 0,
    snapshot_ms: f64 = 0,
    parallel_snapshot_ms: f64 = 0,
    prometheus_ms: f64 = 0,
    mixed_ops_sec: f64 = 0,
    skipped: bool = false,

    fn getMetric(self: TierData, name: []const u8) f64 {
        if (std.mem.eql(u8, name, "counter_ops_sec")) return self.counter_ops_sec;
        if (std.mem.eql(u8, name, "gauge_ops_sec")) return self.gauge_ops_sec;
        if (std.mem.eql(u8, name, "histogram_ops_sec")) return self.histogram_ops_sec;
        if (std.mem.eql(u8, name, "timer_ops_sec")) return self.timer_ops_sec;
        if (std.mem.eql(u8, name, "registration_ns")) return self.registration_ns;
        if (std.mem.eql(u8, name, "snapshot_ms")) return self.snapshot_ms;
        if (std.mem.eql(u8, name, "parallel_snapshot_ms")) return self.parallel_snapshot_ms;
        if (std.mem.eql(u8, name, "prometheus_ms")) return self.prometheus_ms;
        if (std.mem.eql(u8, name, "mixed_ops_sec")) return self.mixed_ops_sec;
        return 0;
    }
};

const BenchmarkFile = struct {
    version: f64 = 0,
    tiers: []TierData = &.{},
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const io_inst = std.Io.Threaded.global_single_threaded.io();
    var stdout_buf: [8192]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io_inst, &stdout_buf);
    const stdout = &stdout_fw.interface;

    // Parse CLI args
    var args = std.process.args();
    _ = args.next(); // skip program name

    const baseline_path = args.next() orelse {
        try stdout.print("Usage: compare <baseline.json> <current.json> [threshold%]\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const current_path = args.next() orelse {
        try stdout.print("Usage: compare <baseline.json> <current.json> [threshold%]\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const threshold: f64 = if (args.next()) |t|
        std.fmt.parseFloat(f64, t) catch DEFAULT_THRESHOLD
    else
        DEFAULT_THRESHOLD;

    // Read and parse files
    const baseline_data = std.Io.Dir.cwd().readFileAlloc(io_inst, baseline_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        try stdout.print("Error reading baseline file '{s}': {}\n", .{ baseline_path, err });
        try stdout.flush();
        std.process.exit(2);
    };
    defer allocator.free(baseline_data);

    const current_data = std.Io.Dir.cwd().readFileAlloc(io_inst, current_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        try stdout.print("Error reading current file '{s}': {}\n", .{ current_path, err });
        try stdout.flush();
        std.process.exit(2);
    };
    defer allocator.free(current_data);

    const baseline = std.json.parseFromSlice(BenchmarkFile, allocator, baseline_data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        try stdout.print("Error parsing baseline JSON: {}\n", .{err});
        try stdout.flush();
        std.process.exit(2);
    };
    defer baseline.deinit();

    const current = std.json.parseFromSlice(BenchmarkFile, allocator, current_data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        try stdout.print("Error parsing current JSON: {}\n", .{err});
        try stdout.flush();
        std.process.exit(2);
    };
    defer current.deinit();

    // Compare
    try stdout.print(
        \\================================================================================
        \\  Metrics Performance Comparison (threshold: {d:.0}%)
        \\================================================================================
        \\
    , .{threshold});

    var total_regressions: usize = 0;
    var total_metrics: usize = 0;

    for (baseline.value.tiers) |base_tier| {
        if (base_tier.skipped) continue;

        // Find matching tier in current
        const cur_tier = findTier(current.value.tiers, base_tier.name) orelse {
            try stdout.print("\n  {s} tier: MISSING in current results\n", .{base_tier.name});
            total_regressions += 1;
            continue;
        };

        if (cur_tier.skipped) {
            try stdout.print("\n  {s} tier: SKIPPED in current results\n", .{base_tier.name});
            continue;
        }

        try stdout.print("\n  {s} tier:\n", .{base_tier.name});
        try stdout.print("  {s:<24}  {s:>14}  {s:>14}  {s:>9}  {s}\n", .{
            "Metric", "Baseline", "Current", "Delta", "Status",
        });
        try stdout.print("  {s}  {s}  {s}  {s}  {s}\n", .{
            "------------------------",
            "--------------",
            "--------------",
            "---------",
            "------",
        });

        for (metric_defs) |mdef| {
            const base_val = base_tier.getMetric(mdef.name);
            const cur_val = cur_tier.getMetric(mdef.name);

            if (base_val == 0 and cur_val == 0) continue;

            total_metrics += 1;

            const delta_pct: f64 = if (base_val != 0)
                (cur_val - base_val) / @abs(base_val) * 100.0
            else
                0;

            const is_regression = switch (mdef.dir) {
                .higher_is_better => delta_pct < -threshold,
                .lower_is_better => delta_pct > threshold,
            };

            if (is_regression) total_regressions += 1;

            const status: []const u8 = if (is_regression) "FAIL" else "PASS";

            // Format values based on unit
            if (std.mem.endsWith(u8, mdef.unit, "/s")) {
                try stdout.print("  {s:<24}  {d:>14.0}  {d:>14.0}  {d:>8.1}%  {s}\n", .{
                    mdef.name, base_val, cur_val, delta_pct, status,
                });
            } else {
                try stdout.print("  {s:<24}  {d:>14.1}  {d:>14.1}  {d:>8.1}%  {s}\n", .{
                    mdef.name, base_val, cur_val, delta_pct, status,
                });
            }
        }
    }

    try stdout.print(
        \\
        \\================================================================================
        \\
    , .{});

    if (total_regressions > 0) {
        try stdout.print("  Result: FAIL ({d} regression(s) out of {d} metrics)\n", .{
            total_regressions, total_metrics,
        });
        try stdout.print(
            \\================================================================================
            \\
        , .{});
        try stdout.flush();
        std.process.exit(1);
    } else {
        try stdout.print("  Result: PASS ({d} metrics compared, 0 regressions)\n", .{total_metrics});
        try stdout.print(
            \\================================================================================
            \\
        , .{});
        try stdout.flush();
    }
}

fn findTier(tiers: []const TierData, name: []const u8) ?TierData {
    for (tiers) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}
