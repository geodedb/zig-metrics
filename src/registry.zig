// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Instance-based metrics registry.
//!
//! The Registry owns and manages the lifecycle of all registered metrics.
//! It is fully instance-based with no global state (MET-REQ-004).
//! Thread-safe for concurrent registration and collection.

const std = @import("std");
const tp = @import("thread_pool");

/// 0.16.0 shim: std.Thread.RwLock was moved to std.Io.RwLock and requires
/// an Io instance for all lock/unlock calls. Wrap std.Io.Mutex instead to
/// keep the Registry API Io-free. Read-vs-write distinction is sacrificed
/// (all ops take exclusive lock) but correctness is preserved.
const RwLockShim = struct {
    inner: std.Io.Mutex = std.Io.Mutex.init,

    fn getIo() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    pub fn lock(self: *RwLockShim) void {
        self.inner.lockUncancelable(getIo());
    }
    pub fn unlock(self: *RwLockShim) void {
        self.inner.unlock(getIo());
    }
    pub fn lockShared(self: *RwLockShim) void {
        self.inner.lockUncancelable(getIo());
    }
    pub fn unlockShared(self: *RwLockShim) void {
        self.inner.unlock(getIo());
    }
};
/// 0.16.0 shim: std.time.nanoTimestamp() was removed. Use Io clock instead.
fn nanoTimestampCompat() i96 {
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io_inst, .real).raw.toNanoseconds();
}

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

