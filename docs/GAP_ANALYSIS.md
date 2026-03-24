# GAP Analysis

Last updated: 2026-03-23

Repository status: core metrics library implemented with consolidated API.

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

## Acceptance Criteria

- [x] This repo exposes one coherent metrics API, not three competing ones.
- [x] No global singletons remain in the extracted core.
- [x] Prometheus export remains supported.
- [x] The variance benchmark and smoke test still pass against the extracted core.
