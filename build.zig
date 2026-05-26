const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "one-cap",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkSystemLibrary("pulse");
    exe.linkSystemLibrary("pulse-simple");
    exe.linkSystemLibrary("gtk-3");
    exe.linkSystemLibrary("glib-2.0");
    exe.linkSystemLibrary("gobject-2.0");
    exe.linkLibC();

    // GTK include paths (Ubuntu 24.04)
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/gtk-3.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/pango-1.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/glib-2.0/include" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/libpng16" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/gdk-pixbuf-2.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/atk-1.0" });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run one-cap");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_tests.linkSystemLibrary("pulse");
    exe_tests.linkSystemLibrary("pulse-simple");
    exe_tests.linkSystemLibrary("gtk-3");
    exe_tests.linkSystemLibrary("glib-2.0");
    exe_tests.linkSystemLibrary("gobject-2.0");
    exe_tests.linkLibC();
    exe_tests.addIncludePath(.{ .cwd_relative = "/usr/include/gtk-3.0" });
    exe_tests.addIncludePath(.{ .cwd_relative = "/usr/include/pango-1.0" });
    exe_tests.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    exe_tests.addIncludePath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/glib-2.0/include" });
    exe_tests.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    exe_tests.addIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
    exe_tests.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    exe_tests.addIncludePath(.{ .cwd_relative = "/usr/include/libpng16" });
    exe_tests.addIncludePath(.{ .cwd_relative = "/usr/include/gdk-pixbuf-2.0" });
    exe_tests.addIncludePath(.{ .cwd_relative = "/usr/include/atk-1.0" });

    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
