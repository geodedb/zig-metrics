# metrics

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15.1+-orange.svg)](https://ziglang.org/)

A Zig library for metrics

## Features

- **Zero Dependencies**: Pure Zig standard library only
- **Memory Safe**: Proper allocation patterns with no leaks
- **Cross-Platform**: Linux, macOS support (Windows cross-compiles but is not CI-validated)
- **Well Tested**: Comprehensive unit and integration tests

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .metrics = .{
        .url = "https://gitlab.com/devnw/zig/metrics/-/archive/v0.1.0/metrics-v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const metrics = b.dependency("metrics", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("metrics", metrics.module("metrics"));
```

## Quick Start

```zig
const std = @import("std");
const metrics = @import("metrics");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create an instance-based registry (no globals)
    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();

    // Register and use metrics
    const requests = try reg.counter("http_requests_total", "Total HTTP requests");
    requests.inc();

    const connections = try reg.gauge("active_connections", "Active connections");
    connections.set(42);

    const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0, 5.0 };
    const latency = try reg.histogram("request_latency_seconds", "Latency", &buckets);
    latency.observe(0.03);

    // Export to Prometheus text format
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try metrics.writePrometheus(&reg, fbs.writer());
}
```

## Requirements

- Zig 0.15.1 or later

## Building

```bash
# Build the library
make build

# Run tests
make test

# Quick development iteration
make dev

# Full CI pipeline
make ci
```

## Observability

`metrics` carries an opt-in OpenTelemetry seam exposed at
`metrics.observability` (and a bootstrap helper at
`metrics.observability_init`). It is **off by default**; building or
depending on `metrics` without any extra flags emits zero
otel/observability symbols and never resolves the otel package.

To compile in the seam:

```sh
zig build test -Dwith_otel=true
# or, when consuming metrics as a dependency:
zig build -Dwith_otel=true
```

When the flag is on, the otel package is fetched lazily from the pinned
SHA in `build.zig.zon` (`.otel`). When it is off, the verifier
`otel/scripts/verify-consumer-noop.sh` confirms no
`otel`/`observability` symbols leak into the metrics build artifacts.

**`metrics` is build-flag-only — instrumenting individual counter
increments would be too high-volume and could create feedback loops.**
Counter, gauge, histogram, and timer mutations happen on hot paths
where adding a span emit per increment would (a) explode telemetry
volume far beyond anything useful, and (b) form an observability cycle,
since `otel` itself depends on `metrics` under
`-Dotel_use_devnw_metrics=true`. The cycle is broken at build time
because both edges are lazy: `otel`'s `metrics` edge is only walked
when the operator opts into the devnw aggregation registry, and
`metrics`'s `otel` edge is only walked when `-Dwith_otel=true`. Neither
default-flag build resolves the other.

The seam is exposed for two reasons:

1. **Forward compatibility**: a future metrics operation with a natural
   span surface (e.g. a registry-wide flush, an exporter handshake) can
   call into the seam without re-plumbing the package manifest, build
   flags, or symbol surface.
2. **Consumer wiring**: applications that embed `metrics` inside an
   OpenTelemetry-aware service can use `metrics.observability` to
   instrument their own metric mutation call sites with the same
   conventions and helpers the rest of the devnw/zig stack uses.

See `src/observability.zig` for the seam surface and
`src/observability_init.zig` for the bootstrap helper. The integration
recipe lives at `otel/docs/integration/RECIPE.md` in the otel
repository.

## Documentation

See the [docs](docs/) directory for detailed documentation.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
