// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Zig 0.16 compatibility shims shared across the library (Q-023).
//!
//! std.time.nanoTimestamp() was removed in 0.16; the Io clock API
//! replaces it. Two variants are exposed because they answer different
//! questions (P-011):
//! - wall (.real / CLOCK_REALTIME): "what time is it" — snapshot
//!   timestamps. Settable, NTP-stepped; never use for durations.
//! - monotonic (.awake / CLOCK_MONOTONIC): "how much time elapsed" —
//!   timer duration measurement. Immune to clock steps.

const std = @import("std");

/// Wall-clock timestamp in nanoseconds (CLOCK_REALTIME).
/// Use for point-in-time labels (e.g. Snapshot.timestamp_ns).
pub fn nanoTimestampWall() i96 {
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io_inst, .real).raw.toNanoseconds();
}

/// Monotonic timestamp in nanoseconds (CLOCK_MONOTONIC).
/// Use for measuring elapsed durations (Timer).
pub fn nanoTimestampMonotonic() i96 {
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io_inst, .awake).raw.toNanoseconds();
}

test "wall and monotonic clocks both advance" {
    const w = nanoTimestampWall();
    const m = nanoTimestampMonotonic();
    try std.testing.expect(w > 0);
    try std.testing.expect(m > 0);
}
