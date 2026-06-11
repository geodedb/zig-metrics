# Security Gap Analysis

Last updated: 2026-06-11

## Attack Surface

- **Type:** In-process library (no network, no file I/O, no HTTP)
- **Dependencies:** Zero external (Zig std only)
- **Trust boundary:** Caller controls allocator, metric names, bucket config, observe values, and writer
- **Concurrency:** Snapshot collection fans out to a vendored thread pool (`thread_pool`); the pool's backpressure policy is a correctness/safety surface (see S-018)
- **Supply chain:** CI uses `devnw/ci-catalog` components and downloads the Zig toolchain (SHA-256 verified, see S-006)

## Summary

| Severity | Open | Closed | Won't Do |
|---|---|---|---|
| Critical | 0 | 0 | 0 |
| High | 0 | 3 | 0 |
| Medium | 0 | 9 | 2 |
| Low | 0 | 9 | 4 |
| Info | 0 | 1 | 1 |
| **Total** | **0** | **22** | **7** |

All S-017..S-023 findings closed in the 2026-06-11 gap-closure sprint. S-022(b) (index.json TOFU) retains a Won't Do note — see resolution below.

## Open Findings

No open security findings remain.

## Findings by Area

- **Memory safety (auth/lifecycle):** S-017 **Closed** (c362468), S-018 **Closed** (52924f8 + 2c207d3).
- **Resource control / DoS:** S-019 **Closed** (6f3a694).
- **Exposition integrity (output/input):** S-020 **Closed** (81f0b9d).
- **Supply chain:** S-021 **Closed** (0e6e880).
- **CI/CD & ops:** S-022 **Closed** (0e6e880) — S-022(b) index TOFU Won't Do (strategic, see resolved notes). S-023 **Closed** (1066c72).

## Roadmap

No open roadmap items. All sprint security items resolved.

## Resolved / Closed Findings

