# Gap Closure Implementation Plan (2026-06-11 audit)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every actionable gap from the 2026-06-11 audit (GAP-005..009, Q-018..029, P-011..014, S-017..023) with real code, tests, and docs.

**Architecture:** A Zig 0.16 metrics library (counters/gauges/histograms/timers, instance-based registry, Prometheus text exporter, parallel snapshot via the `thread_pool` dep). Fixes land in dependency order: bench compile fix → registry security fixes (S-018→S-017→S-019→Q-024) → clock/compat extraction → exporter precision → version single-sourcing → bench validity → lock upgrade → tests → README/docs/CI.

**Tech Stack:** Zig 0.16.0, GitLab CI, pre-commit, Python 3 (one script).

**Canonical commands:**

- Build check: `zig build check`
- Unit tests: `zig build test --summary all` (baseline: 66 pass / 1 skip)
- Integration: `zig build test-integration --summary all` (baseline: 9 pass)
- Format: `zig fmt src/ tests/ benchmarks/ build.zig examples/`
- All hooks: `pre-commit run --all-files`

**Commit convention:** conventional commits, enforced by commitizen hook. End every commit message body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Rule for every task:** after the code change, run `zig fmt src/ tests/ benchmarks/ build.zig examples/`, then `zig build check && zig build test --summary all && zig build test-integration --summary all`. All must pass before commit.

---

## Task 1: GAP-005 — Fix benchmark compile failure on Zig 0.16 (`std.process.args` removed)

**Files:**

- Modify: `benchmarks/scale_bench.zig:104-128`
- Modify: `benchmarks/compare.zig` (`pub fn main` around line 80-111)
- Modify: `build.zig` (add `bench-check` step after the `compare-bench` block, ~line 201)
- Modify: `.gitlab-ci.yml` (add `bench-check` job in `build` stage)

- [ ] **Step 1: Verify the failure (red)**

Run: `zig build scale-bench 2>&1 | head -5` and `zig build compare-bench 2>&1 | head -5`
Expected: both FAIL with `error: root source file struct 'process' has no member named 'args'`

- [ ] **Step 2: Fix scale_bench.zig entry point**

Zig 0.16 passes args via `std.process.Init`. The vendored dep shows the pattern (`zig-pkg/thread_pool-0.2.5-*/benchmarks/compare.zig:4-9`). Change `benchmarks/scale_bench.zig`:

```zig
// OLD (line 104):
pub fn main() !void {
// NEW:
pub fn main(init: std.process.Init) !void {
```

And replace the arg-parsing block (lines 117-128):

```zig
    // OLD:
    // var filter_buf: [16][]const u8 = undefined;
    // var filter_count: usize = 0;
    // var args = std.process.args();
    // _ = args.next(); // skip program name
    // while (args.next()) |arg| { ... }
    // const filters = filter_buf[0..filter_count];

    // NEW:
    // Parse optional tier filter from CLI args (Zig 0.16: args come from
    // std.process.Init instead of the removed std.process.args()).
    const argv = try init.minimal.args.toSlice(allocator);
    defer allocator.free(argv);
    const filters = if (argv.len > 1) argv[1..] else argv[0..0];
```

Note: `argv` slices point into process memory; only the outer slice is allocated. If `toSlice` returns `[][:0]const u8`, the existing `std.mem.eql(u8, f, tier.name)` comparisons still work via coercion; if the compiler complains, change the filter loop variable type accordingly.

- [ ] **Step 3: Fix compare.zig entry point**

```zig
// OLD:
pub fn main() !void {
// NEW:
pub fn main(init: std.process.Init) !void {
```

Replace the arg parsing (lines ~94-111):

```zig
    // OLD:
    // var args = std.process.args();
    // _ = args.next(); // skip program name
    // const baseline_path = args.next() orelse { ... };
    // const current_path = args.next() orelse { ... };
    // const threshold: f64 = if (args.next()) |t| ... ;

    // NEW:
    const argv = try init.minimal.args.toSlice(allocator);
    defer allocator.free(argv);

    if (argv.len < 3) {
        try stdout.print("Usage: compare <baseline.json> <current.json> [threshold%]\n", .{});
        try stdout.flush();
        std.process.exit(2);
    }
    const baseline_path = argv[1];
    const current_path = argv[2];
    const threshold: f64 = if (argv.len > 3)
        std.fmt.parseFloat(f64, argv[3]) catch DEFAULT_THRESHOLD
    else
        DEFAULT_THRESHOLD;
```

If `std.process.exit` also errors on 0.16, replace each `std.process.exit(2)` with `return error.Usage;` (declare nothing — inferred error set) — but verify first; only change what fails to compile.

- [ ] **Step 4: Verify benches compile and run**

Run: `zig build scale-bench -- light 2>&1 | tail -5` (light tier only, fast) and `zig build compare-bench 2>&1 | head -3`
Expected: scale-bench runs the light tier and prints JSON; compare-bench prints `Usage: compare <baseline.json> <current.json> [threshold%]` and exits 2 (the run step may report failure exit code — compilation success is what matters; `zig build compare-bench --help` alternative: just confirm no compile error).

- [ ] **Step 5: Add a compile-only `bench-check` step to build.zig**

Insert after the `compare-bench` block (~line 201):

```zig
    // Compile-only gate for all benchmark executables. CI runs this so
    // benchmark bit-rot (e.g. stdlib API removals) is caught at merge
    // time without paying the cost of running the benchmarks (GAP-005).
    const bench_check_step = b.step("bench-check", "Compile all benchmarks without running");
    bench_check_step.dependOn(&bench_exe.step);
    bench_check_step.dependOn(&scale_bench_exe.step);
    bench_check_step.dependOn(&compare_bench_exe.step);
```

- [ ] **Step 6: Add CI job**

In `.gitlab-ci.yml`, after the `build:` job:

```yaml
# Compile-only benchmark gate (GAP-005): catches stdlib API drift in
# benchmark sources without running them.
bench-check:
  stage: build
  image: debian:bookworm-slim
  before_script:
    - *install-zig
  script:
    - zig build bench-check
```

- [ ] **Step 7: Run full validation**

Run: `zig fmt src/ tests/ benchmarks/ build.zig examples/ && zig build check && zig build test --summary all && zig build test-integration --summary all && zig build bench-check`
Expected: all PASS (66/67 unit + 9/9 integration unchanged).

- [ ] **Step 8: Commit**

