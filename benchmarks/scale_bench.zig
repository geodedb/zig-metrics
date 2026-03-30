// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Multi-tier performance benchmark for the metrics library.
//!
//! Runs benchmarks across increasing scale tiers (light -> extreme) and produces
//! structured JSON output suitable for baseline comparison and regression detection.
//!
//! Output:
//!   stderr: Human-readable summary table
//!   stdout: JSON document (redirect with `2>/dev/null` for clean JSON)
//!
//! Usage:
//!   zig build scale-bench                     # All tiers
//!   zig build scale-bench -- light            # Single tier
//!   zig build scale-bench -- moderate heavy   # Specific tiers

const std = @import("std");
const metrics = @import("metrics");
const spice = @import("spice");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const TIER_TIMEOUT_NS: u64 = 5 * 60 * std.time.ns_per_s;
const WARMUP_ITERATIONS: u64 = 1_000;
const SNAPSHOT_SAMPLES: usize = 10;
const PROMETHEUS_SAMPLES: usize = 10;
const DEFAULT_BUCKETS = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

const Tier = struct {
    name: []const u8,
    metric_count: usize,
    thread_count: usize,
    iterations: u64,
};

const all_tiers = [_]Tier{
    .{ .name = "light", .metric_count = 10, .thread_count = 2, .iterations = 100_000 },
    .{ .name = "moderate", .metric_count = 50, .thread_count = 4, .iterations = 500_000 },
    .{ .name = "heavy", .metric_count = 200, .thread_count = 8, .iterations = 1_000_000 },
    .{ .name = "extreme", .metric_count = 500, .thread_count = 16, .iterations = 2_000_000 },
};

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

