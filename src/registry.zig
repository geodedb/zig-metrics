// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Instance-based metrics registry.
//!
//! The Registry owns and manages the lifecycle of all registered metrics.
//! It is fully instance-based with no global state (MET-REQ-004).
//! Thread-safe for concurrent registration and collection.
//!
//! Ownership: the Registry copies metric `name`/`help` strings into its
//! own allocator at registration time; callers may free their buffers
//! immediately after registering (S-017). Histogram/timer bucket slices
//! are still borrowed and must outlive the Registry.

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
const compat = @import("compat.zig");

const Counter = @import("counter.zig").Counter;
const Gauge = @import("gauge.zig").Gauge;
const Histogram = @import("histogram.zig").Histogram;
const Timer = @import("timer.zig").Timer;
const snapshot_mod = @import("snapshot.zig");
const Snapshot = snapshot_mod.Snapshot;

/// Errors that can occur during metric registration.
/// Bucket validation errors are composed directly from
/// `Histogram.BucketError` so the two sets cannot drift (Q-024).
pub const RegistryError = error{
    /// A metric with the given name already exists.
    AlreadyRegistered,
    /// Allocation failed.
    OutOfMemory,
    /// Metric name contains invalid characters (must match [a-zA-Z_:][a-zA-Z0-9_:]*).
    InvalidMetricName,
    /// Help text contains unescaped newlines.
    InvalidHelpText,
    /// The registry's max_metrics cardinality cap has been reached (S-019).
    CardinalityLimitExceeded,
} || Histogram.BucketError;

