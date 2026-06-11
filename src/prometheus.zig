// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Prometheus text exposition format exporter (MET-REQ-003).
//!
//! Writes metrics from a Registry in the standard Prometheus text format
//! (version 0.0.4). Uses a snapshot-first approach: captures metric values
//! under the registry lock, then writes to the output writer without holding
//! the lock.
//!
//! Reference: https://prometheus.io/docs/instrumenting/exposition_formats/

const std = @import("std");
const Registry = @import("registry.zig").Registry;
const snapshot_mod = @import("snapshot.zig");
const Snapshot = snapshot_mod.Snapshot;
const MetricSnapshot = snapshot_mod.MetricSnapshot;
const MetricKind = snapshot_mod.MetricKind;

/// Write all metrics from a registry in Prometheus text exposition format.
///
/// Captures a snapshot under the lock, then writes outside the lock.
/// This minimizes mutex hold time and avoids blocking producers during I/O.
pub fn writePrometheus(registry: *Registry, writer: anytype) !void {
    var snap = try registry.snapshot();
    defer snap.deinit();

    try writeSnapshot(&snap, writer);
}

/// Write a pre-captured snapshot in Prometheus text exposition format.
pub fn writeSnapshot(snap: *const Snapshot, writer: anytype) !void {
    for (snap.entries) |*entry| {
        switch (entry.kind) {
            .counter => try writeCounter(entry, writer),
            .gauge => try writeGauge(entry, writer),
            .histogram, .timer => try writeHistogram(entry, writer),
        }
    }
}

fn writeCounter(entry: *const MetricSnapshot, writer: anytype) !void {
    try writer.print("# HELP {s} {s}\n", .{ entry.name, entry.help });
    try writer.print("# TYPE {s} counter\n", .{entry.name});
    try writer.print("{s} {d}\n", .{ entry.name, entry.counter_value });
}

fn writeGauge(entry: *const MetricSnapshot, writer: anytype) !void {
    try writer.print("# HELP {s} {s}\n", .{ entry.name, entry.help });
    try writer.print("# TYPE {s} gauge\n", .{entry.name});
    try writer.print("{s} {d}\n", .{ entry.name, entry.gauge_value });
}

fn writeHistogram(entry: *const MetricSnapshot, writer: anytype) !void {
    try writer.print("# HELP {s} {s}\n", .{ entry.name, entry.help });
    try writer.print("# TYPE {s} histogram\n", .{entry.name});

    var cumulative: u64 = 0;
    for (entry.hist_buckets, entry.hist_bucket_counts) |bucket, count| {
        cumulative += count;
        try writer.print("{s}_bucket{{le=\"{d}\"}} {d}\n", .{ entry.name, bucket, cumulative });
    }

    try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ entry.name, entry.hist_count });
    try writer.print("{s}_sum {d}\n", .{ entry.name, entry.hist_sum });
    try writer.print("{s}_count {d}\n", .{ entry.name, entry.hist_count });
}

// ============================================================================
// Unit Tests
// ============================================================================

test "Prometheus: empty registry produces no output" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePrometheus(&reg, &writer);

    try std.testing.expectEqualStrings("", writer.buffered());
}

test "Prometheus: counter format" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const c = try reg.counter("http_requests_total", "Total HTTP requests");
    c.add(42);

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePrometheus(&reg, &writer);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "# HELP http_requests_total Total HTTP requests\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE http_requests_total counter\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "http_requests_total 42\n") != null);
}

test "Prometheus: gauge format" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const g = try reg.gauge("temperature", "Current temperature");
    g.set(-5);

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePrometheus(&reg, &writer);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE temperature gauge\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "temperature -5\n") != null);
}

test "Prometheus: histogram per-bucket cumulative output" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const buckets = [_]f64{ 0.1, 0.5, 1.0 };
    const h = try reg.histogram("latency_seconds", "Latency", &buckets);
    h.observe(0.05); // -> bucket[0] (<=0.1)
    h.observe(0.3); // -> bucket[1] (<=0.5)
    h.observe(2.0); // -> no bucket

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePrometheus(&reg, &writer);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE latency_seconds histogram\n") != null);
    // Per-bucket counts: [1, 1, 0]. Cumulative: le=0.1:1, le=0.5:2, le=1.0:2
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_seconds_bucket{le=\"0.1\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_seconds_bucket{le=\"0.5\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_seconds_bucket{le=\"1\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_seconds_bucket{le=\"+Inf\"} 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_seconds_count 3\n") != null);
}

test "Prometheus: timer uses histogram format" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const buckets = [_]f64{ 0.01, 0.1, 1.0 };
    const t = try reg.timer("request_duration_seconds", "Request duration", &buckets);
    t.recordSeconds(0.05);

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePrometheus(&reg, &writer);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE request_duration_seconds histogram\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "request_duration_seconds_count 1\n") != null);
}

test "Prometheus: multiple metrics in output" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    _ = try reg.counter("c1", "counter one");
    _ = try reg.gauge("g1", "gauge one");

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePrometheus(&reg, &writer);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "c1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "g1") != null);
}

test "Prometheus: above-max observation appears only in +Inf and _count (Q-027)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const buckets = [_]f64{ 1.0, 5.0 };
    const h = try reg.histogram("ovf_seconds", "Overflow", &buckets);
    h.observe(10.0);

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePrometheus(&reg, &writer);

    const output = writer.buffered();
    // Explicit buckets exclude it; +Inf and _count include it.
    try std.testing.expect(std.mem.indexOf(u8, output, "ovf_seconds_bucket{le=\"1\"} 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ovf_seconds_bucket{le=\"5\"} 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ovf_seconds_bucket{le=\"+Inf\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ovf_seconds_count 1\n") != null);
}

test "Prometheus: sub-microsecond bucket bounds stay distinct in le labels (S-020)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const buckets = [_]f64{ 1e-7, 2e-7, 1.0 };
    const h = try reg.histogram("tiny_seconds", "Tiny", &buckets);
    h.observe(1.5e-7); // second bucket

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePrometheus(&reg, &writer);

    const output = writer.buffered();
    // With {d:.6} both bounds collapsed to le="0.000000". Shortest
    // round-trip must keep them textually distinct.
    const needle = "tiny_seconds_bucket{le=\"";
    const first = std.mem.indexOf(u8, output, needle) orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOfPos(u8, output, first + 1, needle) orelse return error.TestUnexpectedResult;
    const first_end = std.mem.indexOfPos(u8, output, first, "\"}") orelse return error.TestUnexpectedResult;
    const second_end = std.mem.indexOfPos(u8, output, second, "\"}") orelse return error.TestUnexpectedResult;
    const label_a = output[first + needle.len .. first_end];
    const label_b = output[second + needle.len .. second_end];
    try std.testing.expect(!std.mem.eql(u8, label_a, label_b));
}
