//! observability.zig — single-file otel seam.
//!
//! When build_options.with_otel == false, every public function in this file
//! collapses to a comptime-known no-op so the optimizer eliminates the call
//! site entirely. When true, calls forward to the appropriate
//! `otel.api.trace`/`otel.api.metrics` helper.
//!
//! INVARIANT: every emit is `catch {}`-discarded. A failing exporter never
//! reaches the caller.
//!
//! NOTE: metrics is a build-flag-only consumer. No source file in this repo
//! calls into the seam, and individual counter/gauge/histogram increment
//! sites deliberately remain uninstrumented — span emission on every metric
//! mutation would be both far too high-volume to be useful and would create
//! a feedback loop, since otel itself depends on metrics under
//! `-Dotel_use_devnw_metrics=true`. The seam is exposed for two reasons:
//! forward compatibility (a future metrics operation with a natural span
//! surface — e.g. a registry-wide flush — could call into it without
//! re-plumbing flags or symbols) and consumer wiring (an application that
//! embeds metrics inside an OpenTelemetry-aware service can use it to
//! instrument its own metric mutation call sites with the same conventions
//! and helpers the rest of the devnw/zig stack uses).

const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.with_otel;

const otel = if (enabled) @import("otel") else struct {};

/// Opaque handle for an in-flight operation. When disabled, this is a
/// zero-sized struct the optimizer drops entirely. The no-op fallback's
/// `end` signature MUST match `otel.api.trace.Span.end(?u64) void` so
/// callers can write `span.end(null)` regardless of `enabled` state.
pub const Span = if (enabled) otel.api.trace.Span else struct {
    pub fn end(self: @This(), _: ?u64) void {
        _ = self;
    }
};

/// Start a span for an outbound operation. The caller passes anything with
/// `method_string()` and `url_string()` accessors. metrics itself never
/// invokes this — the duck-typed shape matches the canonical seam shape so
/// consumers can wire it from their own code if useful.
pub fn startClientSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startClientSpan(
        tracer.*,
        .empty(),
        .{
            .method = req.method_string(),
            .url = req.url_string(),
        },
    ) catch return Span{};
    return span;
}

pub fn endClientSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endClientSpan(span, .{ .status_code = status });
}

/// Start a span for an inbound operation. The caller passes anything with
/// `method_string()`, `route_string()`, and `url_string()` accessors. metrics
/// itself never invokes this — the shape matches the canonical seam shape so
/// consumers can wire it from their own server-side code if useful.
pub fn startServerSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startServerSpan(
        tracer.*,
        .empty(),
        .{
            .method = req.method_string(),
            .route = req.route_string(),
            .url = req.url_string(),
        },
    ) catch return Span{};
    return span;
}

pub fn endServerSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endServerSpan(span, status);
}

/// Set once at process start by `observability_init.Otel.init`. Only
/// referenced when enabled is true; otherwise the optimizer drops it.
pub const global = if (enabled) struct {
    pub var tracer: ?*otel.api.trace.Tracer = null;
    pub var meter: ?*otel.api.metrics.Meter = null;
} else struct {};