```bash
git add benchmarks/scale_bench.zig benchmarks/compare.zig build.zig .gitlab-ci.yml
git commit -m "fix: close GAP-005 - benchmarks compile on Zig 0.16 via std.process.Init

std.process.args() was removed in Zig 0.16. Port scale_bench and
compare to the Init-based args API and add a compile-only bench-check
build step + CI job so benchmark bit-rot fails the pipeline.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: S-018 — `parallelSnapshot` must not return uninitialized entries on partial batch submission

**Files:**

- Modify: `src/registry.zig:558-589` (`parallelSnapshot` submit/wait tail)
- Test: `tests/integration.zig` (new test at end)

Background: `pool.submitBatch` returns `SubmitBatchResult{ .submitted: usize }` (see `zig-pkg/thread_pool-0.2.5-*/src/pool.zig:942-944`). Under the default `.return_error` backpressure it can return `submitted < tasks.len` WITHOUT an error. Unsubmitted shards never write their `entries` slots (allocated `undefined` at `registry.zig:363`), so the returned Snapshot contains wild pointers. Also: on an error return from `submitBatch`, earlier tasks in the batch may already be running — we must `wg.wait()` before letting `errdefer` free the buffers they write into.

- [ ] **Step 1: Write the failing/regression test**

Append to `tests/integration.zig`:

```zig
test "thread_pool: parallelSnapshot never returns garbage entries under pool saturation (S-018)" {
    // Tiny descriptor pool + many single-metric shards makes partial
    // batch submission likely. With the fix, every iteration either
    // succeeds with fully-initialized entries or fails cleanly with
    // error.SnapshotIncomplete / a pool error -- never garbage.
    var pool = try tp.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 1,
        .queue_capacity = 4,
    });
    defer pool.deinit();

    var reg = metrics.Registry.initWithOptions(std.testing.allocator, .{
        .snapshot_chunk_size = 1,
    });
    defer reg.deinit();

    const buckets = [_]f64{ 0.5, 1.0 };
    inline for (0..32) |i| {
        const name = std.fmt.comptimePrint("sat_h_{d}", .{i});
        const h = try reg.histogram(name, "help", &buckets);
        h.observe(0.25);
    }

    var successes: usize = 0;
    for (0..50) |_| {
        var snap = reg.parallelSnapshot(&pool) catch |err| switch (err) {
            error.SnapshotIncomplete => continue, // clean partial-submit rejection
            else => continue, // pool backpressure errors are acceptable
        };
        defer snap.deinit();
        successes += 1;
        // Every entry must be fully initialized and readable.
        try std.testing.expectEqual(@as(usize, 32), snap.len());
        for (snap.entries) |*entry| {
            try std.testing.expect(entry.name.len >= 7); // "sat_h_N"
            try std.testing.expect(std.mem.startsWith(u8, entry.name, "sat_h_"));
            try std.testing.expectEqual(@as(u64, 1), entry.hist_count);
        }
    }
    // The pool drains fast, so most iterations should succeed.
    try std.testing.expect(successes > 0);
}
```

Note: if `tp.ThreadPool.init` rejects `.queue_capacity = 4` (it must be >= some minimum or power-of-two — see `zig-pkg/thread_pool-0.2.5-*/src/types.zig:232-244`), use the smallest accepted value. If `error.SnapshotIncomplete` does not exist yet, the test fails to compile — that is the red state.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-integration --summary all`
Expected: FAIL — `error.SnapshotIncomplete` not a member of the error set (compile error), proving the guard doesn't exist.

- [ ] **Step 3: Implement the fix**

In `src/registry.zig`, replace the submit/wait tail (current lines 558-580):

```zig
        // Fan-out gauges, histogram-shards, timer-shards to the thread
        // pool. `wg` ensures the worker captures complete before we
        // return the snapshot.
        var wg = pool.waitGroup();
        // Propagate the real thread-pool error (ShutdownInProgress,
        // QueueFull, etc.) instead of masking it as OutOfMemory.
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

        // S-018: under .return_error backpressure submitBatch can accept
        // only part of the batch without raising an error. Unsubmitted
        // shards never ran, so their output slots are uninitialized --
        // returning them would hand the caller wild name/help pointers.
        if (submit_result.submitted != total_tasks) return error.SnapshotIncomplete;
```

