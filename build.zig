const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    exe_mod.linkSystemLibrary("pulse", .{});
    exe_mod.linkSystemLibrary("pulse-simple", .{});
    exe_mod.linkSystemLibrary("gtk-3", .{});
    exe_mod.linkSystemLibrary("gdk-3", .{});
    exe_mod.linkSystemLibrary("glib-2.0", .{});
    exe_mod.linkSystemLibrary("gobject-2.0", .{});
    exe_mod.linkSystemLibrary("wayland-client", .{});

    const gtk_includes = [_][]const u8{
        "/usr/include/gtk-3.0",
        "/usr/include/pango-1.0",
        "/usr/include/glib-2.0",
        "/usr/lib/glib-2.0/include",
        "/usr/lib/x86_64-linux-gnu/glib-2.0/include",
        "/usr/include/cairo",
        "/usr/include/harfbuzz",
        "/usr/include/freetype2",
        "/usr/include/libpng16",
        "/usr/include/gdk-pixbuf-2.0",
        "/usr/include/atk-1.0",
    };
    for (gtk_includes) |path| {
        exe_mod.addIncludePath(.{ .cwd_relative = path });
    }
    // Generated wlr-screencopy C bindings.
    exe_mod.addIncludePath(b.path("src/wayland_gen"));
    exe_mod.addCSourceFile(.{
        .file = b.path("src/wayland_gen/wlr-screencopy-protocol.c"),
        .flags = &.{},
    });

    const exe = b.addExecutable(.{
        .name = "one-cap",
        .root_module = exe_mod,
        .use_lld = true,
        .use_llvm = true,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run one-cap");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkSystemLibrary("pulse", .{});
    test_mod.linkSystemLibrary("pulse-simple", .{});
    test_mod.linkSystemLibrary("gtk-3", .{});
    test_mod.linkSystemLibrary("glib-2.0", .{});
    test_mod.linkSystemLibrary("gobject-2.0", .{});
    test_mod.linkSystemLibrary("wayland-client", .{});
    for (gtk_includes) |path| {
        test_mod.addIncludePath(.{ .cwd_relative = path });
    }
    test_mod.addIncludePath(b.path("src/wayland_gen"));
    test_mod.addCSourceFile(.{
        .file = b.path("src/wayland_gen/wlr-screencopy-protocol.c"),
        .flags = &.{},
    });

    const exe_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
