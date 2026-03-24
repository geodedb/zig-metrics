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
