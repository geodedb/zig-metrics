# Resolved Gap Items

Items moved from `GAP_ANALYSIS.md` after verification.

## GAP-001: Three overlapping metrics surfaces

- **Status:** Closed
- **Closed:** 2026-03-23
- **Resolution:** Consolidated into modular single-purpose files (`counter.zig`, `gauge.zig`, `histogram.zig`, `timer.zig`, `snapshot.zig`, `registry.zig`, `prometheus.zig`) with one public API surface in `root.zig`.
- **Evidence:** 47 unit tests + 6 integration tests pass. All types accessible via `@import("metrics")`.

## GAP-002: Global singleton state

- **Status:** Closed
- **Closed:** 2026-03-23
- **Resolution:** `Registry` is fully instance-based. No module-level mutable state anywhere in the library.
- **Evidence:** Integration test `no globals: two registries are fully independent` confirms two registries do not share state.

## GAP-003: Zig drift in metrics.zig

- **Status:** Closed
- **Closed:** 2026-03-23
- **Resolution:** Implementation written for Zig 0.15.x from scratch (historical, as of extraction). At the time it used `std.atomic.Value`, `std.Thread.Mutex`, and `std.fs.File.deprecatedWriter`. Superseded by the Zig 0.16.0 migration: the current toolchain is Zig 0.16.0 and the registry lock is `std.Io.RwLock` (P-014).
- **Evidence:** At closure (2026-03-23), all tests passed in Debug, ReleaseSafe, and ReleaseFast modes on Zig 0.15.2; the suite now passes on Zig 0.16.0.

## GAP-004: metrics_server.zig mixes transport concerns

- **Status:** Closed
- **Closed:** 2026-03-23
- **Resolution:** HTTP server transport is not included. `writePrometheus(registry, writer)` accepts any writer type, allowing Geode (or any consumer) to wire their own transport.
- **Evidence:** No HTTP/server/socket imports exist in the library source.

## README Quick Start used non-existent metrics.init() API [RESOLVED]

