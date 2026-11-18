const std = @import("std");
const Io = std.Io;

const easyrelay = @import("easyrelay");
const config = easyrelay.config;

pub const std_options: std.Options = .{
    .logFn = easyrelay.logging.logFn,
    // Filtering happens at run time, against logging.level.
    .log_level = .debug,
};

const usage =
    \\easyrelay — a Nostr relay
    \\
    \\Usage: easyrelay [--config <path>]
    \\       easyrelay init
    \\       easyrelay doctor [--config <path>]
    \\       easyrelay backup --out <file> [--config <path>]
    \\       easyrelay compact [--config <path>]
    \\
    \\With no options it serves a relay on ws://127.0.0.1:7777 and keeps its
    \\events in ./data. There is nothing to configure and no file to write first.
    \\
    \\Commands:
    \\  init             Print a configuration file with every default, to edit
    \\                   and save as easyrelay.zon
    \\  doctor           Check the configuration, the data directory and the
    \\                   store, and say how the relay will be reached
    \\  backup           Copy the store to a new file while the relay keeps serving
    \\  compact          Rewrite the store without its free pages; stop the relay first
    \\
    \\Options:
    \\  --config <path>  Read this configuration file instead of ./easyrelay.zon
    \\  --out <file>     Where backup writes its copy; the file must not exist
    \\  -h, --help       Show this message and exit
    \\  -V, --version    Show the version and exit
    \\
    \\Every setting can also be set as EASYRELAY_<SECTION>_<KEY>.
    \\
;

const Command = union(enum) {
    serve: ?[]const u8,
    init,
    doctor: ?[]const u8,
    backup: struct { config: ?[]const u8, out: []const u8 },
    compact: ?[]const u8,
    help,
    version,
};

const UsageError = struct { message: []const u8, argument: []const u8 = "" };

const Verb = enum { serve, init, doctor, backup, compact };

fn parseArguments(args: []const []const u8) union(enum) { command: Command, wrong: UsageError } {
    var config_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var verb: Verb = .serve;
    var index: usize = 0;
    if (args.len != 0) {
        for ([_]Verb{ .init, .doctor, .backup, .compact }) |candidate| {
            if (std.mem.eql(u8, args[0], @tagName(candidate))) {
                verb = candidate;
                index = 1;
            }
        }
    }
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .{ .command = .help };
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return .{ .command = .version };
        if (verb != .init and std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index == args.len) return .{ .wrong = .{ .message = "--config needs a path" } };
            config_path = args[index];
            continue;
        }
        if (verb == .backup and std.mem.eql(u8, arg, "--out")) {
            index += 1;
            if (index == args.len) return .{ .wrong = .{ .message = "--out needs a file path" } };
            out_path = args[index];
            continue;
        }
        return .{ .wrong = .{ .message = "unknown argument", .argument = arg } };
    }
    return .{ .command = switch (verb) {
        .serve => .{ .serve = config_path },
        .init => .init,
        .doctor => .{ .doctor = config_path },
        .compact => .{ .compact = config_path },
        .backup => .{ .backup = .{
            .config = config_path,
            .out = out_path orelse return .{ .wrong = .{ .message = "backup needs --out <file>" } },
        } },
    } };
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
        .serve => |config_path| try serve(gpa, arena, io, try loadOrExit(arena, io, init.environ_map, config_path, stderr), stdout, stderr),
        .doctor => |config_path| {
            const healthy = try doctor(gpa, arena, io, init.environ_map, config_path, stdout);
            try stdout.flush();
            if (!healthy) std.process.exit(1);
        },
        .backup => |request| {
            const loaded = try loadOrExit(arena, io, init.environ_map, request.config, stderr);
            const settings = loaded.settings;
            easyrelay.lmdb.backup(gpa, io, settings.storage.path, settings.storage.map_size, request.out) catch |err| {
                try stderr.print("error: backup failed: {s}\n", .{copyFailure(err)});
                try stderr.flush();
                std.process.exit(1);
            };
            try stdout.print("backed up {s} to {s}\n", .{ settings.storage.path, request.out });
        },
        .compact => |config_path| {
            const loaded = try loadOrExit(arena, io, init.environ_map, config_path, stderr);
            const settings = loaded.settings;
            const sizes = easyrelay.lmdb.compact(gpa, io, settings.storage.path, storeOptions(settings)) catch |err| {
                try stderr.print("error: compaction failed: {s}\n", .{copyFailure(err)});
                try stderr.flush();
                std.process.exit(1);
            };
            try stdout.print("compacted {s}: {d} bytes, now {d}\n", .{ settings.storage.path, sizes.before, sizes.after });
        },
    }
    try stdout.flush();
}

