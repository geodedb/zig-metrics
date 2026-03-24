// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Integration tests for the metrics library.
//!
//! These tests verify end-to-end functionality and cross-module interactions.

const std = @import("std");
const metrics = @import("metrics");

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
    var fbs = std.io.fixedBufferStream(&buf);
    try metrics.writePrometheus(&reg, fbs.writer());

    const output = fbs.getWritten();

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

test "version is defined" {
    try std.testing.expectEqualStrings("0.1.0", metrics.version);
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