(The existing counter-capture block and `wg.wait()` move as shown; the final `return .{ ... }` stays unchanged after the check. The `errdefer`s at lines 364-368 then free everything on the incomplete path.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all && zig build test-integration --summary all`
Expected: PASS (10/10 integration including the new test).

- [ ] **Step 5: Commit**

```bash
git add src/registry.zig tests/integration.zig
git commit -m "fix: close S-018 - reject partial batch submission in parallelSnapshot

submitBatch can accept only part of a batch without error under
.return_error backpressure; unsubmitted shards left Snapshot entries
uninitialized (wild name/help pointers, CWE-908). Drain the wait group
before propagating submit errors and return error.SnapshotIncomplete
when submitted != total_tasks.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: S-017 — Registry must own (dupe) `name`/`help` strings

**Files:**

- Modify: `src/registry.zig:110-139` (`deinit`), `175-279` (all four register fns), doc comments at 4-8
- Test: `tests/integration.zig` (new test)

- [ ] **Step 1: Write the failing test**

Append to `tests/integration.zig`:

```zig
test "registry owns name/help copies; caller may free originals (S-017)" {
    const allocator = std.testing.allocator;
    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();

    // Heap-allocate name/help, register, then free the originals.
    const name = try std.fmt.allocPrint(allocator, "heap_{s}_total", .{"requests"});
    const help = try std.fmt.allocPrint(allocator, "help text {d}", .{42});
    const c = try reg.counter(name, help);
    c.add(7);
    allocator.free(name);
    allocator.free(help);

    // Lookup by a fresh equal-content key must still work, and the
    // stored name/help must read back correctly (no dangling slices).
    const found = reg.getCounter("heap_requests_total") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 7), found.get());
    try std.testing.expectEqualStrings("heap_requests_total", found.name);
    try std.testing.expectEqualStrings("help text 42", found.help);

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try metrics.writePrometheus(&reg, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "heap_requests_total 7\n") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-integration --summary all`
Expected: FAIL — `std.testing.allocator` is a DebugAllocator that poisons freed memory (0xAA), so the lookup/string compare reads poisoned bytes and the assertions fail (or the allocator traps the invalid read).

- [ ] **Step 3: Implement duping in all four register fns**

Pattern for `counter` (apply the same shape to `gauge`, `histogram`, `timer` — errdefer fires on every `error` return including `catch return error.X`):

```zig
    pub fn counter(self: *Registry, name: []const u8, help: []const u8) RegistryError!*Counter {
        try validateName(name);
        try validateHelp(help);

        self.rwlock.lock();
        defer self.rwlock.unlock();

        if (self.nameInUse(name)) return error.AlreadyRegistered;

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
```

For `histogram` and `timer`, keep the existing `Histogram.init`/`Timer.init` error-mapping switch for now (Task 5 removes it) but pass `name_owned`/`help_owned` and add the same errdefers; on the init-error path the errdefers free the duped strings automatically.

- [ ] **Step 4: Free owned strings in `deinit`**

Replace the four loops in `deinit` (the key IS the owned name, and `c.help` is the owned help):

```zig
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
            self.allocator.free(kv.key_ptr.*);
        }
        self.gauges.deinit();

        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |kv| {
            const h = kv.value_ptr.*;
            self.allocator.free(h.help);
            h.deinit();
            self.allocator.destroy(h);
            self.allocator.free(kv.key_ptr.*);
        }
        self.histograms.deinit();

        var timer_iter = self.timers.iterator();
        while (timer_iter.next()) |kv| {
            const t = kv.value_ptr.*;
            self.allocator.free(t.histogram.help);
            t.deinit();
            self.allocator.destroy(t);
            self.allocator.free(kv.key_ptr.*);
        }
        self.timers.deinit();
    }
```

- [ ] **Step 5: Update doc comments**

In `src/registry.zig:4-8` module doc, append: `//! The Registry copies metric name/help strings into its own allocator at registration; callers may free their buffers immediately after registering (S-017). Histogram/timer bucket slices are still borrowed and must outlive the Registry.`

- [ ] **Step 6: Run tests (leak check is built into std.testing.allocator)**

Run: `zig build test --summary all && zig build test-integration --summary all`
Expected: PASS, no leaks reported.

- [ ] **Step 7: Commit**

```bash
git add src/registry.zig tests/integration.zig
git commit -m "fix: close S-017 - registry dupes name/help; no dangling caller slices

Registration previously stored caller slices by reference and used the
caller's name buffer as the hashmap key (CWE-416 if freed). Dupe both
into the registry allocator, free them in deinit, and document the
ownership contract.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: S-019 — Optional cardinality cap (`max_metrics`)

**Files:**

- Modify: `src/registry.zig` (`RegistryError`, `RegistryOptions`, all four register fns)
- Test: `src/registry.zig` (new unit tests at end)

- [ ] **Step 1: Write the failing tests**

Append to `src/registry.zig` tests:

```zig
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
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test --summary all`
Expected: FAIL — `RegistryOptions` has no field `max_metrics` (compile error).

- [ ] **Step 3: Implement**

Add to `RegistryError` (after `NonFiniteBucket`):

```zig
    /// The registry's max_metrics cardinality cap has been reached (S-019).
    CardinalityLimitExceeded,
```

Add to `RegistryOptions`:

```zig
    /// Optional hard cap on the total number of registered metrics across
    /// all types. Null (default) means unlimited. Metric names must always
    /// be low-cardinality and developer-controlled -- never derived from
    /// untrusted input -- but a cap converts an accidental cardinality
    /// explosion (CWE-770 memory-exhaustion DoS) into a clean error.
    max_metrics: ?usize = null,
```

Add a private helper to `Registry` (callers hold the lock):

```zig
    /// Total metric count. Caller must hold the lock.
    fn countLocked(self: *const Registry) usize {
        return self.counters.count() + self.gauges.count() +
            self.histograms.count() + self.timers.count();
    }
```

In each of the four register fns, immediately after `if (self.nameInUse(name)) return error.AlreadyRegistered;`:

```zig
        if (self.options.max_metrics) |cap| {
            if (self.countLocked() >= cap) return error.CardinalityLimitExceeded;
        }
```

Optionally simplify `metricCount` to `lockShared` + `return self.countLocked();`.

- [ ] **Step 4: Run tests**

Run: `zig build test --summary all && zig build test-integration --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/registry.zig
git commit -m "feat: close S-019 - optional max_metrics cardinality cap

Adds RegistryOptions.max_metrics (default null = unlimited) returning
error.CardinalityLimitExceeded before any allocation, converting
cardinality explosions into clean errors instead of OOM (CWE-770).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Q-024 — Compose `RegistryError` from `Histogram.BucketError`

**Files:**

- Modify: `src/registry.zig:50-66` (error set), `~216-280` (histogram/timer register fns)

- [ ] **Step 1: Replace the error set**

```zig
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
```

(Delete the hand-written `EmptyBuckets`/`UnsortedBuckets`/`NonFiniteBucket` members — they now come from the composition. `error.EmptyBuckets` etc. remain the same error values, so callers and tests are unaffected.)

- [ ] **Step 2: Remove the two identity-mapping switches**

In `histogram()` and `timer()`, the `Histogram.init`/`Timer.init` call site becomes (histogram shown; timer identical with `Timer.init` and `t`):

```zig
        const h = self.allocator.create(Histogram) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(h);
        h.* = Histogram.init(self.allocator, name_owned, help_owned, buckets) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |bucket_err| return bucket_err,
        };
        self.histograms.put(name_owned, h) catch return error.OutOfMemory;
```

If the compiler accepts a plain `catch |err| return err;` (the init error set `BucketError || error{OutOfMemory}` is a subset of `RegistryError`), prefer that one-liner.

- [ ] **Step 3: Run tests**

Run: `zig build check && zig build test --summary all && zig build test-integration --summary all`
Expected: PASS — existing bucket-error tests (`error.EmptyBuckets` etc.) unchanged.

- [ ] **Step 4: Commit**

```bash
git add src/registry.zig
git commit -m "refactor: close Q-024 - compose RegistryError from Histogram.BucketError

Removes the hand-duplicated bucket error variants and the two identity
switch blocks; the error sets can no longer drift.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: P-011 + Q-023 — Monotonic timer clock + shared `src/compat.zig`

**Files:**

- Create: `src/compat.zig`
- Modify: `src/timer.zig:13-17,52,85`, `src/registry.zig:37-41,587`, `src/snapshot.zig:11-15,~164`
- Modify: `src/root.zig` (re-export), `benchmarks/variance.zig:~22`, `benchmarks/scale_bench.zig:~26`
- Test: `src/timer.zig` (new test)

- [ ] **Step 1: Write the failing test**

Append to `src/timer.zig`:

```zig
test "Timer: uses monotonic clock for durations (P-011)" {
    // Monotonic timestamps can never go backward; two consecutive reads
    // must be non-decreasing. This also pins the compat helper choice:
    // Timer must use the monotonic (.awake) clock, not wall (.real).
    const a = @import("compat.zig").nanoTimestampMonotonic();
    const b = @import("compat.zig").nanoTimestampMonotonic();
    try std.testing.expect(b >= a);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test --summary all`
Expected: FAIL — `compat.zig` does not exist (compile error).

- [ ] **Step 3: Create `src/compat.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Zig 0.16 compatibility shims shared across the library (Q-023).
//!
//! std.time.nanoTimestamp() was removed in 0.16; the Io clock API
//! replaces it. Two variants are exposed because they answer different
//! questions (P-011):
//! - wall (.real / CLOCK_REALTIME): "what time is it" -- snapshot
//!   timestamps. Settable, NTP-stepped; never use for durations.
//! - monotonic (.awake / CLOCK_MONOTONIC): "how much time elapsed" --
//!   timer duration measurement. Immune to clock steps.

const std = @import("std");

/// Wall-clock timestamp in nanoseconds (CLOCK_REALTIME).
/// Use for point-in-time labels (e.g. Snapshot.timestamp_ns).
pub fn nanoTimestampWall() i96 {
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io_inst, .real).raw.toNanoseconds();
}

/// Monotonic timestamp in nanoseconds (CLOCK_MONOTONIC).
/// Use for measuring elapsed durations (Timer).
pub fn nanoTimestampMonotonic() i96 {
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io_inst, .awake).raw.toNanoseconds();
}