const TierResult = struct {
    name: []const u8,
    metric_count: u64,
    thread_count: u64,
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
    skip_reason: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Spice work function argument types (must be named for type identity)
// ---------------------------------------------------------------------------

const CounterWorkArgs = struct { counter: *metrics.Counter, iterations: u64 };
const GaugeWorkArgs = struct { gauge: *metrics.Gauge, iterations: u64 };
const HistogramWorkArgs = struct { histogram: *metrics.Histogram, iterations: u64, seed: u64 };
const TimerWorkArgs = struct { timer: *metrics.Timer, iterations: u64, seed: u64 };
const MixedWorkArgs = struct {
    counters: [*]const *metrics.Counter,
    gauges: [*]const *metrics.Gauge,
    histograms: [*]const *metrics.Histogram,
    timers: [*]const *metrics.Timer,
    len: usize,
    iterations: u64,
    seed: u64,
};

// Run-args types for pool.call (must be named to match spice type identity)
const CounterRunArgs = struct { c: *metrics.Counter, tc: usize, iters: u64 };
const GaugeRunArgs = struct { g: *metrics.Gauge, tc: usize, iters: u64 };
const HistogramRunArgs = struct { h: *metrics.Histogram, tc: usize, iters: u64 };
const TimerRunArgs = struct { tmr: *metrics.Timer, tc: usize, iters: u64 };
const MixedRunArgs = struct {
    cp: [*]const *metrics.Counter,
    gp: [*]const *metrics.Gauge,
    hp: [*]const *metrics.Histogram,
    tp: [*]const *metrics.Timer,
    len: usize,
    tc: usize,
    iters: u64,
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse optional tier filter from CLI args
    var filter_buf: [16][]const u8 = undefined;
    var filter_count: usize = 0;
    var args = std.process.args();
    _ = args.next(); // skip program name
    while (args.next()) |arg| {
        if (filter_count < filter_buf.len) {
            filter_buf[filter_count] = arg;
            filter_count += 1;
        }
    }
    const filters = filter_buf[0..filter_count];

    try stderr.print(
        \\================================================================================
        \\  metrics scale benchmark
        \\================================================================================
        \\
    , .{});

    var results: [all_tiers.len]TierResult = undefined;

    for (all_tiers, 0..) |tier, i| {
        // Apply tier filter if specified
        if (filters.len > 0) {
            var matched = false;
            for (filters) |f| {
                if (std.mem.eql(u8, f, tier.name)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                results[i] = .{
                    .name = tier.name,
                    .metric_count = tier.metric_count,
                    .thread_count = tier.thread_count,
                    .skipped = true,
                    .skip_reason = "filtered",
                };
                continue;
            }
        }

        try stderr.print("\n--- {s} tier ({d} metrics, {d} threads, {d} iters/thread) ---\n", .{
            tier.name, tier.metric_count, tier.thread_count, tier.iterations,
        });

        results[i] = runTier(allocator, tier, stderr) catch {
            results[i] = .{
                .name = tier.name,
                .metric_count = tier.metric_count,
                .thread_count = tier.thread_count,
                .skipped = true,
                .skip_reason = "error",
            };
            continue;
        };

        try printTierSummary(stderr, results[i]);
    }

    try stderr.print(
        \\
        \\================================================================================
        \\
    , .{});

    try writeJson(stdout, allocator, &results);
}

// ---------------------------------------------------------------------------
// Tier runner
// ---------------------------------------------------------------------------

fn runTier(allocator: std.mem.Allocator, tier: Tier, stderr: anytype) !TierResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tier_start = std.time.nanoTimestamp();
    var result = TierResult{
        .name = tier.name,
        .metric_count = tier.metric_count,
        .thread_count = tier.thread_count,
    };

    // Generate metric names (arena-allocated, valid for tier lifetime)
    const counter_names = try generateNames(a, "c", tier.metric_count);
    const gauge_names = try generateNames(a, "g", tier.metric_count);
    const hist_names = try generateNames(a, "h", tier.metric_count);
    const timer_names = try generateNames(a, "t", tier.metric_count);

    // 1. Registration benchmark
    try stderr.print("  registration...", .{});
    result.registration_ns = try benchRegistration(allocator, counter_names, gauge_names, hist_names, timer_names);
    try stderr.print(" {d:.0} ns/op\n", .{result.registration_ns});
    if (timedOut(tier_start)) return timeoutResult(result);

    // 2. Counter throughput
    try stderr.print("  counter throughput...", .{});
    result.counter_ops_sec = try benchCounter(allocator, tier);
    try stderr.print(" {d:.0} ops/sec\n", .{result.counter_ops_sec});
    if (timedOut(tier_start)) return timeoutResult(result);

    // 3. Gauge throughput
    try stderr.print("  gauge throughput...", .{});
    result.gauge_ops_sec = try benchGauge(allocator, tier);
    try stderr.print(" {d:.0} ops/sec\n", .{result.gauge_ops_sec});
    if (timedOut(tier_start)) return timeoutResult(result);

    // 4. Histogram throughput
    try stderr.print("  histogram throughput...", .{});
    result.histogram_ops_sec = try benchHistogram(allocator, tier);
    try stderr.print(" {d:.0} ops/sec\n", .{result.histogram_ops_sec});
    if (timedOut(tier_start)) return timeoutResult(result);

    // 5. Timer throughput
    try stderr.print("  timer throughput...", .{});
    result.timer_ops_sec = try benchTimer(allocator, tier);
    try stderr.print(" {d:.0} ops/sec\n", .{result.timer_ops_sec});
    if (timedOut(tier_start)) return timeoutResult(result);

    // 6. Snapshot capture
    try stderr.print("  snapshot...", .{});
    result.snapshot_ms = try benchSnapshot(allocator, tier, counter_names, gauge_names, hist_names, timer_names);
    try stderr.print(" {d:.1} ms\n", .{result.snapshot_ms});
    if (timedOut(tier_start)) return timeoutResult(result);

    // 7. Parallel snapshot
    try stderr.print("  parallel snapshot...", .{});
    result.parallel_snapshot_ms = try benchParallelSnapshot(allocator, tier, counter_names, gauge_names, hist_names, timer_names);
    try stderr.print(" {d:.1} ms\n", .{result.parallel_snapshot_ms});
    if (timedOut(tier_start)) return timeoutResult(result);

    // 8. Prometheus export
    try stderr.print("  prometheus export...", .{});
    result.prometheus_ms = try benchPrometheus(allocator, tier, counter_names, gauge_names, hist_names, timer_names);
    try stderr.print(" {d:.1} ms\n", .{result.prometheus_ms});
    if (timedOut(tier_start)) return timeoutResult(result);

    // 9. Mixed workload
    try stderr.print("  mixed workload...", .{});
    result.mixed_ops_sec = try benchMixed(allocator, tier, counter_names, gauge_names, hist_names, timer_names);
    try stderr.print(" {d:.0} ops/sec\n", .{result.mixed_ops_sec});

    return result;
}

fn timedOut(tier_start: i128) bool {
    const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - tier_start));
    return elapsed > TIER_TIMEOUT_NS;
}

