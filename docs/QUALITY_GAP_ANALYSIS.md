# Quality Gap Analysis

Last updated: 2026-03-23

## Findings

| ID | Severity | Finding | Status | Resolution |
|---|---|---|---|---|
| Q-001 | Critical | Prometheus histogram double-counting bug | **Closed** | Changed `observe()` to per-bucket storage (break after first match). Prometheus exporter accumulates cumulative counts at export time. Per-bucket assertions added. |
| Q-002 | High | Timers excluded from snapshots | **Closed** | Added `.timer` to `MetricKind`, pass timers map to `captureSnapshot()`, timer snapshot test added. |
| Q-003 | High | README Quick Start shows non-existent `metrics.init()` API | **Closed** | Replaced with real `Registry.init(allocator)` example showing counter, gauge, histogram, and Prometheus export. |
| Q-004 | Medium | No Prometheus per-bucket value assertions in tests | **Closed** | Added `"Prometheus: histogram per-bucket cumulative output"` test asserting individual bucket le values. |
| Q-005 | Medium | No concurrent histogram test | **Closed** | Added `"Histogram: concurrent observations"` test with 4 threads x 10K iterations verifying atomic correctness. |
| Q-006 | Medium | Example `basic.zig` is entirely commented-out stub | **Closed** | Rewrote with clear usage documentation and pointers to integration tests for working examples. |
| Q-007 | Medium | Registry has 4x duplicated registration patterns | **Won't Do** | Zig's type system doesn't support the generic abstraction needed to deduplicate without sacrificing clarity. Each method has distinct error handling. Acceptable for 4 methods. |
| Q-008 | Medium | `prometheus.zig` bypasses public `getBucketCount()` API | **Closed** | Rewrote Prometheus exporter to use snapshot-first approach. No longer accesses histogram internals directly. |
| Q-009 | Low | CODEOWNERS uses template placeholder | **Closed** | Replaced `@your-username` with `@benjiv`. |
| Q-010 | Low | No code coverage measurement | **Won't Do** | No mature Zig code coverage tool available. Zig test runner does not emit coverage data natively. Monitor for future tooling. |
| Q-011 | Low | CI doesn't compile examples or benchmarks | **Won't Do** | Infrastructure concern. Examples are stubs; benchmarks are validated locally. Can be added to CI later. |
| Q-012 | Low | REQUIREMENTS.md documentation requirements lack IDs | **Won't Do** | Low impact. IDs were assigned in GitLab issues (#11-#13) during audit. |
| Q-013 | Low | README claims Windows support without CI validation | **Closed** | Updated README to say "Windows cross-compiles but is not CI-validated". |
| Q-014 | Low | No fuzz testing for CAS loop | **Won't Do** | Future improvement. CAS loop is standard pattern; covered by concurrent tests. |
| Q-015 | High | Cross-type metric name collision: counter "foo" and gauge "foo" could coexist, producing invalid Prometheus output | **Closed** | Added `nameInUse()` helper checking all 4 maps. All registration methods now reject names already used by any metric type. Tests added. |
| Q-016 | Medium | Prometheus HELP text not escaped: backslash characters could corrupt parser | **Closed** | Extended `validateHelp()` to reject backslash (`\\`) alongside newlines. Test added. |
| Q-017 | Low | validateHelp did not reject carriage return (`\\r`) | **Closed** | Extended `validateHelp()` to reject `\\r`. Test added. |
