const std = @import("std");

const codec = @import("codec.zig");

pub const Outcome = enum {
    accepted,
    duplicate,
    invalid,
    rate_limited,
    blocked,
    auth_required,
    restricted,
    pow,
    @"error",

    pub fn of(ok: codec.Ok) Outcome {
        const prefix = ok.prefix orelse return .accepted;
        return switch (prefix) {
            .duplicate => .duplicate,
            .invalid => .invalid,
            .rate_limited => .rate_limited,
            .blocked => .blocked,
            .auth_required => .auth_required,
            .restricted => .restricted,
            .pow => .pow,
            .internal => .@"error",
        };
    }

    fn label(self: Outcome) []const u8 {
        return switch (self) {
            .rate_limited => "rate-limited",
            .auth_required => "auth-required",
            inline else => |tag| @tagName(tag),
        };
    }
};

/// A Prometheus histogram over seconds with fixed buckets, safe to observe from any thread.
pub const Histogram = struct {
    counts: [bounds.len + 1]std.atomic.Value(u64) = @splat(.init(0)),
    sum_ns: std.atomic.Value(u64) = .init(0),

    pub const bounds = [_]f64{ 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5 };

    pub fn observe(self: *Histogram, nanoseconds: u64) void {
        const seconds = @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s;
        const slot = for (bounds, 0..) |bound, position| {
            if (seconds <= bound) break position;
        } else bounds.len;
        _ = self.counts[slot].fetchAdd(1, .monotonic);
        _ = self.sum_ns.fetchAdd(nanoseconds, .monotonic);
    }

    fn write(self: *const Histogram, writer: *std.Io.Writer, name: []const u8, help: []const u8) std.Io.Writer.Error!void {
        try writer.print("# HELP {s} {s}\n# TYPE {s} histogram\n", .{ name, help, name });
        var cumulative: u64 = 0;
        for (bounds, 0..) |bound, position| {
            cumulative += self.counts[position].load(.monotonic);
            try writer.print("{s}_bucket{{le=\"{d}\"}} {d}\n", .{ name, bound, cumulative });
        }
        cumulative += self.counts[bounds.len].load(.monotonic);
        try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ name, cumulative });
        const sum = @as(f64, @floatFromInt(self.sum_ns.load(.monotonic))) / std.time.ns_per_s;
        try writer.print("{s}_sum {d}\n{s}_count {d}\n", .{ name, sum, name, cumulative });
    }
};

/// What is measured at scrape time rather than counted as it happens.
pub const Gauges = struct {
    connections: usize,
    subscriptions: usize,
    write_queue_depth: usize,
    store_events: ?u64 = null,
    store_map_used_ratio: ?f64 = null,
};

