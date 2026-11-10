const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name matches one of these filters",
    ) orelse &.{};

    const nostr = b.dependency("nostr", .{ .target = target, .optimize = optimize });
    const lmdb = lmdbModule(b, target, optimize);

    const mod = b.addModule("easyrelay", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nostr", .module = nostr.module("nostr") },
            .{ .name = "lmdb", .module = lmdb.wrapper },
            .{ .name = "lmdb_c", .module = lmdb.header },
        },
    });

    mod.addAnonymousImport("nips.md", .{ .root_source_file = b.path("docs/nips.md") });

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

    const conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "easyrelay", .module = mod },
                .{ .name = "nostr", .module = nostr.module("nostr") },
            },
        }),
        .filters = test_filters,
    });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(vector_tests).step);
    test_step.dependOn(&b.addRunArtifact(conformance_tests).step);

    const check_step = b.step("check", "Type-check without producing artifacts");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&exe_tests.step);
    check_step.dependOn(&vector_tests.step);
    check_step.dependOn(&conformance_tests.step);
}

/// zig-lmdb's wrapper without its own liblmdb: the copy zig-nostr links, built without UBSan, is the only one.
fn lmdbModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) struct { wrapper: *std.Build.Module, header: *std.Build.Module } {
    const wrapper = b.dependency("lmdb", .{ .target = target, .optimize = optimize });
    const liblmdb = wrapper.builder.dependency("lmdb", .{});
    const header = b.addTranslateC(.{
        .root_source_file = liblmdb.path("libraries/liblmdb/lmdb.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const module = b.createModule(.{
        .root_source_file = wrapper.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const header_module = header.createModule();
    module.addImport("c", header_module);
    return .{ .wrapper = module, .header = header_module };
}
