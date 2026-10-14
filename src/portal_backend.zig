//! GNOME / portal backend: xdg-desktop-portal ScreenCast session (portal.zig)
//! → PipeWire frames (pipewire_capture.zig) → ffmpeg encoder.

const std = @import("std");
const portal = @import("portal.zig");
const pw = @import("pipewire_capture.zig");
const encoder = @import("encoder.zig");

pub const Config = struct {
    output_path: []const u8,
    framerate: u32,
    video_bitrate_kbps: u32,
    region: ?encoder.Region = null,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    session: portal.Session,
    capture: *pw.Capture,
    ffmpeg: std.process.Child,
    thread: std.Thread,

    pub fn start(allocator: std.mem.Allocator, cfg: Config) !Backend {
        var session = try portal.open(allocator, .{ .monitor_only = true });
        errdefer session.close();
        const st = session.stream;

        const capture = try pw.Capture.create(allocator, session.pw_fd, st.node_id, cfg.framerate);
        errdefer capture.destroy();

        const fmt = try capture.waitFormat(5 * std.time.ns_per_s);
        const pix_fmt = pw.pixFmtName(fmt.spa_format) orelse {
            std.log.err("pipewire: unsupported video format {d}", .{fmt.spa_format});
            return error.UnsupportedFormat;
        };

        const full = encoder.Rect{ .x = 0, .y = 0, .w = fmt.width & ~@as(u32, 1), .h = fmt.height & ~@as(u32, 1) };
        const crop = cropFor(cfg.region, st, fmt) orelse full;
        std.log.info("portal: node={d} {d}x{d} pix_fmt={s} crop={d}x{d}+{d}+{d}", .{
            st.node_id, fmt.width, fmt.height, pix_fmt, crop.w, crop.h, crop.x, crop.y,
        });
        try capture.setCrop(crop);

        var child = try encoder.spawn(allocator, .{
            .output_path = cfg.output_path,
            .framerate = cfg.framerate,
            .video_bitrate_kbps = cfg.video_bitrate_kbps,
            .pix_fmt = pix_fmt,
            .in_w = crop.w,
            .in_h = crop.h,
            .crop = .{ .x = 0, .y = 0, .w = crop.w, .h = crop.h },
        });
        errdefer _ = child.kill() catch {};

        const thread = try std.Thread.spawn(.{}, pw.writerLoop, .{ capture, child.stdin.? });

        return .{
            .allocator = allocator,
            .session = session,
            .capture = capture,
            .ffmpeg = child,
            .thread = thread,
        };
    }

    pub fn stop(self: *Backend) void {
        self.capture.stop();
        self.thread.join();
        encoder.finish(&self.ffmpeg);
    }

    pub fn setPaused(self: *Backend, p: bool) void {
        self.capture.setPaused(p);
    }

    pub fn deinit(self: *Backend) void {
        self.capture.destroy();
        self.session.close();
    }
};

fn cropFor(region: ?encoder.Region, st: portal.Stream, fmt: pw.Format) ?encoder.Rect {
    const r = region orelse return null;
    const pos = st.position orelse [2]i32{ r.mon_x, r.mon_y };
    const size = st.size orelse [2]i32{ r.mon_w, r.mon_h };
    const rect = encoder.regionToCrop(r, pos[0], pos[1], size[0], size[1], fmt.width, fmt.height);
    if (rect == null) std.log.warn("selected area is not on the shared monitor; recording full stream", .{});
    return rect;
}

/// One frame from the shared monitor, for the area picker background.
pub fn grabStill(allocator: std.mem.Allocator) !encoder.Still {
    var session = try portal.open(allocator, .{ .monitor_only = true });
    defer session.close();
    const capture = try pw.Capture.create(allocator, session.pw_fd, session.stream.node_id, 30);
    defer capture.destroy();

    const fmt = try capture.waitFormat(3 * std.time.ns_per_s);
    const swap_rb = switch (fmt.spa_format) {
        pw.spa_bgrx, pw.spa_bgra => false,
        pw.spa_rgbx, pw.spa_rgba => true,
        else => return error.UnsupportedFormat,
    };
    try capture.setCrop(.{ .x = 0, .y = 0, .w = fmt.width, .h = fmt.height });

    var timer = try std.time.Timer.start();
    const data = try allocator.alloc(u8, capture.latest.len);
    errdefer allocator.free(data);
    while (true) {
        capture.mutex.lock();
        const ready = capture.has_frame;
        if (ready) @memcpy(data, capture.latest);
        capture.mutex.unlock();
        if (ready) break;
        if (timer.read() > 3 * std.time.ns_per_s) return error.FrameTimeout;
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    if (swap_rb) {
        var i: usize = 0;
        while (i < data.len) : (i += 4) std.mem.swap(u8, &data[i], &data[i + 2]);
    }
    return .{
        .data = data,
        .width = fmt.width,
        .height = fmt.height,
        .stride = fmt.width * 4,
        .origin = session.stream.position,
        .allocator = allocator,
    };
}