test "wall and monotonic clocks both advance" {
    const w = nanoTimestampWall();
    const m = nanoTimestampMonotonic();
    try std.testing.expect(w > 0);
    try std.testing.expect(m > 0);
}
```

Note: verify `.awake` is the monotonic clock variant in `std.Io.Clock` (it is used for sleep in `src/timer.zig:136`); if the enum differs (e.g. `.monotonic`), use the actual member — check `grep -n "pub const Clock" -A 30 /home/benji/.local/share/mise/installs/zig/0.16.0/lib/std/Io.zig`.

- [ ] **Step 4: Replace the five inline copies**

- `src/timer.zig`: delete `nanoTimestampCompat` (lines 13-17); add `const compat = @import("compat.zig");`; in `start()` use `.start_ns = compat.nanoTimestampMonotonic()`, in `Sample.finish()` use `const end_ns = compat.nanoTimestampMonotonic();`. Update the `finish` doc comment: clock-backward clamping note stays (defensive), but note durations are now monotonic.
- `src/registry.zig`: delete `nanoTimestampCompat` (lines 37-41); add `const compat = @import("compat.zig");`; at the `parallelSnapshot` return use `.timestamp_ns = compat.nanoTimestampWall()`.
- `src/snapshot.zig`: delete `nanoTimestampCompat` (lines 11-15); add `const compat = @import("compat.zig");`; replace its use (search `nanoTimestampCompat()` — it sets `timestamp_ns` in `captureSnapshot`) with `compat.nanoTimestampWall()`.
- `src/root.zig`: add after the `prometheus` export:

```zig
/// Zig 0.16 timestamp compatibility helpers (wall + monotonic clocks).
pub const compat = @import("compat.zig");
```

- `benchmarks/variance.zig` and `benchmarks/scale_bench.zig`: delete the local `nanoTimestampCompat` definitions and replace call sites with `metrics.compat.nanoTimestampWall()` (benchmark elapsed measurement wants... actually elapsed: use `metrics.compat.nanoTimestampMonotonic()` for elapsed-time measurement in benches — bench timing is a duration). Check each call site: timing loops → Monotonic; generated-at timestamps → Wall.

- [ ] **Step 5: Verify no inline copies remain**

Run: `grep -rn "fn nanoTimestampCompat" src/ benchmarks/`
Expected: no matches.

- [ ] **Step 6: Run full validation**

Run: `zig fmt src/ benchmarks/ && zig build check && zig build test --summary all && zig build test-integration --summary all && zig build bench-check`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/compat.zig src/timer.zig src/registry.zig src/snapshot.zig src/root.zig benchmarks/variance.zig benchmarks/scale_bench.zig
git commit -m "fix: close P-011/Q-023 - monotonic timer clock via shared compat module

Timer measured durations with CLOCK_REALTIME, so NTP steps corrupted
recorded latencies. Extract the five duplicated nanoTimestampCompat
copies into src/compat.zig with explicit wall vs monotonic variants;
Timer now uses the monotonic clock (zero perf cost, same vDSO path).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: S-020 — Shortest-round-trip float format for `le` and `_sum`

**Files:**

- Modify: `src/prometheus.zig:61,65` and existing test at 117-139
- Test: `src/prometheus.zig` (new test)

- [ ] **Step 1: Write the failing test**

Append to `src/prometheus.zig`:

```zig
test "Prometheus: sub-microsecond bucket bounds stay distinct in le labels (S-020)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const buckets = [_]f64{ 1e-7, 2e-7, 1.0 };
    const h = try reg.histogram("tiny_seconds", "Tiny", &buckets);
    h.observe(1.5e-7); // second bucket

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePrometheus(&reg, &writer);

    const output = writer.buffered();
    // With {d:.6} both bounds collapsed to le="0.000000". Shortest
    // round-trip must keep them textually distinct.
    const first = std.mem.indexOf(u8, output, "tiny_seconds_bucket{le=\"") orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOfPos(u8, output, first + 1, "tiny_seconds_bucket{le=\"") orelse return error.TestUnexpectedResult;
    const first_end = std.mem.indexOfPos(u8, output, first, "\"}") orelse return error.TestUnexpectedResult;
    const second_end = std.mem.indexOfPos(u8, output, second, "\"}") orelse return error.TestUnexpectedResult;
    const label_a = output[first + 24 .. first_end];
    const label_b = output[second + 24 .. second_end];
    try std.testing.expect(!std.mem.eql(u8, label_a, label_b));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test --summary all`
Expected: FAIL on the distinctness assertion (both labels render `0.000000`).

- [ ] **Step 3: Fix the format strings**

In `writeHistogram`, change `{d:.6}` to `{d}` (Zig's `{d}` float formatting emits shortest round-trip decimal):

```zig
        try writer.print("{s}_bucket{{le=\"{d}\"}} {d}\n", .{ entry.name, bucket, cumulative });
```

and

```zig
    try writer.print("{s}_sum {d}\n", .{ entry.name, entry.hist_sum });
```

- [ ] **Step 4: Update the existing fixed-precision assertions**

In `test "Prometheus: histogram per-bucket cumulative output"` (lines 133-136), the expected labels change from `0.100000` → `0.1`, `0.500000` → `0.5`, `1.000000` → `1`:

```zig
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_seconds_bucket{le=\"0.1\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_seconds_bucket{le=\"0.5\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_seconds_bucket{le=\"1\"} 2\n") != null);
```

Run the test first and paste the ACTUAL rendered labels (e.g. `1` vs `1.0` — Zig may render `1` for 1.0 with `{d}`; whatever the real output is, assert that). Grep the whole repo for other `0.000000`-style assertions: `grep -rn '\.000000\|le=\\"' src/ tests/` and fix all.

- [ ] **Step 5: Run tests**

Run: `zig build test --summary all && zig build test-integration --summary all`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/prometheus.zig tests/
git commit -m "fix: close S-020 - shortest round-trip floats for le labels and _sum

Fixed {d:.6} precision collapsed distinct sub-microsecond bucket bounds
into identical le labels, producing malformed exposition output
(CWE-682). {d} renders shortest round-trip decimals so distinct bounds
always render distinctly.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 8: Q-020 — Single-source the version constant from build.zig.zon

**Files:**

- Modify: `build.zig:28-30`, `src/root.zig:35-36`, `tests/integration.zig:120-126`, `build.zig` integration-test module imports (~line 140-150)

- [ ] **Step 1: Wire version into build_options**

In `build.zig`, after `const build_options = b.addOptions();` (line 28):

```zig
    // Q-020: single-source the library version from build.zig.zon so
    // code and manifest cannot drift. ZON imports are typed; declare
    // only the fields we read.
    const manifest: struct {
        name: enum { metrics },
        version: []const u8,
        fingerprint: u64,
        minimum_zig_version: []const u8,
        dependencies: struct {
            thread_pool: struct { url: []const u8, hash: []const u8 },
        },
        paths: []const []const u8,
    } = @import("build.zig.zon");
    build_options.addOption([]const u8, "version", manifest.version);
```

If `@import("build.zig.zon")` fails to compile on 0.16 (e.g. enum-literal name field mismatch), adjust the struct to the actual manifest shape (`.name = .metrics` → `enum { metrics }` is correct for 0.16 zon). As a last resort define `const version = "0.1.3";` in build.zig with a comment `// keep in sync with build.zig.zon (checked by integration test)` — but try the import first.

- [ ] **Step 2: Read it in root.zig**

Replace `src/root.zig:35-36`:

```zig
/// Library version, injected from build.zig.zon via build_options (Q-020).
pub const version: []const u8 = @import("build_options").version;
```

- [ ] **Step 3: Fix the integration test and its module imports**

The integration test module (build.zig ~line 140-150) lacks the `build_options` import — add it:

```zig
            .imports = &.{
                .{ .name = "metrics", .module = module },
                .{ .name = "thread_pool", .module = tp_module },
                .{ .name = "build_options", .module = build_options_module },
            },
```

Replace `tests/integration.zig:124-126`:

```zig
test "version matches build manifest" {
    try std.testing.expectEqualStrings(@import("build_options").version, metrics.version);
    // Sanity: semver-ish shape (at least "x.y.z").
    try std.testing.expect(std.mem.count(u8, metrics.version, ".") == 2);
}
```

- [ ] **Step 4: Run tests**

Run: `zig build check && zig build test --summary all && zig build test-integration --summary all`
Expected: PASS; `metrics.version` now reports `0.1.3`.

- [ ] **Step 5: Commit**

```bash
git add build.zig src/root.zig tests/integration.zig
git commit -m "fix: close Q-020 - single-source version from build.zig.zon

root.zig hardcoded 0.1.0 while the manifest said 0.1.3. The version now
flows manifest -> build_options -> metrics.version, and the integration
test asserts equality with the injected value instead of a literal.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 9: P-012 + P-013 — Benchmarks must measure ReleaseFast library code with a production allocator

**Files:**

- Modify: `build.zig` (scale-bench module wiring, ~lines 171-188)
- Modify: `benchmarks/variance.zig:39`, `benchmarks/scale_bench.zig:105`

- [ ] **Step 1: Give scale-bench a ReleaseFast metrics module**

In `build.zig`, before the scale-bench block, create dedicated ReleaseFast instances (the exe was already `.ReleaseFast`, but it imported the user-optimize `module`, so the measured library code was Debug by default — P-012):

```zig
    // P-012: benchmarks must measure ReleaseFast library code regardless
    // of the user's -Doptimize. Dedicated module instances; the test and
    // check artifacts keep using the user-optimize `module`.
    const tp_dep_fast = b.dependency("thread_pool", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const tp_module_fast = tp_dep_fast.module("thread_pool");
    const metrics_module_fast = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "thread_pool", .module = tp_module_fast },
            .{ .name = "build_options", .module = build_options_module },
        },
    });
