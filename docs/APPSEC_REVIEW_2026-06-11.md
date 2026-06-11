# Application Security Code Review — `devnw/zig/metrics`

**Reviewer role:** Defensive AppSec code review (OWASP Top 10:2025 + CIS Controls v8.1.2)
**Date:** 2026-06-11
**Repo:** `/home/benji/src/gl/gitlab.com/devnw/zig/metrics` @ `main` (ffe99df)
**Scope basis:** Entire working tree (default scope; no diff specified)

---

## 1. Scope and Assumptions

**Reviewed (read in full):**

- Core library: `src/counter.zig`, `gauge.zig`, `histogram.zig`, `timer.zig`, `snapshot.zig`, `registry.zig`, `prometheus.zig`, `root.zig`, `observability.zig`, `observability_init.zig`
- Tests: `tests/integration.zig`, `.pre-commit-config.yaml` hooks
- Build/supply chain: `build.zig`, `build.zig.zon`, `.gitlab-ci.yml`, `scripts/detect_diamond_deps.py`, `.gitleaks.toml`
- `docs/SECURITY_GAP_ANALYSIS.md` (to avoid re-reporting accepted items)
- Cross-checked Zig 0.16.0 stdlib (`std/Io.zig` Mutex impl) and the `thread_pool` dep's `src/sync.zig` to validate the locking primitive.

**Not reviewed / out of scope:**

- Transitive contents of the `thread_pool` dependency beyond its `sync.zig` locking shim (per input contract).
- Benchmarks (`benchmarks/*.zig`), `examples/basic.zig`, and the observability-disabled/enabled test files were read only for cross-references, not audited as attack surface (no runtime exposure).
- No code was executed; analysis is static plus read-only stdlib inspection.

**Assumptions:**

- The library is consumed in-process by trusted Zig applications. The "attacker" in the threat model is a hostile or buggy **caller-supplied input** (metric names, label/help text, observed values, bucket configs) and the **software supply chain** — not a remote network attacker (there is no network or file I/O surface).
- Metric output flows downstream into a Prometheus exposition consumer; output integrity matters.
- The `with_otel` seam is a permanent compile-time no-op (`observability.zig:33`, `build.zig:20`); the otel paths are dead in default builds and were assessed as such.

**Overall confidence:** High for the in-process library surface (small, well-tested, ~3300 LOC). Medium for the supply-chain/CI posture (depends on org-internal CI catalog components not in this repo).

---

## 2. Executive Summary