fn loadOrExit(arena: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, path: ?[]const u8, stderr: *Io.Writer) !Loaded {
    return load(arena, io, environment, path) catch |err| switch (err) {
        error.InvalidConfig => {
            try stderr.flush();
            std.process.exit(2);
        },
        else => return err,
    };
}

fn copyFailure(err: easyrelay.lmdb.CopyError) []const u8 {
    return switch (err) {
        error.NoStore => "there is no store in storage.path; check the path, or start the relay once to create it",
        error.Output => "the output could not be written; it must not already exist, and its directory must be writable",
        error.InUse => "a relay is serving this store; stop it first",
        error.OutOfMemory => "out of memory",
        error.Backend => "LMDB refused the store; check that storage.map_size is at least the size it was created with",
    };
}

const Report = struct {
    out: *Io.Writer,
    failed: bool = false,

    fn line(self: *Report, comptime status: []const u8, topic: []const u8, comptime format: []const u8, args: anytype) !void {
        if (comptime std.mem.eql(u8, status, "fail")) self.failed = true;
        try self.out.print("{s: <5}{s: <15}" ++ format ++ "\n", .{ status, topic } ++ args);
    }
};

/// Above these fractions of storage.map_size, doctor warns and then fails.
const map_warn_ratio = 0.8;
const map_fail_ratio = 0.95;

fn doctor(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, config_path: ?[]const u8, stdout: *Io.Writer) !bool {
    var report: Report = .{ .out = stdout };
    const loaded = load(arena, io, environment, config_path) catch |err| switch (err) {
        error.InvalidConfig => {
            try report.line("fail", "configuration", "does not load; the reason is above", .{});
            return false;
        },
        else => return err,
    };
    const settings = loaded.settings;
    try report.line("ok", "configuration", "{s}", .{loaded.source});

    const data_dir = settings.storage.path;
    if (Io.Dir.cwd().openDir(io, data_dir, .{})) |opened| {
        var dir = opened;
        defer dir.close(io);
        const probe = ".easyrelay-doctor";
        if (dir.createFile(io, probe, .{})) |file| {
            file.close(io);
            dir.deleteFile(io, probe) catch {};
            try report.line("ok", "data directory", "{s} is writable", .{data_dir});
        } else |err| try report.line("fail", "data directory", "{s} is not writable ({t}); fix its ownership or permissions", .{ data_dir, err });
    } else |err| switch (err) {
        error.FileNotFound => try report.line("ok", "data directory", "{s} does not exist yet; the relay creates it on first start", .{data_dir}),
        else => try report.line("fail", "data directory", "{s} cannot be opened ({t})", .{ data_dir, err }),
    }

    if (easyrelay.lmdb.inspect(gpa, io, data_dir, settings.storage.map_size)) |stats| {
        const ratio = stats.used_ratio orelse 0;
        const percent = ratio * 100;
        if (ratio >= map_fail_ratio) {
            try report.line("fail", "store", "{d} events, {d:.1}% of storage.map_size used; raise storage.map_size before writes fail", .{ stats.events, percent });
        } else if (ratio >= map_warn_ratio) {
            try report.line("warn", "store", "{d} events, {d:.1}% of storage.map_size used; plan to raise storage.map_size", .{ stats.events, percent });
        } else {
            try report.line("ok", "store", "{d} events, {d:.1}% of storage.map_size used", .{ stats.events, percent });
        }
    } else |err| switch (err) {
        error.NoStore => try report.line("ok", "store", "none yet; created on first start", .{}),
        else => try report.line("fail", "store", "cannot be read: {s}", .{copyFailure(err)}),
    }
    if (!settings.storage.durable) try report.line("warn", "durability", "storage.durable is false: a crash can lose recently accepted events", .{});

    const network = settings.network;
    if (isLoopback(network.address)) {
        try report.line("ok", "network", "{s}:{d} is reachable from this machine only; a TLS reverse proxy in front makes it public", .{ network.address, network.port });
    } else {
        try report.line("warn", "network", "{s}:{d} accepts connections from other machines; easyrelay speaks plain ws, so TLS must come from a proxy in front", .{ network.address, network.port });
        if (settings.metrics.enabled) try report.line("warn", "metrics", "{s} is served to anyone who can reach the relay; block it at the proxy", .{settings.metrics.path});
    }
    const address = std.Io.net.IpAddress.parse(network.address, network.port) catch {
        try report.line("fail", "network", "network.address {s} is not an IP address", .{network.address});
        return !report.failed;
    };
    if (easyrelay.listener.listen(address, 1)) |bound| {
        var server = bound;
        server.deinit(io);
        try report.line("ok", "port", "{d} is free", .{network.port});
    } else |err| switch (err) {
        error.AddressInUse => try report.line("warn", "port", "{d} is in use; if that is not this relay already running, choose another network.port", .{network.port}),
        else => try report.line("fail", "port", "cannot listen on {s}:{d} ({t})", .{ network.address, network.port, err }),
    }
    return !report.failed;
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
            .max_held_bytes = settings.network.write_buffer_limit,
        },
    };
}

