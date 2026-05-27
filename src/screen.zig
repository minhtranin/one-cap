//! Screen capture.
//! Strategy per compositor:
//!   wlr-screencopy  → in-process Zig (libwayland) + ffmpeg stdin (niri/sway/Hyprland/wayfire/river/KDE)
//!   wf-recorder     → wlroots CLI fallback
//!   ffmpeg x11grab  → XWayland
//!   ffmpeg kmsgrab  → DRM, needs CAP_SYS_ADMIN

const std = @import("std");
const screencopy_backend = @import("screencopy_backend.zig");

pub const Backend = enum {
    wlr_screencopy,    // in-process Zig + libwayland (wlroots, niri, KDE)
    portal_pipewire,   // Python helper does DBus + GStreamer (GNOME/Ubuntu)
    wf_recorder,
    ffmpeg_x11grab,
    ffmpeg_kmsgrab,

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .wlr_screencopy => "wlr-screencopy(zig)",
            .portal_pipewire => "xdg-portal+gstreamer(python)",
            .wf_recorder => "wf-recorder",
            .ffmpeg_x11grab => "ffmpeg+x11grab",
            .ffmpeg_kmsgrab => "ffmpeg+kmsgrab",
        };
    }

    pub fn extension(self: Backend) []const u8 {
        return switch (self) {
            .wlr_screencopy, .portal_pipewire => "mkv",
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
        // Portal helper prints PORTAL_READY to stdout after the user clicks
        // Share; we need to read it to know capture has started. Other
        // subprocess backends don't have a readiness handshake.
        child.stdout_behavior = if (backend == .portal_pipewire) .Pipe else .Ignore;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        if (backend == .portal_pipewire) {
            try waitForReady(&child);
        }

        return .{ .allocator = allocator, .backend = backend, .impl = .{ .subprocess = child } };
    }

    pub fn stop(self: *Recorder) !void {
        switch (self.impl) {
            .screencopy => |*sc| sc.stop(),
            .subprocess => |*child| {
                if (child.stdin) |stdin| {
                    // Portal helper listens on stdin for STOP; for other
                    // backends this is harmless extra data we then close.
                    if (self.backend == .portal_pipewire) {
                        _ = stdin.writeAll("STOP\n") catch {};
                    }
                    stdin.close();
                    child.stdin = null;
                }
                // Watchdog: Ubuntu 26 + GStreamer 1.24+ sometimes hangs in
                // pipeline.set_state(NULL) on shutdown after a pause/resume
                // cycle — child.wait() would block forever. Spawn a watcher
                // that escalates SIGTERM after 4s then SIGKILL 4s later so
                // we always return control to the user. Detached: if the
                // child exits cleanly first, the kill returns ESRCH and the
                // thread ends on its own.
                const pid = child.id;
                const watcher = std.Thread.spawn(.{}, watchdogKill, .{pid}) catch null;
                _ = child.wait() catch {};
                if (watcher) |t| t.detach();
            },
        }
    }

    pub fn sendCommand(self: *Recorder, line: []const u8) !void {
        switch (self.impl) {
            .screencopy => |*sc| {
                if (std.mem.startsWith(u8, line, "PAUSE")) sc.setPaused(true)
                else if (std.mem.startsWith(u8, line, "RESUME")) sc.setPaused(false);
            },
            .subprocess => |*child| {
                // Only the portal helper has a stdin command channel.
                if (self.backend != .portal_pipewire) return;
                const stdin = child.stdin orelse return error.NoStdin;
                try stdin.writeAll(line);
            },
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

/// Escalates child shutdown: wait 4 s, then SIGTERM; wait 4 s more, then
/// SIGKILL. Exits early if the process is already gone (kill returns ESRCH).
/// Runs in its own thread alongside the blocking child.wait().
fn watchdogKill(pid: std.posix.pid_t) void {
    const term_after_ns: u64 = 4 * std.time.ns_per_s;
    const kill_after_ns: u64 = 4 * std.time.ns_per_s;

    std.time.sleep(term_after_ns);
    std.posix.kill(pid, std.posix.SIG.TERM) catch return;
    std.log.warn("screen helper still alive after 4s; sent SIGTERM (pid={d})", .{pid});

    std.time.sleep(kill_after_ns);
    std.posix.kill(pid, std.posix.SIG.KILL) catch return;
    std.log.warn("screen helper still alive after 8s; sent SIGKILL (pid={d})", .{pid});
}

/// Reads the portal helper's stdout until the PORTAL_READY marker arrives —
/// that's the signal the GStreamer pipeline has gone PLAYING and frames are
/// flowing. Callers must wait for this before starting audio so the two
/// streams' clocks line up.
fn waitForReady(child: *std.process.Child) !void {
    const stdout = child.stdout orelse return error.NoStdout;
    var buf: [256]u8 = undefined;
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
    if (wayland != null and wayland.?.len > 0) {
        // GNOME / Ubuntu Wayland: no wlr-screencopy global. Use the Python
        // portal helper (xdg-desktop-portal ScreenCast + GStreamer).
        if (isGnomeCompositor() and hasBin(allocator, "python3") and hasBin(allocator, "ffmpeg"))
            return .portal_pipewire;
        // wlroots-style compositors (niri/sway/Hyprland/KDE on wlroots) →
        // fast in-process libwayland capture.
        if (hasBin(allocator, "ffmpeg")) return .wlr_screencopy;
    }
    if (isWlrootsCompositor() and hasBin(allocator, "wf-recorder")) return .wf_recorder;
    const display = std.posix.getenv("DISPLAY");
    if (display != null and display.?.len > 0 and hasBin(allocator, "ffmpeg")) return .ffmpeg_x11grab;
    if (hasBin(allocator, "ffmpeg")) return .ffmpeg_kmsgrab;
    return error.NoBackendAvailable;
}

fn isGnomeCompositor() bool {
    const desktop = std.posix.getenv("XDG_CURRENT_DESKTOP") orelse "";
    const session = std.posix.getenv("XDG_SESSION_DESKTOP") orelse "";
    const gnome_names = [_][]const u8{ "GNOME", "gnome", "Unity", "ubuntu" };
    for (gnome_names) |name| {
        if (std.mem.indexOf(u8, desktop, name) != null) return true;
        if (std.mem.indexOf(u8, session, name) != null) return true;
    }
    return false;
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
        .portal_pipewire => {
            const script = try findPortalHelper(allocator);
            try list.append(try allocator.dupe(u8, "python3"));
            try list.append(script);
            try list.append(path);
            try list.append(fr);
            try list.append(br);
            allocator.free(display);
        },
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

/// Locate portal_screencast.py at runtime. Order:
///   1. $ONECAP_PORTAL_HELPER env override
///   2. Sibling of the running executable (AppImage layout: bin/one-cap →
///      same dir's portal_screencast.py)
///   3. Hard-coded source-tree path (for `zig build run` from the repo)
///   4. System install paths
fn findPortalHelper(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("ONECAP_PORTAL_HELPER")) |env_path| {
        return allocator.dupe(u8, env_path);
    }
    // Resolve sibling of the running binary.
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExeDirPath(&self_buf)) |dir| {
        const sibling = try std.fmt.allocPrint(allocator, "{s}/portal_screencast.py", .{dir});
        if (std.fs.cwd().access(sibling, .{})) |_| {
            return sibling;
        } else |_| {
            allocator.free(sibling);
        }
        // AppImage installs scripts under ../share/one-cap/
        const share = try std.fmt.allocPrint(allocator, "{s}/../share/one-cap/portal_screencast.py", .{dir});
        if (std.fs.cwd().access(share, .{})) |_| {
            return share;
        } else |_| {
            allocator.free(share);
        }
    } else |_| {}

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
