const std = @import("std");

pub const default_path = "easyrelay.zon";

pub const Config = struct {
    network: Network = .{},
    storage: Storage = .{},
    limits: Limits = .{},
    rate_limit: RateLimit = .{},
    info: Info = .{},
};

pub const Network = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 7777,
    max_connections: usize = 1024,
    handshake_timeout_ms: u32 = 5000,
};

pub const Storage = struct {
    path: []const u8 = "./data",
    map_size: usize = 10 * 1024 * 1024 * 1024,
    durable: bool = true,
    max_scan: usize = 100_000,
};

pub const Limits = struct {
    max_event_size: usize = 65536,
    max_message_size: usize = 131072,
    max_event_tags: usize = 2000,
    max_content_length: usize = 65536,
    max_subscriptions: usize = 20,
    max_filters: usize = 10,
    max_limit: usize = 5000,
    default_limit: usize = 500,
    max_subid_length: usize = 64,
    created_at_upper_limit_s: i64 = 900,
    created_at_lower_limit_s: ?i64 = null,
};

pub const RateLimit = struct {
    write_queue_depth: usize = 4096,
};

pub const Info = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    banner: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    pubkey: ?[]const u8 = null,
    contact: ?[]const u8 = null,
    posting_policy: ?[]const u8 = null,
    privacy_policy: ?[]const u8 = null,
    terms_of_service: ?[]const u8 = null,
    relay_countries: []const []const u8 = &.{},
    language_tags: []const []const u8 = &.{},
};

const descriptions = .{
    .network = .{
        .address = "Bind address. Loopback by default: put a TLS reverse proxy in front before exposing it.",
        .port = "Bind port.",
        .max_connections = "Connections accepted before new ones are refused.",
        .handshake_timeout_ms = "Time allowed to complete the WebSocket handshake.",
    },
    .storage = .{
        .path = "Data directory. The LMDB environment lives in its `events` subdirectory.",
        .map_size = "LMDB map size in bytes. Address space, not a disk reservation, but a hard ceiling.",
        .durable = "Sync on commit. `false` trades durability for throughput.",
        .max_scan = "Index entries one query may examine before it is answered early.",
    },
    .limits = .{
        .max_event_size = "Serialized event bytes.",
        .max_message_size = "WebSocket message bytes.",
        .max_event_tags = "Tags per event.",
        .max_content_length = "`content` bytes.",
        .max_subscriptions = "Open subscriptions per connection.",
        .max_filters = "Filters per REQ.",
        .max_limit = "Cap applied to a filter's `limit`.",
        .default_limit = "Applied when a filter has no `limit`.",
        .max_subid_length = "Subscription id characters.",
        .created_at_upper_limit_s = "Seconds into the future an event may claim.",
        .created_at_lower_limit_s = "Seconds into the past an event may claim. `null` disables the check.",
    },
    .rate_limit = .{
        .write_queue_depth = "Pending writes before events are refused with rate-limited:.",
    },
    .info = .{
        .name = "Relay name in the NIP-11 document.",
        .description = "Relay description in the NIP-11 document.",
        .banner = "Banner image URL.",
        .icon = "Icon image URL.",
        .pubkey = "Operator pubkey, 64 lowercase hex characters.",
        .contact = "Operator contact, such as a mailto: URI.",
        .posting_policy = "Posting policy URL.",
        .privacy_policy = "Privacy policy URL.",
        .terms_of_service = "Terms of service URL.",
        .relay_countries = "ISO 3166-1 alpha-2 codes.",
        .language_tags = "IETF language tags.",
    },
};

pub const Error = error{ InvalidConfig, OutOfMemory };

/// Holds the reason for the last `error.InvalidConfig`, naming the offending key.
pub const Diagnostics = struct {
    buffer: [1024]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostics) []const u8 {
        return self.buffer[0..self.len];
    }

    fn fail(self: *Diagnostics, comptime format: []const u8, args: anytype) error{InvalidConfig} {
        const written = std.fmt.bufPrint(&self.buffer, format, args) catch blk: {
            const marker = "...";
            @memcpy(self.buffer[self.buffer.len - marker.len ..], marker);
            break :blk self.buffer[0..];
        };
        self.len = written.len;
        return error.InvalidConfig;
    }
};

