# GAP Analysis

Last updated: 2026-06-11

Repository status: core metrics library implemented with consolidated API. All functional gaps closed as of 2026-06-11.

## Open Gaps

No open functional gaps remain. All items from GAP-005 through GAP-009 were closed in the 2026-06-11 gap-closure sprint. See `GAP_ANALYSIS_RESOLVED.md` for full resolution evidence.

---

## Historical Context (Resolved Extraction Work)

> The sections below document the original Geode-extraction effort (GAP-001..GAP-004 and the
> parallelism/concurrency review). All of these are **Closed** and recorded in
> `GAP_ANALYSIS_RESOLVED.md`. They are retained here for architectural context only and are not
> open gaps. See the "Open Gaps" section above for current work.

## Goal

Create a standalone metrics library from Geode's monitoring code after consolidating the currently duplicated collector/registry/exporter implementations.

## Intended Boundary

Candidate code for this library:

| Geode source | Why it belongs here |
|---|---|
| `src/monitoring/metrics.zig:5`, `:225`, `:307`, `:356`, `:623` | Generic counters, gauges, histograms, timers, snapshots, and query profiling |
| `src/monitoring/prometheus.zig:5`, `:55`, `:147`, `:233`, `:249`, `:376` | Prometheus exporter and collector surface |
| `src/monitoring/registry.zig:49`, `:55`, `:59` | Lightweight registry/export surface |

Keep in Geode or make optional later:

| Geode source | Why it stays |
|---|---|
| `src/monitoring/metrics_server.zig:10`, `:17`, `:32`, `:50`, `:125` | HTTP endpoint/server wiring is adapter code rather than pure metrics core |

## Concrete Gaps

| Gap | Status | Evidence | Resolution |
|---|---|---|---|
| Three overlapping metrics surfaces exist today | **Closed** | `src/monitoring/metrics.zig:5`, `src/monitoring/prometheus.zig:233`, `src/monitoring/registry.zig:49` | Consolidated into one coherent model: `src/counter.zig`, `src/gauge.zig`, `src/histogram.zig`, `src/timer.zig`, `src/snapshot.zig`, `src/registry.zig`, `src/prometheus.zig` with a single public API in `src/root.zig`. |
| Global singleton state exists | **Closed** | `src/monitoring/registry.zig:85`, `src/monitoring/metrics_server.zig:139` | `Registry` is fully instance-based. No module-level mutable state. Verified by integration test `no globals: two registries are fully independent`. |
| Standalone review found Zig drift in `metrics.zig` | **Closed** | standalone compile failed during review | At extraction time all code compiled and passed tests on Zig 0.15.2 (Debug, ReleaseSafe, ReleaseFast); since superseded by the Zig 0.16.0 migration -- current toolchain is Zig 0.16.0 and the registry uses `std.Io.RwLock` (P-014). |
| `metrics_server.zig` mixes transport concerns with metrics | **Closed** | `src/monitoring/metrics_server.zig:10`, `:50`, `:125` | HTTP server transport is not included in this library. Core exposes `writePrometheus(registry, writer)` which accepts any `writer` -- transport adapters remain in Geode. |

## Tests And Benchmarks Carried Over

| Original test / benchmark | Status | Coverage provided |
|---|---|---|
| Core metric and snapshot behavior | **Ported** | 47 unit tests covering Counter, Gauge, Histogram, Timer, Snapshot, Registry, Prometheus export |
| End-to-end smoke coverage (MET-TEST-002) | **Ported** | 6 integration tests including full smoke test with all metric types and Prometheus export |
| Metrics registry variance benchmark (MET-TEST-003) | **Ported** | `benchmarks/variance.zig` -- Counter throughput, Histogram observation, Mixed workload with CV < 10% |
| HTTP server test | **Stays in Geode** | Not applicable -- server transport is outside this library's boundary |

## Proposed Public API

Implemented public surface:

- `Counter` -- thread-safe monotonically increasing counter
- `Gauge` -- thread-safe bidirectional gauge
- `Histogram` -- configurable bucket histogram with atomic sum
- `Timer` -- duration measurement wrapping Histogram
- `Snapshot` / `MetricSnapshot` / `MetricKind` -- point-in-time metric captures
- `Registry` -- instance-based metric lifecycle management
- `writePrometheus` -- Prometheus text exposition format export
- `default_buckets` / `default_timer_buckets` -- standard bucket configurations

The HTTP endpoint/server layer remains a separate adapter in Geode.

## Parallelism & Concurrency Review

Reviewed: 2026-03-30

### Concurrency Architecture

The library uses a three-tier concurrency strategy:

| Tier | Mechanism | Purpose |
|---|---|---|
| Lock-free atomics | `std.atomic.Value` with `.monotonic` ordering | Hot-path metric updates (Counter, Gauge, Histogram) |
| RwLock | `std.Thread.RwLock` on Registry | Protects map operations; shared lock for reads, exclusive for registration |
| Spice fork/join | `spice.ThreadPool` + `spice.Future` | Parallel snapshot capture, benchmark workloads |

### Atomic Operations

| Component | Mechanism | Ordering | Location |
|---|---|---|---|
| `Counter` | `std.atomic.Value(u64)` with `fetchAdd` | `.monotonic` | `src/counter.zig:18,31,36` |
| `Gauge` | `std.atomic.Value(i64)` with `fetchAdd`/`fetchSub`/`store`/`load` | `.monotonic` | `src/gauge.zig:18,31,36,41,46,51` |
| `Histogram` bucket counts | `std.atomic.Value(u64)` array with `fetchAdd` | `.monotonic` | `src/histogram.zig:26-28,88,93` |
| `Histogram` sum | `atomicAddF64` CAS spin-loop on bitcast `u64` | `.monotonic` | `src/histogram.zig:114-129` |

