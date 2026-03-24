// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Point-in-time snapshot of all metrics in a registry.
//!
//! Snapshots provide a consistent, immutable view of metric values at a given
//! instant. They are useful for export, comparison, and testing.

const std = @import("std");
const Counter = @import("counter.zig").Counter;
const Gauge = @import("gauge.zig").Gauge;
const Histogram = @import("histogram.zig").Histogram;
const Timer = @import("timer.zig").Timer;

/// The type of a captured metric value.
pub const MetricKind = enum {
    counter,
    gauge,
    histogram,
    timer,
};

/// A single metric value captured at snapshot time.
pub const MetricSnapshot = struct {
    name: []const u8,
    help: []const u8,
    kind: MetricKind,
    /// Counter value (u64 stored directly; use counter_value for full range).
    counter_value: u64 = 0,
    /// Gauge value (i64).
    gauge_value: i64 = 0,
    /// Histogram/timer observation count.
    hist_count: u64 = 0,
    /// Histogram/timer sum.
    hist_sum: f64 = 0.0,
    /// Histogram/timer bucket upper bounds (owned by snapshot).
    hist_buckets: []const f64 = &.{},
    /// Histogram/timer per-bucket counts (owned by snapshot).
    hist_bucket_counts: []const u64 = &.{},
};

/// An immutable point-in-time collection of metric values.
pub const Snapshot = struct {
    entries: []MetricSnapshot,
    /// Owned storage for bucket count + boundary slices.
    bucket_count_storage: []u64,
    bucket_bound_storage: []f64,
    allocator: std.mem.Allocator,
    timestamp_ns: i128,

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.bucket_count_storage);
        self.allocator.free(self.bucket_bound_storage);
        self.allocator.free(self.entries);
    }

    /// Find a metric by name. Returns null if not found.
    pub fn get(self: *const Snapshot, name: []const u8) ?*const MetricSnapshot {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }

    /// Return the number of metrics in the snapshot.
    pub fn len(self: *const Snapshot) usize {
        return self.entries.len;
    }
};

/// Capture a snapshot from separate metric maps.
///
/// This is called by the registry; callers should use `Registry.snapshot()` instead.
pub fn captureSnapshot(
    allocator: std.mem.Allocator,
    counters: *std.StringHashMap(*Counter),
    gauges: *std.StringHashMap(*Gauge),
    histograms: *std.StringHashMap(*Histogram),
    timers: *std.StringHashMap(*Timer),
) error{OutOfMemory}!Snapshot {
    const total = counters.count() + gauges.count() + histograms.count() + timers.count();

    // Pre-calculate total bucket storage needed
    var bucket_total: usize = 0;
    var hist_iter_count = histograms.valueIterator();
    while (hist_iter_count.next()) |h| {
        bucket_total += h.*.buckets.len;
    }
    var timer_iter_count = timers.valueIterator();
    while (timer_iter_count.next()) |t| {
        bucket_total += t.*.histogram.buckets.len;
    }

    const entries = try allocator.alloc(MetricSnapshot, total);
    errdefer allocator.free(entries);

    const bucket_count_storage = try allocator.alloc(u64, bucket_total);
    errdefer allocator.free(bucket_count_storage);

    const bucket_bound_storage = try allocator.alloc(f64, bucket_total);
    errdefer allocator.free(bucket_bound_storage);

    var idx: usize = 0;
    var bucket_offset: usize = 0;

    // Capture counters
    var counter_iter = counters.iterator();
    while (counter_iter.next()) |entry| {
        const c = entry.value_ptr.*;
        entries[idx] = .{
            .name = c.name,
            .help = c.help,
            .kind = .counter,
            .counter_value = c.get(),
        };
        idx += 1;
    }

    // Capture gauges
    var gauge_iter = gauges.iterator();
    while (gauge_iter.next()) |entry| {
        const g = entry.value_ptr.*;
        entries[idx] = .{
            .name = g.name,
            .help = g.help,
            .kind = .gauge,
            .gauge_value = g.get(),
        };
        idx += 1;
    }

    // Capture histograms
    var hist_iter = histograms.iterator();
    while (hist_iter.next()) |entry| {
        const h = entry.value_ptr.*;
        bucket_offset = captureHistogramBuckets(h, bucket_count_storage, bucket_bound_storage, bucket_offset, entries, idx);
        entries[idx].kind = .histogram;
        idx += 1;
    }

    // Capture timers
    var timer_iter = timers.iterator();
    while (timer_iter.next()) |entry| {
        const t = entry.value_ptr.*;
        bucket_offset = captureHistogramBuckets(&t.histogram, bucket_count_storage, bucket_bound_storage, bucket_offset, entries, idx);
        entries[idx].kind = .timer;
        idx += 1;
    }

    return .{
        .entries = entries,
        .bucket_count_storage = bucket_count_storage,
        .bucket_bound_storage = bucket_bound_storage,
        .allocator = allocator,
        .timestamp_ns = std.time.nanoTimestamp(),
    };
}

