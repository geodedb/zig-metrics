# Requirements

Last updated: 2026-03-21

## Functional Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| MET-REQ-001 | The library SHALL expose counters, gauges, histograms, timers, and snapshots. | `src/monitoring/metrics.zig:5`, `:225`, `:307`, `:356` |
| MET-REQ-002 | The library SHALL expose a registry or collector lifecycle API. | `src/monitoring/registry.zig:49`, `:55`, `:59`, `src/monitoring/prometheus.zig:233`, `:249` |
| MET-REQ-003 | The library SHALL expose Prometheus export support. | `src/monitoring/prometheus.zig:147`, `:376`, `src/monitoring/registry.zig:59`, `src/monitoring/metrics.zig:356` |
| MET-REQ-004 | The core package SHALL NOT depend on Geode-global registries or collectors. | `src/monitoring/registry.zig:85`, `src/monitoring/metrics_server.zig:139` |
| MET-REQ-005 | The initial extraction SHALL keep HTTP endpoint/server wiring outside the core package. | `src/monitoring/metrics_server.zig:10`, `:50`, `:125` |

## Packaging Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| MET-PKG-001 | The three current metrics surfaces SHALL be consolidated before a public API is declared stable. | `src/monitoring/metrics.zig:5`, `src/monitoring/prometheus.zig:233`, `src/monitoring/registry.zig:49` |
| MET-PKG-002 | The implementation SHALL build on the pinned Zig toolchain. | `metrics.zig` standalone review failure |

## Test Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| MET-TEST-001 | Port the core metrics unit tests. | `src/monitoring/metrics.zig:405`, `:415`, `:425`, `:438`, `:452`, `:464`, `:474`, `:484`, `:503`, `:510`, `:519`, `:527`, `:537`, `:551`, `:565`, `:577`, `:588`, `:601`, `:608` |
| MET-TEST-002 | Preserve end-to-end smoke coverage. | `tests/canary_metrics_smoke.zig:3` |
| MET-TEST-003 | Preserve the current variance benchmark reference. | `benchmarks/benchmark_monitoring_metrics_variance.zig:85`, `:138` |

## Documentation Requirements

- Document the chosen collector/registry model.
- Document Prometheus export behavior.
- Document that the HTTP server is an adapter, not part of the core package.

## Migration Requirements

1. Consolidate the collector/registry/exporter implementations.
2. Remove global singletons.
3. Keep `metrics_server.zig` in Geode or split it into a follow-on adapter package.
