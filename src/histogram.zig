// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Thread-safe histogram metric with configurable buckets.
//!
//! Histograms sample observations and count them in configurable buckets.
//! They also provide a total count and sum of observed values.
//! Typical uses: request latencies, response sizes.

const std = @import("std");

/// Default Prometheus-style latency buckets (in seconds).
pub const default_buckets: []const f64 = &.{
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
};

/// A thread-safe histogram with configurable buckets.
///
/// Bucket counts are per-bucket (non-cumulative): each bucket counts only
/// observations that fall into its range (previous_bound, current_bound].
/// The Prometheus exporter computes cumulative counts at export time.
pub const Histogram = struct {
    name: []const u8,
    help: []const u8,
    buckets: []const f64,
    counts: []std.atomic.Value(u64),
    sum_bits: std.atomic.Value(u64),
    count: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    /// Bucket validation errors.
    pub const BucketError = error{
        /// Buckets slice must not be empty.
        EmptyBuckets,
        /// Buckets must be sorted in strictly ascending order with no duplicates.
        UnsortedBuckets,
        /// Bucket boundaries must be finite (no NaN or Inf).
        NonFiniteBucket,
    };

    /// Create a new histogram with validated bucket boundaries.
    /// The caller retains ownership of `buckets` (must outlive the Histogram).
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        help: []const u8,
        buckets: []const f64,
    ) (BucketError || error{OutOfMemory})!Histogram {
        if (buckets.len == 0) return error.EmptyBuckets;
        for (buckets) |b| {
            if (std.math.isNan(b) or std.math.isInf(b)) return error.NonFiniteBucket;
        }
        for (0..buckets.len - 1) |i| {
            if (buckets[i] >= buckets[i + 1]) return error.UnsortedBuckets;
        }

        const counts = try allocator.alloc(std.atomic.Value(u64), buckets.len);
        for (counts) |*c| {
            c.* = std.atomic.Value(u64).init(0);
        }

        return .{
            .name = name,
            .help = help,
            .buckets = buckets,
            .counts = counts,
            .sum_bits = std.atomic.Value(u64).init(@bitCast(@as(f64, 0.0))),
            .count = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    /// Free bucket count storage.
    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.counts);
    }

    /// Record an observation. The value is added to the sum and the
    /// matching bucket counter is incremented. Only the first bucket
    /// whose upper bound >= value is incremented (per-bucket storage).
    ///
    /// NaN and Inf values are silently ignored (not counted).
    /// Negative values are accepted: they match the first bucket whose
    /// upper bound >= the value (typically the lowest bucket).
    pub fn observe(self: *Histogram, value: f64) void {
        if (std.math.isNan(value) or std.math.isInf(value)) return;

        _ = self.count.fetchAdd(1, .monotonic);
        atomicAddF64(&self.sum_bits, value);

        for (self.buckets, 0..) |bucket, i| {
            if (value <= bucket) {
                _ = self.counts[i].fetchAdd(1, .monotonic);
                break;
            }
        }
    }

    /// Return the total number of observations.
    pub fn getCount(self: *const Histogram) u64 {
        return self.count.load(.monotonic);
    }

    /// Return the sum of all observed values.
    pub fn getSum(self: *const Histogram) f64 {
        return @bitCast(self.sum_bits.load(.monotonic));
    }

    /// Return the per-bucket (non-cumulative) count at `index`.
    pub fn getBucketCount(self: *const Histogram, index: usize) u64 {
        return self.counts[index].load(.monotonic);
    }

    /// Atomically add an f64 to an atomic u64 storing bit-cast f64.
    fn atomicAddF64(bits: *std.atomic.Value(u64), delta: f64) void {
        var current = bits.load(.monotonic);
        while (true) {
            const current_f: f64 = @bitCast(current);
            const new_f: f64 = current_f + delta;
            const new_bits: u64 = @bitCast(new_f);
            const result = bits.cmpxchgWeak(current, new_bits, .monotonic, .monotonic);
            if (result) |actual| {
                current = actual;
                std.atomic.spinLoopHint();
            } else {
                return;
            }
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Histogram: initial state" {
    const allocator = std.testing.allocator;
    const buckets = [_]f64{ 0.1, 0.5, 1.0, 5.0 };
    var h = try Histogram.init(allocator, "test", "help", &buckets);
    defer h.deinit();

    try std.testing.expectEqual(@as(u64, 0), h.getCount());
    try std.testing.expectEqual(@as(f64, 0.0), h.getSum());
    for (0..buckets.len) |i| {
        try std.testing.expectEqual(@as(u64, 0), h.getBucketCount(i));
    }
}

test "Histogram: single observation goes into correct bucket (per-bucket)" {
    const allocator = std.testing.allocator;
    const buckets = [_]f64{ 0.1, 0.5, 1.0, 5.0 };
    var h = try Histogram.init(allocator, "test", "help", &buckets);
    defer h.deinit();

    h.observe(0.3);

    try std.testing.expectEqual(@as(u64, 1), h.getCount());
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), h.getSum(), 1e-10);

    // 0.3 > 0.1, so bucket[0] = 0
    try std.testing.expectEqual(@as(u64, 0), h.getBucketCount(0));
    // 0.3 <= 0.5 (first match), so bucket[1] = 1
    try std.testing.expectEqual(@as(u64, 1), h.getBucketCount(1));
    // bucket[2] and [3] are 0 because we break after first match
    try std.testing.expectEqual(@as(u64, 0), h.getBucketCount(2));
    try std.testing.expectEqual(@as(u64, 0), h.getBucketCount(3));
}