fn captureHistogramBuckets(
    h: *const Histogram,
    bucket_count_storage: []u64,
    bucket_bound_storage: []f64,
    offset: usize,
    entries: []MetricSnapshot,
    idx: usize,
) usize {
    const bucket_len = h.buckets.len;
    const count_slice = bucket_count_storage[offset .. offset + bucket_len];
    const bound_slice = bucket_bound_storage[offset .. offset + bucket_len];
    for (0..bucket_len) |i| {
        count_slice[i] = h.getBucketCount(i);
        bound_slice[i] = h.buckets[i];
    }
    entries[idx] = .{
        .name = h.name,
        .help = h.help,
        .kind = .histogram, // caller overrides for timer
        .hist_count = h.getCount(),
        .hist_sum = h.getSum(),
        .hist_buckets = bound_slice,
        .hist_bucket_counts = count_slice,
    };
    return offset + bucket_len;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "Snapshot: empty snapshot" {
    const allocator = std.testing.allocator;
    var counters = std.StringHashMap(*Counter).init(allocator);
    defer counters.deinit();
    var gauges = std.StringHashMap(*Gauge).init(allocator);
    defer gauges.deinit();
    var histograms = std.StringHashMap(*Histogram).init(allocator);
    defer histograms.deinit();
    var timers = std.StringHashMap(*Timer).init(allocator);
    defer timers.deinit();

    var snap = try captureSnapshot(allocator, &counters, &gauges, &histograms, &timers);
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 0), snap.len());
    try std.testing.expect(snap.get("nonexistent") == null);
}

test "Snapshot: captures counter value (full u64 range)" {
    const allocator = std.testing.allocator;
    var c = Counter.init("requests_total", "Total requests");
    c.add(42);

    var counters = std.StringHashMap(*Counter).init(allocator);
    defer counters.deinit();
    try counters.put("requests_total", &c);

    var gauges = std.StringHashMap(*Gauge).init(allocator);
    defer gauges.deinit();
    var histograms = std.StringHashMap(*Histogram).init(allocator);
    defer histograms.deinit();
    var timers = std.StringHashMap(*Timer).init(allocator);
    defer timers.deinit();

    var snap = try captureSnapshot(allocator, &counters, &gauges, &histograms, &timers);
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 1), snap.len());
    const entry = snap.get("requests_total") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(MetricKind.counter, entry.kind);
    try std.testing.expectEqual(@as(u64, 42), entry.counter_value);
}

test "Snapshot: captures gauge value" {
    const allocator = std.testing.allocator;
    var g = Gauge.init("connections", "Active connections");
    g.set(-5);

    var counters = std.StringHashMap(*Counter).init(allocator);
    defer counters.deinit();
    var gauges = std.StringHashMap(*Gauge).init(allocator);
    defer gauges.deinit();
    try gauges.put("connections", &g);
    var histograms = std.StringHashMap(*Histogram).init(allocator);
    defer histograms.deinit();
    var timers = std.StringHashMap(*Timer).init(allocator);
    defer timers.deinit();

    var snap = try captureSnapshot(allocator, &counters, &gauges, &histograms, &timers);
    defer snap.deinit();

    const entry = snap.get("connections") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(MetricKind.gauge, entry.kind);
    try std.testing.expectEqual(@as(i64, -5), entry.gauge_value);
}

test "Snapshot: captures histogram with owned bucket boundaries" {
    const allocator = std.testing.allocator;
    const buckets = [_]f64{ 1.0, 5.0, 10.0 };
    var h = try Histogram.init(allocator, "latency", "Latency", &buckets);
    defer h.deinit();
    h.observe(2.0);
    h.observe(7.0);

    var counters = std.StringHashMap(*Counter).init(allocator);
    defer counters.deinit();
    var gauges = std.StringHashMap(*Gauge).init(allocator);
    defer gauges.deinit();
    var histograms = std.StringHashMap(*Histogram).init(allocator);
    defer histograms.deinit();
    try histograms.put("latency", &h);
    var timers = std.StringHashMap(*Timer).init(allocator);
    defer timers.deinit();

    var snap = try captureSnapshot(allocator, &counters, &gauges, &histograms, &timers);
    defer snap.deinit();

    const entry = snap.get("latency") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(MetricKind.histogram, entry.kind);
    try std.testing.expectEqual(@as(u64, 2), entry.hist_count);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), entry.hist_sum, 1e-10);
    try std.testing.expectEqual(@as(usize, 3), entry.hist_bucket_counts.len);
    // Bucket boundaries are owned copies
    try std.testing.expectEqual(@as(f64, 1.0), entry.hist_buckets[0]);
    try std.testing.expectEqual(@as(f64, 10.0), entry.hist_buckets[2]);
}

test "Snapshot: captures timers" {
    const allocator = std.testing.allocator;
    const buckets = [_]f64{ 0.01, 0.1, 1.0 };
    var t = try Timer.init(allocator, "duration", "Duration", &buckets);
    defer t.deinit();
    t.recordSeconds(0.05);

    var counters = std.StringHashMap(*Counter).init(allocator);
    defer counters.deinit();
    var gauges = std.StringHashMap(*Gauge).init(allocator);
    defer gauges.deinit();
    var histograms = std.StringHashMap(*Histogram).init(allocator);
    defer histograms.deinit();
    var timers = std.StringHashMap(*Timer).init(allocator);
    defer timers.deinit();
    try timers.put("duration", &t);

    var snap = try captureSnapshot(allocator, &counters, &gauges, &histograms, &timers);
    defer snap.deinit();

    const entry = snap.get("duration") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(MetricKind.timer, entry.kind);
    try std.testing.expectEqual(@as(u64, 1), entry.hist_count);
}

test "Snapshot: get returns null for missing name" {
    const allocator = std.testing.allocator;
    var counters = std.StringHashMap(*Counter).init(allocator);
    defer counters.deinit();
    var gauges = std.StringHashMap(*Gauge).init(allocator);
    defer gauges.deinit();
    var histograms = std.StringHashMap(*Histogram).init(allocator);
    defer histograms.deinit();
    var timers = std.StringHashMap(*Timer).init(allocator);
    defer timers.deinit();

    var snap = try captureSnapshot(allocator, &counters, &gauges, &histograms, &timers);
    defer snap.deinit();

    try std.testing.expect(snap.get("missing") == null);
}
