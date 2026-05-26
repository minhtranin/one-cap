//! Screen capture.
//! Strategy per compositor:
//!   wlr-screencopy  → in-process Zig (libwayland) + ffmpeg stdin (niri/sway/Hyprland/wayfire/river/KDE)
//!   wf-recorder     → wlroots CLI fallback
//!   ffmpeg x11grab  → XWayland
//!   ffmpeg kmsgrab  → DRM, needs CAP_SYS_ADMIN

const std = @import("std");
const screencopy_backend = @import("screencopy_backend.zig");

pub const Backend = enum {
    wlr_screencopy,
    wf_recorder,
    ffmpeg_x11grab,
    ffmpeg_kmsgrab,

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .wlr_screencopy => "wlr-screencopy(zig)",
            .wf_recorder => "wf-recorder",
            .ffmpeg_x11grab => "ffmpeg+x11grab",
            .ffmpeg_kmsgrab => "ffmpeg+kmsgrab",
        };
    }

    pub fn extension(self: Backend) []const u8 {
        return switch (self) {
            .wlr_screencopy => "mkv",
            else => "mp4",
        };
    }
};

pub const Config = struct {
    output_path: []const u8,
    framerate: u32 = 30,
    video_bitrate_kbps: u32 = 20000,
    display: []const u8 = ":0.0",
    backend: ?Backend = null,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    impl: Impl,

    const Impl = union(enum) {
        subprocess: std.process.Child,
        screencopy: screencopy_backend.Backend,
    };

    pub fn start(allocator: std.mem.Allocator, cfg: Config) !Recorder {
        const backend = cfg.backend orelse try detectBackend(allocator);
        std.log.info("screen capture backend: {s} → {s}", .{ backend.label(), cfg.output_path });

        if (backend == .wlr_screencopy) {
            const sc = try screencopy_backend.Backend.start(allocator, .{
                .output_path = cfg.output_path,
                .framerate = cfg.framerate,
                .video_bitrate_kbps = cfg.video_bitrate_kbps,
            });
            return .{ .allocator = allocator, .backend = backend, .impl = .{ .screencopy = sc } };
        }

        var argv = try buildArgv(allocator, backend, cfg);
        defer freeArgv(allocator, &argv);

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        return .{ .allocator = allocator, .backend = backend, .impl = .{ .subprocess = child } };
    }

    pub fn stop(self: *Recorder) !void {
        switch (self.impl) {
            .screencopy => |*sc| sc.stop(),
            .subprocess => |*child| {
                if (child.stdin) |stdin| {
                    stdin.close();
                    child.stdin = null;
                }
                _ = child.wait() catch {};
            },
        }
    }

    /// For wlr_screencopy: routes PAUSE/RESUME lines to the in-process capture.
    /// For subprocess backends this is a no-op (no command channel).
    pub fn sendCommand(self: *Recorder, line: []const u8) !void {
        switch (self.impl) {
            .screencopy => |*sc| {
                if (std.mem.startsWith(u8, line, "PAUSE")) sc.setPaused(true)
                else if (std.mem.startsWith(u8, line, "RESUME")) sc.setPaused(false);
            },
            .subprocess => {},
        }
    }

    pub fn setShowCursor(self: *Recorder, v: bool) void {
        switch (self.impl) {
            .screencopy => |*sc| sc.setShowCursor(v),
            .subprocess => {},
        }
    }

    pub fn deinit(self: *Recorder) void {
        switch (self.impl) {
            .screencopy => |*sc| sc.deinit(),
            .subprocess => |*child| {
                _ = child.kill() catch {};
            },
        }
    }

    pub fn backendUsed(self: Recorder) Backend {
        return self.backend;
    }
};

// --- detection ---

pub fn detectBackend(allocator: std.mem.Allocator) !Backend {
    const wayland = std.posix.getenv("WAYLAND_DISPLAY");
    if (wayland != null and wayland.?.len > 0 and hasBin(allocator, "ffmpeg")) {
        return .wlr_screencopy;
    }
    if (isWlrootsCompositor() and hasBin(allocator, "wf-recorder")) return .wf_recorder;
    const display = std.posix.getenv("DISPLAY");
    if (display != null and display.?.len > 0 and hasBin(allocator, "ffmpeg")) return .ffmpeg_x11grab;
    if (hasBin(allocator, "ffmpeg")) return .ffmpeg_kmsgrab;
    return error.NoBackendAvailable;
}

