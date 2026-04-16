// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic usage example for the metrics library.
//!
//! Demonstrates creating a registry, registering metrics, recording values,
//! and exporting in Prometheus text format.
//!
//! This file is not wired into the build system.
//! See tests/integration.zig for runnable usage examples.

const std = @import("std");
// Note: When using as a dependency, import as:
// const metrics = @import("metrics");
// This example uses direct imports since it's not wired into the build system.

pub fn main() !void {
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    var buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io_inst, &buf);
    const stdout = &stdout_fw.interface;

    try stdout.print("metrics library example\n", .{});
    try stdout.print("========================\n\n", .{});

    // In a real application, import "metrics" and use:
    //
    //   var reg = metrics.Registry.init(allocator);
    //   defer reg.deinit();
    //
    //   const requests = try reg.counter("http_requests_total", "Total HTTP requests");
    //   requests.inc();
    //
    //   const connections = try reg.gauge("active_connections", "Active connections");
    //   connections.set(42);
    //
    //   const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0, 5.0 };
    //   const latency = try reg.histogram("request_latency_seconds", "Latency", &buckets);
    //   latency.observe(0.03);
    //
    //   const timer = try reg.timer("db_query_seconds", "DB query time", &buckets);
    //   const sample = timer.start();
    //   // ... do work ...
    //   sample.finish();
    //
    //   // Export to Prometheus format
    //   try metrics.writePrometheus(&reg, writer);
    //
    //   // Or take a snapshot
    //   var snap = try reg.snapshot();
    //   defer snap.deinit();

    try stdout.print("See src/root.zig for the full public API.\n", .{});
    try stdout.print("See tests/integration.zig for working usage examples.\n", .{});
    try stdout.flush();
}
