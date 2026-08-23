const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name matches one of these filters",
    ) orelse &.{};

    const mod = b.addModule("easyrelay", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
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

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Compiles everything without installing it, so an editor can get diagnostics
    // without racing the real build over the output directory.
    const check_step = b.step("check", "Type-check without producing artifacts");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&exe_tests.step);
}
