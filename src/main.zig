const std = @import("std");
const Io = std.Io;

const easyrelay = @import("easyrelay");
const config = easyrelay.config;

const usage =
    \\easyrelay — a Nostr relay
    \\
    \\Usage: easyrelay [--config <path>]
    \\       easyrelay init
    \\
    \\With no options it serves a relay on ws://127.0.0.1:7777 and keeps its
    \\events in ./data. There is nothing to configure and no file to write first.
    \\
    \\Commands:
    \\  init             Print a configuration file with every default, to edit
    \\                   and save as easyrelay.zon
    \\
    \\Options:
    \\  --config <path>  Read this configuration file instead of ./easyrelay.zon
    \\  -h, --help       Show this message and exit
    \\  -V, --version    Show the version and exit
    \\
    \\Every setting can also be set as EASYRELAY_<SECTION>_<KEY>.
    \\
;

const Command = union(enum) {
    serve: ?[]const u8,
    init,
    help,
    version,
};

const UsageError = struct { message: []const u8, argument: []const u8 = "" };

fn parseArguments(args: []const []const u8) union(enum) { command: Command, wrong: UsageError } {
    var config_path: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .{ .command = .help };
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return .{ .command = .version };
        if (std.mem.eql(u8, arg, "init") and index == 0 and args.len == 1) return .{ .command = .init };
        if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index == args.len) return .{ .wrong = .{ .message = "--config needs a path" } };
            config_path = args[index];
            continue;
        }
        return .{ .wrong = .{ .message = "unknown argument", .argument = arg } };
    }
    return .{ .command = .{ .serve = config_path } };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    // Streaming, not positional: positional writes clobber other writers under `> log 2>&1`.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file.interface;

    const command = switch (parseArguments(args[1..])) {
        .command => |command| command,
        .wrong => |wrong| {
            if (wrong.argument.len != 0) {
                try stderr.print("error: {s} '{s}'\n\n{s}", .{ wrong.message, wrong.argument, usage });
            } else {
                try stderr.print("error: {s}\n\n{s}", .{ wrong.message, usage });
            }
            try stderr.flush();
            std.process.exit(2);
        },
    };

    switch (command) {
        .help => try stdout.writeAll(usage),
        .version => try stdout.print("easyrelay {s}\n", .{easyrelay.version}),
        .init => try config.writeTemplate(stdout),
        .serve => |config_path| {
            const loaded = load(arena, io, init.environ_map, config_path) catch |err| switch (err) {
                error.InvalidConfig => {
                    try stderr.flush();
                    std.process.exit(2);
                },
                else => return err,
            };
            try serve(gpa, io, loaded, stdout, stderr);
        },
    }
    try stdout.flush();
}

const Loaded = struct {
    settings: config.Config,
    source: []const u8,
};

