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
- **Resolution:** Implementation written for Zig 0.15.x from scratch. Uses current `std.atomic.Value`, `std.Thread.Mutex`, and `std.fs.File.deprecatedWriter` APIs.
- **Evidence:** All tests pass in Debug, ReleaseSafe, and ReleaseFast modes on Zig 0.15.2.

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
