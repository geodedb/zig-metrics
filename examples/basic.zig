// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic usage example for the metrics library.
//!
//! Demonstrates creating a registry, registering metrics, recording
//! values, and exporting in Prometheus text format.
//!
//! Run with: zig build example

const std = @import("std");
const metrics = @import("metrics");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = metrics.Registry.init(allocator);
    defer reg.deinit();

    const requests = try reg.counter("http_requests_total", "Total HTTP requests");
    requests.inc();
    requests.add(99);

    const connections = try reg.gauge("active_connections", "Active connections");
    connections.set(42);

    const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0, 5.0 };
    const latency = try reg.histogram("request_latency_seconds", "Latency", &buckets);
    latency.observe(0.03);

    const db_timer = try reg.timer("db_query_seconds", "DB query time", &buckets);
    const sample = db_timer.start();
    sample.finish();

    // Export to Prometheus text format on stdout.
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    var out_buf: [8192]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io_inst, &out_buf);
    const stdout = &stdout_fw.interface;
    try metrics.writePrometheus(&reg, stdout);
    try stdout.flush();
}