fn load(arena: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, explicit: ?[]const u8) !Loaded {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};

    const path = explicit orelse config.default_path;
    var diagnostics: config.Diagnostics = .{};
    var loaded: Loaded = .{ .settings = .{}, .source = "defaults (no easyrelay.zon here)" };

    const text = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => if (explicit != null) {
            try stderr.print("error: the configuration file {s} does not exist\n", .{path});
            return error.InvalidConfig;
        } else null,
        else => {
            try stderr.print("error: cannot read the configuration file {s}: {t}\n", .{ path, err });
            return error.InvalidConfig;
        },
    };
    if (text) |source| {
        loaded.settings = config.parse(arena, source, path, &diagnostics) catch |err| switch (err) {
            error.InvalidConfig => {
                try stderr.print("error: {s}\n", .{diagnostics.message()});
                return error.InvalidConfig;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        loaded.source = path;
    }

    config.applyEnvironment(arena, &loaded.settings, environment, &diagnostics) catch |err| switch (err) {
        error.InvalidConfig => {
            try stderr.print("error: {s}\n", .{diagnostics.message()});
            return error.InvalidConfig;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    config.validate(loaded.settings, &diagnostics) catch {
        try stderr.print("error: {s}\n", .{diagnostics.message()});
        return error.InvalidConfig;
    };
    return loaded;
}

fn sessionLimits(settings: config.Config) easyrelay.session.Limits {
    const limits = settings.limits;
    return .{
        .event = .{
            .max_event_size = limits.max_event_size,
            .max_event_tags = limits.max_event_tags,
            .max_content_length = limits.max_content_length,
            .created_at_upper_limit_s = limits.created_at_upper_limit_s,
            .created_at_lower_limit_s = limits.created_at_lower_limit_s,
        },
        .message = .{ .max_subid_length = limits.max_subid_length, .max_filters = limits.max_filters },
        .subscription = .{
            .max_subscriptions = limits.max_subscriptions,
            .max_limit = limits.max_limit,
            .default_limit = limits.default_limit,
        },
    };
}

fn serverOptions(settings: config.Config) easyrelay.server.Options {
    return .{
        .address = settings.network.address,
        .port = settings.network.port,
        .max_connections = settings.network.max_connections,
        .handshake_timeout_ms = settings.network.handshake_timeout_ms,
        .max_message_size = settings.limits.max_message_size,
    };
}

fn storeOptions(settings: config.Config) easyrelay.lmdb.Options {
    return .{
        .map_size = settings.storage.map_size,
        .max_scan = settings.storage.max_scan,
        .durable = settings.storage.durable,
    };
}

fn isLoopback(address: []const u8) bool {
    return std.mem.startsWith(u8, address, "127.") or std.mem.eql(u8, address, "::1") or std.mem.eql(u8, address, "localhost");
}

fn serve(gpa: std.mem.Allocator, io: Io, loaded: Loaded, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    const settings = loaded.settings;
    var events = easyrelay.lmdb.Lmdb.open(gpa, io, settings.storage.path, storeOptions(settings)) catch |err| {
        if (err == error.InUse) {
            try stderr.print("error: another easyrelay is already serving {s}. Stop it, or point storage.path elsewhere\n", .{settings.storage.path});
            try stderr.flush();
            std.process.exit(1);
        }
        try stderr.print(
            "error: cannot open the store in {s}: {t}. Check that storage.path is writable and that storage.map_size fits this machine's address space\n",
            .{ settings.storage.path, err },
        );
        try stderr.flush();
        std.process.exit(1);
    };
    defer events.close();

    var connections = easyrelay.hub.Hub.init(gpa, io);
    defer connections.deinit();

    var writer = try easyrelay.writer.Writer.init(gpa, io, events.store(), &connections, settings.rate_limit.write_queue_depth);
    defer writer.deinit();
    try writer.start();
    defer writer.stop();

    const shared: easyrelay.session.Shared = .{
        .io = io,
        .store = events.store(),
        .hub = &connections,
        .writer = &writer,
        .limits = sessionLimits(settings),
    };
    var app: easyrelay.server.App = .{ .gpa = gpa, .shared = &shared };

    const options = serverOptions(settings);
    var relay = easyrelay.server.init(gpa, &app, options) catch |err| {
        try stderr.print("error: cannot listen on {s}:{d}: {t}. Check network.address and network.port\n", .{ options.address, options.port, err });
        try stderr.flush();
        std.process.exit(1);
    };
    defer relay.deinit();

    const data_dir = Io.Dir.cwd().realPathFileAlloc(io, settings.storage.path, gpa) catch null;
    defer if (data_dir) |path| gpa.free(path);

    try stdout.print("easyrelay {s} is serving ws://{s}:{d}\n", .{ easyrelay.version, options.address, options.port });
    try stdout.print("data directory: {s}\n", .{data_dir orelse settings.storage.path});
    try stdout.print("configuration: {s}\n", .{loaded.source});
    if (!settings.storage.durable) try stdout.writeAll("storage.durable is false: a crash can lose recently accepted events\n");
    if (isLoopback(options.address)) {
        try stdout.writeAll(
            \\reachable from this machine only. To serve other clients, put a TLS reverse proxy
            \\in front and point it here, or set network.address to "0.0.0.0" behind one.
            \\
        );
    }
    try stdout.flush();

    try relay.listen();
}

const testing = std.testing;

fn parsed(args: []const []const u8) Command {
    return switch (parseArguments(args)) {
        .command => |command| command,
        .wrong => unreachable,
    };
}

test "arguments select a command" {
    try testing.expectEqual(Command.help, parsed(&.{"-h"}));
    try testing.expectEqual(Command.help, parsed(&.{"--help"}));
    try testing.expectEqual(Command.version, parsed(&.{"-V"}));
    try testing.expectEqual(Command.version, parsed(&.{"--version"}));
    try testing.expectEqual(Command.init, parsed(&.{"init"}));
    try testing.expectEqual(@as(?[]const u8, null), parsed(&.{}).serve);
    try testing.expectEqualStrings("relay.zon", parsed(&.{ "--config", "relay.zon" }).serve.?);
}

test "anything else is a usage error" {
    for ([_][]const []const u8{ &.{"--verison"}, &.{"-v"}, &.{""}, &.{"serve"}, &.{"--config"}, &.{ "init", "x" } }) |args| {
        try testing.expect(parseArguments(args) == .wrong);
    }
}

test "usage text names every command and flag" {
    for ([_][]const u8{ "-h", "--help", "-V", "--version", "init", "--config" }) |flag| {
        try testing.expect(std.mem.indexOf(u8, usage, flag) != null);
    }
}

test "the configuration defaults are the defaults every component already has" {
    const settings: config.Config = .{};
    try testing.expectEqualDeep(easyrelay.session.Limits{}, sessionLimits(settings));
    try testing.expectEqualDeep(easyrelay.server.Options{ .address = settings.network.address }, serverOptions(settings));
    try testing.expectEqualDeep(easyrelay.lmdb.Options{}, storeOptions(settings));
}

test "loopback addresses are recognised" {
    try testing.expect(isLoopback("127.0.0.1"));
    try testing.expect(isLoopback("::1"));
    try testing.expect(!isLoopback("0.0.0.0"));
}
