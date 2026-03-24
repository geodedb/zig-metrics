// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Timer metric for measuring durations.
//!
//! A Timer wraps a Histogram and records elapsed time in seconds.
//! Typical uses: function call durations, request handling times.

const std = @import("std");
const histogram_mod = @import("histogram.zig");
const Histogram = histogram_mod.Histogram;

/// Default timer buckets (in seconds) suitable for typical latency measurements.
pub const default_timer_buckets: []const f64 = &.{
    0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
};

/// A timer that measures elapsed durations and records them in an underlying histogram.
///
/// Durations are recorded in seconds (as f64).
pub const Timer = struct {
    histogram: Histogram,

    /// Create a new timer with the given name, help text, and bucket boundaries.
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        help: []const u8,
        buckets: []const f64,
    ) (Histogram.BucketError || error{OutOfMemory})!Timer {
        return .{
            .histogram = try Histogram.init(allocator, name, help, buckets),
        };
    }

    /// Free resources.
    pub fn deinit(self: *Timer) void {
        self.histogram.deinit();
    }

    /// Start a measurement. Returns a `Sample` that records the elapsed time
    /// when `.finish()` is called.
    pub fn start(self: *Timer) Sample {
        return .{
            .timer = self,
            .start_ns = std.time.nanoTimestamp(),
        };
    }

    /// Record an externally measured duration in seconds.
    pub fn recordSeconds(self: *Timer, seconds: f64) void {
        self.histogram.observe(seconds);
    }

    /// Record an externally measured duration in nanoseconds.
    pub fn recordNanos(self: *Timer, nanos: u64) void {
        const seconds: f64 = @as(f64, @floatFromInt(nanos)) / 1_000_000_000.0;
        self.histogram.observe(seconds);
    }

    /// Return the total number of recorded durations.
    pub fn getCount(self: *const Timer) u64 {
        return self.histogram.getCount();
    }

    /// Return the sum of all recorded durations in seconds.
    pub fn getSum(self: *const Timer) f64 {
        return self.histogram.getSum();
    }

    /// An in-flight timing measurement.
    pub const Sample = struct {
        timer: *Timer,
        start_ns: i128,

        /// Stop the timer and record the elapsed duration.
        /// Clamps to zero if clock moved backward (e.g., NTP correction).
        pub fn finish(self: Sample) void {
            const end_ns = std.time.nanoTimestamp();
            const elapsed_ns = @max(0, end_ns - self.start_ns);
            const seconds: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            self.timer.histogram.observe(seconds);
        }
    };
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Timer: initial state" {
    const allocator = std.testing.allocator;
    var t = try Timer.init(allocator, "test_timer", "help", default_timer_buckets);
    defer t.deinit();

    try std.testing.expectEqual(@as(u64, 0), t.getCount());
    try std.testing.expectEqual(@as(f64, 0.0), t.getSum());
}

test "Timer: recordSeconds" {
    const allocator = std.testing.allocator;
    var t = try Timer.init(allocator, "test_timer", "help", default_timer_buckets);
    defer t.deinit();

    t.recordSeconds(0.5);
    t.recordSeconds(1.0);

    try std.testing.expectEqual(@as(u64, 2), t.getCount());
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), t.getSum(), 1e-10);
}

test "Timer: recordNanos" {
    const allocator = std.testing.allocator;
    var t = try Timer.init(allocator, "test_timer", "help", default_timer_buckets);
    defer t.deinit();

    t.recordNanos(500_000_000); // 0.5s
    try std.testing.expectEqual(@as(u64, 1), t.getCount());
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), t.getSum(), 1e-10);
}

test "Timer: start/finish records elapsed time" {
    const allocator = std.testing.allocator;
    var t = try Timer.init(allocator, "test_timer", "help", default_timer_buckets);
    defer t.deinit();

    const sample = t.start();
    // Busy wait a tiny bit so elapsed > 0
    std.Thread.sleep(1_000_000); // 1ms
    sample.finish();

    try std.testing.expectEqual(@as(u64, 1), t.getCount());
    try std.testing.expect(t.getSum() > 0.0);
}

test "Timer: name and help from underlying histogram" {
    const allocator = std.testing.allocator;
    var t = try Timer.init(allocator, "request_duration_seconds", "Request duration", default_timer_buckets);
    defer t.deinit();

    try std.testing.expectEqualStrings("request_duration_seconds", t.histogram.name);
    try std.testing.expectEqualStrings("Request duration", t.histogram.help);
}

test "Timer: default_timer_buckets is sorted" {
    for (0..default_timer_buckets.len - 1) |i| {
        try std.testing.expect(default_timer_buckets[i] < default_timer_buckets[i + 1]);
    }
}
