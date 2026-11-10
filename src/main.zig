const std = @import("std");
const Io = std.Io;

const easyrelay = @import("easyrelay");

const usage =
    \\easyrelay — a Nostr relay
    \\
    \\Usage: easyrelay [options]
    \\
    \\With no options it serves a relay on ws://127.0.0.1:7777. There is nothing
    \\to configure and no file to write first.
    \\
    \\Options:
    \\  -h, --help       Show this message and exit
    \\  -V, --version    Show the version and exit
    \\
;

const Action = enum { help, version, unknown };

fn classify(arg: []const u8) Action {
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
    if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return .version;
    return .unknown;
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

    for (args[1..]) |arg| switch (classify(arg)) {
        .help => {
            try stdout.writeAll(usage);
            try stdout.flush();
            return;
        },
        .version => {
            try stdout.print("easyrelay {s}\n", .{easyrelay.version});
            try stdout.flush();
            return;
        },
        .unknown => {
            try stderr.print("error: unknown argument '{s}'\n\n{s}", .{ arg, usage });
            try stderr.flush();
            std.process.exit(2);
        },
    };

    try serve(gpa, io, stdout);
}

fn serve(gpa: std.mem.Allocator, io: Io, stdout: *Io.Writer) !void {
    var events = easyrelay.memory.Memory.init(gpa, io);
    defer events.deinit();

    var connections = easyrelay.hub.Hub.init(gpa, io);
    defer connections.deinit();

    var writer = try easyrelay.writer.Writer.init(gpa, io, events.store(), &connections, 4096);
    defer writer.deinit();
    try writer.start();
    defer writer.stop();

    const shared: easyrelay.session.Shared = .{
        .io = io,
        .store = events.store(),
        .hub = &connections,
        .writer = &writer,
    };
    var app: easyrelay.server.App = .{ .gpa = gpa, .shared = &shared };

    const options: easyrelay.server.Options = .{};
    var relay = try easyrelay.server.init(gpa, &app, options);
    defer relay.deinit();

    try stdout.print(
        "easyrelay {s} is serving ws://{s}:{d}\n",
        .{ easyrelay.version, options.address, options.port },
    );
    try stdout.writeAll("events are held in memory only: a restart loses them\n");
    try stdout.flush();

    try relay.listen(&app);
}

test "classify recognises both spellings of every flag" {
    try std.testing.expectEqual(Action.help, classify("-h"));
    try std.testing.expectEqual(Action.help, classify("--help"));
    try std.testing.expectEqual(Action.version, classify("-V"));
    try std.testing.expectEqual(Action.version, classify("--version"));
}

test "classify rejects anything it does not know" {
    try std.testing.expectEqual(Action.unknown, classify("--verison"));
    try std.testing.expectEqual(Action.unknown, classify("-v"));
    try std.testing.expectEqual(Action.unknown, classify(""));
    try std.testing.expectEqual(Action.unknown, classify("serve"));
}

test "usage text names every flag classify accepts" {
    for ([_][]const u8{ "-h", "--help", "-V", "--version" }) |flag| {
        try std.testing.expect(std.mem.indexOf(u8, usage, flag) != null);
    }
}

test "usage text says what happens with no arguments" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "ws://127.0.0.1:7777") != null);
}
