//! Screen capture.
//! Strategy per compositor:
//!   wlr-screencopy  → in-process Zig (libwayland) + ffmpeg stdin (niri/sway/Hyprland/wayfire/river/KDE)
//!   portal+pipewire → in-process Zig (GDBus + libpipewire) + ffmpeg stdin (GNOME/Ubuntu)
//!   wf-recorder     → wlroots CLI fallback
//!   ffmpeg x11grab  → XWayland
//!   ffmpeg kmsgrab  → DRM, needs CAP_SYS_ADMIN

const std = @import("std");
const screencopy_backend = @import("screencopy_backend.zig");
const portal_backend = @import("portal_backend.zig");
const encoder = @import("encoder.zig");

pub const Backend = enum {
    wlr_screencopy,    // in-process Zig + libwayland (wlroots, niri, KDE)
    portal_pipewire,   // in-process Zig: GDBus portal + libpipewire (GNOME/Ubuntu)
    wf_recorder,
    ffmpeg_x11grab,
    ffmpeg_kmsgrab,

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .wlr_screencopy => "wlr-screencopy(zig)",
            .portal_pipewire => "xdg-portal+pipewire(zig)",
            .wf_recorder => "wf-recorder",
            .ffmpeg_x11grab => "ffmpeg+x11grab",
            .ffmpeg_kmsgrab => "ffmpeg+kmsgrab",
        };
    }

    pub fn extension(self: Backend) []const u8 {
        return switch (self) {
            .wlr_screencopy, .portal_pipewire, .ffmpeg_x11grab, .ffmpeg_kmsgrab => "mp4",
            .wf_recorder => "mp4",
        };
    }
};

pub const Config = struct {
    output_path: []const u8,
    framerate: u32 = 30,
    video_bitrate_kbps: u32 = 20000,
    display: []const u8 = ":0.0",
    backend: ?Backend = null,
    region: ?encoder.Region = null,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    impl: Impl,

    const Impl = union(enum) {
        subprocess: std.process.Child,
        screencopy: screencopy_backend.Backend,
        portal: portal_backend.Backend,
    };

    pub fn start(allocator: std.mem.Allocator, cfg: Config) !Recorder {
        const backend = cfg.backend orelse try detectBackend(allocator);
        std.log.info("screen capture backend: {s} → {s}", .{ backend.label(), cfg.output_path });

        if (backend == .wlr_screencopy) {
            const sc = try screencopy_backend.Backend.start(allocator, .{
                .output_path = cfg.output_path,
                .framerate = cfg.framerate,
                .video_bitrate_kbps = cfg.video_bitrate_kbps,
                .region = cfg.region,
            });
            return .{ .allocator = allocator, .backend = backend, .impl = .{ .screencopy = sc } };
        }
        if (backend == .portal_pipewire) {
            const pb = try portal_backend.Backend.start(allocator, .{
                .output_path = cfg.output_path,
                .framerate = cfg.framerate,
                .video_bitrate_kbps = cfg.video_bitrate_kbps,
                .region = cfg.region,
            });
            return .{ .allocator = allocator, .backend = backend, .impl = .{ .portal = pb } };
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
            .portal => |*pb| pb.stop(),
            .subprocess => |*child| {
                if (child.stdin) |stdin| {
                    stdin.close();
                    child.stdin = null;
                }
                // Watchdog: escalate SIGTERM after 4s then SIGKILL 4s later so
                // a wedged child never blocks the user. Detached: if the child
                // exits first, kill returns ESRCH and the thread ends.
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
            .portal => |*pb| {
                if (std.mem.startsWith(u8, line, "PAUSE")) pb.setPaused(true)
                else if (std.mem.startsWith(u8, line, "RESUME")) pb.setPaused(false);
            },
            .subprocess => {},
        }
    }

    pub fn setShowCursor(self: *Recorder, v: bool) void {
        switch (self.impl) {
            .screencopy => |*sc| sc.setShowCursor(v),
            .portal, .subprocess => {},
        }
    }

    pub fn deinit(self: *Recorder) void {
        switch (self.impl) {
            .screencopy => |*sc| sc.deinit(),
            .portal => |*pb| pb.deinit(),
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

    std.Thread.sleep(term_after_ns);
    std.posix.kill(pid, std.posix.SIG.TERM) catch return;
    std.log.warn("screen helper still alive after 4s; sent SIGTERM (pid={d})", .{pid});

    std.Thread.sleep(kill_after_ns);
    std.posix.kill(pid, std.posix.SIG.KILL) catch return;
    std.log.warn("screen helper still alive after 8s; sent SIGKILL (pid={d})", .{pid});
}

/// Frozen frame for the area picker background; null when the backend can't
/// provide one quickly (the picker then falls back to a plain dim overlay).
pub fn grabStill(allocator: std.mem.Allocator, backend: Backend) ?encoder.Still {
    const still = switch (backend) {
        .portal_pipewire => portal_backend.grabStill(allocator),
        .wlr_screencopy => screencopy_backend.grabStill(allocator),
        else => return null,
    } catch |e| {
        std.log.warn("area picker background unavailable: {t}", .{e});
        return null;
    };
    return still;
}

// --- detection ---

pub fn detectBackend(allocator: std.mem.Allocator) !Backend {
    const wayland = std.posix.getenv("WAYLAND_DISPLAY");
    if (wayland != null and wayland.?.len > 0) {
        // GNOME / Ubuntu Wayland: no wlr-screencopy global → portal + PipeWire.
        if (isGnomeCompositor() and hasBin(allocator, "ffmpeg"))
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
    const path = std.posix.getenv("PATH") orelse return false;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = std.fs.path.join(allocator, &.{ dir, name }) catch return false;
        defer allocator.free(full);
        std.posix.access(full, std.posix.X_OK) catch continue;
        return true;
    }
    return false;
}

fn buildArgv(
    allocator: std.mem.Allocator,
    backend: Backend,
    cfg: Config,
) !std.array_list.Managed([]const u8) {
    var list = std.array_list.Managed([]const u8).init(allocator);
    errdefer freeArgv(allocator, &list);

    const fr = try std.fmt.allocPrint(allocator, "{d}", .{cfg.framerate});
    const br = try std.fmt.allocPrint(allocator, "{d}", .{cfg.video_bitrate_kbps});
    const path = try allocator.dupe(u8, cfg.output_path);
    const display = try allocator.dupe(u8, cfg.display);

    switch (backend) {
        .wlr_screencopy, .portal_pipewire => unreachable, // in-process, handled in Recorder.start
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

fn freeArgv(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit();
}
