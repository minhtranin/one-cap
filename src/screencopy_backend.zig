//! Wlr-screencopy backend: in-process Wayland capture thread feeding raw
//! frames to an ffmpeg subprocess via stdin (niri / wlroots).

const std = @import("std");
const screencopy = @import("screencopy.zig");
const encoder = @import("encoder.zig");

pub const Config = struct {
    output_path: []const u8,
    framerate: u32,
    video_bitrate_kbps: u32,
    region: ?encoder.Region = null,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    capture: *screencopy.Capture,
    ffmpeg: std.process.Child,
    thread: std.Thread,

    pub fn start(allocator: std.mem.Allocator, cfg: Config) !Backend {
        const capture = try allocator.create(screencopy.Capture);
        errdefer allocator.destroy(capture);

        capture.* = try screencopy.Capture.init(allocator, cfg.framerate);
        errdefer capture.deinit();

        // Probe one frame to discover dims/format before launching ffmpeg.
        const info = try capture.firstFrameInfo();
        const pix_fmt = screencopy.pixFmtName(info.format);

        const full = encoder.Rect{ .x = 0, .y = 0, .w = info.width & ~@as(u32, 1), .h = info.height & ~@as(u32, 1) };
        const crop = cropFor(cfg.region, info) orelse full;
        std.log.info(
            "screencopy: {d}x{d} stride={d} fmt={d} pix_fmt={s} crop={d}x{d}+{d}+{d}",
            .{ info.width, info.height, info.stride, info.format, pix_fmt, crop.w, crop.h, crop.x, crop.y },
        );

        // Strides can be wider than width*4; ffmpeg gets the padded width and
        // the crop trims it.
        var child = try encoder.spawn(allocator, .{
            .output_path = cfg.output_path,
            .framerate = cfg.framerate,
            .video_bitrate_kbps = cfg.video_bitrate_kbps,
            .pix_fmt = pix_fmt,
            .in_w = info.stride / 4,
            .in_h = info.height,
            .crop = crop,
        });
        errdefer _ = child.kill() catch {};

        const thread = try std.Thread.spawn(.{}, screencopy.captureLoop, .{ capture, child.stdin.? });

        return .{
            .allocator = allocator,
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

    pub fn setShowCursor(self: *Backend, v: bool) void {
        self.capture.setShowCursor(v);
    }

    pub fn deinit(self: *Backend) void {
        self.capture.deinit();
        self.allocator.destroy(self.capture);
    }
};

/// wlr-screencopy records the first wl_output, which GDK lists as monitor 0.
fn cropFor(region: ?encoder.Region, info: screencopy.Frame) ?encoder.Rect {
    const r = region orelse return null;
    if (r.monitor_index != 0) {
        std.log.warn("selected area is not on the first monitor; recording full output", .{});
        return null;
    }
    return encoder.regionToCrop(r, r.mon_x, r.mon_y, r.mon_w, r.mon_h, info.width, info.height);
}

/// One frame of the first output, for the area picker background.
pub fn grabStill(allocator: std.mem.Allocator) !encoder.Still {
    var capture = try screencopy.Capture.init(allocator, 30);
    defer capture.deinit();
    const info = try capture.firstFrameInfo();
    switch (info.format) {
        screencopy.format_xrgb8888, screencopy.format_argb8888 => {},
        else => return error.UnsupportedFormat,
    }
    const len = @as(usize, info.stride) * info.height;
    const data = try allocator.dupe(u8, capture.state.shm_ptr.?[0..len]);
    return .{ .data = data, .width = info.width, .height = info.height, .stride = info.stride, .allocator = allocator };
}
