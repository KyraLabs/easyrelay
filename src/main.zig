const std = @import("std");
const Io = std.Io;

const easyrelay = @import("easyrelay");

const usage =
    \\easyrelay — a Nostr relay
    \\
    \\Usage: easyrelay [options]
    \\
    \\Options:
    \\  -h, --help       Show this message and exit
    \\  -V, --version    Show the version and exit
    \\
;

const not_implemented =
    \\easyrelay is pre-alpha: the relay is not implemented yet, so there is nothing to serve.
    \\
    \\What exists today is the project scaffold and the design documentation. The order of
    \\work, and what each phase must satisfy before it is considered done, is in:
    \\
    \\  https://github.com/KyraLabs/easyrelay/blob/main/docs/roadmap.md
    \\
;

const Action = enum { help, version, serve, unknown };

fn classify(arg: []const u8) Action {
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
    if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return .version;
    return .unknown;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
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
        // Name the offending argument instead of dumping usage alone. An error the
        // operator cannot act on is a bug: see docs/adr/0009-deployment-experience.md.
        .unknown => {
            try stderr.print("error: unknown argument '{s}'\n\n{s}", .{ arg, usage });
            try stderr.flush();
            std.process.exit(2);
        },
        .serve => unreachable,
    };

    try stderr.writeAll(not_implemented);
    try stderr.flush();
    std.process.exit(1);
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