| ID | Severity | Finding | Status | Resolution |
|---|---|---|---|---|
| S-001 | High | Prometheus output injection via unsanitized metric names/help | **Closed** | Added `validateName()` checking `[a-zA-Z_:][a-zA-Z0-9_:]*` and `validateHelp()` rejecting newlines. Registration returns `InvalidMetricName` / `InvalidHelpText` errors. |
| S-002 | High | NaN/Inf propagation corrupts histogram sum | **Closed** | Added guard at top of `observe()`: `if (std.math.isNan(value) or std.math.isInf(value)) return`. Test added. |
| S-003 | Medium | No bucket validation | **Closed** | Added `BucketError` with `EmptyBuckets`, `UnsortedBuckets`, `NonFiniteBucket`. Validated in `Histogram.init()`. Propagated through Registry and Timer. 5 tests added. |
| S-004 | Medium | `@intCast` truncation u64->i64 in snapshot | **Closed** | Changed `MetricSnapshot` to use separate `counter_value: u64` and `gauge_value: i64` fields instead of shared `int_value: i64`. Full u64 range preserved. |
| S-005 | Medium | CI catalog components pinned by tag not SHA | **Won't Do** | Components are from the same `devnw` organization. GitLab CI catalog doesn't support SHA pinning natively. Mitigated by organizational trust. |
| S-006 | Medium | CI downloads Zig without checksum verification | **Closed** | **Reclassified 2026-06-11 (was Won't Do).** CI **does** SHA-256-verify the Zig toolchain: `.install-zig` fetches `ziglang.org/download/index.json`, extracts the per-version/arch `shasum`, and runs `sha256sum --check --strict` against the downloaded tarball before extraction (.gitlab-ci.yml:38-72, check at :71). Residual TOFU on `index.json` itself tracked as S-022(b). From appsec I1. |
| S-007 | Medium | Prometheus histogram double-counting | **Closed** | Fixed by changing to per-bucket storage in `observe()` (same as Q-001/P-001). |
| S-008 | Low | Counter u64 wrapping on overflow | **Won't Do** | Documented behavior. 2^64 increments is infeasible in practice. |
| S-009 | Low | Gauge i64 wrapping on overflow/underflow | **Won't Do** | Documented behavior. Same rationale as S-008. |
| S-010 | Low | Timer finish() can produce negative duration | **Closed** | Added `@max(0, elapsed)` clamp in `Sample.finish()`. |
| S-011 | Low | Snapshot borrows histogram bucket pointers | **Closed** | Snapshot now copies bucket boundaries into owned `bucket_bound_storage`. No borrowed pointers remain. |
| S-012 | Low | CODEOWNERS template placeholder | **Closed** | Replaced `@your-username` with `@benjiv`. |
| S-013 | Low | No Zig-specific SAST tooling | **Won't Do** | No Zig SAST tools exist. Mitigated by comprehensive unit tests and manual review. |
| S-014 | Medium | Prometheus HELP text backslash not escaped (CWE-116) | **Closed** | Extended `validateHelp()` to reject backslash characters. Prevents Prometheus parser confusion from unescaped `\` sequences. |
| S-015 | Low | validateHelp did not reject carriage return (CWE-93) | **Closed** | Extended `validateHelp()` to reject `\r` alongside `\n`. Prevents CRLF injection edge cases. |
| S-016 | Low | Cross-type metric name collision (CWE-694) | **Closed** | Added `nameInUse()` checking all 4 maps. Prevents duplicate `# TYPE` declarations in Prometheus output. |
| S-017 | Medium | Borrowed name/help stored by reference; dangling-pointer dereference (CWE-416/825) | **Closed** | Commit c362468: all four register fns (`counter`/`gauge`/`histogram`/`timer`) now `dupe` name/help into the registry allocator; `deinit` frees owned strings. Regression test added (`tests/integration.zig`: "registry owns name/help copies; caller may free originals"). Issue [#23](https://gitlab.com/devnw/zig/metrics/-/work_items/23) closed 2026-06-11. |
| S-018 | High | `parallelSnapshot` partial batch submission leaves uninitialized snapshot entries (CWE-908/125) | **Closed** | Commits 52924f8 + 2c207d3: `wg.wait()` drains before error propagation; `error.SnapshotIncomplete` returned when `submitted != total_tasks`. Saturation regression test added (`tests/integration.zig`: "thread_pool: parallelSnapshot never returns garbage entries under pool saturation"). Issue [#21](https://gitlab.com/devnw/zig/metrics/-/work_items/21) closed 2026-06-11. |
| S-019 | Medium | Unbounded metric cardinality → OOM DoS (CWE-770/400) | **Closed** | Commit 6f3a694: `RegistryOptions.max_metrics` (default null = unlimited) added; `error.CardinalityLimitExceeded` returned before any allocation. README guidance added. Tests added. Issue [#29](https://gitlab.com/devnw/zig/metrics/-/work_items/29) closed 2026-06-11. |
| S-020 | Low | Histogram `le`/`_sum` fixed `{d:.6}` precision collapses distinct sub-1e-6 buckets (CWE-682/684) | **Closed** | Commit 81f0b9d: changed to `{d}` (shortest-round-trip float format) for `le` labels and `_sum`; regression test `{1e-7, 2e-7, 1.0}` added. Issue [#30](https://gitlab.com/devnw/zig/metrics/-/work_items/30) closed 2026-06-11. |
| S-021 | Medium | CI catalog security components pinned v1.7.1 vs org-standard v1.25.1 (18-version drift) | **Closed** | Commit 0e6e880: bumped `.gitlab-ci.yml` catalog component pins to v1.25.1. Issue [#35](https://gitlab.com/devnw/zig/metrics/-/work_items/35) closed 2026-06-11. |
| S-022 | Low | CI/CD hardening bundle: (a) image digests, (b) index.json TOFU, (c) ZIG_VERSION override, (d) cache re-verify, (e) gitleaks pre-commit hook | **Closed (with Won't Do note)** | Commit 0e6e880: (a) debian:bookworm-slim images pinned by digest, (c) ZIG_VERSION protected, (d) cached zig re-verified, (e) gitleaks pre-commit hook added. **(b) index.json TOFU remains Won't Do** — strategic cross-repo SHA pinning requires coordinated infrastructure work across devnw/zig repos; tracked as a future improvement, not an active open gap. Issue [#36](https://gitlab.com/devnw/zig/metrics/-/work_items/36) closed 2026-06-11 with the Won't Do note on (b) recorded. |
| S-023 | Info | `detect_diamond_deps.py` interpolates `.hash` into filesystem paths without validation (CWE-22) | **Closed** | Commit 1066c72: added `^[A-Za-z0-9._-]+$` regex validation before path join in `scripts/detect_diamond_deps.py`. Issue tracked doc-only; closed 2026-06-11. |

## Secret Scan Results

| Tool | Findings |
|---|---|
| gitleaks | 0 |
| trufflehog | 0 |
| trivy secrets | 0 |

## Dependency Scan Results

| Tool | Findings |
|---|---|
| grype | 0 (zero dependencies) |
| trivy fs | 0 |
| osv-scanner | 0 |
| semgrep | 0 |