fn isWlrootsCompositor() bool {
    const desktop = std.posix.getenv("XDG_CURRENT_DESKTOP") orelse "";
    const session = std.posix.getenv("XDG_SESSION_DESKTOP") orelse "";
    const wlroots = [_][]const u8{ "sway", "Sway", "Hyprland", "hyprland", "wayfire", "Wayfire", "river", "River", "niri", "Niri" };
    for (wlroots) |name| {
        if (std.mem.indexOf(u8, desktop, name) != null) return true;
        if (std.mem.indexOf(u8, session, name) != null) return true;
    }
    return false;
}

fn hasBin(allocator: std.mem.Allocator, name: []const u8) bool {
    const argv = &[_][]const u8{ "which", name };
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn buildArgv(
    allocator: std.mem.Allocator,
    backend: Backend,
    cfg: Config,
) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).init(allocator);
    errdefer freeArgv(allocator, &list);

    const fr = try std.fmt.allocPrint(allocator, "{d}", .{cfg.framerate});
    const br = try std.fmt.allocPrint(allocator, "{d}", .{cfg.video_bitrate_kbps});
    const path = try allocator.dupe(u8, cfg.output_path);
    const display = try allocator.dupe(u8, cfg.display);

    switch (backend) {
        .wlr_screencopy => unreachable, // handled in Recorder.start before this
        .wf_recorder => {
            try list.append(try allocator.dupe(u8, "wf-recorder"));
            try list.append(try allocator.dupe(u8, "-f"));
            try list.append(path);
            try list.append(try allocator.dupe(u8, "-r"));
            try list.append(fr);
            allocator.free(display);
            allocator.free(br);
        },
        .ffmpeg_x11grab => {
            const br_k = try std.fmt.allocPrint(allocator, "{d}k", .{cfg.video_bitrate_kbps});
            try list.append(try allocator.dupe(u8, "ffmpeg"));
            try list.append(try allocator.dupe(u8, "-y"));
            try list.append(try allocator.dupe(u8, "-f"));
            try list.append(try allocator.dupe(u8, "x11grab"));
            try list.append(try allocator.dupe(u8, "-framerate"));
            try list.append(fr);
            try list.append(try allocator.dupe(u8, "-i"));
            try list.append(display);
            try list.append(try allocator.dupe(u8, "-c:v"));
            try list.append(try allocator.dupe(u8, "libx264"));
            try list.append(try allocator.dupe(u8, "-preset"));
            try list.append(try allocator.dupe(u8, "veryfast"));
            try list.append(try allocator.dupe(u8, "-b:v"));
            try list.append(br_k);
            try list.append(try allocator.dupe(u8, "-pix_fmt"));
            try list.append(try allocator.dupe(u8, "yuv420p"));
            try list.append(path);
            allocator.free(br);
        },
        .ffmpeg_kmsgrab => {
            const br_k = try std.fmt.allocPrint(allocator, "{d}k", .{cfg.video_bitrate_kbps});
            try list.append(try allocator.dupe(u8, "ffmpeg"));
            try list.append(try allocator.dupe(u8, "-y"));
            try list.append(try allocator.dupe(u8, "-f"));
            try list.append(try allocator.dupe(u8, "kmsgrab"));
            try list.append(try allocator.dupe(u8, "-framerate"));
            try list.append(fr);
            try list.append(try allocator.dupe(u8, "-i"));
            try list.append(try allocator.dupe(u8, "-"));
            try list.append(try allocator.dupe(u8, "-vf"));
            try list.append(try allocator.dupe(u8, "hwdownload,format=bgr0"));
            try list.append(try allocator.dupe(u8, "-c:v"));
            try list.append(try allocator.dupe(u8, "libx264"));
            try list.append(try allocator.dupe(u8, "-preset"));
            try list.append(try allocator.dupe(u8, "veryfast"));
            try list.append(try allocator.dupe(u8, "-b:v"));
            try list.append(br_k);
            try list.append(try allocator.dupe(u8, "-pix_fmt"));
            try list.append(try allocator.dupe(u8, "yuv420p"));
            try list.append(path);
            allocator.free(display);
            allocator.free(br);
        },
    }

    return list;
}

fn freeArgv(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit();
}
