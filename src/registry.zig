// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Instance-based metrics registry.
//!
//! The Registry owns and manages the lifecycle of all registered metrics.
//! It is fully instance-based with no global state (MET-REQ-004).
//! Thread-safe for concurrent registration and collection.

const std = @import("std");
const Counter = @import("counter.zig").Counter;
const Gauge = @import("gauge.zig").Gauge;
const Histogram = @import("histogram.zig").Histogram;
const Timer = @import("timer.zig").Timer;
const snapshot_mod = @import("snapshot.zig");
const Snapshot = snapshot_mod.Snapshot;

/// Errors that can occur during metric registration.
pub const RegistryError = error{
    /// A metric with the given name already exists.
    AlreadyRegistered,
    /// Allocation failed.
    OutOfMemory,
    /// Metric name contains invalid characters (must match [a-zA-Z_:][a-zA-Z0-9_:]*).
    InvalidMetricName,
    /// Help text contains unescaped newlines.
    InvalidHelpText,
    /// Histogram buckets are empty.
    EmptyBuckets,
    /// Histogram buckets are not sorted in strictly ascending order.
    UnsortedBuckets,
    /// Histogram bucket boundary is NaN or Inf.
    NonFiniteBucket,
};

/// An instance-based metrics registry.
///
/// Owns all registered metrics and provides thread-safe access.
/// Create one per application or component; no global singletons.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    counters: std.StringHashMap(*Counter),
    gauges: std.StringHashMap(*Gauge),
    histograms: std.StringHashMap(*Histogram),
    timers: std.StringHashMap(*Timer),
    mutex: std.Thread.Mutex,

    /// Create a new empty registry.
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .counters = std.StringHashMap(*Counter).init(allocator),
            .gauges = std.StringHashMap(*Gauge).init(allocator),
            .histograms = std.StringHashMap(*Histogram).init(allocator),
            .timers = std.StringHashMap(*Timer).init(allocator),
            .mutex = .{},
        };
    }

    /// Destroy the registry and free all owned metrics.
    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var counter_iter = self.counters.valueIterator();
        while (counter_iter.next()) |c| {
            self.allocator.destroy(c.*);
        }
        self.counters.deinit();

        var gauge_iter = self.gauges.valueIterator();
        while (gauge_iter.next()) |g| {
            self.allocator.destroy(g.*);
        }
        self.gauges.deinit();

        var hist_iter = self.histograms.valueIterator();
        while (hist_iter.next()) |h| {
            h.*.deinit();
            self.allocator.destroy(h.*);
        }
        self.histograms.deinit();

        var timer_iter = self.timers.valueIterator();
        while (timer_iter.next()) |t| {
            t.*.deinit();
            self.allocator.destroy(t.*);
        }
        self.timers.deinit();
    }

    /// Validate a Prometheus metric name: [a-zA-Z_:][a-zA-Z0-9_:]*
    fn validateName(name: []const u8) RegistryError!void {
        if (name.len == 0) return error.InvalidMetricName;
        const first = name[0];
        if (!isAlpha(first) and first != '_' and first != ':') return error.InvalidMetricName;
        for (name[1..]) |ch| {
            if (!isAlpha(ch) and !isDigit(ch) and ch != '_' and ch != ':') return error.InvalidMetricName;
        }
    }

    /// Validate help text contains no newlines, carriage returns, or
    /// backslashes (which require escaping in Prometheus exposition format).
    fn validateHelp(help: []const u8) RegistryError!void {
        for (help) |ch| {
            if (ch == '\n' or ch == '\r' or ch == '\\') return error.InvalidHelpText;
        }
    }

    /// Check that `name` is not already registered under any metric type.
    fn nameInUse(self: *const Registry, name: []const u8) bool {
        return self.counters.contains(name) or
            self.gauges.contains(name) or
            self.histograms.contains(name) or
            self.timers.contains(name);
    }

    fn isAlpha(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
    }

    fn isDigit(ch: u8) bool {
        return ch >= '0' and ch <= '9';
    }

    /// Register a new counter. Returns `AlreadyRegistered` if the name is taken
    /// by any metric type.
    pub fn counter(self: *Registry, name: []const u8, help: []const u8) RegistryError!*Counter {
        try validateName(name);
        try validateHelp(help);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.nameInUse(name)) return error.AlreadyRegistered;

        const c = self.allocator.create(Counter) catch return error.OutOfMemory;
        c.* = Counter.init(name, help);
        self.counters.put(name, c) catch {
            self.allocator.destroy(c);
            return error.OutOfMemory;
        };
        return c;
    }

    /// Register a new gauge. Returns `AlreadyRegistered` if the name is taken
    /// by any metric type.
    pub fn gauge(self: *Registry, name: []const u8, help: []const u8) RegistryError!*Gauge {
        try validateName(name);
        try validateHelp(help);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.nameInUse(name)) return error.AlreadyRegistered;

        const g = self.allocator.create(Gauge) catch return error.OutOfMemory;
        g.* = Gauge.init(name, help);
        self.gauges.put(name, g) catch {
            self.allocator.destroy(g);
            return error.OutOfMemory;
        };
        return g;
    }

    /// Register a new histogram. Returns `AlreadyRegistered` if the name is taken.
    pub fn histogram(
        self: *Registry,
        name: []const u8,
        help: []const u8,
        buckets: []const f64,
    ) RegistryError!*Histogram {
        try validateName(name);
        try validateHelp(help);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.nameInUse(name)) return error.AlreadyRegistered;

        const h = self.allocator.create(Histogram) catch return error.OutOfMemory;
        h.* = Histogram.init(self.allocator, name, help, buckets) catch |err| {
            self.allocator.destroy(h);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.EmptyBuckets => error.EmptyBuckets,
                error.UnsortedBuckets => error.UnsortedBuckets,
                error.NonFiniteBucket => error.NonFiniteBucket,
            };
        };
        self.histograms.put(name, h) catch {
            h.deinit();
            self.allocator.destroy(h);
            return error.OutOfMemory;
        };
        return h;
    }

    /// Register a new timer. Returns `AlreadyRegistered` if the name is taken.
    pub fn timer(
        self: *Registry,
        name: []const u8,
        help: []const u8,
        buckets: []const f64,
    ) RegistryError!*Timer {
        try validateName(name);
        try validateHelp(help);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.nameInUse(name)) return error.AlreadyRegistered;

        const t = self.allocator.create(Timer) catch return error.OutOfMemory;
        t.* = Timer.init(self.allocator, name, help, buckets) catch |err| {
            self.allocator.destroy(t);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.EmptyBuckets => error.EmptyBuckets,
                error.UnsortedBuckets => error.UnsortedBuckets,
                error.NonFiniteBucket => error.NonFiniteBucket,
            };
        };
        self.timers.put(name, t) catch {
            t.deinit();
            self.allocator.destroy(t);
            return error.OutOfMemory;
        };
        return t;
    }

    /// Look up a counter by name. Returns null if not found.
    pub fn getCounter(self: *Registry, name: []const u8) ?*Counter {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.counters.get(name);
    }

    /// Look up a gauge by name. Returns null if not found.
    pub fn getGauge(self: *Registry, name: []const u8) ?*Gauge {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.gauges.get(name);
    }

    /// Look up a histogram by name. Returns null if not found.
    pub fn getHistogram(self: *Registry, name: []const u8) ?*Histogram {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.histograms.get(name);
    }

    /// Look up a timer by name. Returns null if not found.
    pub fn getTimer(self: *Registry, name: []const u8) ?*Timer {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.timers.get(name);
    }

    /// Capture a point-in-time snapshot of all metrics.
    pub fn snapshot(self: *Registry) error{OutOfMemory}!Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return snapshot_mod.captureSnapshot(
            self.allocator,
            &self.counters,
            &self.gauges,
            &self.histograms,
            &self.timers,
        );
    }

    /// Return the total number of registered metrics across all types.
    pub fn metricCount(self: *Registry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.counters.count() + self.gauges.count() +
            self.histograms.count() + self.timers.count();
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Registry: init and deinit empty" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), reg.metricCount());
}