fn timeoutResult(partial: TierResult) TierResult {
    var r = partial;
    r.skipped = true;
    r.skip_reason = "timeout (>5min)";
    return r;
}

// ---------------------------------------------------------------------------
// Individual benchmarks
// ---------------------------------------------------------------------------

fn benchRegistration(
    allocator: std.mem.Allocator,
    counter_names: []const []const u8,
    gauge_names: []const []const u8,
    hist_names: []const []const u8,
    timer_names: []const []const u8,
) !f64 {
    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();

    const total = counter_names.len + gauge_names.len + hist_names.len + timer_names.len;
    const start = std.time.nanoTimestamp();

    for (counter_names) |name| _ = try reg.counter(name, "bench");
    for (gauge_names) |name| _ = try reg.gauge(name, "bench");
    for (hist_names) |name| _ = try reg.histogram(name, "bench", &DEFAULT_BUCKETS);
    for (timer_names) |name| _ = try reg.timer(name, "bench", &DEFAULT_BUCKETS);

    const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total));
}

fn benchCounter(allocator: std.mem.Allocator, tier: Tier) !f64 {
    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();
    const c = try reg.counter("bench_c", "bench");

    // Warmup
    for (0..WARMUP_ITERATIONS) |_| c.inc();
    c.reset();

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = tier.thread_count - 1 });
    defer pool.deinit();

    const start = std.time.nanoTimestamp();
    pool.call(void, struct {
        pub fn run(t: *spice.Task, args: CounterRunArgs) void {
            const futs = @constCast(&([1]spice.Future(CounterWorkArgs, void){spice.Future(CounterWorkArgs, void).init()} ** (16 - 1)));
            const count = args.tc - 1;
            for (futs[0..count]) |*f| {
                f.* = spice.Future(CounterWorkArgs, void).init();
                f.fork(t, counterWork, CounterWorkArgs{ .counter = args.c, .iterations = args.iters });
            }
            counterWork(t, CounterWorkArgs{ .counter = args.c, .iterations = args.iters });
            var i: usize = count;
            while (i > 0) {
                i -= 1;
                if (futs[i].join(t) == null) {
                    t.call(void, counterWork, CounterWorkArgs{ .counter = args.c, .iterations = args.iters });
                }
            }
        }
    }.run, CounterRunArgs{ .c = c, .tc = tier.thread_count, .iters = tier.iterations });
    const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));

    const total_ops = tier.thread_count * tier.iterations;
    return opsPerSec(total_ops, elapsed_ns);
}

fn benchGauge(allocator: std.mem.Allocator, tier: Tier) !f64 {
    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();
    const g = try reg.gauge("bench_g", "bench");

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = tier.thread_count - 1 });
    defer pool.deinit();

    const start = std.time.nanoTimestamp();
    pool.call(void, struct {
        pub fn run(t: *spice.Task, args: GaugeRunArgs) void {
            const futs = @constCast(&([1]spice.Future(GaugeWorkArgs, void){spice.Future(GaugeWorkArgs, void).init()} ** (16 - 1)));
            const count = args.tc - 1;
            for (futs[0..count]) |*f| {
                f.* = spice.Future(GaugeWorkArgs, void).init();
                f.fork(t, gaugeWork, GaugeWorkArgs{ .gauge = args.g, .iterations = args.iters });
            }
            gaugeWork(t, GaugeWorkArgs{ .gauge = args.g, .iterations = args.iters });
            var i: usize = count;
            while (i > 0) {
                i -= 1;
                if (futs[i].join(t) == null) {
                    t.call(void, gaugeWork, GaugeWorkArgs{ .gauge = args.g, .iterations = args.iters });
                }
            }
        }
    }.run, GaugeRunArgs{ .g = g, .tc = tier.thread_count, .iters = tier.iterations });
    const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));

    return opsPerSec(tier.thread_count * tier.iterations, elapsed_ns);
}

