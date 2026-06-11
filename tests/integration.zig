// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Integration tests for the metrics library.
//!
//! These tests verify end-to-end functionality and cross-module interactions.

const std = @import("std");
const metrics = @import("metrics");
const tp = @import("thread_pool");

// ============================================================================
// Smoke Tests (MET-TEST-002)
// ============================================================================

test "smoke: create registry and register all metric types" {
    var reg = metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    const c = try reg.counter("requests_total", "Total requests");
    const g = try reg.gauge("connections", "Active connections");
    const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0, 5.0 };
    const h = try reg.histogram("latency_seconds", "Latency", &buckets);
    const t = try reg.timer("duration_seconds", "Duration", &buckets);

    // Use every metric type
    c.inc();
    c.add(99);
    g.set(42);
    g.inc();
    g.dec();
    h.observe(0.03);
    h.observe(0.7);
    t.recordSeconds(0.2);
    t.recordNanos(500_000); // 0.0005s

    try std.testing.expectEqual(@as(u64, 100), c.get());
    try std.testing.expectEqual(@as(i64, 42), g.get());
    try std.testing.expectEqual(@as(u64, 2), h.getCount());
    try std.testing.expectEqual(@as(u64, 2), t.getCount());
}

test "smoke: prometheus export produces valid output" {
    var reg = metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    const c = try reg.counter("smoke_counter", "A test counter");
    c.add(7);

    const g = try reg.gauge("smoke_gauge", "A test gauge");
    g.set(99);

    const buckets = [_]f64{ 0.1, 0.5, 1.0 };
    const h = try reg.histogram("smoke_hist", "A test histogram", &buckets);
    h.observe(0.3);

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try metrics.writePrometheus(&reg, &writer);

    const output = writer.buffered();

    // Verify counter
    try std.testing.expect(std.mem.indexOf(u8, output, "smoke_counter 7") != null);

    // Verify gauge
    try std.testing.expect(std.mem.indexOf(u8, output, "smoke_gauge 99") != null);

    // Verify histogram has TYPE, buckets, sum, count
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE smoke_hist histogram") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "smoke_hist_bucket{le=\"+Inf\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "smoke_hist_count 1") != null);
}

test "smoke: snapshot captures consistent point-in-time values" {
    var reg = metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    const c = try reg.counter("snap_c", "counter");
    c.add(1000);

    const g = try reg.gauge("snap_g", "gauge");
    g.set(-42);

    var snap = try reg.snapshot();
    defer snap.deinit();

    // Mutate after snapshot
    c.add(9999);
    g.set(0);

    // Snapshot should reflect pre-mutation values
    const cs = snap.get("snap_c") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1000), cs.counter_value);

    const gs = snap.get("snap_g") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, -42), gs.gauge_value);
}

// ============================================================================
// No Global State Verification (MET-REQ-004)
// ============================================================================

test "no globals: two registries are fully independent" {
    var reg1 = metrics.Registry.init(std.testing.allocator);
    defer reg1.deinit();
    var reg2 = metrics.Registry.init(std.testing.allocator);
    defer reg2.deinit();

    const c1 = try reg1.counter("shared_name", "from reg1");
    const c2 = try reg2.counter("shared_name", "from reg2");

    c1.add(10);
    c2.add(20);

    try std.testing.expectEqual(@as(u64, 10), c1.get());
    try std.testing.expectEqual(@as(u64, 20), c2.get());
}

// ============================================================================
// Version
// ============================================================================

test "version matches build manifest" {
    try std.testing.expectEqualStrings(@import("build_options").version, metrics.version);
    // Sanity: semver-ish shape (at least "x.y.z").
    try std.testing.expect(std.mem.count(u8, metrics.version, ".") == 2);
}

// ============================================================================
// Cross-module type re-exports
// ============================================================================

test "public types are accessible" {
    // Verify all public types from the root module compile and are accessible
    _ = metrics.Counter;
    _ = metrics.Gauge;
    _ = metrics.Histogram;
    _ = metrics.Timer;
    _ = metrics.Registry;
    _ = metrics.Snapshot;
    _ = metrics.MetricSnapshot;
    _ = metrics.MetricKind;
    _ = metrics.RegistryError;
    _ = metrics.default_buckets;
    _ = metrics.default_timer_buckets;
    _ = metrics.writePrometheus;
}

