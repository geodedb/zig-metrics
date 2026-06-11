# GAP Analysis

Last updated: 2026-06-11

Repository status: core metrics library implemented with consolidated API.

## Open Gaps

Functional gaps currently open. Each links to its GitLab issue (source of truth).

### GAP-005: Benchmarks fail to compile on Zig 0.16 (std.process.args removed)

- **Issue:** [#19](https://gitlab.com/devnw/zig/metrics/-/issues/19)
- **Category:** Bug
- **Severity:** High
- **Status:** Open
- **Requirement source:** build.zig.zon:5 (`minimum_zig_version = "0.16.0"`); Makefile bench targets (`bench-save`, `bench-baseline`, `bench-compare`, `scale-bench`)
- **Current state (evidence):**
  - benchmarks/scale_bench.zig:120 -- `var args = std.process.args();`
  - benchmarks/compare.zig:95 -- `var args = std.process.args();`
  - Compile error: `root source file struct 'process' has no member named 'args'`
  - Correct 0.16 pattern in zig-pkg/thread_pool-0.2.5-*/benchmarks/common.zig:67 (`parseOutputArg(allocator, args: std.process.Args)` using `args.toSlice(allocator)`)
- **Why this is a gap:** `std.process.args()` was removed in Zig 0.16, but the package's `minimum_zig_version` is 0.16.0; benchmarks do not build on the supported toolchain.
- **Impact/Risk:** Breaks `make bench-save`/`bench-baseline`/`bench-compare`/`scale-bench`; perf regression gating non-functional; no compile-only bench check in CI to catch it.
- **Recommended fix:** Port both benchmark args parsers to the Zig 0.16 allocator-based `std.process.Args` pattern (mirror thread_pool common.zig:67); add a compile-only benchmark check to CI.
- **Acceptance criteria:** both benchmarks compile and run on Zig 0.16; `make bench-compare` works end-to-end; CI gains a compile-only bench check.
- **Cross-reference:** Same root cause as perf review P-020 -- single issue, tracked here functionally and in the perf gap analysis from the perf angle.

### GAP-006: No prose docs for registry lifecycle / parallelSnapshot

- **Issue:** [#11](https://gitlab.com/devnw/zig/metrics/-/issues/11) (MET-DOC-001)
- **Category:** Docs
- **Severity:** Medium
- **Status:** Open
- **Requirement source:** docs/REQUIREMENTS.md -- Documentation Requirements (document the collector/registry model)
- **Current state (evidence):**
  - docs/README.md is an 18-line stub -- only points at the docs/ directory.
  - Registry lifecycle, thread-safety, snapshot model, and `Registry.parallelSnapshot(pool)` are described only in src/registry.zig doc comments, not in prose docs.
- **Why this is a gap:** The public Registry API exists and is tested, but no user-facing prose documents its lifecycle, ownership, thread-safety, or the spice-accelerated parallel snapshot path.
- **Impact/Risk:** Consumers lack guidance on init/deinit, memory ownership, RwLock guarantees, and when to use `parallelSnapshot`.
- **Recommended fix:** Add a Registry documentation page/section covering lifecycle, thread-safety (RwLock shared/exclusive), memory ownership, and `parallelSnapshot`.
- **Acceptance criteria:** docs describe Registry API + init/deinit lifecycle; thread-safety guarantees documented; memory ownership documented; `parallelSnapshot(pool)` documented; docs/README.md expanded beyond the 18-line stub.

### GAP-007: No prose docs for Prometheus export behavior

- **Issue:** [#12](https://gitlab.com/devnw/zig/metrics/-/issues/12) (MET-DOC-002)
- **Category:** Docs
- **Severity:** Medium
- **Status:** Open
- **Requirement source:** docs/REQUIREMENTS.md -- Documentation Requirements (document Prometheus export behavior)
- **Current state (evidence):**
  - docs/README.md is an 18-line stub; no doc describes the export path.
  - `writePrometheus(registry, writer)` is implemented/tested in src/prometheus.zig, but the snapshot-then-write flow, output format structure (HELP/TYPE lines, histogram bucket/`_sum`/`_count`, text exposition 0.0.4), and empty-registry behavior are undocumented in prose.
- **Why this is a gap:** Export works but consumers have no prose spec/examples for the format or edge cases.
- **Impact/Risk:** Consumers cannot predict output format or empty-registry behavior without reading source.
- **Recommended fix:** Add a Prometheus export documentation section: snapshot-then-write flow, format structure, empty-registry behavior, and `writePrometheus` usage examples.
- **Acceptance criteria:** docs describe export behavior; snapshot-then-write flow documented; output format structure specified (HELP/TYPE, histogram bucket/`_sum`/`_count`); empty-registry behavior documented; `writePrometheus` shown with examples.

### GAP-008: README missing writer-pattern / BYO-HTTP section

- **Issue:** [#13](https://gitlab.com/devnw/zig/metrics/-/issues/13) (MET-DOC-003)
- **Category:** Docs
- **Severity:** Low
- **Status:** Open
- **Requirement source:** docs/REQUIREMENTS.md -- Documentation Requirements (document that the HTTP server is an adapter, not core); docs/GAP_ANALYSIS.md Intended Boundary table
- **Current state (evidence):**
  - README.md has no section explaining the library is transport-agnostic and that `writePrometheus` accepts any writer (BYO-HTTP).
  - The boundary is noted in this doc's Intended Boundary table but not surfaced to users in the README.
- **Why this is a gap:** Consumers have no README guidance on the writer pattern or how to bring their own HTTP transport.
- **Impact/Risk:** Users may assume HTTP serving is built in, or not realize `writePrometheus` accepts any writer.
- **Recommended fix:** Add a README writer-pattern / BYO-HTTP section with an example wiring `writePrometheus` to an HTTP handler.
- **Acceptance criteria:** README states the library does not include HTTP transport; documents the writer pattern; includes an example wiring `writePrometheus` to an HTTP handler.

### GAP-009: README version claims stale (badge / install URL / Requirements)

- **Issue:** [#20](https://gitlab.com/devnw/zig/metrics/-/issues/20)
- **Category:** Docs
- **Severity:** Low
- **Status:** Open
- **Requirement source:** build.zig.zon:3 (`version = "0.1.3"`); build.zig.zon:5 (`minimum_zig_version = "0.16.0"`)
- **Current state (evidence):**
  - README.md:4 -- badge `Zig-0.15.1+` (should be 0.16.0)
  - README.md:24 -- install URL pins `.../archive/v0.1.0/metrics-v0.1.0.tar.gz` (package is 0.1.3)
  - README.md:75 -- Requirements: `Zig 0.15.1 or later` (should be 0.16.0)
  - vs build.zig.zon:3 (`version = 0.1.3`) and build.zig.zon:5 (`minimum_zig_version = 0.16.0`)
- **Why this is a gap:** README advertises Zig 0.15.1 and a v0.1.0 archive while the package requires 0.16.0 and is at 0.1.3.
- **Impact/Risk:** Users on Zig 0.15.1 hit build failures the README implies are supported; the pinned v0.1.0 install URL fetches a stale release. Documentation-only, no runtime impact.
- **Recommended fix:** Update README badge to 0.16.0+, install URL to v0.1.3, and Requirements to Zig 0.16.0 or later.
- **Acceptance criteria:** README Zig badge matches minimum_zig_version (0.16.0); install URL points at v0.1.3; Requirements states Zig 0.16.0 or later; all README version claims consistent with build.zig.zon.
- **Cross-reference:** The in-source version-constant drift at src/root.zig:36 (`pub const version = "0.1.0"`) is tracked separately by the quality review as MQ-003; GAP-009 covers README docs drift only.

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
| Standalone review found Zig drift in `metrics.zig` | **Closed** | standalone compile failed during review | All code compiles and passes tests on Zig 0.15.2 (Debug, ReleaseSafe, ReleaseFast). |
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