fn benchHistogram(allocator: std.mem.Allocator, tier: Tier) !f64 {
    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();
    const h = try reg.histogram("bench_h", "bench", &DEFAULT_BUCKETS);

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = tier.thread_count - 1 });
    defer pool.deinit();

    const start = std.time.nanoTimestamp();
    pool.call(void, struct {
        pub fn run(t: *spice.Task, args: HistogramRunArgs) void {
            const futs = @constCast(&([1]spice.Future(HistogramWorkArgs, void){spice.Future(HistogramWorkArgs, void).init()} ** (16 - 1)));
            const count = args.tc - 1;
            for (futs[0..count], 0..) |*f, idx| {
                f.* = spice.Future(HistogramWorkArgs, void).init();
                f.fork(t, histogramWork, HistogramWorkArgs{ .histogram = args.h, .iterations = args.iters, .seed = idx });
            }
            histogramWork(t, HistogramWorkArgs{ .histogram = args.h, .iterations = args.iters, .seed = 999 });
            var i: usize = count;
            while (i > 0) {
                i -= 1;
                if (futs[i].join(t) == null) {
                    t.call(void, histogramWork, HistogramWorkArgs{ .histogram = args.h, .iterations = args.iters, .seed = i + 100 });
                }
            }
        }
    }.run, HistogramRunArgs{ .h = h, .tc = tier.thread_count, .iters = tier.iterations });
    const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));

    return opsPerSec(tier.thread_count * tier.iterations, elapsed_ns);
}

fn benchTimer(allocator: std.mem.Allocator, tier: Tier) !f64 {
    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();
    const tmr = try reg.timer("bench_t", "bench", &DEFAULT_BUCKETS);

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = tier.thread_count - 1 });
    defer pool.deinit();

    const start = std.time.nanoTimestamp();
    pool.call(void, struct {
        pub fn run(t: *spice.Task, args: TimerRunArgs) void {
            const futs = @constCast(&([1]spice.Future(TimerWorkArgs, void){spice.Future(TimerWorkArgs, void).init()} ** (16 - 1)));
            const count = args.tc - 1;
            for (futs[0..count], 0..) |*f, idx| {
                f.* = spice.Future(TimerWorkArgs, void).init();
                f.fork(t, timerWork, TimerWorkArgs{ .timer = args.tmr, .iterations = args.iters, .seed = idx });
            }
            timerWork(t, TimerWorkArgs{ .timer = args.tmr, .iterations = args.iters, .seed = 999 });
            var i: usize = count;
            while (i > 0) {
                i -= 1;
                if (futs[i].join(t) == null) {
                    t.call(void, timerWork, TimerWorkArgs{ .timer = args.tmr, .iterations = args.iters, .seed = i + 100 });
                }
            }
        }
    }.run, TimerRunArgs{ .tmr = tmr, .tc = tier.thread_count, .iters = tier.iterations });
    const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));

    return opsPerSec(tier.thread_count * tier.iterations, elapsed_ns);
}

fn benchSnapshot(
    allocator: std.mem.Allocator,
    tier: Tier,
    counter_names: []const []const u8,
    gauge_names: []const []const u8,
    hist_names: []const []const u8,
    timer_names: []const []const u8,
) !f64 {
    var reg = try populateRegistry(allocator, counter_names, gauge_names, hist_names, timer_names);
    defer reg.deinit();

    // Warmup
    for (0..3) |_| {
        var snap = try reg.snapshot();
        snap.deinit();
    }

    const start = std.time.nanoTimestamp();
    for (0..SNAPSHOT_SAMPLES) |_| {
        var snap = try reg.snapshot();
        snap.deinit();
    }
    const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
    _ = tier;

    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(SNAPSHOT_SAMPLES)) / 1_000_000.0;
}