// ============================================================================
// Thread pool integration (structured concurrency)
// ============================================================================

const CounterArgs = struct { counter: *metrics.Counter };

fn counterTask(ctx: *anyopaque, _: *tp.TaskContext) void {
    const args: *CounterArgs = @ptrCast(@alignCast(ctx));
    for (0..10_000) |_| {
        args.counter.inc();
    }
}

test "thread_pool: concurrent counter updates via thread pool" {
    const thread_count = 4;

    var pool = try tp.ThreadPool.init(std.testing.allocator, .{});
    defer pool.deinit();

    var reg = metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    const c = try reg.counter("tp_counter", "thread_pool test counter");

    var args: [thread_count]CounterArgs = undefined;
    var tasks: [thread_count]tp.BatchTask = undefined;
    for (0..thread_count) |i| {
        args[i] = .{ .counter = c };
        tasks[i] = .{ .task_fn = counterTask, .ctx = &args[i] };
    }

    var wg = pool.waitGroup();
    _ = try pool.submitBatch(&tasks, .{ .wait_group = &wg });
    wg.wait();

    try std.testing.expectEqual(@as(u64, 10_000 * thread_count), c.get());
}

test "thread_pool: parallel snapshot captures consistent data" {
    var pool = try tp.ThreadPool.init(std.testing.allocator, .{});
    defer pool.deinit();

    var reg = metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    const c = try reg.counter("ps_counter", "counter");
    c.add(42);
    const g = try reg.gauge("ps_gauge", "gauge");
    g.set(-7);
    const buckets = [_]f64{ 0.1, 1.0, 10.0 };
    const h = try reg.histogram("ps_hist", "histogram", &buckets);
    h.observe(0.5);
    h.observe(5.0);

    var snap = try reg.parallelSnapshot(&pool);
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 3), snap.len());

    const cs = snap.get("ps_counter") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 42), cs.counter_value);

    const gs = snap.get("ps_gauge") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, -7), gs.gauge_value);

    const hs = snap.get("ps_hist") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), hs.hist_count);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), hs.hist_sum, 1e-10);
}

test "thread_pool: parallelSnapshot shards histograms when count > chunk_size" {
    var pool = try tp.ThreadPool.init(std.testing.allocator, .{ .max_threads = 4 });
    defer pool.deinit();

    var reg = metrics.Registry.initWithOptions(std.testing.allocator, .{ .snapshot_chunk_size = 4 });
    defer reg.deinit();

    // Register 16 histograms → expect ceil(16/4) = 4 histogram sub-tasks.
    const buckets = [_]f64{ 1.0, 10.0, 100.0 };
    inline for (0..16) |i| {
        const name = std.fmt.comptimePrint("h_{d}", .{i});
        const h = try reg.histogram(name, "help", &buckets);
        // Observe at least once so the snapshot has non-trivial data
        // and the capture loop actually runs through every bucket.
        h.observe(@floatFromInt(i + 1));
    }

    const before = pool.statsSnapshot().submitted;
    var snap = try reg.parallelSnapshot(&pool);
    defer snap.deinit();
    const after = pool.statsSnapshot().submitted;

    // 1 gauge-task + 4 hist-shards + 1 timer-task (timer count 0 → 0
    // tasks). Minimum is 1 + 4 + 0 = 5; the implementation may emit
    // >= 5 depending on whether zero-count types are elided. The
    // baseline (pre-sharding) only submits 3 tasks total.
    try std.testing.expect(after - before >= 5);

    // Snapshot content sanity: all 16 histograms must be captured with
    // the observed values preserved.
    try std.testing.expectEqual(@as(usize, 16), snap.len());
    inline for (0..16) |i| {
        const name = std.fmt.comptimePrint("h_{d}", .{i});
        const hs = snap.get(name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u64, 1), hs.hist_count);
        try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(i + 1)), hs.hist_sum, 1e-10);
    }
}