/// Tuning knobs for Registry behavior.
pub const RegistryOptions = struct {
    /// In `parallelSnapshot`, subdivide histograms/timers into
    /// `ceil(count / snapshot_chunk_size)` sub-tasks. Default 64 is
    /// chosen empirically: above this, the per-task overhead is dwarfed
    /// by per-metric bucket-copy cost. Lower values distribute work
    /// across more workers at the cost of more per-task bookkeeping.
    snapshot_chunk_size: usize = 64,
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
    rwlock: RwLockShim,
    options: RegistryOptions = .{},

    /// Create a new empty registry with default options.
    pub fn init(allocator: std.mem.Allocator) Registry {
        return initWithOptions(allocator, .{});
    }

    /// Create a new empty registry with explicit tuning options.
    pub fn initWithOptions(allocator: std.mem.Allocator, options: RegistryOptions) Registry {
        return .{
            .allocator = allocator,
            .counters = std.StringHashMap(*Counter).init(allocator),
            .gauges = std.StringHashMap(*Gauge).init(allocator),
            .histograms = std.StringHashMap(*Histogram).init(allocator),
            .timers = std.StringHashMap(*Timer).init(allocator),
            .rwlock = .{},
            .options = options,
        };
    }

    /// Destroy the registry and free all owned metrics.
    pub fn deinit(self: *Registry) void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

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

        self.rwlock.lock();
        defer self.rwlock.unlock();

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

        self.rwlock.lock();
        defer self.rwlock.unlock();

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

        self.rwlock.lock();
        defer self.rwlock.unlock();

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

        self.rwlock.lock();
        defer self.rwlock.unlock();

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
    /// Uses a shared (read) lock -- concurrent lookups do not block each other.
    pub fn getCounter(self: *Registry, name: []const u8) ?*Counter {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();
        return self.counters.get(name);
    }

    /// Look up a gauge by name. Returns null if not found.
    pub fn getGauge(self: *Registry, name: []const u8) ?*Gauge {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();
        return self.gauges.get(name);
    }

    /// Look up a histogram by name. Returns null if not found.
    pub fn getHistogram(self: *Registry, name: []const u8) ?*Histogram {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();
        return self.histograms.get(name);
    }

    /// Look up a timer by name. Returns null if not found.
    pub fn getTimer(self: *Registry, name: []const u8) ?*Timer {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();
        return self.timers.get(name);
    }

    /// Capture a point-in-time snapshot of all metrics.
    /// Uses a shared (read) lock -- concurrent snapshots and lookups
    /// do not block each other or metric updates (which are lock-free).
    pub fn snapshot(self: *Registry) error{OutOfMemory}!Snapshot {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();
        return snapshot_mod.captureSnapshot(
            self.allocator,
            &self.counters,
            &self.gauges,
            &self.histograms,
            &self.timers,
        );
    }

    /// Capture a snapshot using thread-pool submitBatch to fan-out capture
    /// across the four metric types concurrently. Each metric type is captured
    /// on a separate worker thread when workers are available.
    ///
    /// Requires an initialised thread-pool.
    ///
    /// Errors: `OutOfMemory` from the pre-allocation phase, or any error
    /// that `tp.ThreadPool.submitBatch` can return (e.g.
    /// `error.ShutdownInProgress`, `error.QueueFull`, `error.Timeout`,
    /// `error.TaskPoolExhausted`, `error.BuildOptionMismatch`). The error
    /// set is inferred from the implementation so callers see the actual
    /// failure rather than a coerced `OutOfMemory` — a shutting-down
    /// pool looks nothing like an allocator failure and should not be
    /// triaged as one.
    pub fn parallelSnapshot(self: *Registry, pool: *tp.ThreadPool) !Snapshot {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        // Pre-calculate sizes (sequential -- needed before allocation)
        const counter_count = self.counters.count();
        const gauge_count = self.gauges.count();
        const hist_count = self.histograms.count();
        const timer_count = self.timers.count();
        const total = counter_count + gauge_count + hist_count + timer_count;

        var hist_bucket_total: usize = 0;
        var hist_iter_pre = self.histograms.valueIterator();
        while (hist_iter_pre.next()) |h| {
            hist_bucket_total += h.*.buckets.len;
        }
        var timer_bucket_total: usize = 0;
        var timer_iter_pre = self.timers.valueIterator();
        while (timer_iter_pre.next()) |t| {
            timer_bucket_total += t.*.histogram.buckets.len;
        }
        const bucket_total = hist_bucket_total + timer_bucket_total;

        // Allocate storage
        const entries = self.allocator.alloc(snapshot_mod.MetricSnapshot, total) catch return error.OutOfMemory;
        errdefer self.allocator.free(entries);
        const bucket_count_storage = self.allocator.alloc(u64, bucket_total) catch return error.OutOfMemory;
        errdefer self.allocator.free(bucket_count_storage);
        const bucket_bound_storage = self.allocator.alloc(f64, bucket_total) catch return error.OutOfMemory;
        errdefer self.allocator.free(bucket_bound_storage);

        // Slice ranges for each metric type
        const counter_entries = entries[0..counter_count];
        const gauge_entries = entries[counter_count .. counter_count + gauge_count];
        const hist_entries = entries[counter_count + gauge_count .. counter_count + gauge_count + hist_count];
        const timer_entries = entries[counter_count + gauge_count + hist_count .. total];
        const hist_bucket_counts = bucket_count_storage[0..hist_bucket_total];
        const hist_bucket_bounds = bucket_bound_storage[0..hist_bucket_total];
        const timer_bucket_counts = bucket_count_storage[hist_bucket_total..bucket_total];
        const timer_bucket_bounds = bucket_bound_storage[hist_bucket_total..bucket_total];

        // Task context types for the three background captures.
        const GaugeCtx = struct {
            gauges: *std.StringHashMap(*Gauge),
            out: []snapshot_mod.MetricSnapshot,
        };
        const HistCtx = struct {
            histograms: *std.StringHashMap(*Histogram),
            out: []snapshot_mod.MetricSnapshot,
            counts: []u64,
            bounds: []f64,
        };
        const TimerCtx = struct {
            timers: *std.StringHashMap(*Timer),
            out: []snapshot_mod.MetricSnapshot,
            counts: []u64,
            bounds: []f64,
        };

        var gauge_ctx = GaugeCtx{ .gauges = &self.gauges, .out = gauge_entries };
        var hist_ctx = HistCtx{
            .histograms = &self.histograms,
            .out = hist_entries,
            .counts = hist_bucket_counts,
            .bounds = hist_bucket_bounds,
        };
        var timer_ctx = TimerCtx{
            .timers = &self.timers,
            .out = timer_entries,
            .counts = timer_bucket_counts,
            .bounds = timer_bucket_bounds,
        };

        // Fan-out gauges, histograms, timers to the thread pool.
        var wg = pool.waitGroup();
        const tasks = [_]tp.BatchTask{
            .{
                .task_fn = struct {
                    fn run(ctx: *anyopaque, _: *tp.TaskContext) void {
                        const c: *GaugeCtx = @ptrCast(@alignCast(ctx));
                        var iter = c.gauges.iterator();
                        var idx: usize = 0;
                        while (iter.next()) |entry| {
                            const g = entry.value_ptr.*;
                            c.out[idx] = .{
                                .name = g.name,
                                .help = g.help,
                                .kind = .gauge,
                                .gauge_value = g.get(),
                            };
                            idx += 1;
                        }
                    }
                }.run,
                .ctx = &gauge_ctx,
            },
            .{
                .task_fn = struct {
                    fn run(ctx: *anyopaque, _: *tp.TaskContext) void {
                        const c: *HistCtx = @ptrCast(@alignCast(ctx));
                        captureHistType(c.histograms, c.out, c.counts, c.bounds, .histogram);
                    }
                }.run,
                .ctx = &hist_ctx,
            },
            .{
                .task_fn = struct {
                    fn run(ctx: *anyopaque, _: *tp.TaskContext) void {
                        const c: *TimerCtx = @ptrCast(@alignCast(ctx));
                        captureTimerType(c.timers, c.out, c.counts, c.bounds);
                    }
                }.run,
                .ctx = &timer_ctx,
            },
        };
        // Propagate the real thread-pool error (ShutdownInProgress,
        // QueueFull, etc.) instead of masking it as OutOfMemory. See the
        // parallelSnapshot doc comment for the full inferred error set.
        _ = try pool.submitBatch(&tasks, .{ .wait_group = &wg });

        // Capture counters on the calling thread while workers run.
        {
            var iter = self.counters.iterator();
            var idx: usize = 0;
            while (iter.next()) |entry| {
                const c = entry.value_ptr.*;
                counter_entries[idx] = .{
                    .name = c.name,
                    .help = c.help,
                    .kind = .counter,
                    .counter_value = c.get(),
                };
                idx += 1;
            }
        }

        wg.wait();

        return .{
            .entries = entries,
            .bucket_count_storage = bucket_count_storage,
            .bucket_bound_storage = bucket_bound_storage,
            .allocator = self.allocator,
            .timestamp_ns = nanoTimestampCompat(),
        };
    }

    fn captureHistType(
        histograms: *std.StringHashMap(*Histogram),
        out: []snapshot_mod.MetricSnapshot,
        counts: []u64,
        bounds: []f64,
        kind: snapshot_mod.MetricKind,
    ) void {
        var iter = histograms.iterator();
        var idx: usize = 0;
        var offset: usize = 0;
        while (iter.next()) |entry| {
            const h = entry.value_ptr.*;
            const blen = h.buckets.len;
            const count_slice = counts[offset .. offset + blen];
            const bound_slice = bounds[offset .. offset + blen];
            for (0..blen) |i| {
                count_slice[i] = h.getBucketCount(i);
                bound_slice[i] = h.buckets[i];
            }
            out[idx] = .{
                .name = h.name,
                .help = h.help,
                .kind = kind,
                .hist_count = h.getCount(),
                .hist_sum = h.getSum(),
                .hist_buckets = bound_slice,
                .hist_bucket_counts = count_slice,
            };
            idx += 1;
            offset += blen;
        }
    }

    fn captureTimerType(
        timers: *std.StringHashMap(*Timer),
        out: []snapshot_mod.MetricSnapshot,
        counts: []u64,
        bounds: []f64,
    ) void {
        var iter = timers.iterator();
        var idx: usize = 0;
        var offset: usize = 0;
        while (iter.next()) |entry| {
            const t = entry.value_ptr.*;
            const h = &t.histogram;
            const blen = h.buckets.len;
            const count_slice = counts[offset .. offset + blen];
            const bound_slice = bounds[offset .. offset + blen];
            for (0..blen) |i| {
                count_slice[i] = h.getBucketCount(i);
                bound_slice[i] = h.buckets[i];
            }
            out[idx] = .{
                .name = h.name,
                .help = h.help,
                .kind = .timer,
                .hist_count = h.getCount(),
                .hist_sum = h.getSum(),
                .hist_buckets = bound_slice,
                .hist_bucket_counts = count_slice,
            };
            idx += 1;
            offset += blen;
        }
    }

    /// Return the total number of registered metrics across all types.
    pub fn metricCount(self: *Registry) usize {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();
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
