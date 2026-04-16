// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Metrics registry variance benchmark (MET-TEST-003).
//!
//! Measures the overhead of concurrent metric operations on a shared registry.
//! Validates that atomic operations maintain correctness under contention while
//! measuring throughput variance across runs.
//!
//! Uses thread-pool submitBatch for structured parallelism.

const std = @import("std");
const metrics = @import("metrics");
const tp = @import("thread_pool");

const WARMUP_ITERATIONS: u64 = 1_000;
const BENCH_ITERATIONS: u64 = 100_000;
const THREAD_COUNT: usize = 4;
const SAMPLE_RUNS: usize = 10;

/// 0.16.0 shim: std.time.nanoTimestamp() was removed.
fn nanoTimestampCompat() i96 {
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io_inst, .real).raw.toNanoseconds();
}

pub fn main() !void {
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    var stdout_buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io_inst, &stdout_buf);
    const w = &file_writer.interface;

    try w.print("Metrics Registry Variance Benchmark\n", .{});
    try w.print("====================================\n", .{});
    try w.print("Threads:    {d} (thread-pool workers)\n", .{THREAD_COUNT});
    try w.print("Iterations: {d} per thread\n", .{BENCH_ITERATIONS});
    try w.print("Samples:    {d}\n\n", .{SAMPLE_RUNS});

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a shared thread pool for all benchmarks
    var pool = try tp.ThreadPool.init(allocator, .{});
    defer pool.deinit();

    try w.print("--- Counter Throughput ---\n", .{});
    try benchmarkCounter(allocator, &pool, w);

    try w.print("\n--- Histogram Observation ---\n", .{});
    try benchmarkHistogram(allocator, &pool, w);

    try w.print("\n--- Mixed Workload ---\n", .{});
    try benchmarkMixed(allocator, &pool, w);

    try w.print("\n--- Parallel Snapshot ---\n", .{});
    try benchmarkParallelSnapshot(allocator, &pool, w);

    try w.print("\nBenchmark complete.\n", .{});
    try w.flush();
}

const CounterTaskCtx = struct { counter: *metrics.Counter };

fn counterTaskFn(ctx: *anyopaque, _: *tp.TaskContext) void {
    const c: *CounterTaskCtx = @ptrCast(@alignCast(ctx));
    for (0..BENCH_ITERATIONS) |_| {
        c.counter.inc();
    }
}

fn benchmarkCounter(allocator: std.mem.Allocator, pool: *tp.ThreadPool, w: *std.Io.Writer) !void {
    var samples: [SAMPLE_RUNS]u64 = undefined;

    for (&samples) |*sample| {
        var reg = metrics.Registry.init(allocator);
        defer reg.deinit();
        const c = try reg.counter("bench_counter", "benchmark");

        // Warmup
        for (0..WARMUP_ITERATIONS) |_| c.inc();
        c.reset();

        var ctxs: [THREAD_COUNT]CounterTaskCtx = undefined;
        var tasks: [THREAD_COUNT]tp.BatchTask = undefined;
        for (0..THREAD_COUNT) |i| {
            ctxs[i] = .{ .counter = c };
            tasks[i] = .{ .task_fn = counterTaskFn, .ctx = &ctxs[i] };
        }

        var wg = pool.waitGroup();
        const start = nanoTimestampCompat();
        _ = try pool.submitBatch(&tasks, .{ .wait_group = &wg });
        wg.wait();
        const elapsed: u64 = @intCast(@max(0, nanoTimestampCompat() - start));
        sample.* = elapsed;

        const expected = BENCH_ITERATIONS * THREAD_COUNT;
        if (c.get() != expected) {
            try w.print("ERROR: expected {d}, got {d}\n", .{ expected, c.get() });
            return;
        }
    }

    try printStats(w, &samples);
}

const HistTaskCtx = struct { hist: *metrics.Histogram, seed: usize };

fn histTaskFn(ctx: *anyopaque, _: *tp.TaskContext) void {
    const c: *HistTaskCtx = @ptrCast(@alignCast(ctx));
    var rng = std.Random.DefaultPrng.init(@intCast(c.seed));
    const random = rng.random();
    for (0..BENCH_ITERATIONS) |_| {
        const value: f64 = random.float(f64) * 10.0;
        c.hist.observe(value);
    }
}

fn benchmarkHistogram(allocator: std.mem.Allocator, pool: *tp.ThreadPool, w: *std.Io.Writer) !void {
    var samples: [SAMPLE_RUNS]u64 = undefined;
    const buckets = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

    for (&samples, 0..) |*sample, run_idx| {
        var reg = metrics.Registry.init(allocator);
        defer reg.deinit();
        const h = try reg.histogram("bench_hist", "benchmark", &buckets);

        var ctxs: [THREAD_COUNT]HistTaskCtx = undefined;
        var tasks: [THREAD_COUNT]tp.BatchTask = undefined;
        for (0..THREAD_COUNT) |i| {
            ctxs[i] = .{ .hist = h, .seed = run_idx * THREAD_COUNT + i };
            tasks[i] = .{ .task_fn = histTaskFn, .ctx = &ctxs[i] };
        }

        var wg = pool.waitGroup();
        const start = nanoTimestampCompat();
        _ = try pool.submitBatch(&tasks, .{ .wait_group = &wg });
        wg.wait();
        const elapsed: u64 = @intCast(@max(0, nanoTimestampCompat() - start));
        sample.* = elapsed;

        const expected = BENCH_ITERATIONS * THREAD_COUNT;
        if (h.getCount() != expected) {
            try w.print("ERROR: expected {d} observations, got {d}\n", .{ expected, h.getCount() });
            return;
        }
    }

    try printStats(w, &samples);
}

