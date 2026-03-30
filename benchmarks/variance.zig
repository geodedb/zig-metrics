// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Metrics registry variance benchmark (MET-TEST-003).
//!
//! Measures the overhead of concurrent metric operations on a shared registry.
//! Validates that atomic operations maintain correctness under contention while
//! measuring throughput variance across runs.
//!
//! Uses spice ThreadPool for structured fork/join parallelism instead of raw
//! thread management.

const std = @import("std");
const metrics = @import("metrics");
const spice = @import("spice");

const WARMUP_ITERATIONS: u64 = 1_000;
const BENCH_ITERATIONS: u64 = 100_000;
const THREAD_COUNT: usize = 4;
const SAMPLE_RUNS: usize = 10;

pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.print("Metrics Registry Variance Benchmark\n", .{});
    try stdout.print("====================================\n", .{});
    try stdout.print("Threads:    {d} (spice pool: 1 caller + {d} workers)\n", .{ THREAD_COUNT, THREAD_COUNT - 1 });
    try stdout.print("Iterations: {d} per thread\n", .{BENCH_ITERATIONS});
    try stdout.print("Samples:    {d}\n\n", .{SAMPLE_RUNS});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a shared spice pool for all benchmarks
    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = THREAD_COUNT - 1 });
    defer pool.deinit();

    try stdout.print("--- Counter Throughput ---\n", .{});
    try benchmarkCounter(allocator, &pool, stdout);

    try stdout.print("\n--- Histogram Observation ---\n", .{});
    try benchmarkHistogram(allocator, &pool, stdout);

    try stdout.print("\n--- Mixed Workload ---\n", .{});
    try benchmarkMixed(allocator, &pool, stdout);

    try stdout.print("\n--- Parallel Snapshot ---\n", .{});
    try benchmarkParallelSnapshot(allocator, &pool, stdout);

    try stdout.print("\nBenchmark complete.\n", .{});
}

