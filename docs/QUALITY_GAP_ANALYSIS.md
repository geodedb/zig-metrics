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
| Q-006 | Medium | Example `basic.zig` is entirely commented-out stub | **Reopened** | Re-classified as still-open: the rewrite documented usage in comments but `main()` body remains commented-out (`examples/basic.zig:26-52`) and the file is not wired into the build. Tracked going forward as **Q-022**. |
| Q-007 | Medium | Registry has 4x duplicated registration patterns | **Won't Do** | Zig's type system doesn't support the generic abstraction needed to deduplicate without sacrificing clarity. Each method has distinct error handling. Acceptable for 4 methods. |
| Q-008 | Medium | `prometheus.zig` bypasses public `getBucketCount()` API | **Closed** | Rewrote Prometheus exporter to use snapshot-first approach. No longer accesses histogram internals directly. |
| Q-009 | Low | CODEOWNERS uses template placeholder | **Closed** | Replaced `@your-username` with `@benjiv`. |
| Q-010 | Low | No code coverage measurement | **Won't Do** | No mature Zig code coverage tool available. Zig test runner does not emit coverage data natively. Monitor for future tooling. |
| Q-011 | Low | CI doesn't compile examples or benchmarks | **Reopened** | Original "Won't Do" rationale ("benchmarks are validated locally") is invalidated: the benchmarks do **not** build (cross-ref **GAP-005**, gap domain). Uncompiled doc snippets also let Q-018 (README) regress undetected. Should be reconsidered once GAP-005 restores the benches; example-compile is covered by Q-022. |
| Q-012 | Low | REQUIREMENTS.md documentation requirements lack IDs | **Won't Do** | Low impact. IDs were assigned in GitLab issues (#11-#13) during audit. |
| Q-013 | Low | README claims Windows support without CI validation | **Closed** | Updated README to say "Windows cross-compiles but is not CI-validated". |
| Q-014 | Low | No fuzz testing for CAS loop | **Won't Do** | Future improvement. CAS loop is standard pattern; covered by concurrent tests. |
| Q-015 | High | Cross-type metric name collision: counter "foo" and gauge "foo" could coexist, producing invalid Prometheus output | **Closed** | Added `nameInUse()` helper checking all 4 maps. All registration methods now reject names already used by any metric type. Tests added. |
| Q-016 | Medium | Prometheus HELP text not escaped: backslash characters could corrupt parser | **Closed** | Extended `validateHelp()` to reject backslash (`\\`) alongside newlines. Test added. |
| Q-017 | Low | validateHelp did not reject carriage return (`\\r`) | **Closed** | Extended `validateHelp()` to reject `\\r`. Test added. |

## Summary (Open Findings, Q-018+)

Open quality findings from the Phase 4 audit, scored with `PriorityScore = Impact(1-5) * Likelihood(1-5) * 4`.

| Severity | Count | IDs |
|---|---|---|
| High | 2 | Q-018, Q-019 |
| Medium | 4 | Q-020, Q-023, Q-024, Q-027 |
| Low | 6 | Q-021*, Q-022, Q-025, Q-026, Q-028, Q-029 |

`*` Q-021 (CHANGELOG) is scored Low-Medium (PriorityScore 40); filed as an issue because it is doc-facing and release-blocking-adjacent. Reopened legacy items: **Q-006 -> Q-022**, **Q-011** (depends on GAP-005).

**Top 5 open risks (by PriorityScore):** Q-018 (80), Q-019 (60), Q-020 / Q-023 / Q-027 (48 each).

Dedup / ownership notes (NOT tracked here — owned elsewhere): broken benches = **GAP-005** (gap domain); name/help use-after-free = **S-017** (security); `RwLockShim` concurrency = **P-016** (perf); Timer monotonic-clock fix = **P-011** (perf, but the shared-helper refactor lives in Q-023); README dependency/claims also cross-ref **GAP-009**.

## Open Findings (stack-ranked by PriorityScore)