test "Registry: register and use counter" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const c = try reg.counter("requests_total", "Total requests");
    c.inc();
    c.add(9);
    try std.testing.expectEqual(@as(u64, 10), c.get());
    try std.testing.expectEqual(@as(usize, 1), reg.metricCount());
}

test "Registry: register and use gauge" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const g = try reg.gauge("connections", "Active connections");
    g.set(42);
    try std.testing.expectEqual(@as(i64, 42), g.get());
}

test "Registry: register and use histogram" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const buckets = [_]f64{ 0.1, 0.5, 1.0 };
    const h = try reg.histogram("latency", "Latency", &buckets);
    h.observe(0.3);
    try std.testing.expectEqual(@as(u64, 1), h.getCount());
}

test "Registry: register and use timer" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const buckets = [_]f64{ 0.01, 0.1, 1.0 };
    const t = try reg.timer("duration", "Duration", &buckets);
    t.recordSeconds(0.05);
    try std.testing.expectEqual(@as(u64, 1), t.getCount());
}

test "Registry: duplicate registration returns AlreadyRegistered" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    _ = try reg.counter("foo", "help");
    try std.testing.expectError(error.AlreadyRegistered, reg.counter("foo", "help2"));
}

test "Registry: getCounter returns registered metric" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const c = try reg.counter("foo", "help");
    c.add(7);

    const found = reg.getCounter("foo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 7), found.get());
}

