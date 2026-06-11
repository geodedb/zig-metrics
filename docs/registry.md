# Registry

The `Registry` is the central object in the metrics library. It owns all
registered metrics, enforces name uniqueness across types, and provides
thread-safe snapshot capture.

## Lifecycle

```zig
const metrics = @import("metrics");
const std = @import("std");

// --- Create ---
var reg = metrics.Registry.init(allocator);
// or with tuning options:
var reg = metrics.Registry.initWithOptions(allocator, .{
    .max_metrics       = 1000,  // optional cardinality cap
    .snapshot_chunk_size = 64,  // parallel-snapshot shard size
});
defer reg.deinit();

// --- Register (once, at startup) ---
const requests = try reg.counter("http_requests_total", "Total HTTP requests");
const conns    = try reg.gauge("active_connections", "Active connections");

const latency_buckets = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.5, 1.0 };
const latency = try reg.histogram("request_latency_seconds", "Latency", &latency_buckets);

const dur_buckets = [_]f64{ 0.001, 0.01, 0.1, 1.0 };
const dur = try reg.timer("handler_duration_seconds", "Handler duration", &dur_buckets);

// --- Use (hot path, lock-free) ---
requests.inc();
requests.add(5);
conns.set(42);
latency.observe(0.03);
dur.recordSeconds(0.007);

// --- Snapshot ---
var snap = try reg.snapshot();
defer snap.deinit();

// --- Destroy ---
// reg.deinit() frees all owned metrics; called via defer above.
```

> **Recommended pattern:** cache metric pointers at startup and call them
> directly on the hot path. Avoid per-request lookups via `getCounter` /
> `getGauge` / `getHistogram` / `getTimer` — each takes a shared lock.

## Ownership

| Resource | Who owns it | When freed |
|---|---|---|
| `name` / `help` strings | Registry copies them at registration | `deinit()` |
| Bucket boundaries (`buckets` slice) | **Caller** — Registry borrows | Must outlive the Registry |
| Metric pointers (`*Counter`, etc.) | Registry | `deinit()` |
| `Snapshot` entries (`name`/`help`) | Point at registry-owned strings | Snapshot must not outlive the Registry |

The Registry duplicates `name` and `help` into its own allocator at
registration time (S-017). You may free your string buffers immediately
after the call returns.

Histogram and timer `buckets` slices are **not** copied — the Registry
stores the pointer you pass. Keep the slice alive until `deinit()` is
called. Using a comptime-constant array literal (e.g. `const buckets =
[_]f64{...}`) is the simplest way to satisfy this requirement.

Returned metric pointers remain valid until `deinit()`. Using a pointer
after `deinit()` is undefined behaviour.

## Thread Safety

Registration, lookup, and snapshot all acquire an internal reader-writer
lock (backed by `std.Io.RwLock`). Multiple goroutine-style readers can
run concurrently — `snapshot()`, `getCounter()`, and similar calls share
the lock and never serialize against each other (P-014).

Metric value updates (`counter.inc()`, `gauge.set()`, `histogram.observe()`,
etc.) are lock-free atomic operations and never touch the registry lock.
Snapshots are therefore **eventually consistent**: the count and sum for a
histogram may reflect different numbers of observations at snapshot time.
This is expected and acceptable for monitoring workloads.

## RegistryOptions

```zig
pub const RegistryOptions = struct {
    snapshot_chunk_size: usize = 64,
    max_metrics: ?usize = null,
};
```

### `snapshot_chunk_size`

Controls sharding in `parallelSnapshot`. Histograms and timers are divided
into `ceil(count / snapshot_chunk_size)` sub-tasks and distributed across
the thread pool. The default of 64 is a good starting point; lower values
create finer-grained tasks at the cost of more per-task overhead.

### `max_metrics`

An optional hard cap on the total number of registered metrics across all
types. When the cap is reached, subsequent registration calls return
`error.CardinalityLimitExceeded`.

By default there is no cap (`null`). Setting a cap is recommended in any
context where metric names are generated from configuration or other
developer-controlled (but potentially unbounded) input — it converts an
accidental cardinality explosion into a clean error rather than unbounded
memory growth (CWE-770).

```zig
var reg = metrics.Registry.initWithOptions(allocator, .{ .max_metrics = 500 });
// The 501st registration returns error.CardinalityLimitExceeded.
```

## Snapshot

`Registry.snapshot()` captures a consistent point-in-time view under a
shared lock:

```zig
var snap = try reg.snapshot();
defer snap.deinit();

if (snap.get("http_requests_total")) |entry| {
    std.debug.print("requests: {d}\n", .{entry.counter_value});
}
```

`Snapshot.name` and `Snapshot.help` slices point into registry-owned
memory. The snapshot **must not outlive the Registry** it was captured from.

## parallelSnapshot

For large registries, `parallelSnapshot` fans histogram and timer capture
out across a thread pool:

```zig
var pool = try tp.ThreadPool.init(allocator, .{});
defer pool.deinit();

var snap = reg.parallelSnapshot(&pool) catch |err| switch (err) {
    error.SnapshotIncomplete => blk: {
        // Pool saturated or shutting down; fall back to serial capture.
        break :blk try reg.snapshot();
    },
    else => return err,
};
defer snap.deinit();
```

`parallelSnapshot` requires an initialised `thread_pool.ThreadPool` (the
`thread_pool` module is re-exported as `metrics.thread_pool`).

### Errors

| Error | Meaning |
|---|---|
| `OutOfMemory` | Allocation failed in the pre-allocation phase |
| `error.SnapshotIncomplete` | Pool accepted only part of the batch (S-018) — unsubmitted shards never ran; their output slots would be uninitialized |
| Thread-pool errors | `ShutdownInProgress`, `QueueFull`, `Timeout`, `TaskPoolExhausted`, `BuildOptionMismatch` from `tp.ThreadPool.submitBatch` |

When `error.SnapshotIncomplete` is returned the partially submitted shards
have already completed (the implementation drains the wait group before
returning). Callers should fall back to `reg.snapshot()` or retry with a
less-loaded pool.

## Error Reference

```zig
pub const RegistryError = error{
    AlreadyRegistered,       // name is already used by any metric type
    OutOfMemory,
    InvalidMetricName,       // must match [a-zA-Z_:][a-zA-Z0-9_:]*
    InvalidHelpText,         // contains \n, \r, or backslash
    CardinalityLimitExceeded,// max_metrics cap reached (S-019)
} || Histogram.BucketError; // EmptyBuckets, UnsortedBuckets, NonFiniteBucket
```

Metric names are validated against the Prometheus name charset
(`[a-zA-Z_:][a-zA-Z0-9_:]*`) and help text is validated to exclude
characters that require escaping in the Prometheus exposition format.
These checks guarantee that `writePrometheus` output is always
well-formed without requiring any escaping at export time.
