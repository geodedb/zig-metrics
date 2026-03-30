# Benchmark Results

This directory stores performance baseline and historical benchmark results.

## File Naming

| File | Purpose |
|---|---|
| `baseline.json` | Current accepted performance baseline |
| `<short-sha>.json` | Results saved per-commit via `make bench-save` |

## JSON Format

```json
{
  "version": 1,
  "timestamp": "2026-03-30T12:00:00Z",
  "system": {
    "os": "linux",
    "arch": "x86_64"
  },
  "tiers": [
    {
      "name": "light",
      "metric_count": 10,
      "thread_count": 2,
      "counter_ops_sec": 123456789,
      "gauge_ops_sec": 123456789,
      "histogram_ops_sec": 12345678,
      "timer_ops_sec": 12345678,
      "registration_ns": 1234.5,
      "snapshot_ms": 0.1,
      "parallel_snapshot_ms": 0.1,
      "prometheus_ms": 0.5,
      "mixed_ops_sec": 12345678
    }
  ]
}
```

## Metrics

| Metric | Direction | Unit | Description |
|---|---|---|---|
| `counter_ops_sec` | Higher is better | ops/s | Counter increment throughput under contention |
| `gauge_ops_sec` | Higher is better | ops/s | Gauge update throughput under contention |
| `histogram_ops_sec` | Higher is better | ops/s | Histogram observe throughput under contention |
| `timer_ops_sec` | Higher is better | ops/s | Timer record throughput under contention |
| `registration_ns` | Lower is better | ns | Per-metric registration time |
| `snapshot_ms` | Lower is better | ms | Sequential snapshot capture time |
| `parallel_snapshot_ms` | Lower is better | ms | Parallel snapshot capture time (spice) |
| `prometheus_ms` | Lower is better | ms | Prometheus text export time |
| `mixed_ops_sec` | Higher is better | ops/s | Mixed workload throughput (40% counter, 20% gauge, 30% histogram, 10% timer) |

## Tiers

| Tier | Metrics | Threads | Iterations/thread |
|---|---|---|---|
| light | 10 | 2 | 100K |
| moderate | 50 | 4 | 500K |
| heavy | 200 | 8 | 1M |
| extreme | 500 | 16 | 2M |

## Workflow

```sh
# Run scale benchmark (human-readable to stderr, JSON to stdout)
make scale-bench

# Save results with current commit SHA
make bench-save

# Set current results as the baseline
make bench-baseline

# Run and compare against baseline (exits 1 on regression)
make bench-compare
```