pub const Metrics = struct {
    events_received: [std.meta.fields(Outcome).len]std.atomic.Value(u64) = @splat(.init(0)),
    validation: Histogram = .{},
    query: Histogram = .{},
    scan_budget_exhausted: std.atomic.Value(u64) = .init(0),

    pub fn received(self: *Metrics, ok: codec.Ok) void {
        _ = self.events_received[@intFromEnum(Outcome.of(ok))].fetchAdd(1, .monotonic);
    }

    pub fn exhausted(self: *Metrics) void {
        _ = self.scan_budget_exhausted.fetchAdd(1, .monotonic);
    }

    /// Prometheus text exposition format 0.0.4.
    pub fn write(self: *const Metrics, writer: *std.Io.Writer, gauges: Gauges) std.Io.Writer.Error!void {
        try gauge(writer, "easyrelay_connections_active", "Open WebSocket connections.", gauges.connections);
        try gauge(writer, "easyrelay_subscriptions_active", "Open subscriptions across every connection.", gauges.subscriptions);
        try gauge(writer, "easyrelay_write_queue_depth", "Events waiting for the writer thread.", gauges.write_queue_depth);
        if (gauges.store_events) |events| try gauge(writer, "easyrelay_store_events", "Events in the store.", events);
        if (gauges.store_map_used_ratio) |ratio| {
            try writer.writeAll("# HELP easyrelay_store_map_used_ratio Fraction of storage.map_size in use.\n" ++
                "# TYPE easyrelay_store_map_used_ratio gauge\n");
            try writer.print("easyrelay_store_map_used_ratio {d}\n", .{ratio});
        }

        try writer.writeAll("# HELP easyrelay_events_received_total Events received, by outcome.\n" ++
            "# TYPE easyrelay_events_received_total counter\n");
        inline for (std.meta.fields(Outcome)) |field| {
            const outcome: Outcome = @enumFromInt(field.value);
            try writer.print("easyrelay_events_received_total{{outcome=\"{s}\"}} {d}\n", .{
                outcome.label(),
                self.events_received[field.value].load(.monotonic),
            });
        }
        try writer.writeAll("# HELP easyrelay_query_scan_budget_exhausted_total Queries answered early at storage.max_scan.\n" ++
            "# TYPE easyrelay_query_scan_budget_exhausted_total counter\n");
        try writer.print("easyrelay_query_scan_budget_exhausted_total {d}\n", .{self.scan_budget_exhausted.load(.monotonic)});

        try self.validation.write(writer, "easyrelay_event_validation_seconds", "Time to validate an event, signature included.");
        try self.query.write(writer, "easyrelay_query_seconds", "Time to answer a REQ's stored phase.");
    }
};

fn gauge(writer: *std.Io.Writer, name: []const u8, help: []const u8, value: anytype) std.Io.Writer.Error!void {
    try writer.print("# HELP {s} {s}\n# TYPE {s} gauge\n{s} {d}\n", .{ name, help, name, name, value });
}

const testing = std.testing;

test "outcomes follow the OK prefix" {
    try testing.expectEqual(Outcome.accepted, Outcome.of(.{ .event_id = undefined, .accepted = true }));
    try testing.expectEqual(Outcome.duplicate, Outcome.of(.{ .event_id = undefined, .accepted = true, .prefix = .duplicate }));
    try testing.expectEqual(Outcome.@"error", Outcome.of(.{ .event_id = undefined, .accepted = false, .prefix = .internal }));
}

test "a histogram counts cumulatively and sums its observations" {
    var histogram: Histogram = .{};
    histogram.observe(50 * std.time.ns_per_us);
    histogram.observe(2 * std.time.ns_per_ms);
    histogram.observe(10 * std.time.ns_per_s);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try histogram.write(&out.writer, "x_seconds", "help");
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "x_seconds_bucket{le=\"0.0001\"} 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "x_seconds_bucket{le=\"0.005\"} 2\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "x_seconds_bucket{le=\"5\"} 2\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "x_seconds_bucket{le=\"+Inf\"} 3\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "x_seconds_count 3\n") != null);
}

test "the exposition names every metric operations.md promises" {
    var metrics: Metrics = .{};
    metrics.received(.{ .event_id = undefined, .accepted = false, .prefix = .rate_limited });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try metrics.write(&out.writer, .{ .connections = 3, .subscriptions = 5, .write_queue_depth = 0, .store_events = 9, .store_map_used_ratio = 0.25 });
    const text = out.written();
    for ([_][]const u8{
        "easyrelay_connections_active 3\n",
        "easyrelay_subscriptions_active 5\n",
        "easyrelay_write_queue_depth 0\n",
        "easyrelay_store_events 9\n",
        "easyrelay_store_map_used_ratio 0.25\n",
        "easyrelay_events_received_total{outcome=\"rate-limited\"} 1\n",
        "easyrelay_query_scan_budget_exhausted_total 0\n",
        "easyrelay_event_validation_seconds_count 0\n",
        "easyrelay_query_seconds_count 0\n",
    }) |expected| {
        testing.expect(std.mem.indexOf(u8, text, expected) != null) catch |err| {
            std.debug.print("missing: {s}", .{expected});
            return err;
        };
    }
}
