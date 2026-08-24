const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name matches one of these filters",
    ) orelse &.{};

    // The protocol primitives (event model, canonical serialization, Schnorr via
    // libsecp256k1, filters) and the WebSocket transport. Both are recorded
    // decisions: docs/adr/0002-build-on-zig-nostr.md and
    // docs/adr/0004-websocket-transport.md.
    const nostr = b.dependency("nostr", .{ .target = target, .optimize = optimize });
    const websocket = b.dependency("websocket", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("easyrelay", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nostr", .module = nostr.module("nostr") },
            .{ .name = "websocket", .module = websocket.module("websocket") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "easyrelay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "easyrelay", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the relay");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod, .filters = test_filters });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = test_filters });

    // The vector suite runs on every build, which is the point of it: it is
    // the tripwire on the dependency's canonical serialization and signature
    // behaviour. See tests/vectors/README.md.
    const vector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/vectors/vectors.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nostr", .module = nostr.module("nostr") },
                .{ .name = "easyrelay", .module = mod },
            },
        }),
        .filters = test_filters,
    });

    // The conformance suite: docs/protocol.md driven through a real WebSocket
    // connection, which is what docs/testing.md asks of it. A separate artifact
    // because it links the relay, the transport and a client together, and none
    // of that belongs in a unit test's module.
    const conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "easyrelay", .module = mod },
                .{ .name = "nostr", .module = nostr.module("nostr") },
                .{ .name = "websocket", .module = websocket.module("websocket") },
            },
        }),
        .filters = test_filters,
    });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(vector_tests).step);
    test_step.dependOn(&b.addRunArtifact(conformance_tests).step);

    // Compiles everything without installing it, so an editor can get diagnostics
    // without racing the real build over the output directory.
    const check_step = b.step("check", "Type-check without producing artifacts");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&exe_tests.step);
    check_step.dependOn(&vector_tests.step);
    check_step.dependOn(&conformance_tests.step);
}