```

Then in the `scale_bench_exe` module, replace the imports:

```zig
            .imports = &.{
                .{ .name = "metrics", .module = metrics_module_fast },
                .{ .name = "thread_pool", .module = tp_module_fast },
            },
```

Leave the variance `bench_exe` on user-optimize `module` (the Makefile and CI pass `-Doptimize=ReleaseFast`), but add a Debug-mode warning in `benchmarks/variance.zig` near the top of `main()`:

```zig
    const builtin = @import("builtin");
    if (builtin.mode == .Debug) {
        try stderr.print("WARNING: Debug build -- pass -Doptimize=ReleaseFast for valid numbers\n", .{});
    }
```

(`stderr` already exists in variance.zig's main; if the import name `builtin` collides, use `@import("builtin").mode` inline.)

- [ ] **Step 2: Swap DebugAllocator for smp_allocator in measured paths (P-013)**

`benchmarks/variance.zig:39` and `benchmarks/scale_bench.zig:105`, replace:

```zig
    // OLD:
    // var gpa: std.heap.DebugAllocator(.{}) = .init;
    // defer _ = gpa.deinit();
    // const allocator = gpa.allocator();

    // NEW (P-013): DebugAllocator's per-allocation bookkeeping inflates
    // snapshot/registration costs and benchmark variance. smp_allocator
    // is the production-grade thread-safe allocator.
    const allocator = std.heap.smp_allocator;
```

Remove the now-unused `gpa` deinit lines. (Leak detection belongs to the test suite, not benchmarks.)

- [ ] **Step 3: Validate**

Run: `zig build bench-check && zig build check && zig build test --summary all`
Expected: PASS.

Run: `zig build scale-bench -- light 2>&1 | tail -3`
Expected: light tier completes; throughput materially higher than the old Debug-library numbers.

- [ ] **Step 4: Commit**

```bash
git add build.zig benchmarks/variance.zig benchmarks/scale_bench.zig
git commit -m "fix: close P-012/P-013 - benches measure ReleaseFast code with smp_allocator

scale-bench's exe was ReleaseFast but imported the user-optimize
metrics module (Debug by default), so all baselines measured Debug
library code. Wire a dedicated ReleaseFast module pair, warn on Debug
variance runs, and replace DebugAllocator with smp_allocator in
measured loops.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 10: P-014 — Adopt `std.Io.RwLock` in the registry lock shim

**Files:**

- Modify: `src/registry.zig:13-36`

API verified in 0.16 stdlib (`std/Io/RwLock.zig`): `init`, `lockUncancelable(io)`, `unlock(io)`, `lockSharedUncancelable(io)`, `unlockShared(io)`.

- [ ] **Step 1: Replace the shim**

```zig
/// Zig 0.16 lock wrapper. std.Thread.RwLock moved to std.Io.RwLock and
/// every lock/unlock call needs an Io instance; this wrapper supplies
/// the global single-threaded Io so the Registry API stays Io-parameter
/// free. Real reader-writer semantics: concurrent getX/snapshot calls
/// take a shared lock and no longer serialize against each other (P-014).
const RwLockShim = struct {
    inner: std.Io.RwLock = .init,

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
        self.inner.lockSharedUncancelable(getIo());
    }
    pub fn unlockShared(self: *RwLockShim) void {
        self.inner.unlockShared(getIo());
    }
};
```

- [ ] **Step 2: Run the full suite including the concurrency tests**

Run: `zig build check && zig build test --summary all && zig build test-integration --summary all && zig build test -Doptimize=ReleaseFast --summary all`
Expected: all PASS (the ReleaseFast run exercises the lock under optimized codegen).

- [ ] **Step 3: Commit**

```bash
git add src/registry.zig
git commit -m "perf: close P-014 - real reader-writer lock via std.Io.RwLock

The 0.16 shim collapsed shared locks to an exclusive std.Io.Mutex,
serializing all concurrent lookups/snapshots. std.Io.RwLock provides
the uncancelable shared/exclusive API the shim needs; readers now run
concurrently.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 11: Q-027 — Close the three test gaps

**Files:**

- Modify: `tests/integration.zig:218-255` (shard-count test), `src/gauge.zig` (new test), `src/histogram.zig` + `src/prometheus.zig` (above-max-bucket test)

- [ ] **Step 1: Fix the shard-count test comment and tighten the assertion**

In `tests/integration.zig` (test `"thread_pool: parallelSnapshot shards histograms when count > chunk_size"`), replace the comment and assertion (lines 240-244):

```zig
    // 1 gauge-task + ceil(16/4)=4 hist-shards + 1 timer-task: empty
    // metric types still emit one task each (registry.zig forces
    // timer_chunks = 1 when timer_count == 0), so exactly 6 tasks.
    // The pre-sharding baseline submitted only 3.
    try std.testing.expectEqual(@as(u64, 6), after - before);
```

- [ ] **Step 2: Add an asymmetric concurrent gauge test**

Append to `src/gauge.zig` (the existing net-zero test can't detect lost updates; an asymmetric expectation can):

```zig
test "Gauge: concurrent asymmetric inc/add nets to exact expected value" {
    var g = Gauge.init("concurrent_exact", "help");
    const iterations: usize = 10_000;
    const inc_threads = 3; // 3 * 10_000 * +1 = +30_000
    const dec_threads = 1; // 1 * 10_000 * -1 = -10_000

    var threads: [inc_threads + dec_threads]std.Thread = undefined;
    for (threads[0..inc_threads]) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(gauge: *Gauge) void {
                for (0..iterations) |_| gauge.inc();
            }
        }.run, .{&g});
    }
    for (threads[inc_threads..]) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(gauge: *Gauge) void {
                for (0..iterations) |_| gauge.dec();
            }
        }.run, .{&g});
    }
    for (&threads) |*t| t.join();

    // Any lost update breaks this exact total (unlike the symmetric
    // net-zero test, which broken atomics can still pass by symmetry).
    try std.testing.expectEqual(@as(i64, 20_000), g.get());
}
```

- [ ] **Step 3: Pin above-max-bucket routing**

Append to `src/histogram.zig`:

```zig
test "Histogram: observation above max bucket counts only in count/sum, no explicit bucket" {
    const allocator = std.testing.allocator;
    const buckets = [_]f64{ 1.0, 5.0 };
    var h = try Histogram.init(allocator, "overflow", "help", &buckets);
    defer h.deinit();

    h.observe(0.5); // bucket 0
    h.observe(10.0); // above all bounds: count/sum only

    try std.testing.expectEqual(@as(u64, 2), h.getCount());
    try std.testing.expectEqual(@as(u64, 1), h.getBucketCount(0));
    try std.testing.expectEqual(@as(u64, 0), h.getBucketCount(1));
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), h.getSum(), 1e-10);
}
```

Append to `src/prometheus.zig`:

```zig
test "Prometheus: above-max observation appears only in +Inf and _count (Q-027)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const buckets = [_]f64{ 1.0, 5.0 };
    const h = try reg.histogram("ovf_seconds", "Overflow", &buckets);
    h.observe(10.0);

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePrometheus(&reg, &writer);

    const output = writer.buffered();
    // Explicit buckets exclude it; +Inf and _count include it.
    try std.testing.expect(std.mem.indexOf(u8, output, "ovf_seconds_bucket{le=\"1\"} 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ovf_seconds_bucket{le=\"5\"} 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ovf_seconds_bucket{le=\"+Inf\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ovf_seconds_count 1\n") != null);
}
```

(Adjust the `le=\"1\"`/`le=\"5\"` literals to the actual `{d}` rendering from Task 7 — run once and paste real output.)

