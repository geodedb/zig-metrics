// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Thread-safe monotonically increasing counter metric.
//!
//! Counters represent a cumulative value that only ever goes up (or resets to zero).
//! Typical uses: request counts, error counts, bytes transferred.

const std = @import("std");

/// A thread-safe monotonically increasing counter.
///
/// Uses atomic operations for lock-free concurrent updates.
/// Counter values are unsigned 64-bit integers.
pub const Counter = struct {
    name: []const u8,
    help: []const u8,
    value: std.atomic.Value(u64),

    /// Create a new counter with the given name and help text.
    pub fn init(name: []const u8, help: []const u8) Counter {
        return .{
            .name = name,
            .help = help,
            .value = std.atomic.Value(u64).init(0),
        };
    }

    /// Increment the counter by 1.
    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Add `delta` to the counter.
    pub fn add(self: *Counter, delta: u64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    /// Read the current value.
    pub fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }

    /// Reset the counter to zero.
    pub fn reset(self: *Counter) void {
        self.value.store(0, .monotonic);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Counter: default value is zero" {
    const c = Counter.init("test", "help");
    try std.testing.expectEqual(@as(u64, 0), c.get());
}

test "Counter: inc increments by one" {
    var c = Counter.init("test", "help");
    c.inc();
    try std.testing.expectEqual(@as(u64, 1), c.get());
    c.inc();
    try std.testing.expectEqual(@as(u64, 2), c.get());
}

test "Counter: add increments by delta" {
    var c = Counter.init("test", "help");
    c.add(10);
    try std.testing.expectEqual(@as(u64, 10), c.get());
    c.add(5);
    try std.testing.expectEqual(@as(u64, 15), c.get());
}

test "Counter: add zero is a no-op" {
    var c = Counter.init("test", "help");
    c.add(42);
    c.add(0);
    try std.testing.expectEqual(@as(u64, 42), c.get());
}

test "Counter: reset sets value to zero" {
    var c = Counter.init("test", "help");
    c.add(100);
    c.reset();
    try std.testing.expectEqual(@as(u64, 0), c.get());
}

test "Counter: name and help are preserved" {
    const c = Counter.init("http_requests_total", "Total HTTP requests");
    try std.testing.expectEqualStrings("http_requests_total", c.name);
    try std.testing.expectEqualStrings("Total HTTP requests", c.help);
}

test "Counter: concurrent increments" {
    var c = Counter.init("concurrent", "help");
    const iterations: u64 = 10_000;
    const thread_count = 4;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(counter: *Counter) void {
                for (0..iterations) |_| {
                    counter.inc();
                }
            }
        }.run, .{&c});
    }
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(iterations * thread_count, c.get());
}