const MixedTaskCtx = struct {
    c: *metrics.Counter,
    g: *metrics.Gauge,
    h: *metrics.Histogram,
    seed: usize,
};

fn mixedTaskFn(ctx: *anyopaque, _: *tp.TaskContext) void {
    const a: *MixedTaskCtx = @ptrCast(@alignCast(ctx));
    var rng = std.Random.DefaultPrng.init(@intCast(a.seed));
    const random = rng.random();
    for (0..BENCH_ITERATIONS) |_| {
        a.c.inc();
        a.g.add(1);
        a.h.observe(random.float(f64));
    }
}

fn benchmarkMixed(allocator: std.mem.Allocator, pool: *tp.ThreadPool, w: *std.Io.Writer) !void {
    var samples: [SAMPLE_RUNS]u64 = undefined;
    const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0 };

    for (&samples, 0..) |*sample, run_idx| {
        var reg = metrics.Registry.init(allocator);
        defer reg.deinit();

        const c = try reg.counter("bench_mixed_c", "counter");
        const g = try reg.gauge("bench_mixed_g", "gauge");
        const h = try reg.histogram("bench_mixed_h", "histogram", &buckets);

        var ctxs: [THREAD_COUNT]MixedTaskCtx = undefined;
        var tasks: [THREAD_COUNT]tp.BatchTask = undefined;
        for (0..THREAD_COUNT) |i| {
            ctxs[i] = .{ .c = c, .g = g, .h = h, .seed = run_idx * THREAD_COUNT + i };
            tasks[i] = .{ .task_fn = mixedTaskFn, .ctx = &ctxs[i] };
        }

        var wg = pool.waitGroup();
        const start = nanoTimestampCompat();
        _ = try pool.submitBatch(&tasks, .{ .wait_group = &wg });
        wg.wait();
        const elapsed: u64 = @intCast(@max(0, nanoTimestampCompat() - start));
        sample.* = elapsed;
    }

    try printStats(w, &samples);
}

const counter_names = [10][]const u8{ "counter_0", "counter_1", "counter_2", "counter_3", "counter_4", "counter_5", "counter_6", "counter_7", "counter_8", "counter_9" };
const gauge_names = [10][]const u8{ "gauge_0", "gauge_1", "gauge_2", "gauge_3", "gauge_4", "gauge_5", "gauge_6", "gauge_7", "gauge_8", "gauge_9" };
const hist_names = [10][]const u8{ "hist_0", "hist_1", "hist_2", "hist_3", "hist_4", "hist_5", "hist_6", "hist_7", "hist_8", "hist_9" };
const timer_names = [10][]const u8{ "timer_0", "timer_1", "timer_2", "timer_3", "timer_4", "timer_5", "timer_6", "timer_7", "timer_8", "timer_9" };

fn benchmarkParallelSnapshot(allocator: std.mem.Allocator, pool: *tp.ThreadPool, w: *std.Io.Writer) !void {
    var samples: [SAMPLE_RUNS]u64 = undefined;
    const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0 };

    for (&samples) |*sample| {
        var reg = metrics.Registry.init(allocator);
        defer reg.deinit();

        // Register a representative mix of metrics
        for (counter_names) |name| _ = try reg.counter(name, "bench counter");
        for (gauge_names) |name| _ = try reg.gauge(name, "bench gauge");
        for (hist_names) |name| _ = try reg.histogram(name, "bench hist", &buckets);
        for (timer_names) |name| _ = try reg.timer(name, "bench timer", &buckets);

        const start = nanoTimestampCompat();

        var snap = try reg.parallelSnapshot(pool);
        snap.deinit();

        const elapsed: u64 = @intCast(@max(0, nanoTimestampCompat() - start));
        sample.* = elapsed;
    }

    try printStats(w, &samples);
}

fn printStats(w: *std.Io.Writer, samples_in: []const u64) !void {
    var sum: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    for (samples_in) |s| {
        sum += s;
        if (s < min) min = s;
        if (s > max) max = s;
    }
    const mean = sum / samples_in.len;

    var variance_sum: u128 = 0;
    for (samples_in) |s| {
        const diff: i128 = @as(i128, @intCast(s)) - @as(i128, @intCast(mean));
        variance_sum += @intCast(@abs(diff * diff));
    }
    const variance = variance_sum / samples_in.len;
    const stddev: u64 = @intCast(std.math.sqrt(variance));
    const cv: f64 = if (mean > 0) @as(f64, @floatFromInt(stddev)) / @as(f64, @floatFromInt(mean)) * 100.0 else 0.0;

    try w.print("  Mean:   {d:.3} ms\n", .{@as(f64, @floatFromInt(mean)) / 1_000_000.0});
    try w.print("  Min:    {d:.3} ms\n", .{@as(f64, @floatFromInt(min)) / 1_000_000.0});
    try w.print("  Max:    {d:.3} ms\n", .{@as(f64, @floatFromInt(max)) / 1_000_000.0});
    try w.print("  StdDev: {d:.3} ms\n", .{@as(f64, @floatFromInt(stddev)) / 1_000_000.0});
    try w.print("  CV:     {d:.1}%\n", .{cv});
}
