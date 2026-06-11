# Prometheus Export

`writePrometheus` serializes all metrics in a registry to the Prometheus
text exposition format (version 0.0.4).

## Basic Usage

```zig
const metrics = @import("metrics");
const std = @import("std");

// Fixed buffer writer
var buf: [8192]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);
try metrics.writePrometheus(&reg, &writer);
const output = writer.buffered(); // []const u8 — Prometheus text

// Or write directly to a file / socket writer
try metrics.writePrometheus(&reg, file_writer);
```

## Snapshot-then-Write

`writePrometheus` captures a snapshot under the registry lock, then writes
to the output writer **outside** the lock:

```text
writePrometheus()
  └─ registry.snapshot()          ← shared (read) lock held, values captured
       └─ lock released
  └─ writeSnapshot(snap, writer)  ← I/O happens here, no lock held
```

Slow or blocking writers (network sockets, pipes) never stall metric
producers. The registry is unlocked before the first byte is written.

## Output Structure

Each metric produces a block of lines:

```text
# HELP <name> <help text>
# TYPE <name> <type>
<value line(s)>
```

### Counter

```text
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total 42
```

### Gauge

```text
# HELP active_connections Active connections
# TYPE active_connections gauge
active_connections 7
```

### Histogram and Timer

Histograms and timers both emit `histogram` type with cumulative bucket
lines, `+Inf`, `_sum`, and `_count`:

```text
# HELP request_latency_seconds Request latency
# TYPE request_latency_seconds histogram
request_latency_seconds_bucket{le="0.1"} 3
request_latency_seconds_bucket{le="0.5"} 7
request_latency_seconds_bucket{le="1"} 7
request_latency_seconds_bucket{le="+Inf"} 9
request_latency_seconds_sum 4.23
request_latency_seconds_count 9
```

Bucket counts are **cumulative**: each `le` line reports the number of
observations that are less than or equal to that bound. Observations above
all explicit bounds appear only in `+Inf` and `_count`.

`le` labels and `_sum` use Zig's shortest round-trip decimal formatting
(`{d}`) so that distinct bucket boundaries always produce distinct label
strings, even for sub-microsecond bounds like `1e-7` and `2e-7` (S-020).

## Empty Registry

An empty registry produces no output — `writePrometheus` writes zero bytes.

## Injection Safety

`writePrometheus` never needs to escape metric names or help text because
the Registry validates both at registration time:

- Names must match `[a-zA-Z_:][a-zA-Z0-9_:]*`.
- Help text must not contain `\n`, `\r`, or backslash.

Any string that passes registration is guaranteed to produce well-formed
Prometheus exposition output.

## Buffering Advice

Each metric emits several small `print` calls. If your writer is backed by
an unbuffered sink (raw socket, `std.fs.File` without buffering), wrap it
in a buffered writer to avoid a syscall per print:

```zig
// Example: write to an unbuffered file with buffering
var bw = std.io.bufferedWriter(file.writer());
// (std.io buffered writer — adapt to your actual writer type)
```

`std.Io.Writer.fixed` (used in tests) is already fully buffered in memory
and needs no wrapping.

## Full Example

```zig
const metrics = @import("metrics");
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();

    const reqs = try reg.counter("requests_total", "Total requests handled");
    reqs.add(3);

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try metrics.writePrometheus(&reg, &writer);

    std.debug.print("{s}", .{writer.buffered()});
}
```

Expected output:

```text
# HELP requests_total Total requests handled
# TYPE requests_total counter
requests_total 3
```

## HTTP Transport

`writePrometheus` accepts any `*std.Io.Writer`, so the library is
transport-agnostic. A typical `/metrics` HTTP handler:

```zig
fn handleMetrics(reg: *metrics.Registry, response_writer: *std.Io.Writer) !void {
    try metrics.writePrometheus(reg, response_writer);
}
```

Set the response `Content-Type` header to `text/plain; version=0.0.4`.
HTTP server wiring is the responsibility of the embedding application —
see MET-REQ-005.
