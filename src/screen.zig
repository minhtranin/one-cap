//! Screen capture for Wayland.
//! Strategy per compositor:
//!   GNOME           → org.gnome.Shell.Screencast DBus (writes WebM)
//!   wlroots         → wf-recorder subprocess
//!   XWayland-only   → ffmpeg x11grab (NOTE: on GNOME this captures black)
//!   Fallback        → ffmpeg kmsgrab (needs CAP_SYS_ADMIN)

const std = @import("std");

pub const Backend = enum {
    portal_pipewire, // xdg-desktop-portal ScreenCast + GStreamer (works on GNOME/KDE Wayland)
    wf_recorder, // wlroots compositors
    ffmpeg_x11grab, // XWayland — NOTE: produces black on GNOME Wayland
    ffmpeg_kmsgrab, // any DRM, needs CAP_SYS_ADMIN

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .portal_pipewire => "portal+pipewire",
            .wf_recorder => "wf-recorder",
            .ffmpeg_x11grab => "ffmpeg+x11grab",
            .ffmpeg_kmsgrab => "ffmpeg+kmsgrab",
        };
    }

    pub fn extension(self: Backend) []const u8 {
        return switch (self) {
            .portal_pipewire => "mkv",
            else => "mp4",
        };
    }
};

pub const Config = struct {
    output_path: []const u8, // path the backend writes to (intermediate, before mux)
    framerate: u32 = 30,
    display: []const u8 = ":0.0",
    backend: ?Backend = null,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    backend: Backend,

    pub fn start(allocator: std.mem.Allocator, cfg: Config) !Recorder {
        const backend = cfg.backend orelse try detectBackend(allocator);
        std.log.info("screen capture backend: {s} → {s}", .{ backend.label(), cfg.output_path });

        var argv = try buildArgv(allocator, backend, cfg);
        defer freeArgv(allocator, &argv);

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = if (backend == .portal_pipewire) .Pipe else .Ignore;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        // Portal backend prints PORTAL_READY when pipeline is live — wait for it
        // so caller doesn't start audio before the screen pipeline is recording.
        if (backend == .portal_pipewire) {
            try waitForReady(&child);
        }

        return .{ .allocator = allocator, .child = child, .backend = backend };
    }

    pub fn stop(self: *Recorder) !void {
        if (self.child.stdin) |stdin| {
            stdin.close();
            self.child.stdin = null;
        }
        std.posix.kill(self.child.id, std.posix.SIG.INT) catch {};
        _ = self.child.wait() catch {};
    }

    pub fn deinit(self: *Recorder) void {
        _ = self.child.kill() catch {};
    }

    pub fn backendUsed(self: Recorder) Backend {
        return self.backend;
    }
};

fn waitForReady(child: *std.process.Child) !void {
    const stdout = child.stdout orelse return error.NoStdout;
    var buf: [128]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stdout.read(buf[total..]) catch return error.PortalReadyFailed;
        if (n == 0) return error.PortalHelperExited;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "PORTAL_READY")) |_| return;
    }
    return error.PortalHelperNoReady;
}

// --- detection ---

pub fn detectBackend(allocator: std.mem.Allocator) !Backend {
    const wayland = std.posix.getenv("WAYLAND_DISPLAY");
    if (wayland != null and wayland.?.len > 0 and hasBin(allocator, "python3")) {
        return .portal_pipewire;
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
    const wlroots = [_][]const u8{ "sway", "Sway", "Hyprland", "hyprland", "wayfire", "Wayfire", "river", "River" };
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
    const path = try allocator.dupe(u8, cfg.output_path);
    const display = try allocator.dupe(u8, cfg.display);

    switch (backend) {
        .portal_pipewire => {
            const script = try findPortalHelper(allocator);
            try list.append(try allocator.dupe(u8, "python3"));
            try list.append(script);
            try list.append(path);
            try list.append(fr);
            allocator.free(display);
        },
        .wf_recorder => {
            try list.append(try allocator.dupe(u8, "wf-recorder"));
            try list.append(try allocator.dupe(u8, "-f"));
            try list.append(path);
            try list.append(try allocator.dupe(u8, "-r"));
            try list.append(fr);
            allocator.free(display);
        },
        .ffmpeg_x11grab => {
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
            try list.append(try allocator.dupe(u8, "ultrafast"));
            try list.append(try allocator.dupe(u8, "-pix_fmt"));
            try list.append(try allocator.dupe(u8, "yuv420p"));
            try list.append(path);
        },
        .ffmpeg_kmsgrab => {
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
            try list.append(try allocator.dupe(u8, "-pix_fmt"));
            try list.append(try allocator.dupe(u8, "yuv420p"));
            try list.append(path);
            allocator.free(display);
        },
    }

    return list;
}

fn freeArgv(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit();
}

/// Locate portal_screencast.py: env override, then sibling of executable, then dev path.
fn findPortalHelper(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("ONECAP_PORTAL_HELPER")) |env_path| {
        return allocator.dupe(u8, env_path);
    }

    const candidates = [_][]const u8{
        "/home/tcm/workspace/personal/one-cap/src/portal_screencast.py",
        "./src/portal_screencast.py",
        "/usr/local/share/one-cap/portal_screencast.py",
        "/usr/share/one-cap/portal_screencast.py",
    };
    for (candidates) |p| {
        std.fs.cwd().access(p, .{}) catch continue;
        return allocator.dupe(u8, p);
    }
    return error.PortalHelperNotFound;
}