- **No Critical or High vulnerabilities found in the reviewed scope.** The previously-identified Prometheus injection vector (S-001) is genuinely closed: metric names are validated against `[a-zA-Z_:][a-zA-Z0-9_:]*` and help text rejects `\n`, `\r`, `\`, all *before* the lock and before any output (`registry.zig:142-157`). NaN/Inf, bucket, and overflow guards are present and tested.
- **The library's strongest residual risk is a lifetime / dangling-pointer gap (M1):** the registry stores caller-supplied `name`/`help` slices **by reference** (and uses `name` directly as the hashmap key) without duplicating them, while documenting that it "owns... the lifecycle of all registered metrics" (`registry.zig:6`). A caller that frees those buffers after registration leaves the registry reading freed memory at export time — a use-after-free that produces corrupted or attacker-influenced exposition output. This contract is undocumented (contrast with buckets, where lifetime *is* documented).
- **Unbounded label/metric cardinality (M2):** there is no cap on the number of registered metrics; each registration permanently allocates a `Counter`/`Gauge`/`Histogram`/`Timer` plus hashmap entry, never reclaimed except at `deinit`. A caller driven by untrusted input (e.g. metric-name-per-request) can exhaust memory. This is the classic metrics-cardinality DoS and is unmitigated and undocumented.
- **Output-correctness weakness (L1):** histogram bucket boundaries are emitted with fixed `{d:.6}` precision (`prometheus.zig:61`), which silently collapses distinct sub-microsecond bucket bounds into identical `le` labels, producing malformed/ambiguous histograms. Validation accepts such buckets at registration, so the corruption is silent.
- **Supply chain is sound; one stale gap-analysis entry:** the direct dependency is pinned by both git commit SHA and content hash (`build.zig.zon:8-9`), and the CI Zig toolchain download **is** SHA-256-verified against the ziglang index (`.gitlab-ci.yml:38-72`) — which contradicts gap-analysis item **S-006** ("CI downloads Zig without checksum verification — Won't Do"). That accepted item is stale and should be reclassified Closed.
- **Thread-safety verified, not assumed:** the `RwLockShim` (`registry.zig:17-36`) is built on `std.Io.Mutex.lockUncancelable`, which performs real atomic-CAS + futex blocking in the 0.16.0 stdlib (`Io.zig:1623-1639`). The "single_threaded" Io instance name refers to the runtime task model, not the lock's cross-thread correctness. Lock-free metric updates use independent `.monotonic` atomics with a documented eventually-consistent snapshot model — acceptable for monitoring; no torn-read vuln.

---

## 3. Findings Table

| ID | Severity | Confidence | Title | Location | OWASP 2025 | Status |
|----|----------|-----------|-------|----------|-----------|--------|
| M1 | Medium | High | Borrowed `name`/`help` slices → use-after-free if caller frees buffers (contract undocumented & contradicts "owns lifecycle") | `registry.zig:177-193, 6`; `counter.zig:25-31` | A06 Insecure Design / A10 | Open |
| M2 | Medium | High | Unbounded metric/label cardinality → memory-exhaustion DoS, no cap, undocumented | `registry.zig:177-279` | A06 Insecure Design | Open |
| L1 | Low | High | Histogram `le` label fixed `{d:.6}` precision collapses distinct buckets → malformed exposition | `prometheus.zig:61`; `histogram.zig:83-85` | A10 Mishandling of Exceptional Conditions | Open |
| L2 | Low | Medium | Version string drift (`0.1.0` in code vs `0.1.3` in manifest) weakens artifact-integrity/provenance signal | `root.zig:36`; `build.zig.zon:3`; `integration.zig:125` | A08 Software/Data Integrity | Open |
| I1 | Info | High | Stale gap-analysis item S-006 (Zig checksum) — CI **does** verify SHA-256; reclassify | `.gitlab-ci.yml:38-72` vs `docs/SECURITY_GAP_ANALYSIS.md:20` | A03 Supply Chain | Doc fix |
| I2 | Info | Medium | CI catalog components pinned by tag, not SHA (accepted as S-005); noted for completeness | `.gitlab-ci.yml:11-24` | A03 Supply Chain | Accepted (S-005) |

---

## 4. Finding Details

### M1 — Borrowed `name`/`help` slices create a use-after-free at export time

**Evidence.**

- `registry.zig:6` documents: *"The Registry owns and manages the lifecycle of all registered metrics."*
- Registration stores the caller's slices by reference and uses `name` itself as the hashmap key, with **no `dupe`**:

  ```zig
  // registry.zig:186-191
  const c = self.allocator.create(Counter) catch return error.OutOfMemory;
  c.* = Counter.init(name, help);          // Counter stores name/help by reference
  self.counters.put(name, c) catch { ... } // hashmap KEY is the caller's slice
  ```

- `Counter.init` (and Gauge/Histogram/Timer) store the slices verbatim: `counter.zig:25-31` → `.name = name, .help = help`.
- A repo-wide search found `dupe` used nowhere for name/help; lifetime is documented **only** for histogram `buckets` (`histogram.zig:72`), not for name/help. The README advertises *"Memory Safe"* (README.md:11) and every example uses **string literals** (static storage), which masks the hazard.

**Attack scenario (non-destructive, scoped).** A caller constructs a metric name in a heap buffer (e.g. `try std.fmt.allocPrint(alloc, "req_{s}_total", .{tenant})`), registers it, then frees the buffer (a natural pattern when the name is computed per-subsystem during init). The registry's hashmap key and the metric's `name`/`help` now dangle. At the next `writePrometheus`/`snapshot`, the exporter reads freed memory (`prometheus.zig:43-45` prints `entry.name`/`entry.help`). Depending on allocator reuse, this yields corrupted exposition output, an info leak of whatever now occupies that memory, or a crash. Hashmap lookups by the freed key (`getCounter`) also compare against freed bytes.

**Impact.** Use-after-free / information disclosure / availability. Severity capped at **Medium**: triggering requires a caller mistake, but the mistake is *invited* by the "owns lifecycle" doc claim and is not guarded or documented. CWE-416 (UAF), CWE-825 (expired pointer dereference).

**Root cause.** Ambiguous ownership contract: the registry takes responsibility for metric *objects* it allocates but silently borrows the *strings*, with no documentation or enforcement.

**Remediation (pick one, ordered by safety):**

1. **Duplicate on registration (recommended; matches the documented "owns lifecycle" claim).** `dupe` `name`/`help` into `self.allocator`, use the duped `name` as the key, and free them in `deinit`.
2. **If borrowing is intentional for zero-alloc**, document it explicitly on every register fn ("`name` and `help` must outlive the Registry") mirroring `histogram.zig:72`, fix the `registry.zig:6` "owns lifecycle" wording, and remove the unqualified "Memory Safe" claim from the README.

**Regression tests.**

- A test that registers a counter with a heap-allocated name, frees the name, then asserts `getCounter`/`writePrometheus` still return the correct bytes (passes only after option 1).

**Mapping.** OWASP A06 (Insecure Design — ambiguous ownership), A10; CWE-416, CWE-825; CIS v8.1.2 Control 16 (secure design principles, vetted modules).

---

### M2 — Unbounded metric cardinality enables memory-exhaustion DoS

**Evidence.** Every successful registration permanently allocates and inserts with no upper bound and no eviction:

- `registry.zig:186-192` (counter), `206-212` (gauge), `230-245` (histogram), `263-278` (timer) — each does `allocator.create(...)` + `map.put(...)`.
- Memory is reclaimed only in `Registry.deinit` (`registry.zig:110-139`). There is no `unregister`, no max-metric cap, and no rate limit.

**Attack scenario.** An application instruments a code path with a metric name derived from untrusted input (a common anti-pattern: per-tenant/per-ID metric names). Each distinct input creates a permanent metric. An attacker sending many distinct values drives unbounded growth of four `StringHashMap`s plus per-metric allocations until OOM.

**Impact.** Availability / resource exhaustion (CWE-770: allocation without limits; CWE-400: uncontrolled resource consumption). **Medium**: exploitation depends on the *embedding* application feeding untrusted strings into names, but the library provides no guardrail and the failure mode (process OOM) is severe.

**Root cause.** No cardinality budget; the library treats the name space as unbounded and trusts the caller entirely, without documenting that names must be low-cardinality and caller-controlled.

**Remediation.**

- Add an optional `max_metrics` to `RegistryOptions` (default unlimited for back-compat, but documented), and return a new `error.CardinalityLimitExceeded` from the register paths when exceeded.
- Document prominently (README + registry doc-comment) that metric names MUST be bounded, low-cardinality, and developer-controlled — never derived from untrusted request data.

**Regression tests.** Register up to `max_metrics`, assert the next registration returns `CardinalityLimitExceeded` and leaks nothing (Debug allocator clean).

**Mapping.** OWASP A06; CWE-770, CWE-400; CIS v8.1.2 Control 16.10 (secure design — resource limits).

---

### L1 — Histogram `le` label fixed 6-decimal precision silently collapses distinct buckets

**Evidence.**

- Exporter formats bucket bounds with fixed precision: `prometheus.zig:61`

  ```zig
  try writer.print("{s}_bucket{{le=\"{d:.6}\"}} {d}\n", .{ entry.name, bucket, cumulative });
  ```

- Registration validates only ordering/finiteness/NaN (`histogram.zig:79-85`), accepting strictly-ascending bounds that differ below 1e-6 (e.g. `0.0000001` and `0.0000002`, both render as `le="0.000000"`). The sum/observation values share the same `{d:.6}` issue (`prometheus.zig:65`).

**Attack scenario.** A caller supplies fine-grained sub-microsecond buckets. The exporter emits two `_bucket` lines with identical `le="0.000000"` labels. A Prometheus scraper sees duplicate/ambiguous `le` series; the histogram is malformed and downstream queries silently misbehave.

**Impact.** Output integrity / observability correctness (CWE-682 incorrect calculation / CWE-684 incorrect output). **Low** — silent and undermines the monitoring signal the library exists to provide.

**Remediation.**

- Use a shortest-round-trip float format for `le` and `_sum` so distinct bounds always render distinctly, matching Prometheus client conventions.

**Regression test.** Register a histogram with bounds `{1e-7, 2e-7, 1.0}`, export, assert the two small-bucket `le` labels are textually distinct and cumulative counts are monotonic.

**Mapping.** OWASP A10; CWE-682/CWE-684; CIS v8.1.2 Control 16.

---

### L2 — Version string drift between code and manifest

**Evidence.**

- `root.zig:36` → `pub const version = "0.1.0";`
- `build.zig.zon:3` → `.version = "0.1.3"`
- `integration.zig:125` asserts the code value is `"0.1.0"`, and README install snippet references `v0.1.0` (README.md:24). Recent commits show tags up to v0.1.3.

**Impact.** Integrity/provenance weakness. A consumer reading `metrics.version` at runtime gets a value that does not match the package they resolved, undermining incident response and SBOM accuracy. **Low**.

**Remediation.** Surface the version via `build_options` from `build.zig.zon` (or a generated constant) so code and manifest cannot drift, and update the integration test to assert against that single source.

**Mapping.** OWASP A08; CIS v8.1.2 Control 2 (software inventory accuracy).

---

### I1 — Stale gap-analysis entry: CI **does** verify the Zig toolchain checksum (informational / doc fix)

**Evidence.** `docs/SECURITY_GAP_ANALYSIS.md:20` lists **S-006** "CI downloads Zig without checksum verification" as **Won't Do**. The current pipeline contradicts this: it fetches `ziglang.org/download/index.json`, extracts the official `shasum`, and runs `sha256sum --check --strict` on the downloaded tarball before extraction (`.gitlab-ci.yml:38-72`).

**Recommendation.** Reclassify S-006 from "Won't Do" to **Closed** with the `.gitlab-ci.yml:38-72` evidence.

---

### I2 — CI catalog components pinned by tag (accepted as S-005)

**Evidence.** `.gitlab-ci.yml:11-24` pins `gitlab.com/devnw/ci-catalog/*` components by `@v1.7.1` / `@v1.2.1` (mutable tags) rather than immutable SHAs. S-005 already accepts this on organizational-trust grounds. Recorded here only for completeness; no new action required. CWE-1357 applies in principle but is mitigated by same-org provenance.

---

## 5. Secure Design Notes (positive controls observed)

- **Injection defense is real and ordered correctly.** Name validation (`registry.zig:142-149`) and help validation rejecting `\n`/`\r`/`\` (`registry.zig:153-157`) run *before* the lock and *before* any allocation/output, fully closing the Prometheus-exposition injection class for names and help. (S-001/S-014/S-015 verified effective.)
- **Cross-type name-collision guard** (`nameInUse`, `registry.zig:160-165`) prevents duplicate `# TYPE` declarations (S-016 verified).
- **NaN/Inf hardening:** `observe()` drops non-finite values (`histogram.zig:116`), and bucket init rejects non-finite/unsorted/empty bucket sets (`histogram.zig:79-85`).
- **Snapshot-then-write under a real lock:** export captures values under the mutex and writes outside it (`prometheus.zig:24-29`, `registry.zig:313-323`).
- **Lock-free updates with an honestly-documented consistency model:** independent `.monotonic` atomics with a CAS loop for the f64 sum (`histogram.zig:145-159`).
- **Integer-range correctness:** counters use full `u64`, gauges `i64`, separate typed snapshot fields (`snapshot.zig:36-37`) (S-004). Timer clamps negative elapsed to zero (`timer.zig:86`, S-010).
- **Snapshot owns its bucket storage** (`snapshot.zig:53-62`, `registry.zig:599-657`) (S-011) — note this makes the *unfixed* M1 name/help borrowing the lone remaining borrow.
- **Supply-chain hygiene:** direct dep pinned by commit SHA **and** content hash (`build.zig.zon:8-9`); SHA-256-verified Zig toolchain (`.gitlab-ci.yml:38-72`); SBOM + SAST + dependency scanning + secret scanning + gitleaks in CI; diamond-dependency detector (`scripts/detect_diamond_deps.py`).
- **Pre-commit posture:** `detect-private-key`, `check-added-large-files`, shellcheck, ruff, zig fmt/build/test gates.
- **No global mutable state** (instance-based registry, MET-REQ-004).

---

## 6. Coverage Gaps and Questions

- **Transitive `thread_pool` internals** were not audited (out of scope). Only its `sync.zig` locking shim was validated.
- **`parallelSnapshot` adversarial sizing not exercised:** recommend a stress test registering tens of thousands of histograms/timers and snapshotting under a leak-checking allocator. Confirm `wg.wait()` (`registry.zig:580`) cannot block forever if `submitBatch` partially submitted before erroring.
- **Observability seam is dead code in default builds** (`enabled = false`). If `-Dwith_otel=true` is ever re-enabled, `observability_init.zig`'s pointer-stability contract (`installGlobals`, `observability_init.zig:96-107`) becomes load-bearing and should get a dedicated review.
- **Fuzzing is non-blocking:** the CI `fuzz` job runs 60s with `allow_failure: true`, schedule/manual only. `validateName`/`validateHelp`/`observe` are the highest-value fuzz targets.
- **No documented ownership contract for name/help** (the M1 root cause) — confirm whether borrowing is intentional zero-alloc design or oversight.

---

## 7. Prioritized Next Actions

1. **(M1, do first) Resolve the name/help ownership ambiguity.** Either `dupe` name/help into the registry allocator and free in `deinit` (recommended), or explicitly document the borrow on every register function. Add the heap-allocated-name regression test.
2. **(M2) Add an optional cardinality cap** (`RegistryOptions.max_metrics` + `error.CardinalityLimitExceeded`) and document low-cardinality naming requirements.
3. **(L1) Fix histogram float formatting** to shortest-round-trip precision for `le` and `_sum`, with a distinct-bucket regression test.
4. **(L2) Unify the version constant** with `build.zig.zon` via `build_options`; fix the integration assertion.
5. **(I1) Update `docs/SECURITY_GAP_ANALYSIS.md`:** reclassify **S-006** to **Closed** with the `.gitlab-ci.yml:38-72` SHA-256 evidence.
6. **(Hardening) Make fuzzing meaningful:** point the fuzz target at `validateName`/`validateHelp`/`observe`; add a leak-checked stress test for `parallelSnapshot` at high metric counts.

**Bottom line:** No confirmed Critical/High vulnerabilities in the reviewed scope. The injection, NaN/Inf, overflow, and supply-chain controls are real and effective. The actionable residual risks are a documented-but-violated string-ownership contract (M1, use-after-free class) and unbounded cardinality (M2, DoS class) — both Medium, both stemming from under-specified trust boundaries between the library and its caller rather than from coding defects in the hot path.