- [ ] **Step 4: Run tests**

Run: `zig build test --summary all && zig build test-integration --summary all`
Expected: PASS, test counts increased.

- [ ] **Step 5: Commit**

```bash
git add tests/integration.zig src/gauge.zig src/histogram.zig src/prometheus.zig
git commit -m "test: close Q-027 - exact shard count, asymmetric gauge race, +Inf routing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 12: GAP-009 + Q-018 + Q-019 + GAP-008 — README accuracy batch

**Files:**

- Modify: `README.md`

- [ ] **Step 1: Apply all README fixes**

1. Line 4 badge: `Zig-0.15.1+` → `Zig-0.16.0+`.
2. Line 10: `- **Zero Dependencies**: Pure Zig standard library only` → `- **Minimal Dependencies**: Zig standard library plus one dependency ([thread-pool](https://gitlab.com/devnw/zig/thread-pool), used only by \`parallelSnapshot\`)`.
3. After the Features list, add a cardinality note (S-019 docs requirement):

```markdown
> **Note on metric names:** keep names low-cardinality and
> developer-controlled — never derive them from untrusted input
> (user IDs, request paths). Each unique name allocates permanently
> until `deinit`. Use `RegistryOptions.max_metrics` to enforce a cap.
```

1. Line 24 install URL: `v0.1.0/metrics-v0.1.0.tar.gz` → `v0.1.3/metrics-v0.1.3.tar.gz`.
2. Quick Start (lines 42-71): replace with compiling Zig 0.16 code (allocator pattern from `src/root.zig:17`, writer pattern from `src/prometheus.zig:78-79`):

````markdown
```zig
const std = @import("std");
const metrics = @import("metrics");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create an instance-based registry (no globals)
    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();

    // Register and use metrics
    const requests = try reg.counter("http_requests_total", "Total HTTP requests");
    requests.inc();

    const connections = try reg.gauge("active_connections", "Active connections");
    connections.set(42);

    const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0, 5.0 };
    const latency = try reg.histogram("request_latency_seconds", "Latency", &buckets);
    latency.observe(0.03);

    // Export to Prometheus text format
    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try metrics.writePrometheus(&reg, &writer);
    std.debug.print("{s}", .{writer.buffered()});
}
```
````

1. Line 75 Requirements: `Zig 0.15.1 or later` → `Zig 0.16.0 or later`.
2. Add a new section after Quick Start (GAP-008):

```markdown
## Exporting over HTTP (bring your own transport)

`metrics` deliberately ships **no HTTP server**. `writePrometheus`
accepts any `*std.Io.Writer`, so the library stays transport-agnostic:
wire it to a fixed buffer, a socket, a file, or your framework's
response writer. A typical `/metrics` endpoint handler:

```zig
fn handleMetrics(reg: *metrics.Registry, response_writer: *std.Io.Writer) !void {
    // Snapshot is captured under the registry lock; writing happens
    // outside it, so a slow client never blocks metric producers.
    try metrics.writePrometheus(reg, response_writer);
}
```

HTTP server wiring (routes, content-type `text/plain; version=0.0.4`,
auth) belongs to the embedding application — see MET-REQ-005.
<!-- markdownlint-disable-next-line MD040 -->
```

- [ ] **Step 2: Verify the Quick Start compiles**

The Task 13 example uses the same code; for now verify by scratch compile:

```bash
mkdir -p /tmp/qs-check && sed -n '/^## Quick Start$/,/^```$/p' README.md | sed -n '/^```zig$/,/^```$/p' | sed '1d;$d' > /tmp/qs-check/main.zig && head -3 /tmp/qs-check/main.zig
```

Then confirm the snippet matches `examples/basic.zig` after Task 13 (they must be the same pattern; the example IS the compile check).

- [ ] **Step 3: Run markdownlint**

Run: `pre-commit run markdownlint --files README.md`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: close GAP-008/GAP-009/Q-018/Q-019 - README accuracy batch

Fix Zig badge/requirements to 0.16.0, install URL to v0.1.3, correct
the false zero-dependencies claim, port the Quick Start to Zig 0.16
APIs, add cardinality guidance, and document the writer-pattern /
bring-your-own-HTTP boundary.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 13: Q-022 — Real runnable example wired into the build

**Files:**

- Modify: `examples/basic.zig` (full rewrite), `build.zig` (add `example` step), `.gitlab-ci.yml` (compile example in build job)

- [ ] **Step 1: Rewrite examples/basic.zig**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic usage example for the metrics library.
//!
//! Demonstrates creating a registry, registering metrics, recording
//! values, and exporting in Prometheus text format.
//!
//! Run with: zig build example

const std = @import("std");
const metrics = @import("metrics");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();

    const requests = try reg.counter("http_requests_total", "Total HTTP requests");
    requests.inc();
    requests.add(99);

    const connections = try reg.gauge("active_connections", "Active connections");
    connections.set(42);

    const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0, 5.0 };
    const latency = try reg.histogram("request_latency_seconds", "Latency", &buckets);
    latency.observe(0.03);

    const db_timer = try reg.timer("db_query_seconds", "DB query time", &buckets);
    const sample = db_timer.start();
    sample.finish();

    // Export to Prometheus text format on stdout.
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    var out_buf: [8192]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io_inst, &out_buf);
    const stdout = &stdout_fw.interface;
    try metrics.writePrometheus(&reg, stdout);
    try stdout.flush();
}
```

- [ ] **Step 2: Wire `zig build example` in build.zig**

After the bench-check block:

```zig
    // Runnable example (Q-022). Compiled in CI so it cannot rot.
    const example_step = b.step("example", "Build and run the basic example");
    const example_exe = b.addExecutable(.{
        .name = "example-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "metrics", .module = module },
            },
        }),
    });
    const run_example = b.addRunArtifact(example_exe);
    example_step.dependOn(&run_example.step);
```

- [ ] **Step 3: Add to CI build job**

In `.gitlab-ci.yml` `build:` job script:

```yaml
  script:
    - zig build check
    - zig build example
```

- [ ] **Step 4: Run it**

Run: `zig build example`
Expected: prints Prometheus exposition output (HELP/TYPE lines, `http_requests_total 100`, histogram buckets) and exits 0.

- [ ] **Step 5: Commit**

```bash
git add examples/basic.zig build.zig .gitlab-ci.yml
git commit -m "feat: close Q-022 - runnable example wired into build and CI

examples/basic.zig was a commented-out stub. It now exercises every
metric type and prints real Prometheus output via zig build example,
compiled in CI (partial Q-011).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 14: Q-021 — CHANGELOG entries for 0.1.0 through 0.1.3

**Files:**

- Modify: `CHANGELOG.md`

- [ ] **Step 1: Gather release history**

Run: `git log --oneline v0.1.0 2>/dev/null | head -1; git tag -l 'v*' --format='%(refname:short) %(creatordate:short)'; git log --oneline v0.1.0..v0.1.1 2>/dev/null; git log --oneline v0.1.1..v0.1.2 2>/dev/null; git log --oneline v0.1.2..v0.1.3 2>/dev/null`
Use the real dates and commit subjects from the output.

- [ ] **Step 2: Replace the template entries**

Replace the `## [0.1.0] - YYYY-MM-DD` placeholder and `[Unreleased]` content with dated sections derived from Step 1, e.g. (substitute real dates/changes):

```markdown
## [Unreleased]

## [0.1.3] - <date of v0.1.3 tag>

### Fixed

- Hardcode `with_otel=false` to avoid the Zig 0.16 `build_options`
  module-dedup compile error.

## [0.1.2] - <date>

### Changed

- Re-pin sibling dependencies to tagged releases.

## [0.1.1] - <date>

### Changed

- Dependency pin updates.

## [0.1.0] - <date of v0.1.0 tag>

### Added

- Initial release: counters, gauges, histograms, timers, snapshots,
  instance-based registry, Prometheus text exporter, parallel snapshot
  via thread-pool.
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: close Q-021 - backfill CHANGELOG for v0.1.0 through v0.1.3

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 15: GAP-006 + GAP-007 — Registry and Prometheus prose docs

**Files:**

- Create: `docs/registry.md`, `docs/prometheus.md`
- Modify: `docs/README.md` (link both)

- [ ] **Step 1: Write docs/registry.md**

Cover, with code samples mirroring the (post-Task-3/4/10) reality:

- Lifecycle: `Registry.init(allocator)` / `initWithOptions` → register (`counter`/`gauge`/`histogram`/`timer`) → use lock-free handles → `snapshot()`/`parallelSnapshot(pool)` → `deinit()`.
- Ownership: registry copies `name`/`help` (S-017); bucket slices are borrowed and must outlive the registry; returned metric pointers are valid until `deinit`.
- Thread-safety: registration/lookup/snapshot under an internal RwLock (shared for reads since P-014); metric updates lock-free atomics, eventually consistent snapshots.
- `RegistryOptions`: `snapshot_chunk_size`, `max_metrics` (+ `error.CardinalityLimitExceeded`).
- `parallelSnapshot`: requires a `thread_pool.ThreadPool`, shards histogram/timer capture, can return `error.SnapshotIncomplete` under pool saturation (S-018) — callers should fall back to `snapshot()` or retry.
- Recommended usage pattern: cache metric pointers at startup; don't do per-request string lookups.

- [ ] **Step 2: Write docs/prometheus.md**

Cover:

- `writePrometheus(registry, writer)` — snapshot-then-write: values captured under the registry lock, text written outside it, so slow writers never block producers.
- Output structure per metric: `# HELP`, `# TYPE`, value lines; histograms/timers emit cumulative `_bucket{le="..."}` lines, `+Inf`, `_sum`, `_count`; `le`/`_sum` use shortest round-trip decimal formatting (S-020).
- Empty registry produces empty output.
- Name/help validation at registration time guarantees injection-free exposition output (S-001/S-014/S-015).
- Buffering advice: wrap unbuffered writers (each metric emits several small prints — P-017 accepted note).

- [ ] **Step 3: Update docs/README.md index**

Add links: `- [Registry model and lifecycle](registry.md)` and `- [Prometheus export behavior](prometheus.md)`.

- [ ] **Step 4: Lint and commit**

Run: `pre-commit run markdownlint --files docs/registry.md docs/prometheus.md docs/README.md`
Expected: PASS.

```bash
git add docs/registry.md docs/prometheus.md docs/README.md
git commit -m "docs: close GAP-006/GAP-007 - registry lifecycle and Prometheus export docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 16: S-021 + S-022(a,c,d,e) — CI and pre-commit hardening

**Files:**

- Modify: `.gitlab-ci.yml`, `.pre-commit-config.yaml`

- [ ] **Step 1: Bump CI catalog components (S-021)**

In `.gitlab-ci.yml:11-24`, change every `@v1.7.1` to `@v1.25.1` (verify the exact latest version first: `glab api 'projects/devnw%2Fci-catalog/releases?per_page=1' --paginate=false 2>/dev/null | head -c 400` — use the newest tag it reports; the sibling thread_pool repo pins v1.25.1). Leave `zig-format@v1.2.1` unless a newer zig-format exists in the same listing.

- [ ] **Step 2: Pin job images by digest (S-022a)**

Get the digest: `docker manifest inspect debian:bookworm-slim 2>/dev/null | head -20` — if docker is unavailable, `curl -fsSL "https://hub.docker.com/v2/repositories/library/debian/tags/bookworm-slim" | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])"`. Then define once in the variables block and reference everywhere:

