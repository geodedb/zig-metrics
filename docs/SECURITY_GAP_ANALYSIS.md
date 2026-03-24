# Security Gap Analysis

Last updated: 2026-03-23

## Attack Surface

- **Type:** In-process library (no network, no file I/O, no HTTP)
- **Dependencies:** Zero external (Zig std only)
- **Trust boundary:** Caller controls allocator, metric names, bucket config, observe values, and writer

## Findings

| ID | Severity | Finding | Status | Resolution |
|---|---|---|---|---|
| S-001 | High | Prometheus output injection via unsanitized metric names/help | **Closed** | Added `validateName()` checking `[a-zA-Z_:][a-zA-Z0-9_:]*` and `validateHelp()` rejecting newlines. Registration returns `InvalidMetricName` / `InvalidHelpText` errors. |
| S-002 | High | NaN/Inf propagation corrupts histogram sum | **Closed** | Added guard at top of `observe()`: `if (std.math.isNan(value) or std.math.isInf(value)) return`. Test added. |
| S-003 | Medium | No bucket validation | **Closed** | Added `BucketError` with `EmptyBuckets`, `UnsortedBuckets`, `NonFiniteBucket`. Validated in `Histogram.init()`. Propagated through Registry and Timer. 5 tests added. |
| S-004 | Medium | `@intCast` truncation u64->i64 in snapshot | **Closed** | Changed `MetricSnapshot` to use separate `counter_value: u64` and `gauge_value: i64` fields instead of shared `int_value: i64`. Full u64 range preserved. |
| S-005 | Medium | CI catalog components pinned by tag not SHA | **Won't Do** | Components are from the same `devnw` organization. GitLab CI catalog doesn't support SHA pinning natively. Mitigated by organizational trust. |
| S-006 | Medium | CI downloads Zig without checksum verification | **Won't Do** | Infrastructure concern. HTTPS provides transport security. Adding checksum would require maintaining hash per version. |
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
