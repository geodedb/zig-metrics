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
| High | 1 | 2 | 0 |
| Medium | 3 | 6 | 2 |
| Low | 2 | 6 | 4 |
| Info | 1 | 0 | 1 |
| **Total** | **7** | **14** | **7** |

### Top 5 open risks (by Risk Score)

1. **S-018 (64, High)** — `parallelSnapshot` discards partial-submit result → uninitialized snapshot entries → OOB read / info-disclosure / crash. CWE-908/125. *Reachable in normal operation; confidential.*
2. **S-017 (36, Medium)** — borrowed name/help slices stored by reference + used as map key (no dupe) → dangling-pointer dereference. CWE-416/825.
3. **S-019 (36, Medium)** — unbounded metric cardinality → OOM DoS when names derive from untrusted input. CWE-770/400.
4. **S-021 (24, Medium)** — CI catalog security components stale (v1.7.1 vs org-standard v1.25.1, 18-version drift). Supply chain.
5. **S-022 (12, Low)** — CI/CD hardening bundle (image digests, index TOFU, ZIG_VERSION override, cache re-verify, gitleaks pre-commit hook).

## Open Findings (stack-ranked by Risk Score)

| Rank | Severity | Risk | Finding | Component | CWE/OWASP | Evidence (file:line) | Issue | Fix | Owner | Due | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | High | 64 | `parallelSnapshot` discards `SubmitBatchResult.submitted`; partial submit under `.return_error` leaves uninitialized `entries` (alloc'd 363), `wg.wait` returns, `Snapshot.get` reads wild slice ptr | registry.zig, snapshot.zig | CWE-908/125, A04:2021 | registry.zig:363,562,580; snapshot.zig:67 | [#21](https://gitlab.com/devnw/zig/metrics/-/work_items/21) (confidential) | Check `res.submitted != total_tasks` → `error.SnapshotIncomplete`; pre-zero entries | <benji@vester.by> | 2026-07-11 | Open |
| 2 | Medium | 36 | Borrowed name/help stored by reference + used as hashmap key without dupe; contradicts "owns lifecycle" doc + README "Memory Safe" | registry.zig, counter.zig | CWE-416/825, A04:2021 | registry.zig:6,177-193; counter.zig:25-31 | [#23](https://gitlab.com/devnw/zig/metrics/-/work_items/23) | Dupe into registry allocator + free in deinit (or document borrow on all four init/register + fix README) | <benji@vester.by> | 2026-09-09 | Open |
| 3 | Medium | 36 | Unbounded metric cardinality — no cap/eviction; OOM DoS if caller derives names from untrusted input | registry.zig | CWE-770/400, A04:2021 | registry.zig:177-279 | [#29](https://gitlab.com/devnw/zig/metrics/-/work_items/29) | Optional `RegistryOptions.max_metrics` + `error.CardinalityLimitExceeded` + README guidance | <benji@vester.by> | 2026-09-09 | Open |
| 4 | Medium | 24 | CI catalog security components pinned v1.7.1 vs sibling thread-pool v1.25.1 (18-version drift) | .gitlab-ci.yml | A06:2021, CIS-16 | .gitlab-ci.yml:10-24 | [#35](https://gitlab.com/devnw/zig/metrics/-/work_items/35) | Bump to v1.25.1 (or current) | <benji@vester.by> | 2026-09-09 | Open |
| 5 | Low | 12 | CI/CD hardening bundle: (a) debian:bookworm-slim images unpinned by digest; (b) zig index.json TOFU; (c) ZIG_VERSION overridable; (d) cached zig skips SHA re-verify; (e) no gitleaks pre-commit hook | .gitlab-ci.yml, .pre-commit-config.yaml | A06/A08:2021, CIS-16 | .gitlab-ci.yml:27,42-76,88-178; .pre-commit-config.yaml | [#36](https://gitlab.com/devnw/zig/metrics/-/work_items/36) | Pin digests; pin index/tarball SHAs; protect ZIG_VERSION; re-verify cache; add gitleaks hook | <benji@vester.by> | 2026-12-08 | Open |
| 6 | Low | 8 | Histogram `le`/`_sum` fixed `{d:.6}` precision collapses distinct sub-1e-6 buckets into identical `le` labels → malformed exposition | prometheus.zig, histogram.zig | CWE-682/684 | prometheus.zig:61,65; histogram.zig:79-85 | [#30](https://gitlab.com/devnw/zig/metrics/-/work_items/30) | Shortest-round-trip float format for `le`/`_sum`; regression test {1e-7,2e-7,1.0} | <benji@vester.by> | 2026-12-08 | Open |
| 7 | Info | 4 | `detect_diamond_deps.py` interpolates `.hash` into filesystem paths without validation; read-only parse of arbitrary `build.zig.zon`-named files | scripts/detect_diamond_deps.py | CWE-22 (defense-in-depth) | scripts/detect_diamond_deps.py:178-184,210 | doc-only | Validate hash `^[A-Za-z0-9._-]+$` before path join | <benji@vester.by> | backlog | Open |

## Findings by Area

- **Memory safety (auth/lifecycle):** S-017 (dangling name/help pointers), S-018 (uninitialized snapshot entries / OOB read).
- **Resource control / DoS:** S-019 (unbounded cardinality → OOM).
- **Exposition integrity (output/input):** S-020 (malformed `le` labels).
- **Supply chain:** S-021 (stale CI catalog components).
- **CI/CD & ops:** S-022 (image digests, index TOFU, version override, cache re-verify, gitleaks pre-commit hook), S-023 (path-traversal defense-in-depth in dependency-audit script).

## Roadmap

- **Quick wins (< 1 day):** S-021 (bump component pins), S-022(e) gitleaks pre-commit hook, S-022(a) image digest pins, S-023 hash regex validation, S-020 float format swap.
- **Medium (1-5 days):** S-018 (submit-result check + pre-zero entries + partial-submit regression test), S-017 (dupe name/help + leak-checked test), S-019 (`max_metrics` option + cap test), S-022(c)(d) ZIG_VERSION protection + cache re-verify.
- **Strategic (> 5 days):** S-022(b) index.json/tarball SHA pinning strategy across devnw/zig repos; cross-repo CI component pin synchronization with quality Q-020.

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