fn rateLimits(settings: config.Config) easyrelay.rate.Limits {
    const limits = settings.rate_limit;
    return .{
        .events = rule(limits.events_per_second, limits.events_burst),
        .messages = rule(limits.messages_per_second, limits.messages_burst),
        .subscriptions = rule(if (limits.subscriptions_per_minute) |per_minute| per_minute / 60 else null, limits.subscriptions_burst),
        .author_events = rule(limits.author_events_per_second, limits.author_events_burst),
    };
}

fn admissionPolicy(arena: std.mem.Allocator, settings: config.Config) !easyrelay.policy.Policy {
    const lists = settings.policy;
    return easyrelay.policy.Policy.init(arena, .{
        .allowed_pubkeys = lists.allowed_pubkeys,
        .blocked_pubkeys = lists.blocked_pubkeys,
        .allowed_kinds = lists.allowed_kinds,
        .blocked_kinds = lists.blocked_kinds,
        .auth_required_for_write = lists.auth_required_for_write,
        .auth_required_for_read = lists.auth_required_for_read,
    });
}

fn rule(per_second: ?f64, burst: usize) ?easyrelay.rate.Rule {
    return .{ .per_second = per_second orelse return null, .burst = burst };
}

fn serverOptions(settings: config.Config) easyrelay.server.Options {
    return .{
        .address = settings.network.address,
        .port = settings.network.port,
        .max_connections = settings.network.max_connections,
        .handshake_timeout_ms = settings.network.handshake_timeout_ms,
        .max_message_size = settings.limits.max_message_size,
        .write_buffer_limit = settings.network.write_buffer_limit,
        .write_timeout_ms = settings.network.write_timeout_ms,
        .ping_interval_ms = settings.network.ping_interval_s * std.time.ms_per_s,
        .idle_timeout_ms = settings.network.idle_timeout_s * std.time.ms_per_s,
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

/// SIGTERM and SIGINT are blocked in every thread and taken by one thread with `sigwait`, so the
/// shutdown runs as ordinary code rather than inside a signal handler.
const Shutdown = struct {
    signals: std.posix.sigset_t,
    thread: ?std.Thread = null,

    /// Before any other thread starts, so each inherits the mask.
    fn block() Shutdown {
        var signals = std.posix.sigemptyset();
        std.posix.sigaddset(&signals, .TERM);
        std.posix.sigaddset(&signals, .INT);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &signals, null);
        return .{ .signals = signals };
    }

    fn watch(self: *Shutdown, relay: *easyrelay.server.Server) !void {
        self.thread = try std.Thread.spawn(.{}, wait, .{ self, relay });
    }

    fn wait(self: *Shutdown, relay: *easyrelay.server.Server) void {
        var received: c_int = 0;
        if (std.c.sigwait(&self.signals, &received) == 0) {
            log.info("signal {d} received: closing connections, then committing queued events", .{received});
        }
        relay.stop();
    }

    /// Releases the watcher if the relay stopped for another reason, so it is never left holding a
    /// pointer to a relay that is gone.
    fn finish(self: *Shutdown) void {
        const thread = self.thread orelse return;
        _ = std.c.kill(std.c.getpid(), .TERM);
        thread.join();
        self.thread = null;
    }
};

const log = std.log.scoped(.main);

fn serve(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, loaded: Loaded, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    const settings = loaded.settings;
    easyrelay.logging.configure(settings.logging.level, settings.logging.format);
    var shutdown = Shutdown.block();
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

    var counters: easyrelay.metrics.Metrics = .{};

    var writer = try easyrelay.writer.Writer.init(gpa, io, events.store(), &connections, settings.rate_limit.write_queue_depth);
    writer.metrics = &counters;
    defer writer.deinit();
    try writer.start();
    defer writer.stop();

    var reaper: easyrelay.reaper.Reaper = .{ .io = io, .store = events.store(), .interval_s = settings.storage.reaper_interval_s };
    try reaper.start();
    defer reaper.stop();

    const rates = rateLimits(settings);
    var authors: ?easyrelay.rate.Authors = if (rates.author_events) |author_rule| try .init(gpa, io, author_rule) else null;
    defer if (authors) |*present| present.deinit(gpa);

    const shared: easyrelay.session.Shared = .{
        .io = io,
        .store = events.store(),
        .hub = &connections,
        .writer = &writer,
        .limits = sessionLimits(settings),
        .authors = if (authors) |*present| present else null,
        .policy = try admissionPolicy(arena, settings),
        .metrics = &counters,
    };
    const information = try easyrelay.nip11.Responses.render(arena, settings);
    var app: easyrelay.server.App = .{
        .gpa = gpa,
        .shared = &shared,
        .information = &information,
        .rates = rates,
        .metrics = &counters,
        .metrics_path = if (settings.metrics.enabled) settings.metrics.path else null,
    };

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

    try shutdown.watch(&relay);
    defer shutdown.finish();
    try relay.listen();
}

const testing = std.testing;

fn parsed(args: []const []const u8) Command {
    return switch (parseArguments(args)) {
        .command => |command| command,
        .wrong => unreachable,
    };
}

test "commands take their own options" {
    try testing.expectEqual(@as(?[]const u8, null), parsed(&.{"doctor"}).doctor);
    try testing.expectEqualStrings("relay.zon", parsed(&.{ "doctor", "--config", "relay.zon" }).doctor.?);
    try testing.expectEqualStrings("relay.zon", parsed(&.{ "compact", "--config", "relay.zon" }).compact.?);
    const backup = parsed(&.{ "backup", "--out", "copy.mdb", "--config", "relay.zon" }).backup;
    try testing.expectEqualStrings("copy.mdb", backup.out);
    try testing.expectEqualStrings("relay.zon", backup.config.?);
    for ([_][]const []const u8{ &.{"backup"}, &.{ "backup", "--out" }, &.{ "doctor", "--out", "x" }, &.{ "init", "--config", "x" }, &.{ "--config", "x", "doctor" } }) |args| {
        try testing.expect(parseArguments(args) == .wrong);
    }
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
    for ([_][]const u8{ "-h", "--help", "-V", "--version", "init", "doctor", "backup", "compact", "--config", "--out" }) |flag| {
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

test "rate limits follow the settings, and null disables a bucket" {
    var settings: config.Config = .{};
    settings.rate_limit.subscriptions_per_minute = 120;
    settings.rate_limit.events_per_second = null;
    const limits = rateLimits(settings);
    try testing.expectEqual(@as(?easyrelay.rate.Rule, null), limits.events);
    try testing.expectEqual(@as(f64, 2), limits.subscriptions.?.per_second);
    try testing.expectEqual(@as(usize, 20), limits.subscriptions.?.burst);
    try testing.expectEqual(@as(f64, 50), limits.messages.?.per_second);
}