fn benchmarkCounter(allocator: std.mem.Allocator, pool: *spice.ThreadPool, w: std.fs.File.DeprecatedWriter) !void {
    var samples: [SAMPLE_RUNS]u64 = undefined;

    for (&samples) |*sample| {
        var reg = metrics.Registry.init(allocator);
        defer reg.deinit();
        const c = try reg.counter("bench_counter", "benchmark");

        // Warmup
        for (0..WARMUP_ITERATIONS) |_| c.inc();
        c.reset();

        const start = std.time.nanoTimestamp();

        // Fork THREAD_COUNT-1 tasks, run one on the calling thread
        pool.call(void, struct {
            pub fn run(t: *spice.Task, ctr: *metrics.Counter) void {
                var futs: [THREAD_COUNT - 1]spice.Future(*metrics.Counter, void) = undefined;
                for (&futs) |*f| {
                    f.* = spice.Future(*metrics.Counter, void).init();
                    f.fork(t, counterWork, ctr);
                }
                counterWork(t, ctr);
                // Join in reverse (LIFO) order -- spice requires this for queued job pop
                var i: usize = futs.len;
                while (i > 0) {
                    i -= 1;
                    if (futs[i].join(t) == null) {
                        t.call(void, counterWork, ctr);
                    }
                }
            }
        }.run, c);

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

fn counterWork(_: *spice.Task, c: *metrics.Counter) void {
    for (0..BENCH_ITERATIONS) |_| {
        c.inc();
    }
}

const HistArgs = struct { hist: *metrics.Histogram, seed: usize };
const HistRunArgs = struct { hist: *metrics.Histogram, base: usize };

fn benchmarkHistogram(allocator: std.mem.Allocator, pool: *spice.ThreadPool, w: std.fs.File.DeprecatedWriter) !void {
    var samples: [SAMPLE_RUNS]u64 = undefined;
    const buckets = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

    for (&samples, 0..) |*sample, run_idx| {
        var reg = metrics.Registry.init(allocator);
        defer reg.deinit();
        const h = try reg.histogram("bench_hist", "benchmark", &buckets);

        const start = std.time.nanoTimestamp();

        const base_seed = run_idx * THREAD_COUNT;
        pool.call(void, struct {
            pub fn run(t: *spice.Task, args: HistRunArgs) void {
                var futs: [THREAD_COUNT - 1]spice.Future(HistArgs, void) = undefined;
                for (&futs, 0..) |*f, i| {
                    f.* = spice.Future(HistArgs, void).init();
                    f.fork(t, histWork, HistArgs{ .hist = args.hist, .seed = args.base + i });
                }
                histWork(t, HistArgs{ .hist = args.hist, .seed = args.base + THREAD_COUNT - 1 });
                // Join in reverse (LIFO) order
                var i: usize = futs.len;
                while (i > 0) {
                    i -= 1;
                    if (futs[i].join(t) == null) {
                        t.call(void, histWork, HistArgs{ .hist = args.hist, .seed = 0 });
                    }
                }
            }
        }.run, HistRunArgs{ .hist = h, .base = base_seed });

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

fn histWork(_: *spice.Task, args: HistArgs) void {
    var rng = std.Random.DefaultPrng.init(@intCast(args.seed));
    const random = rng.random();
    for (0..BENCH_ITERATIONS) |_| {
        const value: f64 = random.float(f64) * 10.0;
        args.hist.observe(value);
    }
}

const MixedArgs = struct {
    c: *metrics.Counter,
    g: *metrics.Gauge,
    h: *metrics.Histogram,
    seed: usize,
};
const MixedRunArgs = struct {
    c: *metrics.Counter,
    g: *metrics.Gauge,
    h: *metrics.Histogram,
    base: usize,
};

fn benchmarkMixed(allocator: std.mem.Allocator, pool: *spice.ThreadPool, w: std.fs.File.DeprecatedWriter) !void {
    var samples: [SAMPLE_RUNS]u64 = undefined;
    const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0 };

    for (&samples, 0..) |*sample, run_idx| {
        var reg = metrics.Registry.init(allocator);
        defer reg.deinit();

        const c = try reg.counter("bench_mixed_c", "counter");
        const g = try reg.gauge("bench_mixed_g", "gauge");
        const h = try reg.histogram("bench_mixed_h", "histogram", &buckets);

        const start = std.time.nanoTimestamp();
        const base_seed = run_idx * THREAD_COUNT;

        pool.call(void, struct {
            pub fn run(t: *spice.Task, args: MixedRunArgs) void {
                var futs: [THREAD_COUNT - 1]spice.Future(MixedArgs, void) = undefined;
                for (&futs, 0..) |*f, i| {
                    f.* = spice.Future(MixedArgs, void).init();
                    f.fork(t, mixedWork, MixedArgs{ .c = args.c, .g = args.g, .h = args.h, .seed = args.base + i });
                }
                mixedWork(t, MixedArgs{ .c = args.c, .g = args.g, .h = args.h, .seed = args.base + THREAD_COUNT - 1 });
                // Join in reverse (LIFO) order
                var i: usize = futs.len;
                while (i > 0) {
                    i -= 1;
                    if (futs[i].join(t) == null) {
                        t.call(void, mixedWork, MixedArgs{ .c = args.c, .g = args.g, .h = args.h, .seed = 0 });
                    }
                }
            }
        }.run, MixedRunArgs{ .c = c, .g = g, .h = h, .base = base_seed });

        const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
        sample.* = elapsed;
    }

    try printStats(w, &samples);
}

fn mixedWork(_: *spice.Task, args: MixedArgs) void {
    var rng = std.Random.DefaultPrng.init(@intCast(args.seed));
    const random = rng.random();
    for (0..BENCH_ITERATIONS) |_| {
        args.c.inc();
        args.g.add(1);
        args.h.observe(random.float(f64));
    }
}

const counter_names = [10][]const u8{ "counter_0", "counter_1", "counter_2", "counter_3", "counter_4", "counter_5", "counter_6", "counter_7", "counter_8", "counter_9" };
const gauge_names = [10][]const u8{ "gauge_0", "gauge_1", "gauge_2", "gauge_3", "gauge_4", "gauge_5", "gauge_6", "gauge_7", "gauge_8", "gauge_9" };
const hist_names = [10][]const u8{ "hist_0", "hist_1", "hist_2", "hist_3", "hist_4", "hist_5", "hist_6", "hist_7", "hist_8", "hist_9" };
const timer_names = [10][]const u8{ "timer_0", "timer_1", "timer_2", "timer_3", "timer_4", "timer_5", "timer_6", "timer_7", "timer_8", "timer_9" };

fn benchmarkParallelSnapshot(allocator: std.mem.Allocator, pool: *spice.ThreadPool, w: std.fs.File.DeprecatedWriter) !void {
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

        const start = std.time.nanoTimestamp();

        var snap = try reg.parallelSnapshot(pool);
        snap.deinit();

        const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
        sample.* = elapsed;
    }

    try printStats(w, &samples);
}

fn printStats(w: std.fs.File.DeprecatedWriter, samples_in: []const u64) !void {
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