test "Registry: getCounter returns null for missing" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expect(reg.getCounter("missing") == null);
}

test "Registry: snapshot captures all metrics" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const c = try reg.counter("c1", "counter");
    c.add(100);
    const g = try reg.gauge("g1", "gauge");
    g.set(42);

    var snap = try reg.snapshot();
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 2), snap.len());

    const cs = snap.get("c1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 100), cs.counter_value);

    const gs = snap.get("g1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 42), gs.gauge_value);
}

test "Registry: multiple metric types coexist" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    _ = try reg.counter("c", "help");
    _ = try reg.gauge("g", "help");
    const buckets = [_]f64{1.0};
    _ = try reg.histogram("h", "help", &buckets);
    _ = try reg.timer("t", "help", &buckets);

    try std.testing.expectEqual(@as(usize, 4), reg.metricCount());
}

test "Registry: invalid metric name rejected" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectError(error.InvalidMetricName, reg.counter("123bad", "help"));
    try std.testing.expectError(error.InvalidMetricName, reg.counter("has space", "help"));
    try std.testing.expectError(error.InvalidMetricName, reg.counter("has-dash", "help"));
    try std.testing.expectError(error.InvalidMetricName, reg.counter("", "help"));
}

test "Registry: valid metric names accepted" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    _ = try reg.counter("simple", "help");
    _ = try reg.counter("with_underscore", "help");
    _ = try reg.counter("with:colon", "help");
    _ = try reg.counter("_leading_underscore", "help");
    _ = try reg.counter(":leading_colon", "help");
    _ = try reg.counter("MixedCase123", "help");
}

test "Registry: newline in help text rejected" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectError(error.InvalidHelpText, reg.counter("valid_name", "has\nnewline"));
}

test "Registry: carriage return in help text rejected" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectError(error.InvalidHelpText, reg.counter("valid_name", "has\rreturn"));
}

test "Registry: backslash in help text rejected" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectError(error.InvalidHelpText, reg.counter("valid_name", "path C:\\temp"));
}

test "Registry: cross-type duplicate name rejected" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    _ = try reg.counter("shared", "a counter");
    // Same name as gauge should be rejected
    try std.testing.expectError(error.AlreadyRegistered, reg.gauge("shared", "a gauge"));

    const buckets = [_]f64{1.0};
    // Same name as histogram should be rejected
    try std.testing.expectError(error.AlreadyRegistered, reg.histogram("shared", "a histogram", &buckets));
    // Same name as timer should be rejected
    try std.testing.expectError(error.AlreadyRegistered, reg.timer("shared", "a timer", &buckets));
}

test "Registry: different names across types succeed" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    _ = try reg.counter("counter_metric", "help");
    _ = try reg.gauge("gauge_metric", "help");
    const buckets = [_]f64{1.0};
    _ = try reg.histogram("histogram_metric", "help", &buckets);
    _ = try reg.timer("timer_metric", "help", &buckets);

    try std.testing.expectEqual(@as(usize, 4), reg.metricCount());
}
