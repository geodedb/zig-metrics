// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # metrics
//!
//! A standalone, instance-based metrics library for Zig.
//!
//! Provides counters, gauges, histograms, timers, and snapshots with a
//! thread-safe registry and Prometheus text format export.
//!
//! ## Quick Start
//!
//! ```zig
//! const metrics = @import("metrics");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     var reg = metrics.Registry.init(allocator);
//!     defer reg.deinit();
//!
//!     const requests = try reg.counter("http_requests_total", "Total HTTP requests");
//!     requests.inc();
//! }
//! ```
//!
//! ## License
//!
//! Apache-2.0

const std = @import("std");

/// Library version.
pub const version = "0.1.0";

// ============================================================================
// Public API - Re-exported modules
// ============================================================================

/// Thread-safe monotonically increasing counter.
pub const Counter = @import("counter.zig").Counter;

/// Thread-safe gauge (value can go up or down).
pub const Gauge = @import("gauge.zig").Gauge;

/// Histogram with configurable buckets.
pub const Histogram = @import("histogram.zig").Histogram;

/// Default Prometheus-style histogram buckets.
pub const default_buckets = @import("histogram.zig").default_buckets;

/// Timer for measuring durations (wraps a Histogram).
pub const Timer = @import("timer.zig").Timer;

/// Default timer buckets (seconds).
pub const default_timer_buckets = @import("timer.zig").default_timer_buckets;

/// Point-in-time snapshot types.
pub const Snapshot = @import("snapshot.zig").Snapshot;
pub const MetricSnapshot = @import("snapshot.zig").MetricSnapshot;
pub const MetricKind = @import("snapshot.zig").MetricKind;

/// Instance-based metrics registry (no global singletons).
pub const Registry = @import("registry.zig").Registry;
pub const RegistryError = @import("registry.zig").RegistryError;

/// Prometheus text format exporter.
pub const prometheus = @import("prometheus.zig");

/// Write all metrics from a registry in Prometheus text exposition format.
pub const writePrometheus = prometheus.writePrometheus;

// ============================================================================
// Unit Tests - ensure all submodules are referenced
// ============================================================================

test {
    std.testing.refAllDecls(@This());

    // Pull in all submodule tests
    _ = @import("counter.zig");
    _ = @import("gauge.zig");
    _ = @import("histogram.zig");
    _ = @import("timer.zig");
    _ = @import("snapshot.zig");
    _ = @import("registry.zig");
    _ = @import("prometheus.zig");
}