/// Parses a configuration file. Everything returned is allocated in `arena`.
pub fn parse(arena: std.mem.Allocator, source: [:0]const u8, path: []const u8, diagnostics: *Diagnostics) Error!Config {
    var zon: std.zon.parse.Diagnostics = .{};
    defer zon.deinit(arena);
    return std.zon.parse.fromSliceAlloc(Config, arena, source, &zon, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParseZon => {
            var text: std.Io.Writer.Allocating = .init(arena);
            zon.format(&text.writer) catch return error.OutOfMemory;
            const first_line = std.mem.sliceTo(text.written(), '\n');
            const marker = ": error: ";
            const at = std.mem.indexOf(u8, first_line, marker) orelse first_line.len;
            const reason = if (at == first_line.len) "" else first_line[at + marker.len ..];
            return diagnostics.fail("{s}:{s}: {s}", .{ path, first_line[0..at], reason });
        },
    };
}

/// Applies `EASYRELAY_<SECTION>_<KEY>` variables. A list is comma-separated; `null` clears an optional.
pub fn applyEnvironment(arena: std.mem.Allocator, config: *Config, environment: *const std.process.Environ.Map, diagnostics: *Diagnostics) Error!void {
    inline for (@typeInfo(Config).@"struct".fields) |section| {
        const values = &@field(config, section.name);
        inline for (@typeInfo(section.type).@"struct".fields) |field| {
            const name = comptime environmentName(section.name, field.name);
            if (environment.get(name)) |text| {
                @field(values, field.name) = try parseValue(field.type, arena, text) orelse
                    return diagnostics.fail("{s}: cannot read \"{s}\" as {s}", .{ name, text, describeType(field.type) });
            }
        }
    }
}

fn environmentName(comptime section: []const u8, comptime field: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000);
        var name: []const u8 = "EASYRELAY_";
        for (section ++ "_" ++ field) |char| name = name ++ .{std.ascii.toUpper(char)};
        return name;
    }
}

fn parseValue(comptime T: type, arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?T {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (std.mem.eql(u8, text, "null")) return @as(T, null);
            return @as(?T, try parseValue(optional.child, arena, text) orelse return null);
        },
        .bool => {
            if (std.mem.eql(u8, text, "true")) return true;
            if (std.mem.eql(u8, text, "false")) return false;
            return null;
        },
        .int => return std.fmt.parseInt(T, text, 10) catch null,
        .pointer => |pointer| {
            if (pointer.child == u8) return try arena.dupe(u8, text);
            var items: std.ArrayList([]const u8) = .empty;
            var parts = std.mem.splitScalar(u8, text, ',');
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (trimmed.len != 0) try items.append(arena, try arena.dupe(u8, trimmed));
            }
            return items.items;
        },
        else => @compileError("unsupported setting type " ++ @typeName(T)),
    }
}

fn describeType(comptime T: type) []const u8 {
    return comptime switch (@typeInfo(T)) {
        .optional => |optional| describeType(optional.child) ++ " or null",
        .bool => "true or false",
        .int => "an integer in range for " ++ @typeName(T),
        .pointer => |pointer| if (pointer.child == u8) "a string" else "a comma-separated list",
        else => @typeName(T),
    };
}

