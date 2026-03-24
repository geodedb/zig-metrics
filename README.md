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

## Documentation

See the [docs](docs/) directory for detailed documentation.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