```yaml
variables:
  ZIG_VERSION: "0.16.0"  # security-relevant pin -- SHA-verified by .install-zig (do not override in pipeline runs)
  # S-022(a): digest-pinned base image (debian:bookworm-slim as of 2026-06-11).
  CI_BASE_IMAGE: "debian:bookworm-slim@sha256:<digest-from-above>"
```

Replace all 10 `image: debian:bookworm-slim` lines with `image: $CI_BASE_IMAGE`.

- [ ] **Step 3: Re-verify cached Zig binary (S-022d)**

The `.install-zig` template skips SHA verification when `zig-${ZIG_VERSION}/zig` exists. Make the cache trustless by recording the verified hash and re-checking the binary:
after the `tar -xJf` line and before `rm -f "${TARBALL}"`, add:

```yaml
      sha256sum "zig-${ZIG_VERSION}/zig" > "zig-${ZIG_VERSION}/.zig-binary.sha256"
```

and change the outer condition body so a cache hit re-verifies:

```yaml
  - |
    if [ -f "zig-${ZIG_VERSION}/zig" ] && [ -f "zig-${ZIG_VERSION}/.zig-binary.sha256" ]; then
      sha256sum --check --strict "zig-${ZIG_VERSION}/.zig-binary.sha256" || { echo "Cached Zig binary failed verification"; exit 1; }
    fi
```

(Insert this as a new list item right after the `apt-get` line, keeping the existing download block unchanged apart from writing the marker file.)

- [ ] **Step 4: Add gitleaks pre-commit hook (S-022e)**

