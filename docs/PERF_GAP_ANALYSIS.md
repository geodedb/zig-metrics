# Performance Gap Analysis

Last updated: 2026-03-23

## Baseline (pre-fix)

| Benchmark | Throughput | CV | Target |
|---|---|---|---|
| Counter (4T x 100K) | ~111M ops/sec | 4.5% | < 10% |
| Histogram (4T x 100K, 11 buckets) | ~12.5M ops/sec | 9.1-11.0% | < 10% |
| Mixed (4T x 100K) | ~23.5M individual ops/sec | 11.8-19.0% | < 10% |

## Findings

| ID | PerfSeverity | Finding | Status | Resolution |
|---|---|---|---|---|
| P-001 | P0 | Histogram observe() scans all buckets without break | **Closed** | Added `break` after first matching bucket. Reduces average atomic ops from ~7.5 to ~1 per observation. |
| P-002 | P0 | writePrometheus holds registry mutex during I/O | **Closed** | Rewrote to snapshot-first: captures snapshot under lock (fast), writes to writer without lock. |
| P-003 | P1 | captureSnapshot allocates under registry mutex | **Won't Do** | P-002 fix (snapshot-first export) is the main consumer. Allocation under mutex is brief; pre-allocation would add complexity for marginal gain. |
| P-004 | P1 | Exclusive mutex for read-only lookups | **Won't Do** | Zig 0.15 std doesn't provide RWLock. Users should cache metric pointers from registration (documented pattern). |
| P-005 | P2 | CAS loop lacks spinLoopHint | **Closed** | Added `std.atomic.spinLoopHint()` after failed CAS in `atomicAddF64`. |
| P-006 | P2 | Snapshot.get() is O(n) linear scan | **Won't Do** | Acceptable for typical registry sizes (tens to low hundreds of metrics). HashMap would add allocation overhead. |
| P-007 | P2 | MetricSnapshot has unused fields per kind | **Won't Do** | Marginal cache benefit. Tagged union adds complexity for minimal gain at typical registry sizes. |
| P-008 | P3 | No benchmark for export/snapshot path | **Won't Do** | Future improvement. Export path is now snapshot-based so mutex hold time is minimized. |
| P-009 | P3 | CI redownloads Zig toolchain in every job | **Won't Do** | Infrastructure concern outside library code scope. |
| P-010 | P3 | Mixed workload CV exceeds 10% target | **Blocked** | P-001 fix should improve this. Needs re-measurement after all changes. |