Monotonic ordering is documented as correct for metrics: each field is an independent scalar with no cross-field invariants. See `src/histogram.zig` module doc for full rationale.

### Spice Integration

`spice` is wired as a path dependency (`build.zig.zon`) and imported by the metrics module, all test targets, and benchmarks.

- `Registry.parallelSnapshot(pool)` fans out capture across 4 metric types using `spice.Future` fork/join
- `benchmarks/variance.zig` uses `spice.ThreadPool` for all concurrent workloads
- `tests/integration.zig` includes spice-based concurrent counter and parallel snapshot tests
- `root.zig` re-exports `spice` for downstream consumers

## Concrete Gaps (Parallelism)

| Gap | Status | Evidence | Resolution |
|---|---|---|---|
| `spice` dependency missing entirely | **Closed** | `build.zig.zon` had `.dependencies = .{}` | Added as path dependency `../spice`. Wired into metrics module, unit tests, integration tests, benchmarks, and check step in `build.zig`. |
| No multiplexing / fan-out support | **Closed** | No fan-out patterns existed | `Registry.parallelSnapshot(pool)` forks gauge/histogram/timer capture concurrently using `spice.Future`, joining in LIFO order. Counters captured on calling thread. |
| Registry uses a single coarse-grained mutex | **Closed** | `src/registry.zig:46` was `std.Thread.Mutex` | Replaced with `std.Thread.RwLock`. Registration uses exclusive lock; lookups, snapshots, and `metricCount` use shared lock. Concurrent reads no longer block each other. |
| Benchmark threading is ad-hoc | **Closed** | `benchmarks/variance.zig` used `std.Thread.spawn`/`join` | Refactored to use `spice.ThreadPool` with fork/join for all benchmarks (counter, histogram, mixed, parallel snapshot). Pool created once and shared across all benchmark runs. |
| `atomicAddF64` CAS spin-loop is hand-rolled | **Closed (documented)** | `src/histogram.zig:114-129` | The CAS loop is correct and necessary (no hardware atomic f64 add exists). Spice does not provide an alternative. Documented in `src/histogram.zig` module doc with full rationale covering retry behavior, `spinLoopHint()`, and expected contention characteristics. |
| Monotonic ordering used everywhere without justification | **Closed (documented)** | All atomics used `.monotonic` | Monotonic is correct: metric fields are independent scalars with no cross-field invariants. Documented in `src/histogram.zig`, `src/counter.zig`, and `src/gauge.zig` module docs explaining why stronger ordering would add overhead without improving correctness. |
| No concurrent snapshot/export path | **Closed** | `writePrometheus` held mutex during capture | Registry RwLock allows concurrent snapshots via shared lock. `parallelSnapshot(pool)` further parallelizes capture across metric types. `writePrometheus` still uses sequential `snapshot()` but no longer blocks metric registrations (shared lock). |
| Test concurrency uses raw thread spawn | **Closed (partial)** | Unit tests used `std.Thread.spawn` | Integration tests now include spice-based concurrent counter and parallel snapshot tests. Unit tests in `counter.zig`, `gauge.zig`, `histogram.zig` retain raw threads for correctness verification (guarantees true concurrent execution regardless of pool scheduling). |

## Tests And Benchmarks Carried Over

| Original test / benchmark | Status | Coverage provided |
|---|---|---|
| Core metric and snapshot behavior | **Ported** | 47 unit tests covering Counter, Gauge, Histogram, Timer, Snapshot, Registry, Prometheus export |
| End-to-end smoke coverage (MET-TEST-002) | **Ported** | 6 integration tests including full smoke test with all metric types and Prometheus export |
| Metrics registry variance benchmark (MET-TEST-003) | **Ported** | `benchmarks/variance.zig` -- Counter throughput, Histogram observation, Mixed workload, Parallel snapshot (all via spice ThreadPool) |
| Spice integration tests | **New** | 2 integration tests: concurrent counter updates via spice fork/join, parallel snapshot capture verification |
| HTTP server test | **Stays in Geode** | Not applicable -- server transport is outside this library's boundary |

## Proposed Public API

Implemented public surface:

- `Counter` -- thread-safe monotonically increasing counter
- `Gauge` -- thread-safe bidirectional gauge
- `Histogram` -- configurable bucket histogram with atomic sum
- `Timer` -- duration measurement wrapping Histogram
- `Snapshot` / `MetricSnapshot` / `MetricKind` -- point-in-time metric captures
- `Registry` -- instance-based metric lifecycle management with RwLock
- `Registry.parallelSnapshot(pool)` -- spice-accelerated snapshot capture
- `writePrometheus` -- Prometheus text exposition format export
- `default_buckets` / `default_timer_buckets` -- standard bucket configurations
- `spice` -- re-exported structured concurrency module

The HTTP endpoint/server layer remains a separate adapter in Geode.

## Acceptance Criteria

- [x] This repo exposes one coherent metrics API, not three competing ones.
- [x] No global singletons remain in the extracted core.
- [x] Prometheus export remains supported.
- [x] The variance benchmark and smoke test still pass against the extracted core.
- [x] `spice` dependency is added and used for structured concurrency.
- [x] Registry contention is reduced (RwLock with shared/exclusive split).
- [x] Snapshot/export path does not block metric producers (shared lock + parallel capture).
- [x] Memory ordering choices are documented and verified.
