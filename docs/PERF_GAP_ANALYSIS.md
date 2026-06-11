# Performance Gap Analysis

Last updated: 2026-06-11

## Baseline (2026-06-11 — ReleaseFast library + smp_allocator after P-012/P-013; Zig 0.16.0)

Measured with `zig build bench -Doptimize=ReleaseFast` and `zig build scale-bench -- light moderate`.
Conditions: ReleaseFast metrics module (P-012, commit 0b3e7f0), smp_allocator in measured loops
(P-013, commit 0b3e7f0), monotonic timer via compat.zig (P-011, commit 65e28ac), real RwLock
(P-014, commit 6c6ccc5). GAP-005 (benches compile; #19) closed by commit 83c59f0.
`bench-save`/`bench-baseline`/`bench-compare`/`bench-check` Makefile targets now operational.

### Variance bench (4 threads × 100K iters/thread, 10 samples)

| Benchmark | Mean | Min | Max | StdDev | CV | Target |
|---|---|---|---|---|---|---|
| Counter (4T x 100K) | 3.841 ms (~104M ops/sec) | 3.698 ms | 4.056 ms | 0.112 ms | 2.9% | < 10% |
| Histogram (4T x 100K, 11 buckets) | 34.096 ms (~11.7M ops/sec) | 31.507 ms | 36.547 ms | 1.474 ms | 4.3% | < 10% |
| Mixed (4T x 100K, 3 ops/iter) | 57.970 ms (~20.7M ops/sec) | 51.890 ms | 63.449 ms | 3.661 ms | 6.3% | < 10% |
| Parallel Snapshot (40 metrics) | 0.014 ms | 0.004 ms | 0.057 ms | 0.014 ms | 104.5% | — |

> **Note on Parallel Snapshot CV:** The 104.5% CV is expected — snapshot latency is
> dominated by OS scheduling jitter at sub-millisecond timescales. This is not a
> regression target; snapshot runs at scrape cadence (seconds), not per-op.

### Scale bench (ReleaseFast, JSON output)

**Light tier** (10 metrics, 2 threads, 100K iters/thread):

| Metric type | ops/sec | Registration | Snapshot | Parallel snapshot | Prometheus export |
|---|---|---|---|---|---|
| Counter | ~104–123M | ~754–798 ns | < 1 ms | < 1 ms | < 1 ms |
| Gauge | ~109–121M | — | — | — | — |
| Histogram | ~22–25M | — | — | — | — |
| Timer | ~17–30M | — | — | — | — |
| Mixed | ~102–103M | — | — | — | — |

**Moderate tier** (50 metrics, 4 threads, 500K iters/thread):

| Metric type | ops/sec | Registration | Snapshot | Parallel snapshot | Prometheus export |
|---|---|---|---|---|---|
| Counter | ~99–104M | ~397–480 ns | < 1 ms | < 1 ms | ~0.1 ms |
| Gauge | ~103–109M | — | — | — | — |
| Histogram | ~13–14M | — | — | — | — |
| Timer | ~13–15M | — | — | — | — |
| Mixed | ~126–128M | — | — | — | — |

## Summary

Open findings: 0 active (P1/P2 all closed this sprint). Closed/Won't-Do/Blocked: 14 (P-001..P-014).
P-010 re-assessed as **Closed** — all variance-bench CVs now under 10% with clean ReleaseFast + smp_allocator numbers.

Top risks: none open. All sprint items resolved.

## Stack-ranked open findings (by PerfScore descending)

No open findings remain. See **Closed findings** below.

## Findings by area

### app (library code)

- **P-011** (P1, score 48) — Timer wall-clock vs monotonic. **Closed** by commit 65e28ac (monotonic
  timer via `src/compat.zig`). Issue [#27](https://gitlab.com/devnw/zig/metrics/-/issues/27).
- **P-014** (P2, score 24) — RwLockShim serializes readers; stale P-004 rationale. **Closed** by
  commit 6c6ccc5 (`std.Io.RwLock` adopted in `src/registry.zig`). Issue [#32](https://gitlab.com/devnw/zig/metrics/-/issues/32).

### ci / bench harness

- **P-012** (P1, score 100) — Debug library under ReleaseFast harness. **Closed** by commit 0b3e7f0
  (dedicated ReleaseFast bench module). Issue [#28](https://gitlab.com/devnw/zig/metrics/-/issues/28).
- **P-013** (P2, score 48) — DebugAllocator in measured loops. **Closed** by commit 0b3e7f0
  (smp_allocator in measured region). Issue [#31](https://gitlab.com/devnw/zig/metrics/-/issues/31).
- **GAP-005** (cross-ref, gap domain) — Benches fail to compile on Zig 0.16 (`std.process.args`
  removed). **Closed** by commit 83c59f0 (`std.process.Init`). Issue [#19](https://gitlab.com/devnw/zig/metrics/-/issues/19).
  Closure restored `bench-save`/`bench-baseline`/`bench-compare` targets and added new `bench-check` CI gate.

### db / infra

- None.

## Accepted / documented (no issue — rationale recorded)

| ID | Item | Component | Decision | Rationale |
|---|---|---|---|---|
| A-001 | Histogram `observe()` linear bucket scan | `src/histogram.zig:121-126` | **Accept** | Linear scan is optimal for B ≤ 16 buckets (default set is 12). Branch-predictable, cache-friendly, no indirection; binary search would be slower at this size. Already has early `break` (P-001). |
| A-002 | `nameInUse` probes 4 separate hash maps | `src/registry.zig:160-165` | **Accept** | Cold path — runs only at registration, not on the hot increment/observe path. 4 `contains()` lookups are immaterial at registration frequency. |
| A-003 | Allocation under (shared) lock in `parallelSnapshot` / `captureSnapshot` | `src/registry.zig:314-316`, `:340`, `:363-386` | **Accept** | Consistent with **P-003 (Won't Do)**. Snapshot/export runs at scrape cadence (seconds), not per-op; brief allocation under lock is immaterial there. |
| A-004 | `writePrometheus` emits many small `print()` calls | `src/prometheus.zig:43-66` | **Document** | If the caller passes an unbuffered writer, per-field `print()` calls each hit the syscall path. Mitigation is caller-side: **wrap the writer in a buffer** (e.g. buffered `std.Io.Writer`) before passing to `writePrometheus`. No library change; document the expectation. |
| A-005 | `nanoTimestampCompat` `.io()` per-call cost | `src/timer.zig:14-17`, `src/registry.zig:37-41` | **No action (false positive)** | VERIFIED trivial: `std.Io.Threaded.global_single_threaded.io()` returns two pointers; `Timestamp.now` is a vDSO `clock_gettime`. No syscall/alloc overhead. (Clock *kind* is a separate correctness issue — see P-011. Dedup of the helper itself is **Q-023**, quality domain.) |

## Prior findings (P-001 .. P-014)

| ID | PerfSeverity | Finding | Status | Resolution |
|---|---|---|---|---|
| P-001 | P0 | Histogram observe() scans all buckets without break | **Closed** | Added `break` after first matching bucket. Reduces average atomic ops from ~7.5 to ~1 per observation. |
| P-002 | P0 | writePrometheus holds registry mutex during I/O | **Closed** | Rewrote to snapshot-first: captures snapshot under lock (fast), writes to writer without lock. |
| P-003 | P1 | captureSnapshot allocates under registry mutex | **Won't Do** | P-002 fix (snapshot-first export) is the main consumer. Allocation under mutex is brief; pre-allocation would add complexity for marginal gain. |
| P-004 | P1 | Exclusive mutex for read-only lookups | **Won't Do (rationale updated 2026-06-11)** | ~~Zig 0.15 std doesn't provide RWLock.~~ **Correction:** Zig 0.16 *does* provide `std.Io.RwLock` — the original "no std RwLock" rationale is **stale**. P-004 remains deferred because the documented pattern is to cache metric pointers from registration, so the hot path does not take the registry lock. Genuine RwLock adoption is tracked as **P-014** ([#32](https://gitlab.com/devnw/zig/metrics/-/issues/32)). |
| P-005 | P2 | CAS loop lacks spinLoopHint | **Closed** | Added `std.atomic.spinLoopHint()` after failed CAS in `atomicAddF64`. |
| P-006 | P2 | Snapshot.get() is O(n) linear scan | **Won't Do** | Acceptable for typical registry sizes (tens to low hundreds of metrics). HashMap would add allocation overhead. |
| P-007 | P2 | MetricSnapshot has unused fields per kind | **Won't Do** | Marginal cache benefit. Tagged union adds complexity for minimal gain at typical registry sizes. |
| P-008 | P3 | No benchmark for export/snapshot path | **Won't Do** | Future improvement. Export path is now snapshot-based so mutex hold time is minimized. |
| P-009 | P3 | CI redownloads Zig toolchain in every job | **Won't Do** | Infrastructure concern outside library code scope. |
| P-010 | P3 | Mixed workload CV exceeds 10% target | **Closed** | Re-measured 2026-06-11 with ReleaseFast + smp_allocator (P-012/P-013 closed). All CVs now under 10%: Counter 2.9%, Histogram 4.3%, Mixed 6.3%. P-001 fix and clean allocator both contributed. |
| P-011 | P1 | Timer uses wall-clock (`.real`) not monotonic; NTP/admin clock steps corrupt recorded durations | **Closed** | Commit 65e28ac: monotonic timer clock via shared `src/compat.zig` helper (`nanoTimestampMonotonic`). Issue [#27](https://gitlab.com/devnw/zig/metrics/-/issues/27). |
| P-012 | P1 | scale-bench exe is ReleaseFast but imports `metrics` module built at user `optimize` (default Debug); all baseline throughput measured Debug code | **Closed** | Commit 0b3e7f0: dedicated ReleaseFast bench module; `-Doptimize=ReleaseFast` enforced for bench exe and metrics module. Issue [#28](https://gitlab.com/devnw/zig/metrics/-/issues/28). |
| P-013 | P2 | Benches use `DebugAllocator` in measured loops; inflates alloc cost and CV | **Closed** | Commit 0b3e7f0: `smp_allocator` used in measured region; DebugAllocator retained for correctness-only pass. Issue [#31](https://gitlab.com/devnw/zig/metrics/-/issues/31). |
| P-014 | P2 | `RwLockShim` collapses shared locks to exclusive; readers serialize. `std.Io.RwLock` now exists (P-004 rationale stale) | **Closed** | Commit 6c6ccc5: `std.Io.RwLock` adopted in `src/registry.zig`; stale shim and P-004 comment removed. Issue [#32](https://gitlab.com/devnw/zig/metrics/-/issues/32). |

## Roadmap

All sprint items closed. No active roadmap items.

### Potential future work (not tracked as open findings)

- **A-004** — document "wrap the writer in a buffer before `writePrometheus`" in user-facing docs.
- **P-008** — dedicated export/snapshot benchmark (currently covered indirectly by scale-bench snapshot timings).
