const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Read repo-root VERSION file at build time and expose it to the source
    // as build_options.version. Trimmed; falls back to a hard-coded default
    // if the file is missing or empty.
    const version_default = "27.5.26";
    var version_str: []const u8 = version_default;
    if (std.fs.cwd().readFileAlloc(b.allocator, "VERSION", 64)) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) version_str = b.dupe(trimmed);
    } else |_| {}
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", version_str);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addOptions("build_options", build_opts);

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
    test_mod.addOptions("build_options", build_opts);
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
