# Quality Gap Analysis

Last updated: 2026-06-11

## Closed / Resolved Findings (Q-001..Q-017)

| ID | Severity | Finding | Status | Resolution |
|---|---|---|---|---|
| Q-001 | Critical | Prometheus histogram double-counting bug | **Closed** | Changed `observe()` to per-bucket storage (break after first match). Prometheus exporter accumulates cumulative counts at export time. Per-bucket assertions added. |
| Q-002 | High | Timers excluded from snapshots | **Closed** | Added `.timer` to `MetricKind`, pass timers map to `captureSnapshot()`, timer snapshot test added. |
| Q-003 | High | README Quick Start shows non-existent `metrics.init()` API | **Closed** | Replaced with real `Registry.init(allocator)` example showing counter, gauge, histogram, and Prometheus export. |
| Q-004 | Medium | No Prometheus per-bucket value assertions in tests | **Closed** | Added `"Prometheus: histogram per-bucket cumulative output"` test asserting individual bucket le values. |
| Q-005 | Medium | No concurrent histogram test | **Closed** | Added `"Histogram: concurrent observations"` test with 4 threads x 10K iterations verifying atomic correctness. |
| Q-006 | Medium | Example `basic.zig` is entirely commented-out stub | **Closed** | Closed via Q-022 (commit 93c029b): `examples/basic.zig` fully rewritten with a runnable `main()`, wired into `build.zig` as the `example` step, and compiled in CI. |
| Q-007 | Medium | Registry has 4x duplicated registration patterns | **Won't Do** | Zig's type system doesn't support the generic abstraction needed to deduplicate without sacrificing clarity. Each method has distinct error handling. Acceptable for 4 methods. |
| Q-008 | Medium | `prometheus.zig` bypasses public `getBucketCount()` API | **Closed** | Rewrote Prometheus exporter to use snapshot-first approach. No longer accesses histogram internals directly. |
| Q-009 | Low | CODEOWNERS uses template placeholder | **Closed** | Replaced `@your-username` with `@benjiv`. |
| Q-010 | Low | No code coverage measurement | **Won't Do** | No mature Zig code coverage tool available. Zig test runner does not emit coverage data natively. Monitor for future tooling. |
| Q-011 | Low | CI doesn't compile examples or benchmarks | **Closed** | GAP-005 closed (commit 83c59f0): benchmarks compile on Zig 0.16 and CI gains `bench-check` job. Q-022 closed (commit 93c029b): example wired into build and CI. Both blockers resolved. |
| Q-012 | Low | REQUIREMENTS.md documentation requirements lack IDs | **Won't Do** | Low impact. IDs were assigned in GitLab issues (#11-#13) during audit. |
| Q-013 | Low | README claims Windows support without CI validation | **Closed** | Updated README to say "Windows cross-compiles but is not CI-validated". |
| Q-014 | Low | No fuzz testing for CAS loop | **Won't Do** | Future improvement. CAS loop is standard pattern; covered by concurrent tests. |
| Q-015 | High | Cross-type metric name collision: counter "foo" and gauge "foo" could coexist, producing invalid Prometheus output | **Closed** | Added `nameInUse()` helper checking all 4 maps. All registration methods now reject names already used by any metric type. Tests added. |
| Q-016 | Medium | Prometheus HELP text not escaped: backslash characters could corrupt parser | **Closed** | Extended `validateHelp()` to reject backslash (`\\`) alongside newlines. Test added. |
| Q-017 | Low | validateHelp did not reject carriage return (`\\r`) | **Closed** | Extended `validateHelp()` to reject `\\r`. Test added. |

## Summary (Q-018..Q-029 — all closed 2026-06-11)

All open quality findings Q-018..Q-029 were closed in the 2026-06-11 gap-closure sprint. Legacy reopened items Q-006 and Q-011 were also closed. No open quality findings remain.

| Severity | Count | IDs | Status |
|---|---|---|---|
| High | 2 | Q-018, Q-019 | Closed |
| Medium | 4 | Q-020, Q-023, Q-024, Q-027 | Closed |
| Low | 6 | Q-021, Q-022, Q-025, Q-026, Q-028, Q-029 | Closed |

## Closed Findings (Q-018..Q-029)