/// Rejects values that are in range for their type but cannot work, or that contradict each other.
pub fn validate(config: Config, diagnostics: *Diagnostics) error{InvalidConfig}!void {
    const limits = config.limits;
    if (config.network.address.len == 0) return diagnostics.fail("network.address must not be empty", .{});
    if (config.network.port == 0) return diagnostics.fail("network.port must not be 0", .{});
    if (config.network.max_connections == 0) return diagnostics.fail("network.max_connections must be at least 1", .{});
    if (config.storage.path.len == 0) return diagnostics.fail("storage.path must not be empty", .{});
    if (config.storage.map_size < 1024 * 1024) return diagnostics.fail("storage.map_size is {d} bytes; it must be at least 1048576 (1 MiB)", .{config.storage.map_size});
    if (config.storage.max_scan == 0) return diagnostics.fail("storage.max_scan must be at least 1", .{});
    if (config.rate_limit.write_queue_depth == 0) return diagnostics.fail("rate_limit.write_queue_depth must be at least 1", .{});
    inline for (.{ "max_event_size", "max_message_size", "max_subscriptions", "max_filters", "max_limit", "max_subid_length" }) |name| {
        if (@field(limits, name) == 0) return diagnostics.fail("limits." ++ name ++ " must be at least 1", .{});
    }
    if (limits.default_limit > limits.max_limit) return diagnostics.fail(
        "limits.default_limit ({d}) is above limits.max_limit ({d}); lower default_limit or raise max_limit",
        .{ limits.default_limit, limits.max_limit },
    );
    if (limits.max_event_size > limits.max_message_size) return diagnostics.fail(
        "limits.max_event_size ({d}) is above limits.max_message_size ({d}), so no event that large could arrive; raise max_message_size",
        .{ limits.max_event_size, limits.max_message_size },
    );
    if (limits.max_content_length > limits.max_event_size) return diagnostics.fail(
        "limits.max_content_length ({d}) is above limits.max_event_size ({d}); lower max_content_length",
        .{ limits.max_content_length, limits.max_event_size },
    );
    if (limits.created_at_upper_limit_s < 0) return diagnostics.fail("limits.created_at_upper_limit_s must not be negative", .{});
    if (limits.created_at_lower_limit_s) |lower| if (lower < 0) return diagnostics.fail("limits.created_at_lower_limit_s must not be negative", .{});
    if (config.info.pubkey) |pubkey| {
        const hex = pubkey.len == 64 and for (pubkey) |char| switch (char) {
            '0'...'9', 'a'...'f' => {},
            else => break false,
        } else true;
        if (!hex) return diagnostics.fail("info.pubkey must be 64 lowercase hex characters", .{});
    }
}

/// Writes a configuration file holding every setting at its default, each with its description.
pub fn writeTemplate(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const defaults: Config = .{};
    try writer.writeAll(
        \\// easyrelay configuration. Every value below is the default; delete what you do not change.
        \\// Any setting can also be set as EASYRELAY_<SECTION>_<KEY>, which wins over this file.
        \\.{
        \\
    );
    inline for (@typeInfo(Config).@"struct".fields) |section| {
        try writer.print("    .{s} = .{{\n", .{section.name});
        inline for (@typeInfo(section.type).@"struct".fields) |field| {
            try writer.print("        // {s}\n        .{s} = ", .{ @field(@field(descriptions, section.name), field.name), field.name });
            try writeValue(writer, @field(@field(defaults, section.name), field.name));
            try writer.writeAll(",\n");
        }
        try writer.writeAll("    },\n");
    }
    try writer.writeAll("}\n");
}

fn writeValue(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => if (value) |present| try writeValue(writer, present) else try writer.writeAll("null"),
        .bool, .int => try writer.print("{}", .{value}),
        .pointer => |pointer| {
            if (pointer.child == u8) return writer.print("\"{f}\"", .{std.zig.fmtString(value)});
            try writer.writeAll(".{");
            for (value, 0..) |item, position| {
                try writer.writeAll(if (position == 0) " " else ", ");
                try writeValue(writer, item);
            }
            try writer.writeAll(if (value.len == 0) "}" else " }");
        },
        else => @compileError("unsupported setting type " ++ @typeName(T)),
    }
}

const testing = std.testing;

fn parseText(arena: std.mem.Allocator, text: []const u8, diagnostics: *Diagnostics) Error!Config {
    return parse(arena, try arena.dupeZ(u8, text), "easyrelay.zon", diagnostics);
}

test "the template parses back to exactly the defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text: std.Io.Writer.Allocating = .init(arena);
    try writeTemplate(&text.writer);
    var diagnostics: Diagnostics = .{};
    const parsed = parseText(arena, text.written(), &diagnostics) catch |err| {
        std.debug.print("{s}\n", .{diagnostics.message()});
        return err;
    };
    try testing.expectEqualDeep(Config{}, parsed);
    try validate(parsed, &diagnostics);
}

test "the template describes every setting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var text: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try writeTemplate(&text.writer);
    inline for (@typeInfo(Config).@"struct".fields) |section| {
        inline for (@typeInfo(section.type).@"struct".fields) |field| {
            try testing.expect(std.mem.indexOf(u8, text.written(), "." ++ field.name ++ " = ") != null);
        }
    }
}

test "an empty file and a partial file keep every other default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diagnostics: Diagnostics = .{};

    try testing.expectEqualDeep(Config{}, try parseText(arena_state.allocator(), ".{}", &diagnostics));
    const partial = try parseText(arena_state.allocator(), ".{ .network = .{ .port = 8080 }, .info = .{ .name = \"x\" } }", &diagnostics);
    try testing.expectEqual(@as(u16, 8080), partial.network.port);
    try testing.expectEqualStrings("127.0.0.1", partial.network.address);
    try testing.expectEqualStrings("x", partial.info.name.?);
}

