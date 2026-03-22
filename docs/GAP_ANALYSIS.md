# GAP Analysis

Last updated: 2026-03-21

Repository status: bootstrapped from `../zig-template`; no Geode code has been moved yet.

## Goal

Create a standalone metrics library from Geode’s monitoring code after consolidating the currently duplicated collector/registry/exporter implementations.

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

| Gap | Evidence | Impact | Required fix |
|---|---|---|---|
| Three overlapping metrics surfaces exist today | `src/monitoring/metrics.zig:5`, `src/monitoring/prometheus.zig:233`, `src/monitoring/registry.zig:49` | No stable public API boundary yet | Consolidate into one coherent collector/registry/exporter model |
| Global singleton state exists | `src/monitoring/registry.zig:85`, `src/monitoring/metrics_server.zig:139` | Makes library embedding and tests harder | Remove globals from the extracted core |
| Standalone review found Zig drift in `metrics.zig` | standalone compile failed during review | Blocks extraction | Update the implementation for the pinned Zig version |
| `metrics_server.zig` mixes transport concerns with metrics | `src/monitoring/metrics_server.zig:10`, `:50`, `:125` | Risks over-extraction | Keep server transport separate or make it an optional adapter package |

## Tests And Benchmarks To Carry Over

| Geode test / benchmark | Coverage provided |
|---|---|
| `src/monitoring/metrics.zig:405`, `:415`, `:425`, `:438`, `:452`, `:464`, `:474`, `:484`, `:503`, `:510`, `:519`, `:527`, `:537`, `:551`, `:565`, `:577`, `:588`, `:601`, `:608` | Core metric and snapshot behavior |
| `src/monitoring/metrics_server.zig:188` | Keep in Geode if the HTTP server stays outside the library |
| `tests/canary_metrics_smoke.zig:3` | End-to-end smoke coverage |
| `benchmarks/benchmark_monitoring_metrics_variance.zig:85`, `:138` | Metrics registry variance benchmark |

## Proposed Public API

Initial public surface should include:

- counters
- gauges
- histograms
- timers
- registry/collector lifecycle
- Prometheus export helpers

The HTTP endpoint/server layer should remain a separate adapter until the core is stable.

## Extraction Plan

1. Consolidate the three overlapping metrics implementations into one model.
2. Remove global singleton state from the core.
3. Port the collector/export/snapshot tests.
4. Keep or separately package the HTTP server adapter.
5. Rewire Geode’s metrics smoke coverage to use this repo.

## Acceptance Criteria

- This repo exposes one coherent metrics API, not three competing ones.
- No global singletons remain in the extracted core.
- Prometheus export remains supported.
- The variance benchmark and smoke test still pass against the extracted core.