| Rank | Severity | PriorityScore | Category | Finding | Component | Commit | Issue | Status |
|---|---|---|---|---|---|---|---|---|
| 1 | High | 80 | docs | README Quick Start does not compile on Zig 0.16 (pre-0.16 APIs) | README | b6c56a6 | [#22](https://gitlab.com/devnw/zig/metrics/-/issues/22) | **Closed** |
| 2 | High | 60 | docs | README "Zero Dependencies" claim is false | README | b6c56a6 | [#24](https://gitlab.com/devnw/zig/metrics/-/issues/24) | **Closed** |
| 3 | Medium | 48 | maintainability | Version constant drift; test pins stale value | root / tests | 3106587 | [#25](https://gitlab.com/devnw/zig/metrics/-/issues/25) | **Closed** |
| 4 | Medium | 48 | maintainability | `nanoTimestampCompat` duplicated identically in 5 files | registry/snapshot/timer/benches | 65e28ac | [#33](https://gitlab.com/devnw/zig/metrics/-/issues/33) | **Closed** |
| 5 | Medium | 48 | tests | Test gaps: shard-count off-by-one, gauge net-zero, no above-max bucket | tests/registry/gauge/histogram | 8533c76 | [#37](https://gitlab.com/devnw/zig/metrics/-/issues/37) | **Closed** |
| 6 | Medium | 40 | docs | CHANGELOG frozen at template; missing 0.1.1-0.1.3 entries | CHANGELOG | 0f6c03f | [#26](https://gitlab.com/devnw/zig/metrics/-/issues/26) | **Closed** |
| 7 | Medium | 36 | maintainability | `RegistryError` duplicates `Histogram.BucketError` + 2 identity switches | registry | 1ac218b | [#34](https://gitlab.com/devnw/zig/metrics/-/issues/34) | **Closed** |
| 8 | Low | 32 | ci-cd | Pre-commit hooks dirty the tree (MD040, ruff-format, .cz.yaml) | repo hygiene | f98e9bd + 87b0403 | doc-only | **Closed** |
| 9 | Low | 24 | docs | Example `basic.zig` is a commented-out stub, not in build | examples | 93c029b | doc-only (Q-006/Q-022) | **Closed** |
| 10 | Low | 24 | maintainability | `captureHistSlice`/`captureTimerSlice` near-duplicates | registry | 1066c72 | doc-only | **Closed** |
| 11 | Low | 24 | maintainability | `parallelSnapshot` is ~250 lines | registry | 1066c72 | doc-only | **Closed** |
| 12 | Low | 24 | api-contract | API surface papercuts (Timer accessors, deinit doc, lock-dep comment) | timer/registry | 1066c72 | doc-only | **Closed** |

### Resolution notes

- **Q-018** (b6c56a6): README Quick Start ported to Zig 0.16 APIs (`DebugAllocator`, `std.Io.Writer = .fixed`); example compiled in CI via Q-022.
- **Q-019** (b6c56a6): "Zero Dependencies" claim corrected to "Minimal Dependencies: stdlib + thread-pool (parallelSnapshot only)".
- **Q-020** (3106587): version flows `build.zig.zon` → `build_options` → `metrics.version`; integration test asserts injected value, not a literal.
- **Q-021** (0f6c03f): CHANGELOG backfilled with dated sections for v0.1.0..v0.1.3.
- **Q-022** (93c029b): `examples/basic.zig` fully runnable, wired as `zig build example`, compiled in CI. Closes legacy Q-006.
- **Q-023** (65e28ac): `src/compat.zig` extracted; five inline `nanoTimestampCompat` copies removed.
- **Q-024** (1ac218b): `RegistryError` now `error{...} || Histogram.BucketError`; identity switches removed.
- **Q-025** (1066c72): `captureHistSlice`/`captureTimerSlice` unified via generic helper.
- **Q-026** (1066c72): `parallelSnapshot` shard-context types and per-shard helpers extracted.
- **Q-027** (8533c76): exact shard-count assertion, asymmetric gauge race test, `+Inf`/`_count` routing test.
- **Q-028** (f98e9bd + 87b0403): pre-commit hook auto-fixes committed; MD040 fenced-block language annotations applied.
- **Q-029** (1066c72): `Timer.getBucketCount`/`name` accessors added; no-deinit notes and `nameInUse` lock-dependency comment added.
- **Q-011** (GAP-005 + Q-022): both blockers resolved; CI now compiles examples (`bench-check` job) and the example step.

## Closed Findings (Round-2 audit — Q-030, closed 2026-06-11)

| Rank | Severity | PriorityScore | Category | Finding | Component | Commit | Issue | Status |
|---|---|---|---|---|---|---|---|---|
| 1 | Low | 24 | maintainability | Typed ZON manifest import in `build.zig` hard-errors on undeclared dependency fields; otel re-enable path would hit a confusing compile error pointing at the .zon file | build.zig | this commit | [#41](https://gitlab.com/devnw/zig/metrics/-/issues/41) | **Closed** |

### Resolution notes (round 2)

- **Q-030** (this commit, 2026-06-11): warning comment added directly above the `dependencies: struct {` sub-struct in `build.zig` stating every dependency in `build.zig.zon` MUST be declared there, and that re-adding `.otel` (or any new dep) to the manifest requires updating the struct. No behavior change; `zig build check` / full test suite green.

## Roadmap

No open roadmap items. All Q-018..Q-029 sprint items closed.

## Scoring Reference

`PriorityScore = Impact(1-5) * Likelihood(1-5) * 4`. All Q-018..Q-029 findings are `confidence::confirmed` (verified against the code at the cited lines). GitLab issues filed for Medium+ findings (Q-018..Q-021, Q-023, Q-024, Q-027); Low findings (Q-022, Q-025, Q-026, Q-028, Q-029) are tracked doc-only per the quality framework.