fn benchParallelSnapshot(
    allocator: std.mem.Allocator,
    tier: Tier,
    counter_names: []const []const u8,
    gauge_names: []const []const u8,
    hist_names: []const []const u8,
    timer_names: []const []const u8,
) !f64 {
    var reg = try populateRegistry(allocator, counter_names, gauge_names, hist_names, timer_names);
    defer reg.deinit();

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = @min(tier.thread_count, 3) });
    defer pool.deinit();

    // Warmup
    for (0..3) |_| {
        var snap = try reg.parallelSnapshot(&pool);
        snap.deinit();
    }

    const start = std.time.nanoTimestamp();
    for (0..SNAPSHOT_SAMPLES) |_| {
        var snap = try reg.parallelSnapshot(&pool);
        snap.deinit();
    }
    const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));

    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(SNAPSHOT_SAMPLES)) / 1_000_000.0;
}

fn benchPrometheus(
    allocator: std.mem.Allocator,
    tier: Tier,
    counter_names: []const []const u8,
    gauge_names: []const []const u8,
    hist_names: []const []const u8,
    timer_names: []const []const u8,
) !f64 {
    var reg = try populateRegistry(allocator, counter_names, gauge_names, hist_names, timer_names);
    defer reg.deinit();
    _ = tier;

    // Pre-allocate a large buffer for Prometheus output
    const buf = try allocator.alloc(u8, 4 * 1024 * 1024); // 4 MB
    defer allocator.free(buf);

    // Warmup
    for (0..3) |_| {
        var fbs = std.io.fixedBufferStream(buf);
        try metrics.writePrometheus(&reg, fbs.writer());
    }

    const start = std.time.nanoTimestamp();
    for (0..PROMETHEUS_SAMPLES) |_| {
        var fbs = std.io.fixedBufferStream(buf);
        try metrics.writePrometheus(&reg, fbs.writer());
    }
    const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));

    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(PROMETHEUS_SAMPLES)) / 1_000_000.0;
}

fn benchMixed(
    allocator: std.mem.Allocator,
    tier: Tier,
    counter_names: []const []const u8,
    gauge_names: []const []const u8,
    hist_names: []const []const u8,
    timer_names: []const []const u8,
) !f64 {
    var reg = try populateRegistry(allocator, counter_names, gauge_names, hist_names, timer_names);
    defer reg.deinit();

    // Collect metric pointers into arrays for random access
    const n = counter_names.len;
    const counter_ptrs = try allocator.alloc(*metrics.Counter, n);
    defer allocator.free(counter_ptrs);
    const gauge_ptrs = try allocator.alloc(*metrics.Gauge, n);
    defer allocator.free(gauge_ptrs);
    const hist_ptrs = try allocator.alloc(*metrics.Histogram, n);
    defer allocator.free(hist_ptrs);
    const timer_ptrs = try allocator.alloc(*metrics.Timer, n);
    defer allocator.free(timer_ptrs);

    for (counter_names, 0..) |name, i| counter_ptrs[i] = reg.getCounter(name).?;
    for (gauge_names, 0..) |name, i| gauge_ptrs[i] = reg.getGauge(name).?;
    for (hist_names, 0..) |name, i| hist_ptrs[i] = reg.getHistogram(name).?;
    for (timer_names, 0..) |name, i| timer_ptrs[i] = reg.getTimer(name).?;

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = tier.thread_count - 1 });
    defer pool.deinit();

    const start = std.time.nanoTimestamp();
    pool.call(void, struct {
        pub fn run(t: *spice.Task, args: MixedRunArgs) void {
            const futs = @constCast(&([1]spice.Future(MixedWorkArgs, void){spice.Future(MixedWorkArgs, void).init()} ** (16 - 1)));
            const count = args.tc - 1;
            for (futs[0..count], 0..) |*f, idx| {
                f.* = spice.Future(MixedWorkArgs, void).init();
                f.fork(t, mixedWork, MixedWorkArgs{
                    .counters = args.cp,
                    .gauges = args.gp,
                    .histograms = args.hp,
                    .timers = args.tp,
                    .len = args.len,
                    .iterations = args.iters,
                    .seed = idx,
                });
            }
            mixedWork(t, MixedWorkArgs{
                .counters = args.cp,
                .gauges = args.gp,
                .histograms = args.hp,
                .timers = args.tp,
                .len = args.len,
                .iterations = args.iters,
                .seed = 999,
            });
            var i: usize = count;
            while (i > 0) {
                i -= 1;
                if (futs[i].join(t) == null) {
                    t.call(void, mixedWork, MixedWorkArgs{
                        .counters = args.cp,
                        .gauges = args.gp,
                        .histograms = args.hp,
                        .timers = args.tp,
                        .len = args.len,
                        .iterations = args.iters,
                        .seed = i + 500,
                    });
                }
            }
        }
    }.run, MixedRunArgs{
        .cp = counter_ptrs.ptr,
        .gp = gauge_ptrs.ptr,
        .hp = hist_ptrs.ptr,
        .tp = timer_ptrs.ptr,
        .len = n,
        .tc = tier.thread_count,
        .iters = tier.iterations,
    });
    const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));

    return opsPerSec(tier.thread_count * tier.iterations, elapsed_ns);
}