test "an unknown key stops the load and is named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diagnostics: Diagnostics = .{};
    try testing.expectError(error.InvalidConfig, parseText(arena_state.allocator(), ".{ .network = .{ .prot = 1 } }", &diagnostics));
    try testing.expectEqualStrings("easyrelay.zon:1:19: unexpected field 'prot'", diagnostics.message());
}

test "a value out of range for its type stops the load and is named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diagnostics: Diagnostics = .{};
    try testing.expectError(error.InvalidConfig, parseText(arena_state.allocator(), ".{ .network = .{ .port = 70000 } }", &diagnostics));
    try testing.expect(std.mem.indexOf(u8, diagnostics.message(), "easyrelay.zon:1:") != null);
}

test "environment variables override the file and name themselves when malformed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environment = std.process.Environ.Map.init(arena);
    try environment.put("EASYRELAY_NETWORK_PORT", "9000");
    try environment.put("EASYRELAY_STORAGE_DURABLE", "false");
    try environment.put("EASYRELAY_LIMITS_CREATED_AT_LOWER_LIMIT_S", "3600");
    try environment.put("EASYRELAY_INFO_NAME", "from env");
    try environment.put("EASYRELAY_INFO_LANGUAGE_TAGS", "en, es");

    var config: Config = .{};
    var diagnostics: Diagnostics = .{};
    try applyEnvironment(arena, &config, &environment, &diagnostics);
    try testing.expectEqual(@as(u16, 9000), config.network.port);
    try testing.expect(!config.storage.durable);
    try testing.expectEqual(@as(?i64, 3600), config.limits.created_at_lower_limit_s);
    try testing.expectEqualStrings("from env", config.info.name.?);
    try testing.expectEqual(@as(usize, 2), config.info.language_tags.len);
    try testing.expectEqualStrings("es", config.info.language_tags[1]);

    try environment.put("EASYRELAY_NETWORK_PORT", "seventy");
    try testing.expectError(error.InvalidConfig, applyEnvironment(arena, &config, &environment, &diagnostics));
    try testing.expect(std.mem.startsWith(u8, diagnostics.message(), "EASYRELAY_NETWORK_PORT"));
}

test "every validation error names the setting it is about" {
    const Case = struct { config: Config, key: []const u8 };
    const cases = [_]Case{
        .{ .config = .{ .network = .{ .address = "" } }, .key = "network.address" },
        .{ .config = .{ .network = .{ .port = 0 } }, .key = "network.port" },
        .{ .config = .{ .network = .{ .max_connections = 0 } }, .key = "network.max_connections" },
        .{ .config = .{ .storage = .{ .path = "" } }, .key = "storage.path" },
        .{ .config = .{ .storage = .{ .map_size = 4096 } }, .key = "storage.map_size" },
        .{ .config = .{ .storage = .{ .max_scan = 0 } }, .key = "storage.max_scan" },
        .{ .config = .{ .rate_limit = .{ .write_queue_depth = 0 } }, .key = "rate_limit.write_queue_depth" },
        .{ .config = .{ .limits = .{ .max_filters = 0 } }, .key = "limits.max_filters" },
        .{ .config = .{ .limits = .{ .default_limit = 9000 } }, .key = "limits.default_limit" },
        .{ .config = .{ .limits = .{ .max_message_size = 1000 } }, .key = "limits.max_event_size" },
        .{ .config = .{ .limits = .{ .max_content_length = 70000 } }, .key = "limits.max_content_length" },
        .{ .config = .{ .limits = .{ .created_at_upper_limit_s = -1 } }, .key = "limits.created_at_upper_limit_s" },
        .{ .config = .{ .limits = .{ .created_at_lower_limit_s = -1 } }, .key = "limits.created_at_lower_limit_s" },
        .{ .config = .{ .info = .{ .pubkey = "ABC" } }, .key = "info.pubkey" },
    };
    for (cases) |case| {
        var diagnostics: Diagnostics = .{};
        try testing.expectError(error.InvalidConfig, validate(case.config, &diagnostics));
        testing.expect(std.mem.startsWith(u8, diagnostics.message(), case.key)) catch |err| {
            std.debug.print("expected '{s}', got '{s}'\n", .{ case.key, diagnostics.message() });
            return err;
        };
    }
}