- **Issue:** [#14](https://gitlab.com/devnw/zig/metrics/-/issues/14) (closed)
- **Category:** Bug
- **Status:** Closed
- **Closed:** 2026-06-11
- **Resolution:** The README Quick Start example was rewritten to use the real instance-based API. It now constructs a GeneralPurposeAllocator, creates an instance-based `Registry`, registers a counter/gauge/histogram, and exports via `metrics.writePrometheus(&reg, fbs.writer())`. No `metrics.init(.{...})` call remains.
- **Evidence:** README.md:52 -- `var reg = metrics.Registry.init(allocator);` (full block README.md:42-70); matches src/root.zig public API and integration tests.

## README claimed Windows support but CI does not test Windows targets [RESOLVED]

- **Issue:** [#15](https://gitlab.com/devnw/zig/metrics/-/issues/15) (closed)
- **Category:** Bug
- **Status:** Closed
- **Closed:** 2026-06-11
- **Resolution:** The Cross-Platform feature line was rescoped to state Windows is cross-compile-only and not CI-validated, removing the overstated platform-coverage claim. Now consistent with the `.gitlab-ci.yml` `test-cross-build` job (linux + macos only).
- **Evidence:** README.md:12 -- `- **Cross-Platform**: Linux, macOS support (Windows cross-compiles but is not CI-validated)`.

## GAP-005: Benchmarks fail to compile on Zig 0.16 (std.process.args removed)

- **Issue:** [#19](https://gitlab.com/devnw/zig/metrics/-/issues/19) (closed)
- **Category:** Bug
- **Severity:** High
- **Status:** Closed
- **Closed:** 2026-06-11
- **Resolution:** Ported both benchmark entry points (`benchmarks/scale_bench.zig` and `benchmarks/compare.zig`) from the removed `std.process.args()` to the Zig 0.16 `std.process.Init`-based args API. Added a `bench-check` compile-only build step and CI job so benchmark bit-rot fails the pipeline.
- **Evidence:** commit 83c59f0 (`fix: close GAP-005 - benchmarks compile on Zig 0.16 via std.process.Init`). `bench-save`/`bench-baseline`/`bench-compare`/`bench-check` Makefile targets all operational. Cross-ref: perf gap P-010 re-assessed Closed after baseline re-measured (commit 90827a3).

## GAP-006: No prose docs for registry lifecycle / parallelSnapshot

- **Issue:** [#11](https://gitlab.com/devnw/zig/metrics/-/issues/11) (MET-DOC-001, closed)
- **Category:** Docs
- **Severity:** Medium
- **Status:** Closed
- **Closed:** 2026-06-11
- **Resolution:** Added `docs/registry.md` documenting the Registry API: init/deinit lifecycle, memory ownership (name/help duped into registry allocator since S-017), RwLock shared/exclusive semantics, and the `parallelSnapshot(pool)` parallel snapshot path. `docs/README.md` expanded beyond the 18-line stub.
- **Evidence:** commits c2ad77e + 0449169 (`docs: close GAP-006/GAP-007 - registry lifecycle and Prometheus export docs`). Acceptance criteria all met: lifecycle, thread-safety, memory ownership, and `parallelSnapshot` documented.

## GAP-007: No prose docs for Prometheus export behavior

- **Issue:** [#12](https://gitlab.com/devnw/zig/metrics/-/issues/12) (MET-DOC-002, closed)
- **Category:** Docs
- **Severity:** Medium
- **Status:** Closed
- **Closed:** 2026-06-11
- **Resolution:** Added `docs/prometheus.md` documenting the snapshot-then-write flow, output format structure (HELP/TYPE lines, histogram bucket/`_sum`/`_count`, text exposition 0.0.4), empty-registry behavior, and `writePrometheus` usage examples.
- **Evidence:** commits c2ad77e + 0449169 (`docs: close GAP-006/GAP-007`; fix writer-type claims per review). All acceptance criteria met.

## GAP-008: README missing writer-pattern / BYO-HTTP section

- **Issue:** [#13](https://gitlab.com/devnw/zig/metrics/-/issues/13) (MET-DOC-003, closed)
- **Category:** Docs
- **Severity:** Low
- **Status:** Closed
- **Closed:** 2026-06-11
- **Resolution:** Added "Exporting over HTTP (bring your own transport)" section to README.md stating the library ships no HTTP server, documenting the writer pattern, and providing an example wiring `writePrometheus` to an HTTP handler. Also added cardinality guidance note.
- **Evidence:** commit b6c56a6 (`docs: close GAP-008/GAP-009/Q-018/Q-019 - README accuracy batch`). README now explicitly states transport-agnostic design and shows the writer pattern.

## GAP-009: README version claims stale (badge / install URL / Requirements)

- **Issue:** [#20](https://gitlab.com/devnw/zig/metrics/-/issues/20) (closed)
- **Category:** Docs
- **Severity:** Low
- **Status:** Closed
- **Closed:** 2026-06-11
- **Resolution:** Updated README.md badge to `Zig-0.16.0+`, install URL from v0.1.0 to v0.1.3, and Requirements from `Zig 0.15.1 or later` to `Zig 0.16.0 or later`. All README version claims now consistent with `build.zig.zon`.
- **Evidence:** commit b6c56a6 (`docs: close GAP-008/GAP-009/Q-018/Q-019 - README accuracy batch`). Cross-ref: in-source version-constant drift (Q-020) closed separately by commit 3106587.

## GAP-010: build.zig.zon version stale at 0.1.3 while v0.1.4 is tagged

- **Issue:** [#38](https://gitlab.com/devnw/zig/metrics/-/issues/38) (closed)
- **Category:** Bug
- **Severity:** Low
- **Status:** Closed
- **Closed:** 2026-06-11
- **Resolution:** Bumped `build.zig.zon` `.version` from `"0.1.3"` to `"0.1.4"`, matching the existing `v0.1.4` git tag and the `[0.1.4]` CHANGELOG section per repo release convention. No other edits needed: `src/root.zig` derives `metrics.version` from the manifest via build_options (Q-020).
- **Evidence:** this commit. `zig build test-integration --summary all` passes (11/11) including `version matches build manifest`, with the generated build options carrying `.version = "0.1.4"`.

## GAP-011: README install URL pins v0.1.3 instead of v0.1.4

- **Issue:** [#39](https://gitlab.com/devnw/zig/metrics/-/issues/39) (closed)
- **Category:** Bug
- **Severity:** Low
- **Status:** Closed
- **Closed:** 2026-06-11
- **Resolution:** Updated the README.md install snippet archive URL from `v0.1.3/metrics-v0.1.3.tar.gz` to `v0.1.4/metrics-v0.1.4.tar.gz`.
- **Evidence:** this commit. README.md:29; `grep -n "0\.1\.3" README.md` returns no matches.

## GAP-012: Stale Zig 0.15.2 / std.Thread.Mutex claims in gap-analysis docs

- **Issue:** [#40](https://gitlab.com/devnw/zig/metrics/-/issues/40) (closed)
- **Category:** Docs
- **Severity:** Low
- **Status:** Closed
- **Closed:** 2026-06-11
- **Resolution:** Annotated the historical extraction-era claims as superseded: `docs/GAP_ANALYSIS.md` Concrete Gaps row now states the Zig 0.15.2 result was at extraction time and the current toolchain is Zig 0.16.0 with `std.Io.RwLock` (P-014); the GAP-003 entry above was likewise reworded to mark `std.Thread.Mutex` / Zig 0.15.x as historical-as-of-extraction, superseded by the 0.16 migration and P-014.
- **Evidence:** this commit. docs/GAP_ANALYSIS.md:46; docs/GAP_ANALYSIS_RESOLVED.md GAP-003 Resolution/Evidence lines.