test "thread_pool: parallelSnapshot never returns garbage entries under pool saturation (S-018)" {
    // Tiny descriptor pool + many single-metric shards forces partial
    // batch submission. With the fix, every iteration either succeeds
    // with fully-initialized entries or fails cleanly with
    // error.SnapshotIncomplete / a pool error -- never garbage.
    var reg = metrics.Registry.initWithOptions(std.testing.allocator, .{
        .snapshot_chunk_size = 1,
    });
    defer reg.deinit();

    const buckets = [_]f64{ 0.5, 1.0 };
    inline for (0..32) |i| {
        const name = std.fmt.comptimePrint("sat_h_{d}", .{i});
        const h = try reg.histogram(name, "help", &buckets);
        h.observe(0.25);
    }

    // Phase 1: saturated pool. queue_capacity doubles as the descriptor
    // cap (queued + running), so 4 slots can never hold the 34-task
    // batch (1 gauge + 32 hist shards + 1 timer): under .return_error
    // backpressure submitBatch accepts a prefix and reports a short
    // `submitted` count without an error. Pre-fix, parallelSnapshot
    // returned "success" here with uninitialized entries (wild
    // name/help pointers); post-fix every iteration must be rejected
    // cleanly and never hand back a partially-written snapshot.
    {
        var pool = try tp.ThreadPool.init(std.testing.allocator, .{
            .max_threads = 1,
            .queue_capacity = 4,
        });
        defer pool.deinit();

        var clean_rejections: usize = 0;
        for (0..50) |_| {
            var snap = reg.parallelSnapshot(&pool) catch |err| switch (err) {
                error.SnapshotIncomplete => {
                    clean_rejections += 1; // clean partial-submit rejection
                    continue;
                },
                else => continue, // pool backpressure errors are acceptable
            };
            defer snap.deinit();
            // A surprise success is fine only if fully initialized.
            try std.testing.expectEqual(@as(usize, 32), snap.len());
            for (snap.entries) |*entry| {
                if (entry.kind != .histogram) continue;
                try std.testing.expect(entry.name.len >= 7); // "sat_h_N"
                try std.testing.expect(std.mem.startsWith(u8, entry.name, "sat_h_"));
                try std.testing.expectEqual(@as(u64, 1), entry.hist_count);
            }
        }
        // 34 tasks can never fit 4 descriptor slots: the guard must fire.
        try std.testing.expect(clean_rejections > 0);
    }

    // Phase 2: ample pool. The same registry must snapshot successfully
    // with every entry fully initialized and readable.
    {
        var pool = try tp.ThreadPool.init(std.testing.allocator, .{
            .max_threads = 2,
            .queue_capacity = 64,
        });
        defer pool.deinit();

        var successes: usize = 0;
        for (0..50) |_| {
            var snap = reg.parallelSnapshot(&pool) catch |err| switch (err) {
                error.SnapshotIncomplete => return error.TestUnexpectedResult, // healthy pool must accept full batch
                else => continue, // transient pool errors tolerated
            };
            defer snap.deinit();
            successes += 1;
            try std.testing.expectEqual(@as(usize, 32), snap.len());
            for (snap.entries) |*entry| {
                if (entry.kind != .histogram) continue;
                try std.testing.expect(entry.name.len >= 7); // "sat_h_N"
                try std.testing.expect(std.mem.startsWith(u8, entry.name, "sat_h_"));
                try std.testing.expectEqual(@as(u64, 1), entry.hist_count);
            }
        }
        // With 64 descriptor slots for 34 tasks the pool drains fast, so
        // most iterations should succeed.
        try std.testing.expect(successes > 0);
    }
}

test "registry owns name/help copies; caller may free originals (S-017)" {
    const allocator = std.testing.allocator;
    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();

    // Heap-allocate name/help, register, then free the originals.
    const name = try std.fmt.allocPrint(allocator, "heap_{s}_total", .{"requests"});
    const help = try std.fmt.allocPrint(allocator, "help text {d}", .{42});
    const c = try reg.counter(name, help);
    c.add(7);
    allocator.free(name);
    allocator.free(help);

    // Lookup by a fresh equal-content key must still work, and the
    // stored name/help must read back correctly (no dangling slices).
    const found = reg.getCounter("heap_requests_total") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 7), found.get());
    try std.testing.expectEqualStrings("heap_requests_total", found.name);
    try std.testing.expectEqualStrings("help text 42", found.help);

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try metrics.writePrometheus(&reg, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "heap_requests_total 7\n") != null);
}
