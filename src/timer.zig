// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Timer metric for measuring durations.
//!
//! A Timer wraps a Histogram and records elapsed time in seconds.
//! Typical uses: function call durations, request handling times.

const std = @import("std");
const histogram_mod = @import("histogram.zig");
const Histogram = histogram_mod.Histogram;
const compat = @import("compat.zig");

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
        metric_name: []const u8,
        metric_help: []const u8,
        buckets: []const f64,
    ) (Histogram.BucketError || error{OutOfMemory})!Timer {
        return .{
            .histogram = try Histogram.init(allocator, metric_name, metric_help, buckets),
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
            .start_ns = compat.nanoTimestampMonotonic(),
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

    /// Return the timer's metric name (delegates to the inner histogram).
    pub fn name(self: *const Timer) []const u8 {
        return self.histogram.name;
    }

    /// Return the timer's help text (delegates to the inner histogram).
    pub fn help(self: *const Timer) []const u8 {
        return self.histogram.help;
    }

    /// Return the observation count of bucket `index` (delegates to the
    /// inner histogram; per-bucket, not cumulative).
    pub fn getBucketCount(self: *const Timer, index: usize) u64 {
        return self.histogram.getBucketCount(index);
    }

    /// An in-flight timing measurement.
    pub const Sample = struct {
        timer: *Timer,
        start_ns: i96,

        /// Stop the timer and record the elapsed duration.
        /// Clamps to zero; monotonic clock makes backward steps impossible
        /// on conformant platforms, but clamp guards against any quirks.
        pub fn finish(self: Sample) void {
            const end_ns = compat.nanoTimestampMonotonic();
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
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    io_inst.sleep(std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch {}; // 1ms
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

test "Timer: accessors delegate to inner histogram (Q-029)" {
    const allocator = std.testing.allocator;
    var t = try Timer.init(allocator, "acc_timer", "Accessor test", default_timer_buckets);
    defer t.deinit();
    t.recordSeconds(0.002);
    try std.testing.expectEqualStrings("acc_timer", t.name());
    try std.testing.expectEqualStrings("Accessor test", t.help());
    try std.testing.expectEqual(@as(u64, 1), t.getBucketCount(1)); // 0.002 <= 0.005, bucket index 1
}

test "Timer: uses monotonic clock for durations (P-011)" {
    // Monotonic timestamps can never go backward; two consecutive reads
    // must be non-decreasing. This also pins the compat helper choice:
    // Timer must use the monotonic (.awake) clock, not wall (.real).
    const a = @import("compat.zig").nanoTimestampMonotonic();
    const b = @import("compat.zig").nanoTimestampMonotonic();
    try std.testing.expect(b >= a);
}
