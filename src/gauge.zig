// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Thread-safe gauge metric.
//!
//! Gauges represent a single value that can go up or down.
//! Typical uses: temperature, memory usage, active connections.

const std = @import("std");

/// A thread-safe gauge that can increase or decrease.
///
/// Uses atomic operations for lock-free concurrent updates.
/// Gauge values are signed 64-bit integers.
pub const Gauge = struct {
    name: []const u8,
    help: []const u8,
    value: std.atomic.Value(i64),

    /// Create a new gauge with the given name and help text.
    pub fn init(name: []const u8, help: []const u8) Gauge {
        return .{
            .name = name,
            .help = help,
            .value = std.atomic.Value(i64).init(0),
        };
    }

    /// Set the gauge to an absolute value.
    pub fn set(self: *Gauge, value: i64) void {
        self.value.store(value, .monotonic);
    }

    /// Increment the gauge by 1.
    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Decrement the gauge by 1.
    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    /// Add `delta` to the gauge (delta may be negative).
    pub fn add(self: *Gauge, delta: i64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    /// Subtract `delta` from the gauge.
    pub fn sub(self: *Gauge, delta: i64) void {
        _ = self.value.fetchSub(delta, .monotonic);
    }

    /// Read the current value.
    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.monotonic);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Gauge: default value is zero" {
    const g = Gauge.init("test", "help");
    try std.testing.expectEqual(@as(i64, 0), g.get());
}

test "Gauge: set replaces value" {
    var g = Gauge.init("test", "help");
    g.set(42);
    try std.testing.expectEqual(@as(i64, 42), g.get());
    g.set(-10);
    try std.testing.expectEqual(@as(i64, -10), g.get());
}

test "Gauge: inc and dec" {
    var g = Gauge.init("test", "help");
    g.inc();
    try std.testing.expectEqual(@as(i64, 1), g.get());
    g.dec();
    try std.testing.expectEqual(@as(i64, 0), g.get());
    g.dec();
    try std.testing.expectEqual(@as(i64, -1), g.get());
}

test "Gauge: add and sub with deltas" {
    var g = Gauge.init("test", "help");
    g.add(100);
    try std.testing.expectEqual(@as(i64, 100), g.get());
    g.sub(30);
    try std.testing.expectEqual(@as(i64, 70), g.get());
    g.add(-20);
    try std.testing.expectEqual(@as(i64, 50), g.get());
}

test "Gauge: name and help are preserved" {
    const g = Gauge.init("active_connections", "Currently active connections");
    try std.testing.expectEqualStrings("active_connections", g.name);
    try std.testing.expectEqualStrings("Currently active connections", g.help);
}

test "Gauge: concurrent inc and dec" {
    var g = Gauge.init("concurrent", "help");
    const iterations: i64 = 10_000;
    const thread_count = 4;

    var threads: [thread_count * 2]std.Thread = undefined;

    // Half threads increment, half decrement
    for (threads[0..thread_count]) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(gauge: *Gauge) void {
                for (0..@intCast(iterations)) |_| {
                    gauge.inc();
                }
            }
        }.run, .{&g});
    }
    for (threads[thread_count..]) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(gauge: *Gauge) void {
                for (0..@intCast(iterations)) |_| {
                    gauge.dec();
                }
            }
        }.run, .{&g});
    }
    for (&threads) |*t| t.join();

    // Equal inc and dec should net to zero
    try std.testing.expectEqual(@as(i64, 0), g.get());
}