In `.pre-commit-config.yaml`, add a new repo block (match the file's existing style; pin the current gitleaks release tag):

```yaml
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.24.3
    hooks:
      - id: gitleaks
```

Check the latest tag with `git ls-remote --tags https://github.com/gitleaks/gitleaks.git | tail -5` and pin that.

- [ ] **Step 5: Validate**

Run: `pre-commit run check-yaml --files .gitlab-ci.yml .pre-commit-config.yaml && glab ci lint .gitlab-ci.yml 2>&1 | head -5 && pre-commit run gitleaks --all-files`
Expected: YAML valid, CI lint valid, gitleaks 0 findings.

- [ ] **Step 6: Commit**

```bash
git add .gitlab-ci.yml .pre-commit-config.yaml
git commit -m "ci: close S-021/S-022 - bump catalog pins, digest-pin images, harden zig cache, add gitleaks hook

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 17: S-023 + Q-025 + Q-026 + Q-029 — Script guard, registry dedup/extraction, API papercuts

**Files:**

- Modify: `scripts/detect_diamond_deps.py` (~lines 178-184, 210)
- Modify: `src/registry.zig` (capture helpers, `nameInUse` comment)
- Modify: `src/timer.zig` (accessors), `src/counter.zig` + `src/gauge.zig` (doc note)

- [ ] **Step 1: S-023 — validate pkg hash before path join**

In `scripts/detect_diamond_deps.py`, near the top add `import re` (if absent), and in the function that builds paths from `pkg_hash` (the `project_root / "zig-pkg" / pkg_hash` and `zig_global_cache / "p" / pkg_hash` joins), add first:

```python
_HASH_RE = re.compile(r"^[A-Za-z0-9._-]+$")

def _safe_hash(pkg_hash: str) -> bool:
    """Reject hashes that could traverse outside the package roots (CWE-22)."""
    return bool(_HASH_RE.fullmatch(pkg_hash)) and ".." not in pkg_hash
```

and guard each join site:

```python
    if not _safe_hash(pkg_hash):
        return None  # treat like a cache miss; never build a traversal path
```

Run: `python3 scripts/detect_diamond_deps.py && pre-commit run detect-diamond-deps --all-files`
Expected: PASS (script exits 0 on this repo).

- [ ] **Step 2: Q-025 — unify captureHistSlice/captureTimerSlice**

In `src/registry.zig`, replace both functions with one comptime-generic helper and update the two call sites (`hist_run`, `timer_run`):

```zig
    fn captureMetricSlice(
        comptime Entry: type,
        entries: []const Entry,
        out: []snapshot_mod.MetricSnapshot,
        counts: []u64,
        bounds: []f64,
        kind: snapshot_mod.MetricKind,
    ) void {
        var offset: usize = 0;
        for (entries, 0..) |e, idx| {
            const h = if (Entry == HistEntry) e.hist else &e.timer.histogram;
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
```

Call sites: `captureMetricSlice(HistEntry, c.entries, c.out, c.counts, c.bounds, .histogram)` and `captureMetricSlice(TimerEntry, c.entries, c.out, c.counts, c.bounds, .timer)`.

- [ ] **Step 3: Q-026 — extract parallelSnapshot shard builder**

Move the `GaugeCtx`/`HistCtx`/`TimerCtx` struct declarations from inside `parallelSnapshot` to `Registry` container scope (next to `HistEntry`/`TimerEntry`), and extract the two near-identical shard-building loops into one helper at container scope:

```zig
    /// Build shard contexts + tasks for one metric family (histograms or
    /// timers). Returns nothing; fills ctxs[0..chunks] and appends tasks.
    fn buildShards(
        comptime Entry: type,
        comptime Ctx: type,
        entry_list: []const Entry,
        out_entries: []snapshot_mod.MetricSnapshot,
        bucket_counts: []u64,
        bucket_bounds: []f64,
        chunk: usize,
        chunks: usize,
        ctxs: []Ctx,
        tasks: []tp.BatchTask,
        task_idx: *usize,
        run_fn: *const fn (*anyopaque, *tp.TaskContext) void,
    ) void {
        const count = entry_list.len;
        var entry_off: usize = 0;
        var bucket_off: usize = 0;
        var shard: usize = 0;
        while (shard < chunks) : (shard += 1) {
            const shard_end = @min(entry_off + chunk, count);
            const shard_entries = entry_list[entry_off..shard_end];
            var shard_buckets: usize = 0;
            for (shard_entries) |e| {
                const h = if (Entry == HistEntry) e.hist else &e.timer.histogram;
                shard_buckets += h.buckets.len;
            }
            ctxs[shard] = .{
                .entries = shard_entries,
                .out = out_entries[entry_off..shard_end],
                .counts = bucket_counts[bucket_off .. bucket_off + shard_buckets],
                .bounds = bucket_bounds[bucket_off .. bucket_off + shard_buckets],
            };
            tasks[task_idx.*] = .{ .task_fn = run_fn, .ctx = &ctxs[shard] };
            task_idx.* += 1;
            entry_off = shard_end;
            bucket_off += shard_buckets;
        }
    }
```

Replace the two inline `{ var entry_off ... }` blocks with:

```zig
        buildShards(HistEntry, HistCtx, hist_entry_list, hist_entries, hist_bucket_counts, hist_bucket_bounds, chunk, hist_chunks, hist_ctxs, tasks, &task_idx, hist_run);
        buildShards(TimerEntry, TimerCtx, timer_entry_list, timer_entries, timer_bucket_counts, timer_bucket_bounds, chunk, timer_chunks, timer_ctxs, tasks, &task_idx, timer_run);
```

(Moving HistCtx/TimerCtx to container scope is required so `ctxs: []Ctx` type-checks. Keep the field shapes identical.)

- [ ] **Step 4: Q-029 — Timer accessors, deinit doc notes, lock comment**

`src/timer.zig`, after `getSum`:

```zig
    /// Return the timer's metric name (delegates to the inner histogram).
    pub fn name(self: *const Timer) []const u8 {
        return self.histogram.name;
    }

    /// Return the timer's help text (delegates to the inner histogram).
    pub fn help(self: *const Timer) []const u8 {
        return self.histogram.help;
    }

    /// Return the per-bucket (non-cumulative) count at `index`.
    pub fn getBucketCount(self: *const Timer, index: usize) u64 {
        return self.histogram.getBucketCount(index);
    }
```

Plus a test:

```zig
test "Timer: accessors delegate to inner histogram (Q-029)" {
    const allocator = std.testing.allocator;
    var t = try Timer.init(allocator, "acc_timer", "Accessor test", default_timer_buckets);
    defer t.deinit();
    t.recordSeconds(0.002);
    try std.testing.expectEqualStrings("acc_timer", t.name());
    try std.testing.expectEqualStrings("Accessor test", t.help());
    try std.testing.expectEqual(@as(u64, 1), t.getBucketCount(1)); // 0.002 <= 0.005
}
```

(Verify the bucket index: `default_timer_buckets` = {0.001, 0.005, ...}; 0.002 lands in index 1.)

`src/counter.zig` and `src/gauge.zig` module docs: append `//! Counter/Gauge own no heap allocations; no deinit is needed (the owning Registry destroys the struct).` (adjust wording per type).

`src/registry.zig` in each register fn before `nameInUse`: the check-then-insert pair is atomic only because both run under the exclusive lock — add once above the first use:

```zig
        // nameInUse + put form a check-then-insert pair; they are atomic
        // only because both run under the exclusive lock taken above.
        // Do not split them across lock domains (Q-029/MQ-013).
```

- [ ] **Step 5: Full validation and commit**

Run: `zig fmt src/ && zig build check && zig build test --summary all && zig build test-integration --summary all && pre-commit run --all-files`
Expected: PASS.

```bash
git add scripts/detect_diamond_deps.py src/registry.zig src/timer.zig src/counter.zig src/gauge.zig
git commit -m "refactor: close S-023/Q-025/Q-026/Q-029 - script path guard, registry dedup, timer accessors

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 18: Re-measure benchmarks and refresh PERF_GAP_ANALYSIS baseline

**Files:**

- Modify: `docs/PERF_GAP_ANALYSIS.md`

- [ ] **Step 1: Run the re-measurement**

Run: `zig build bench -Doptimize=ReleaseFast 2>&1 | tail -30` and `zig build scale-bench -- light moderate 2>&1 | tail -20`
Capture: counter/histogram/mixed mean/min/max/stddev/CV from the variance bench; tier throughput from scale bench.

- [ ] **Step 2: Update the doc**

In `docs/PERF_GAP_ANALYSIS.md`: replace the "INVALID, pending re-measurement" baseline table with the new numbers (date 2026-06-11, note "ReleaseFast library + smp_allocator after P-012/P-013"); mark P-011, P-012, P-013, P-014 as Closed with commit evidence; re-assess P-010 (CV target <10%) against the fresh CVs and update its status accordingly; note GAP-005 closure restored `bench-save`/`bench-compare`.

- [ ] **Step 3: Commit**

```bash
git add docs/PERF_GAP_ANALYSIS.md
git commit -m "docs: re-measure benchmark baseline after P-012/P-013; close perf gaps

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final validation (after all tasks)

```bash
zig fmt src/ tests/ benchmarks/ build.zig examples/
zig build check
zig build test --summary all
zig build test-integration --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build bench-check
zig build example
pre-commit run --all-files
git status --short   # must be clean
```

All green + clean tree = ready for the gap-closer-verifier phase.

## Deferred / Won't-Do (no tasks — reporter phase records these)

- Q-007, Q-010, Q-012, Q-014, S-005, S-008, S-009, S-013: standing Won't-Do, unchanged.
- S-022(b) (index.json TOFU): Won't-Do for this repo in isolation (multi-repo effort).
- P-010: re-assessed in Task 18 with fresh CVs.
- Perf accepted items A-001..A-005: documented in PERF_GAP_ANALYSIS.md, no code change.
- Q-028: hook auto-fixes already committed (87b0403).
