# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.8] - 2026-10-11

### Changed

- Converge on thread-pool v0.2.8 (Renovate dependency refresh).
- CI: run default jobs on Linux runners; create GitLab Releases with the job token.

## [0.1.7] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5 (GAP-0838 diamond sync).

## [0.1.5] - 2026-06-11

### Added

- Q-022: runnable example wired into `build.zig` and CI (`examples/` directory)
- S-019: optional `max_metrics` cardinality cap on the registry
- Q-027: exact shard-count assertions, asymmetric gauge race test, and +Inf bucket routing tests

### Changed

- P-014: replace ad-hoc locking with `std.Io.RwLock` reader-writer lock for improved concurrency
- Q-024: compose `RegistryError` from `Histogram.BucketError` for cleaner error-set design
- Q-020: single-source version from `build.zig.zon` — no more duplicate version strings

### Fixed

- S-017: registry now copies name/help strings; no dangling caller slices
- S-018: `parallelSnapshot` rejects partial batch submissions (all-or-nothing guarantee)
- S-020: shortest round-trip floats for `le` labels and `_sum` output
- P-011/Q-023: monotonic timer clock via shared compat module
- P-012/P-013: benchmarks measure `ReleaseFast` code with `smp_allocator`
- GAP-005: benchmarks compile on Zig 0.16 via `std.process.Init`
- GAP-008/GAP-009/Q-018/Q-019: README accuracy fixes (build instructions, API docs, feature descriptions)

## [0.1.4] - 2026-06-11

### Changed

- Converge `thread_pool` onto v0.2.5 to resolve GAP-0838 diamond dependency sync

## [0.1.3] - 2026-05-02

### Fixed

- Hardcode `enabled=false` in the OTel seam to dodge Zig 0.16 `build_options` deduplication bug

## [0.1.2] - 2026-05-02

### Changed

- Re-pin sibling dependencies to their newly tagged versions

## [0.1.1] - 2026-05-02

### Changed

- Re-pin sibling dependencies to their newly tagged versions

## [0.1.0] - 2026-05-02

### Added

- Core metrics primitives: counters, gauges, histograms, and timers
- Instance-based registry with configurable `snapshot_chunk_size`
- Parallel snapshot via `thread_pool` with nested fan-out for large histogram/timer counts
- Prometheus text-format exporter
- OpenTelemetry build flag (`-Dwith_otel`) with a no-op seam when disabled
- Diamond-dependency detector script and pre-commit hook
- CI pipeline for Zig 0.16 on company-tagged Linux runners
- Scale benchmark suite

[Unreleased]: https://gitlab.com/devnw/zig/metrics/-/compare/v0.1.5...HEAD
[0.1.5]: https://gitlab.com/devnw/zig/metrics/-/compare/v0.1.4...v0.1.5
[0.1.4]: https://gitlab.com/devnw/zig/metrics/-/compare/v0.1.3...v0.1.4
[0.1.3]: https://gitlab.com/devnw/zig/metrics/-/compare/v0.1.2...v0.1.3
[0.1.2]: https://gitlab.com/devnw/zig/metrics/-/compare/v0.1.1...v0.1.2
[0.1.1]: https://gitlab.com/devnw/zig/metrics/-/compare/v0.1.0...v0.1.1
[0.1.0]: https://gitlab.com/devnw/zig/metrics/-/releases/v0.1.0