/// Tuning knobs for Registry behavior.
pub const RegistryOptions = struct {
    /// In `parallelSnapshot`, subdivide histograms/timers into
    /// `ceil(count / snapshot_chunk_size)` sub-tasks. Default 64 is
    /// chosen empirically: above this, the per-task overhead is dwarfed
    /// by per-metric bucket-copy cost. Lower values distribute work
    /// across more workers at the cost of more per-task bookkeeping.
    snapshot_chunk_size: usize = 64,
    /// Optional hard cap on the total number of registered metrics across
    /// all types. Null (default) means unlimited. Metric names must always
    /// be low-cardinality and developer-controlled — never derived from
    /// untrusted input — but a cap converts an accidental cardinality
    /// explosion (CWE-770 memory-exhaustion DoS) into a clean error.
    max_metrics: ?usize = null,
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

        var counter_iter = self.counters.iterator();
        while (counter_iter.next()) |kv| {
            const c = kv.value_ptr.*;
            self.allocator.free(c.help);
            self.allocator.destroy(c);
            self.allocator.free(kv.key_ptr.*); // owned name (== c.name)
        }
        self.counters.deinit();

        var gauge_iter = self.gauges.iterator();
        while (gauge_iter.next()) |kv| {
            const g = kv.value_ptr.*;
            self.allocator.free(g.help);
            self.allocator.destroy(g);
            self.allocator.free(kv.key_ptr.*); // owned name (== g.name)
        }
        self.gauges.deinit();

        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |kv| {
            const h = kv.value_ptr.*;
            self.allocator.free(h.help);
            h.deinit();
            self.allocator.destroy(h);
            self.allocator.free(kv.key_ptr.*); // owned name (== h.name)
        }
        self.histograms.deinit();

        var timer_iter = self.timers.iterator();
        while (timer_iter.next()) |kv| {
            const t = kv.value_ptr.*;
            self.allocator.free(t.histogram.help);
            t.deinit();
            self.allocator.destroy(t);
            self.allocator.free(kv.key_ptr.*); // owned name (== t.histogram.name)
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
        if (self.options.max_metrics) |cap| {
            if (self.countLocked() >= cap) return error.CardinalityLimitExceeded;
        }

        // S-017: copy name/help into registry-owned memory so the hashmap
        // key and the metric's strings cannot dangle if the caller frees
        // its buffers. Freed in deinit().
        const name_owned = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        errdefer self.allocator.free(name_owned);
        const help_owned = self.allocator.dupe(u8, help) catch return error.OutOfMemory;
        errdefer self.allocator.free(help_owned);

        const c = self.allocator.create(Counter) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(c);
        c.* = Counter.init(name_owned, help_owned);
        self.counters.put(name_owned, c) catch return error.OutOfMemory;
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
        if (self.options.max_metrics) |cap| {
            if (self.countLocked() >= cap) return error.CardinalityLimitExceeded;
        }

        // S-017: copy name/help into registry-owned memory so the hashmap
        // key and the metric's strings cannot dangle if the caller frees
        // its buffers. Freed in deinit().
        const name_owned = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        errdefer self.allocator.free(name_owned);
        const help_owned = self.allocator.dupe(u8, help) catch return error.OutOfMemory;
        errdefer self.allocator.free(help_owned);

        const g = self.allocator.create(Gauge) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(g);
        g.* = Gauge.init(name_owned, help_owned);
        self.gauges.put(name_owned, g) catch return error.OutOfMemory;
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
        if (self.options.max_metrics) |cap| {
            if (self.countLocked() >= cap) return error.CardinalityLimitExceeded;
        }

        // S-017: copy name/help into registry-owned memory so the hashmap
        // key and the metric's strings cannot dangle if the caller frees
        // its buffers. Freed in deinit().
        const name_owned = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        errdefer self.allocator.free(name_owned);
        const help_owned = self.allocator.dupe(u8, help) catch return error.OutOfMemory;
        errdefer self.allocator.free(help_owned);

        const h = self.allocator.create(Histogram) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(h);
        h.* = try Histogram.init(self.allocator, name_owned, help_owned, buckets);
        errdefer h.deinit();
        self.histograms.put(name_owned, h) catch return error.OutOfMemory;
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
        if (self.options.max_metrics) |cap| {
            if (self.countLocked() >= cap) return error.CardinalityLimitExceeded;
        }

        // S-017: copy name/help into registry-owned memory so the hashmap
        // key and the metric's strings cannot dangle if the caller frees
        // its buffers. Freed in deinit().
        const name_owned = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        errdefer self.allocator.free(name_owned);
        const help_owned = self.allocator.dupe(u8, help) catch return error.OutOfMemory;
        errdefer self.allocator.free(help_owned);

        const t = self.allocator.create(Timer) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(t);
        t.* = try Timer.init(self.allocator, name_owned, help_owned, buckets);
        errdefer t.deinit();
        self.timers.put(name_owned, t) catch return error.OutOfMemory;
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
    /// Errors: `OutOfMemory` from the pre-allocation phase, any error
    /// that `tp.ThreadPool.submitBatch` can return (e.g.
    /// `error.ShutdownInProgress`, `error.QueueFull`, `error.Timeout`,
    /// `error.TaskPoolExhausted`, `error.BuildOptionMismatch`), or
    /// `error.SnapshotIncomplete` when the pool accepted only part of
    /// the capture batch under `.return_error` backpressure (S-018) --
    /// the unsubmitted shards never ran, so the snapshot would contain
    /// uninitialized entries. The error set is inferred from the
    /// implementation so callers see the actual failure rather than a
    /// coerced `OutOfMemory` — a shutting-down pool looks nothing like
    /// an allocator failure and should not be triaged as one.
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

        // Pre-materialize (name-less) slices of metric pointers for
        // histograms and timers so that per-task capture can index in
        // directly without walking the StringHashMap on the worker. This
        // also lets us shard the slice in a follow-up change.
        const hist_entry_list = self.allocator.alloc(HistEntry, hist_count) catch return error.OutOfMemory;
        defer self.allocator.free(hist_entry_list);
        const timer_entry_list = self.allocator.alloc(TimerEntry, timer_count) catch return error.OutOfMemory;
        defer self.allocator.free(timer_entry_list);
        {
            var iter = self.histograms.iterator();
            var i: usize = 0;
            while (iter.next()) |kv| : (i += 1) {
                hist_entry_list[i] = .{ .hist = kv.value_ptr.* };
            }
        }
        {
            var iter = self.timers.iterator();
            var i: usize = 0;
            while (iter.next()) |kv| : (i += 1) {
                timer_entry_list[i] = .{ .timer = kv.value_ptr.* };
            }
        }

        // Task context types for the background captures. Gauges stay
        // single-task (per-gauge work is O(1)). Histograms and timers
        // are sharded into `ceil(count / snapshot_chunk_size)` sub-tasks
        // so large registries spread capture work across many workers
        // rather than starving everyone but one.
        const GaugeCtx = struct {
            gauges: *std.StringHashMap(*Gauge),
            out: []snapshot_mod.MetricSnapshot,
        };
        const HistCtx = struct {
            entries: []const HistEntry,
            out: []snapshot_mod.MetricSnapshot,
            counts: []u64,
            bounds: []f64,
        };
        const TimerCtx = struct {
            entries: []const TimerEntry,
            out: []snapshot_mod.MetricSnapshot,
            counts: []u64,
            bounds: []f64,
        };

        // Treat chunk==0 as "no sharding" (collapse to a single task per
        // type) so a caller that sets snapshot_chunk_size=0 gets safe
        // behavior rather than a division-by-zero.
        const chunk = if (self.options.snapshot_chunk_size == 0) std.math.maxInt(usize) else self.options.snapshot_chunk_size;
        // Preserve the pre-sharding invariant: always emit one task per
        // metric type (gauges, histograms, timers) even when that type
        // is empty. This keeps the submitted-count predictable for
        // instrumentation and lets the existing parallelSnapshot fan-out
        // ordering guarantees hold. Histograms and timers may sub-divide
        // further based on `chunk`.
        const hist_chunks: usize = if (hist_count == 0) 1 else (hist_count + chunk - 1) / chunk;
        const timer_chunks: usize = if (timer_count == 0) 1 else (timer_count + chunk - 1) / chunk;
        const gauge_tasks: usize = 1;
        const total_tasks = gauge_tasks + hist_chunks + timer_chunks;

        // Stack-vs-heap task buffer. MAX_STACK_TASKS = 32 covers the
        // common case (thousands of metrics at chunk_size=64 stay under
        // 32 shards per type). Above that, fall back to a heap buffer.
        const MAX_STACK_TASKS = 32;
        var tasks_stack: [MAX_STACK_TASKS]tp.BatchTask = undefined;
        var hist_ctx_stack: [MAX_STACK_TASKS]HistCtx = undefined;
        var timer_ctx_stack: [MAX_STACK_TASKS]TimerCtx = undefined;

        const tasks: []tp.BatchTask = if (total_tasks <= MAX_STACK_TASKS)
            tasks_stack[0..total_tasks]
        else
            self.allocator.alloc(tp.BatchTask, total_tasks) catch return error.OutOfMemory;
        defer if (total_tasks > MAX_STACK_TASKS) self.allocator.free(tasks);

        const hist_ctxs: []HistCtx = if (hist_chunks <= MAX_STACK_TASKS)
            hist_ctx_stack[0..hist_chunks]
        else
            self.allocator.alloc(HistCtx, hist_chunks) catch return error.OutOfMemory;
        defer if (hist_chunks > MAX_STACK_TASKS) self.allocator.free(hist_ctxs);

        const timer_ctxs: []TimerCtx = if (timer_chunks <= MAX_STACK_TASKS)
            timer_ctx_stack[0..timer_chunks]
        else
            self.allocator.alloc(TimerCtx, timer_chunks) catch return error.OutOfMemory;
        defer if (timer_chunks > MAX_STACK_TASKS) self.allocator.free(timer_ctxs);

        var gauge_ctx = GaugeCtx{ .gauges = &self.gauges, .out = gauge_entries };

        const gauge_run = struct {
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
        }.run;

        const hist_run = struct {
            fn run(ctx: *anyopaque, _: *tp.TaskContext) void {
                const c: *HistCtx = @ptrCast(@alignCast(ctx));
                captureHistSlice(c.entries, c.out, c.counts, c.bounds, .histogram);
            }
        }.run;

        const timer_run = struct {
            fn run(ctx: *anyopaque, _: *tp.TaskContext) void {
                const c: *TimerCtx = @ptrCast(@alignCast(ctx));
                captureTimerSlice(c.entries, c.out, c.counts, c.bounds);
            }
        }.run;

        var task_idx: usize = 0;
        tasks[task_idx] = .{ .task_fn = gauge_run, .ctx = &gauge_ctx };
        task_idx += 1;

        // Build histogram shard contexts. Each shard gets a disjoint
        // slice of hist_entry_list, a disjoint sub-slice of the output
        // MetricSnapshot entries, and a disjoint sub-slice of the
        // counts/bounds storage (sized to the sum of bucket lengths
        // for the histograms in this shard).
        {
            var entry_off: usize = 0;
            var bucket_off: usize = 0;
            var shard: usize = 0;
            while (shard < hist_chunks) : (shard += 1) {
                const shard_end = @min(entry_off + chunk, hist_count);
                const shard_entries = hist_entry_list[entry_off..shard_end];
                // Sum bucket lengths for this shard.
                var shard_buckets: usize = 0;
                for (shard_entries) |e| shard_buckets += e.hist.buckets.len;
                hist_ctxs[shard] = .{
                    .entries = shard_entries,
                    .out = hist_entries[entry_off..shard_end],
                    .counts = hist_bucket_counts[bucket_off .. bucket_off + shard_buckets],
                    .bounds = hist_bucket_bounds[bucket_off .. bucket_off + shard_buckets],
                };
                tasks[task_idx] = .{ .task_fn = hist_run, .ctx = &hist_ctxs[shard] };
                task_idx += 1;
                entry_off = shard_end;
                bucket_off += shard_buckets;
            }
        }

        // Build timer shard contexts (same sharding strategy as hist).
        {
            var entry_off: usize = 0;
            var bucket_off: usize = 0;
            var shard: usize = 0;
            while (shard < timer_chunks) : (shard += 1) {
                const shard_end = @min(entry_off + chunk, timer_count);
                const shard_entries = timer_entry_list[entry_off..shard_end];
                var shard_buckets: usize = 0;
                for (shard_entries) |e| shard_buckets += e.timer.histogram.buckets.len;
                timer_ctxs[shard] = .{
                    .entries = shard_entries,
                    .out = timer_entries[entry_off..shard_end],
                    .counts = timer_bucket_counts[bucket_off .. bucket_off + shard_buckets],
                    .bounds = timer_bucket_bounds[bucket_off .. bucket_off + shard_buckets],
                };
                tasks[task_idx] = .{ .task_fn = timer_run, .ctx = &timer_ctxs[shard] };
                task_idx += 1;
                entry_off = shard_end;
                bucket_off += shard_buckets;
            }
        }

        // Fan-out gauges, histogram-shards, timer-shards to the thread
        // pool. `wg` ensures the worker captures complete before we
        // return the snapshot.
        var wg = pool.waitGroup();
        // Propagate the real thread-pool error (ShutdownInProgress,
        // QueueFull, etc.) instead of masking it as OutOfMemory. See the
        // parallelSnapshot doc comment for the full inferred error set.
        //
        // S-018: if submitBatch fails partway, tasks submitted before the
        // failure are already running and writing into our buffers -- we
        // must drain them before errdefer frees that memory.
        const submit_result = pool.submitBatch(tasks, .{ .wait_group = &wg }) catch |err| {
            wg.wait();
            return err;
        };

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

        // S-018: under .return_error backpressure or pool shutdown mid-batch
        // submitBatch can accept only part of the batch without raising an
        // error. Unsubmitted shards never ran, so their output slots are
        // uninitialized — returning them would hand the caller wild
        // name/help pointers.
        if (submit_result.submitted != total_tasks) return error.SnapshotIncomplete;

        return .{
            .entries = entries,
            .bucket_count_storage = bucket_count_storage,
            .bucket_bound_storage = bucket_bound_storage,
            .allocator = self.allocator,
            .timestamp_ns = compat.nanoTimestampWall(),
        };
    }

    /// Lightweight view into a registered histogram. Materialised once
    /// up-front in `parallelSnapshot` so worker tasks can operate on a
    /// flat slice rather than traversing the StringHashMap.
    const HistEntry = struct { hist: *Histogram };

    /// Lightweight view into a registered timer. See `HistEntry`.
    const TimerEntry = struct { timer: *Timer };

    fn captureHistSlice(
        entries: []const HistEntry,
        out: []snapshot_mod.MetricSnapshot,
        counts: []u64,
        bounds: []f64,
        kind: snapshot_mod.MetricKind,
    ) void {
        var offset: usize = 0;
        for (entries, 0..) |e, idx| {
            const h = e.hist;
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
            offset += blen;
        }
    }

    fn captureTimerSlice(
        entries: []const TimerEntry,
        out: []snapshot_mod.MetricSnapshot,
        counts: []u64,
        bounds: []f64,
    ) void {
        var offset: usize = 0;
        for (entries, 0..) |e, idx| {
            const t = e.timer;
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
            offset += blen;
        }
    }

    /// Total metric count. Caller must hold the lock.
    fn countLocked(self: *const Registry) usize {
        return self.counters.count() + self.gauges.count() +
            self.histograms.count() + self.timers.count();
    }

    /// Return the total number of registered metrics across all types.
    pub fn metricCount(self: *Registry) usize {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();
        return self.countLocked();
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

test "Registry: max_metrics cap rejects registration beyond limit (S-019)" {
    var reg = Registry.initWithOptions(std.testing.allocator, .{ .max_metrics = 3 });
    defer reg.deinit();

    _ = try reg.counter("c1", "help");
    _ = try reg.counter("c2", "help");
    _ = try reg.gauge("g1", "help");
    try std.testing.expectError(error.CardinalityLimitExceeded, reg.counter("c4", "help"));
    const buckets = [_]f64{1.0};
    try std.testing.expectError(error.CardinalityLimitExceeded, reg.histogram("h1", "help", &buckets));
    try std.testing.expectEqual(@as(usize, 3), reg.metricCount());
}

test "Registry: default has no cardinality cap" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    _ = try reg.counter("c1", "help");
    _ = try reg.counter("c2", "help");
    try std.testing.expectEqual(@as(usize, 2), reg.metricCount());
}