| Rank | Severity | PriorityScore | Category | Finding | Component | Evidence | Issue | Fix Summary | Owner | Effort | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | High | 80 | docs | README Quick Start does not compile on Zig 0.16 (pre-0.16 APIs) | README | `README.md:47,68-69`; correct forms at `src/root.zig:17`, `src/prometheus.zig:78-79` | [#22](https://gitlab.com/devnw/zig/metrics/-/issues/22) | Replace `GeneralPurposeAllocator`/`std.io.fixedBufferStream` with `DebugAllocator`/`std.Io.Writer = .fixed`; ideally compile snippet in CI | @benjiv | S | Open |
| 2 | High | 60 | docs | README "Zero Dependencies" claim is false | README | `README.md:10` vs `build.zig.zon:6-10`; re-export `src/root.zig:71` | [#24](https://gitlab.com/devnw/zig/metrics/-/issues/24) | Restate as "minimal deps: stdlib + thread-pool (parallelSnapshot only)" | @benjiv | S | Open |
| 3 | Medium | 48 | maintainability | Version constant drift; test pins stale value | root / tests | `src/root.zig:36` "0.1.0" vs `build.zig.zon:3` "0.1.3"; `tests/integration.zig:125` | [#25](https://gitlab.com/devnw/zig/metrics/-/issues/25) | Single-source via `build_options`; assert non-literal in test (appsec L2) | @benjiv | M | Open |
| 4 | Medium | 48 | maintainability | `nanoTimestampCompat` duplicated identically in 5 files | registry/snapshot/timer/benches | `src/snapshot.zig:12`, `src/registry.zig:38`, `src/timer.zig:14`, `benchmarks/variance.zig:22`, `benchmarks/scale_bench.zig:26` | [#33](https://gitlab.com/devnw/zig/metrics/-/issues/33) | Extract `src/compat.zig` with wall + monotonic variants; Timer uses monotonic (P-011) | @benjiv | M | Open |
| 5 | Medium | 48 | tests | Test gaps: shard-count off-by-one, gauge net-zero, no above-max bucket | tests/registry/gauge/histogram | `tests/integration.zig:240-244` vs `src/registry.zig:436-438`; `src/gauge.zig:107-137`; `src/histogram.zig:115-127`, `src/prometheus.zig:64` | [#37](https://gitlab.com/devnw/zig/metrics/-/issues/37) | Assert exact task count; asymmetric inc/dec; pin +Inf/_count routing | @benjiv | M | Open |
| 6 | Medium | 40 | docs | CHANGELOG frozen at template; missing 0.1.1-0.1.3 entries | CHANGELOG | `CHANGELOG.md:18,26-27`; tags v0.1.0..v0.1.3 | [#26](https://gitlab.com/devnw/zig/metrics/-/issues/26) | Add dated sections for each release; adopt `cz changelog` | @benjiv | S | Open |
| 7 | Medium | 36 | maintainability | `RegistryError` duplicates `Histogram.BucketError` + 2 identity switches | registry | `src/registry.zig:51-66,231-239,264-272`; `src/histogram.zig:62-69` | [#34](https://gitlab.com/devnw/zig/metrics/-/issues/34) | `RegistryError = error{...} \|\| Histogram.BucketError`; drop switches | @benjiv | S | Open |
| 8 | Low | 32 | ci-cd | Pre-commit hooks dirty the tree (MD040, ruff-format, .cz.yaml) | repo hygiene | working tree: `.cz.yaml`, `CONTRIBUTING.md`, `scripts/detect_diamond_deps.py`, et al. already auto-fixed | doc-only | Commit the already-applied hook auto-fixes (outside this agent's edit scope) | @benjiv | S | Open |
| 9 | Low | 24 | docs | Example `basic.zig` is a commented-out stub, not in build | examples | `examples/basic.zig:9,26-52`; no `example` step in `build.zig` | doc-only (reopens Q-006) | Make `main()` runnable; add `zig build example` step | @benjiv | S | Open |
| 10 | Low | 24 | maintainability | `captureHistSlice`/`captureTimerSlice` near-duplicates | registry | `src/registry.zig:599-657` | doc-only | Unify via a generic helper parameterized on `kind` + hist accessor | @benjiv | S | Open |
| 11 | Low | 24 | maintainability | `parallelSnapshot` is ~250 lines | registry | `src/registry.zig:339-588` | doc-only | Extract shard-context types + per-shard helpers | @benjiv | M | Open |
| 12 | Low | 24 | api-contract | API surface papercuts (Timer accessors, deinit doc, lock-dep comment) | timer/registry | `src/timer.zig:68-75`; Counter/Gauge no "no deinit" note; `src/registry.zig:184` | doc-only | Add `Timer.getBucketCount`/`name`; document no-deinit + nameInUse lock dependency | @benjiv | S | Open |

## Findings by Category

- **docs**: Q-018 (80), Q-019 (60), Q-021 (40), Q-022 (24)
- **maintainability**: Q-020 (48), Q-023 (48), Q-024 (36), Q-025 (24), Q-026 (24)
- **tests**: Q-027 (48)
- **api-contract**: Q-029 (24)
- **ci-cd / cleanup**: Q-028 (32)

## Roadmap

**Quick wins (< 1 day)** — Q-018 (README compile fix), Q-019 (deps claim), Q-021 (CHANGELOG), Q-024 (error-set compose), Q-028 (commit hook auto-fixes), Q-022 (wire example into build).

**Medium (1-5 days)** — Q-020 (single-source version via `build_options` + test), Q-023 (extract `src/compat.zig`, coordinate Timer monotonic with P-011), Q-027 (three test gaps), Q-025/Q-026 (registry refactors), Q-029 (API accessors + docs).

**Strategic (> 5 days)** — None standalone in this quality batch. Q-011 (CI compile examples/benches) is gated on **GAP-005** restoring the benchmarks; revisit once that lands so the suite, examples, and README snippets are all CI-compiled together.

## Scoring Reference

`PriorityScore = Impact(1-5) * Likelihood(1-5) * 4`. All Q-018..Q-029 findings are `confidence::confirmed` (verified against the code at the cited lines). GitLab issues filed for Medium+ findings (Q-018..Q-021, Q-023, Q-024, Q-027); Low findings (Q-022, Q-025, Q-026, Q-028, Q-029) are tracked doc-only per the quality framework.