// ---------------------------------------------------------------------------
// Spice work functions
// ---------------------------------------------------------------------------

fn counterWork(_: *spice.Task, args: CounterWorkArgs) void {
    for (0..args.iterations) |_| args.counter.inc();
}

fn gaugeWork(_: *spice.Task, args: GaugeWorkArgs) void {
    for (0..args.iterations) |_| args.gauge.inc();
}

fn histogramWork(_: *spice.Task, args: HistogramWorkArgs) void {
    var rng = std.Random.DefaultPrng.init(args.seed);
    const random = rng.random();
    for (0..args.iterations) |_| args.histogram.observe(random.float(f64) * 10.0);
}

fn timerWork(_: *spice.Task, args: TimerWorkArgs) void {
    var rng = std.Random.DefaultPrng.init(args.seed);
    const random = rng.random();
    for (0..args.iterations) |_| args.timer.recordSeconds(random.float(f64));
}

fn mixedWork(_: *spice.Task, args: MixedWorkArgs) void {
    var rng = std.Random.DefaultPrng.init(args.seed);
    const random = rng.random();
    const counters = args.counters[0..args.len];
    const gauges = args.gauges[0..args.len];
    const histograms = args.histograms[0..args.len];
    const timers = args.timers[0..args.len];

    for (0..args.iterations) |_| {
        const idx = random.uintLessThan(usize, args.len);
        const op = random.uintLessThan(u8, 10);
        switch (op) {
            0...3 => counters[idx].inc(), // 40% counter
            4, 5 => gauges[idx].set(random.int(i64)), // 20% gauge
            6...8 => histograms[idx].observe(random.float(f64) * 10.0), // 30% histogram
            else => timers[idx].recordSeconds(random.float(f64)), // 10% timer
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn populateRegistry(
    allocator: std.mem.Allocator,
    counter_names: []const []const u8,
    gauge_names: []const []const u8,
    hist_names: []const []const u8,
    timer_names: []const []const u8,
) !metrics.Registry {
    var reg = metrics.Registry.init(allocator);
    errdefer reg.deinit();

    for (counter_names) |name| {
        const c = try reg.counter(name, "bench");
        c.add(42);
    }
    for (gauge_names) |name| {
        const g = try reg.gauge(name, "bench");
        g.set(100);
    }
    for (hist_names) |name| {
        const h = try reg.histogram(name, "bench", &DEFAULT_BUCKETS);
        h.observe(0.5);
        h.observe(2.5);
        h.observe(7.0);
    }
    for (timer_names) |name| {
        const tmr = try reg.timer(name, "bench", &DEFAULT_BUCKETS);
        tmr.recordSeconds(0.1);
        tmr.recordSeconds(0.5);
    }
    return reg;
}

fn generateNames(allocator: std.mem.Allocator, prefix: []const u8, count: usize) ![][]const u8 {
    const names = try allocator.alloc([]const u8, count);
    for (names, 0..) |*name, i| {
        name.* = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ prefix, i });
    }
    return names;
}

fn opsPerSec(total_ops: anytype, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0;
    const ops: f64 = @floatFromInt(total_ops);
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    return ops / secs;
}

// ---------------------------------------------------------------------------
// Output: human-readable summary
// ---------------------------------------------------------------------------

fn printTierSummary(w: anytype, r: TierResult) !void {
    if (r.skipped) {
        try w.print("  SKIPPED: {s}\n", .{r.skip_reason orelse "unknown"});
        return;
    }
    try w.print(
        \\
        \\  Metric                    Value
        \\  ------------------------  ----------------
    , .{});
    try w.print("\n  counter_ops_sec           {d:.0}\n", .{r.counter_ops_sec});
    try w.print("  gauge_ops_sec             {d:.0}\n", .{r.gauge_ops_sec});
    try w.print("  histogram_ops_sec         {d:.0}\n", .{r.histogram_ops_sec});
    try w.print("  timer_ops_sec             {d:.0}\n", .{r.timer_ops_sec});
    try w.print("  registration_ns           {d:.1}\n", .{r.registration_ns});
    try w.print("  snapshot_ms               {d:.1}\n", .{r.snapshot_ms});
    try w.print("  parallel_snapshot_ms      {d:.1}\n", .{r.parallel_snapshot_ms});
    try w.print("  prometheus_ms             {d:.1}\n", .{r.prometheus_ms});
    try w.print("  mixed_ops_sec             {d:.0}\n", .{r.mixed_ops_sec});
}

// ---------------------------------------------------------------------------
// Output: JSON
// ---------------------------------------------------------------------------

fn writeJson(w: anytype, allocator: std.mem.Allocator, results: []const TierResult) !void {
    _ = allocator;
    // Timestamp
    const epoch_secs: u64 = @intCast(std.time.timestamp());
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    try w.print(
        \\{{
        \\  "version": 1,
        \\  "timestamp": "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        \\  "system": {{
        \\    "os": "{s}",
        \\    "arch": "{s}"
        \\  }},
        \\  "tiers": [
    , .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        @tagName(@import("builtin").os.tag),
        @tagName(@import("builtin").cpu.arch),
    });

    for (results, 0..) |r, i| {
        if (i > 0) try w.print(",", .{});
        try w.print(
            \\
            \\    {{
            \\      "name": "{s}",
            \\      "metric_count": {d},
            \\      "thread_count": {d},
        , .{ r.name, r.metric_count, r.thread_count });

        if (r.skipped) {
            try w.print(
                \\      "skipped": true,
                \\      "skip_reason": "{s}"
            , .{r.skip_reason orelse "unknown"});
        } else {
            try w.print("      \"counter_ops_sec\": {d:.0},\n", .{r.counter_ops_sec});
            try w.print("      \"gauge_ops_sec\": {d:.0},\n", .{r.gauge_ops_sec});
            try w.print("      \"histogram_ops_sec\": {d:.0},\n", .{r.histogram_ops_sec});
            try w.print("      \"timer_ops_sec\": {d:.0},\n", .{r.timer_ops_sec});
            try w.print("      \"registration_ns\": {d:.1},\n", .{r.registration_ns});
            try w.print("      \"snapshot_ms\": {d:.1},\n", .{r.snapshot_ms});
            try w.print("      \"parallel_snapshot_ms\": {d:.1},\n", .{r.parallel_snapshot_ms});
            try w.print("      \"prometheus_ms\": {d:.1},\n", .{r.prometheus_ms});
            try w.print("      \"mixed_ops_sec\": {d:.0}", .{r.mixed_ops_sec});
        }

        try w.print(
            \\
            \\    }}
        , .{});
    }

    try w.print(
        \\
        \\  ]
        \\}}
        \\
    , .{});
}
