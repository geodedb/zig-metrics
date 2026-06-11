# Performance Gap Analysis

Last updated: 2026-06-11

> **Baseline validity warning:** The pre-fix baseline below was measured against
> **Debug-compiled** library code (see **P-012**) using a **DebugAllocator** in the
> measured loops (see **P-013**). It does **not** represent the optimized library
> users ship. The benchmarks also do not currently compile on Zig 0.16
> (**GAP-005**, [#19](https://gitlab.com/devnw/zig/metrics/-/issues/19)). The
> perf baseline **cannot be reproduced** until GAP-005 closes and **P-012**/**P-013**
> land; baselines must then be **re-measured** and this table replaced.

## Baseline (pre-fix — INVALID, pending re-measurement; see P-012/P-013/GAP-005)

| Benchmark | Throughput | CV | Target |
|---|---|---|---|
| Counter (4T x 100K) | ~111M ops/sec | 4.5% | < 10% |
| Histogram (4T x 100K, 11 buckets) | ~12.5M ops/sec | 9.1-11.0% | < 10% |
| Mixed (4T x 100K) | ~23.5M individual ops/sec | 11.8-19.0% | < 10% |

## Summary

Open findings: 4 (P1 x2, P2 x2). Closed/Won't-Do/Blocked from prior rounds: 10 (P-001..P-010).

Top risks (by PerfScore):

1. **P-012 (score 100, P1)** — All baseline throughput numbers measured Debug library code; baselines invalid until fixed and re-measured.
2. **P-011 (score 48, P1)** — Timer uses wall-clock (`.real`) not monotonic; NTP/admin clock steps corrupt recorded durations.
3. **P-013 (score 48, P2)** — DebugAllocator in measured bench loops inflates alloc cost and CV (likely contributor to P-010).
4. **P-014 (score 24, P2)** — `RwLockShim` serializes all readers; `std.Io.RwLock` now exists (P-004 rationale stale).
5. **P-010 (Blocked)** — Mixed-workload CV exceeds 10%; cannot be re-assessed until P-012/P-013 land and benches compile (GAP-005).

## Stack-ranked open findings (by PerfScore descending)

| Rank | PerfSeverity | PerfScore | Finding | Component | Evidence | Measurement | Issue | Fix Summary | Owner | SLA/Due | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | P1 | 100 | scale-bench exe is ReleaseFast but imports `metrics` module built at user `optimize` (default Debug); all baseline throughput measured Debug code | ci/build | `build.zig:178` (exe ReleaseFast) vs `build.zig:40-48` (module at user optimize), default Debug `build.zig:8` | Baselines unreproducible vs shipped artifact; Debug→ReleaseFast often 5-10x | [#28](https://gitlab.com/devnw/zig/metrics/-/issues/28) | Dedicated ReleaseFast module for benches, or enforce `-Doptimize=ReleaseFast` | bench/build owner | Sprint (P1) | Open |
| 2 | P1 | 48 | Timer measures elapsed duration with `CLOCK_REALTIME` (`.real`) instead of monotonic; clock step corrupts durations (clamped to 0 backward, inflated forward) | app | `src/timer.zig:16` (`.real`), used `:52`,`:85`, differenced `:86` | Unbounded duration error on clock adjustment; 0 perf cost to fix (same vDSO) | [#27](https://gitlab.com/devnw/zig/metrics/-/issues/27) | Timer source uses `.awake` (CLOCK_MONOTONIC); snapshot/registry stay `.real`. Coordinate with Q-023 (shared helper supports both clocks) | timer.zig owner | Sprint (P1) | Open |
| 3 | P2 | 48 | Benches use `DebugAllocator` in measured loops; inflates alloc cost and CV | ci/bench | `benchmarks/variance.zig:39`, `benchmarks/scale_bench.zig:105` | Distorted alloc latencies; raised CV (likely feeds P-010) | [#31](https://gitlab.com/devnw/zig/metrics/-/issues/31) | Use `smp_allocator`/arena for measured region; keep DebugAllocator for a separate correctness pass | bench owner | Quarter (P2); pull fwd w/ P-012 | Open |
| 4 | P2 | 24 | `RwLockShim` collapses shared locks to exclusive; readers serialize. `std.Io.RwLock` now exists (P-004 rationale stale); "Io-free" comment false (calls `getIo()`) | app | `src/registry.zig:17-36`; shared sites `:284`,`:291`,`:298`,`:305`,`:314`,`:340`,`:661` | Readers cannot run concurrently; bounded by cached-pointer pattern (hot path skips lock) | [#32](https://gitlab.com/devnw/zig/metrics/-/issues/32) | Adopt `std.Io.RwLock`; at minimum fix stale comment + P-004 note | registry.zig owner | Quarter (P2); comment/note this sprint | Open |

## Findings by area

### app (library code)

- **P-011** (P1, score 48) — Timer wall-clock vs monotonic. `src/timer.zig:16`,`:52`,`:85`. Issue [#27](https://gitlab.com/devnw/zig/metrics/-/issues/27).
- **P-014** (P2, score 24) — RwLockShim serializes readers; stale P-004 rationale. `src/registry.zig:17-36`. Issue [#32](https://gitlab.com/devnw/zig/metrics/-/issues/32).

### ci / bench harness

- **P-012** (P1, score 100) — Debug library under ReleaseFast harness. `build.zig:178` vs `:40-48`. Issue [#28](https://gitlab.com/devnw/zig/metrics/-/issues/28).
- **P-013** (P2, score 48) — DebugAllocator in measured loops. `variance.zig:39`, `scale_bench.zig:105`. Issue [#31](https://gitlab.com/devnw/zig/metrics/-/issues/31).
- **GAP-005** (cross-ref, gap domain) — Benches fail to compile on Zig 0.16 (`std.process.args` removed): `scale_bench.zig:120`, `compare.zig:95`. Issue [#19](https://gitlab.com/devnw/zig/metrics/-/issues/19). **Blocks** P-012/P-013 re-measurement.

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

## Prior findings (P-001 .. P-010)

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
| P-010 | P3 | Mixed workload CV exceeds 10% target | **Blocked** | P-001 fix should improve this. Needs re-measurement after all changes — and **P-012**/**P-013** likely contribute to the inflated CV. Cannot be re-assessed until benches compile (**GAP-005**) and P-012/P-013 land. |

## Roadmap

### Quick wins (< 1 day)

- **P-011** — swap Timer time source to `.awake` (coordinate with Q-023). Zero perf cost.
- **P-014 (minimum)** — fix the false "Io-free" comment in `registry.zig:14-16` and the P-004 note (done in this doc).
- **A-004** — document "wrap the writer in a buffer before `writePrometheus`".

### Medium (1-5 days)

- **P-012** — dedicated ReleaseFast bench module / enforce `-Doptimize` (depends on GAP-005 to compile).
- **P-013** — replace DebugAllocator with `smp_allocator`/arena in measured loops.
- **Re-measure baseline** once GAP-005 + P-012 + P-013 land; replace the invalidated baseline table and re-assess P-010.

### Strategic (> 5 days)

- **P-014 (full)** — adopt `std.Io.RwLock` with a concurrent registration+scrape stress test to guard reader/writer semantics.
