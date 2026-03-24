// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Metrics registry variance benchmark (MET-TEST-003).
//!
//! Measures the overhead of concurrent metric operations on a shared registry.
//! Validates that atomic operations maintain correctness under contention while
//! measuring throughput variance across runs.

const std = @import("std");
const metrics = @import("metrics");

const WARMUP_ITERATIONS: u64 = 1_000;
const BENCH_ITERATIONS: u64 = 100_000;
const THREAD_COUNT: usize = 4;
const SAMPLE_RUNS: usize = 10;

pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.print("Metrics Registry Variance Benchmark\n", .{});
    try stdout.print("====================================\n", .{});
    try stdout.print("Threads:    {d}\n", .{THREAD_COUNT});
    try stdout.print("Iterations: {d} per thread\n", .{BENCH_ITERATIONS});
    try stdout.print("Samples:    {d}\n\n", .{SAMPLE_RUNS});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.print("--- Counter Throughput ---\n", .{});
    try benchmarkCounter(allocator, stdout);

    try stdout.print("\n--- Histogram Observation ---\n", .{});
    try benchmarkHistogram(allocator, stdout);

    try stdout.print("\n--- Mixed Workload ---\n", .{});
    try benchmarkMixed(allocator, stdout);

    try stdout.print("\nBenchmark complete.\n", .{});
}

fn benchmarkCounter(allocator: std.mem.Allocator, w: std.fs.File.DeprecatedWriter) !void {
    var samples: [SAMPLE_RUNS]u64 = undefined;

    for (&samples) |*sample| {
        var reg = metrics.Registry.init(allocator);
        defer reg.deinit();
        const c = try reg.counter("bench_counter", "benchmark");

        // Warmup
        for (0..WARMUP_ITERATIONS) |_| c.inc();
        c.reset();

        const start = std.time.nanoTimestamp();

        var threads: [THREAD_COUNT]std.Thread = undefined;
        for (&threads) |*t| {
            t.* = try std.Thread.spawn(.{}, struct {
                fn run(counter: *metrics.Counter) void {
                    for (0..BENCH_ITERATIONS) |_| {
                        counter.inc();
                    }
                }
            }.run, .{c});
        }
        for (&threads) |*t| t.join();

        const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
        sample.* = elapsed;

        const expected = BENCH_ITERATIONS * THREAD_COUNT;
        if (c.get() != expected) {
            try w.print("ERROR: expected {d}, got {d}\n", .{ expected, c.get() });
            return;
        }
    }

    try printStats(w, &samples);
}

fn benchmarkHistogram(allocator: std.mem.Allocator, w: std.fs.File.DeprecatedWriter) !void {
    var samples: [SAMPLE_RUNS]u64 = undefined;
    const buckets = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

    for (&samples) |*sample| {
        var reg = metrics.Registry.init(allocator);
        defer reg.deinit();
        const h = try reg.histogram("bench_hist", "benchmark", &buckets);

        const start = std.time.nanoTimestamp();

        var threads: [THREAD_COUNT]std.Thread = undefined;
        for (&threads, 0..) |*t, tid| {
            t.* = try std.Thread.spawn(.{}, struct {
                fn run(hist: *metrics.Histogram, seed: usize) void {
                    var rng = std.Random.DefaultPrng.init(@intCast(seed));
                    const random = rng.random();
                    for (0..BENCH_ITERATIONS) |_| {
                        const value: f64 = random.float(f64) * 10.0;
                        hist.observe(value);
                    }
                }
            }.run, .{ h, tid });
        }
        for (&threads) |*t| t.join();

        const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
        sample.* = elapsed;

        const expected = BENCH_ITERATIONS * THREAD_COUNT;
        if (h.getCount() != expected) {
            try w.print("ERROR: expected {d} observations, got {d}\n", .{ expected, h.getCount() });
            return;
        }
    }

    try printStats(w, &samples);
}

fn benchmarkMixed(allocator: std.mem.Allocator, w: std.fs.File.DeprecatedWriter) !void {
    var samples: [SAMPLE_RUNS]u64 = undefined;
    const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0 };

    for (&samples) |*sample| {
        var reg = metrics.Registry.init(allocator);
        defer reg.deinit();

        const c = try reg.counter("bench_mixed_c", "counter");
        const g = try reg.gauge("bench_mixed_g", "gauge");
        const h = try reg.histogram("bench_mixed_h", "histogram", &buckets);

        const start = std.time.nanoTimestamp();

        var threads: [THREAD_COUNT]std.Thread = undefined;
        for (&threads, 0..) |*t, tid| {
            const Args = struct { c: *metrics.Counter, g: *metrics.Gauge, h: *metrics.Histogram, tid: usize };
            t.* = try std.Thread.spawn(.{}, struct {
                fn run(args: Args) void {
                    var rng = std.Random.DefaultPrng.init(@intCast(args.tid));
                    const random = rng.random();
                    for (0..BENCH_ITERATIONS) |_| {
                        args.c.inc();
                        args.g.add(1);
                        args.h.observe(random.float(f64));
                    }
                }
            }.run, .{Args{ .c = c, .g = g, .h = h, .tid = tid }});
        }
        for (&threads) |*t| t.join();

        const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
        sample.* = elapsed;
    }

    try printStats(w, &samples);
}

fn printStats(w: std.fs.File.DeprecatedWriter, samples: []const u64) !void {
    var sum: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    for (samples) |s| {
        sum += s;
        if (s < min) min = s;
        if (s > max) max = s;
    }
    const mean = sum / samples.len;

    var variance_sum: u128 = 0;
    for (samples) |s| {
        const diff: i128 = @as(i128, @intCast(s)) - @as(i128, @intCast(mean));
        variance_sum += @intCast(@abs(diff * diff));
    }
    const variance = variance_sum / samples.len;
    const stddev: u64 = @intCast(std.math.sqrt(variance));
    const cv: f64 = if (mean > 0) @as(f64, @floatFromInt(stddev)) / @as(f64, @floatFromInt(mean)) * 100.0 else 0.0;

    try w.print("  Mean:   {d:.3} ms\n", .{@as(f64, @floatFromInt(mean)) / 1_000_000.0});
    try w.print("  Min:    {d:.3} ms\n", .{@as(f64, @floatFromInt(min)) / 1_000_000.0});
    try w.print("  Max:    {d:.3} ms\n", .{@as(f64, @floatFromInt(max)) / 1_000_000.0});
    try w.print("  StdDev: {d:.3} ms\n", .{@as(f64, @floatFromInt(stddev)) / 1_000_000.0});
    try w.print("  CV:     {d:.1}%\n", .{cv});
    // output flushed by OS on newline for stdout
}