test "Histogram: multiple observations (per-bucket counts)" {
    const allocator = std.testing.allocator;
    const buckets = [_]f64{ 0.1, 0.5, 1.0, 5.0 };
    var h = try Histogram.init(allocator, "test", "help", &buckets);
    defer h.deinit();

    h.observe(0.05); // -> bucket[0] (<=0.1)
    h.observe(0.3); // -> bucket[1] (<=0.5)
    h.observe(2.0); // -> bucket[3] (<=5.0)
    h.observe(10.0); // -> no bucket (exceeds all)

    try std.testing.expectEqual(@as(u64, 4), h.getCount());
    try std.testing.expectApproxEqAbs(@as(f64, 12.35), h.getSum(), 1e-10);

    try std.testing.expectEqual(@as(u64, 1), h.getBucketCount(0)); // 0.05 only
    try std.testing.expectEqual(@as(u64, 1), h.getBucketCount(1)); // 0.3 only
    try std.testing.expectEqual(@as(u64, 0), h.getBucketCount(2)); // nothing in (0.5, 1.0]
    try std.testing.expectEqual(@as(u64, 1), h.getBucketCount(3)); // 2.0 only
}

test "Histogram: boundary values (per-bucket)" {
    const allocator = std.testing.allocator;
    const buckets = [_]f64{ 1.0, 2.0, 3.0 };
    var h = try Histogram.init(allocator, "test", "help", &buckets);
    defer h.deinit();

    h.observe(1.0); // exactly on boundary -> bucket[0]
    h.observe(2.0); // exactly on boundary -> bucket[1]
    h.observe(3.0); // exactly on boundary -> bucket[2]

    try std.testing.expectEqual(@as(u64, 1), h.getBucketCount(0));
    try std.testing.expectEqual(@as(u64, 1), h.getBucketCount(1));
    try std.testing.expectEqual(@as(u64, 1), h.getBucketCount(2));
}

test "Histogram: NaN and Inf are rejected" {
    const allocator = std.testing.allocator;
    const buckets = [_]f64{ 1.0, 5.0 };
    var h = try Histogram.init(allocator, "test", "help", &buckets);
    defer h.deinit();

    h.observe(std.math.nan(f64));
    h.observe(std.math.inf(f64));
    h.observe(-std.math.inf(f64));

    // None of these should be counted
    try std.testing.expectEqual(@as(u64, 0), h.getCount());
    try std.testing.expectEqual(@as(f64, 0.0), h.getSum());
}

test "Histogram: negative values land in first bucket" {
    const allocator = std.testing.allocator;
    const buckets = [_]f64{ 0.1, 1.0, 10.0 };
    var h = try Histogram.init(allocator, "test", "help", &buckets);
    defer h.deinit();

    h.observe(-1.0);

    // -1.0 <= 0.1, so it goes into bucket[0]
    try std.testing.expectEqual(@as(u64, 1), h.getCount());
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), h.getSum(), 1e-10);
    try std.testing.expectEqual(@as(u64, 1), h.getBucketCount(0));
    try std.testing.expectEqual(@as(u64, 0), h.getBucketCount(1));
    try std.testing.expectEqual(@as(u64, 0), h.getBucketCount(2));
}

test "Histogram: concurrent observations" {
    const allocator = std.testing.allocator;
    const buckets = [_]f64{ 0.5, 1.0, 5.0 };
    var h = try Histogram.init(allocator, "test", "help", &buckets);
    defer h.deinit();

    const iterations: u64 = 10_000;
    const thread_count = 4;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(hist: *Histogram) void {
                for (0..iterations) |_| {
                    hist.observe(0.1); // always goes to bucket[0]
                }
            }
        }.run, .{&h});
    }
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(iterations * thread_count, h.getCount());
    try std.testing.expectEqual(iterations * thread_count, h.getBucketCount(0));
}

test "Histogram: name and help preserved" {
    const allocator = std.testing.allocator;
    var h = try Histogram.init(allocator, "request_duration", "Duration in seconds", default_buckets);
    defer h.deinit();

    try std.testing.expectEqualStrings("request_duration", h.name);
    try std.testing.expectEqualStrings("Duration in seconds", h.help);
}

test "Histogram: default_buckets is well-formed" {
    // Verify sorted ascending
    for (0..default_buckets.len - 1) |i| {
        try std.testing.expect(default_buckets[i] < default_buckets[i + 1]);
    }
}

test "Histogram: empty buckets rejected" {
    const allocator = std.testing.allocator;
    const empty: []const f64 = &.{};
    try std.testing.expectError(error.EmptyBuckets, Histogram.init(allocator, "test", "help", empty));
}

test "Histogram: unsorted buckets rejected" {
    const allocator = std.testing.allocator;
    const unsorted = [_]f64{ 1.0, 0.5, 2.0 };
    try std.testing.expectError(error.UnsortedBuckets, Histogram.init(allocator, "test", "help", &unsorted));
}

test "Histogram: duplicate buckets rejected" {
    const allocator = std.testing.allocator;
    const dupes = [_]f64{ 1.0, 1.0, 2.0 };
    try std.testing.expectError(error.UnsortedBuckets, Histogram.init(allocator, "test", "help", &dupes));
}

test "Histogram: NaN bucket rejected" {
    const allocator = std.testing.allocator;
    const bad = [_]f64{ 1.0, std.math.nan(f64), 3.0 };
    try std.testing.expectError(error.NonFiniteBucket, Histogram.init(allocator, "test", "help", &bad));
}

test "Histogram: Inf bucket rejected" {
    const allocator = std.testing.allocator;
    const bad = [_]f64{ 1.0, 2.0, std.math.inf(f64) };
    try std.testing.expectError(error.NonFiniteBucket, Histogram.init(allocator, "test", "help", &bad));
}
