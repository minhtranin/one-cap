//! ffmpeg subprocess that encodes raw frames from stdin to H264 in a
//! fragmented MP4. Shared by the wlr-screencopy and PipeWire backends.

const std = @import("std");

/// Rectangle in pixels of the captured frame.
pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// User-selected area in global logical (compositor) coordinates, plus the
/// geometry of the monitor it was drawn on.
pub const Region = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    monitor_index: i32,
    mon_x: i32,
    mon_y: i32,
    mon_w: i32,
    mon_h: i32,
};

/// Maps a logical region onto a frame of `frame_w`×`frame_h` pixels that
/// shows the logical area (origin_x, origin_y, logical_w, logical_h).
/// Returns null when the region doesn't overlap the frame.
pub fn regionToCrop(
    region: Region,
    origin_x: i32,
    origin_y: i32,
    logical_w: i32,
    logical_h: i32,
    frame_w: u32,
    frame_h: u32,
) ?Rect {
    if (logical_w <= 0 or logical_h <= 0) return null;
    const sx = @as(f64, @floatFromInt(frame_w)) / @as(f64, @floatFromInt(logical_w));
    const sy = @as(f64, @floatFromInt(frame_h)) / @as(f64, @floatFromInt(logical_h));

    const fw: f64 = @floatFromInt(frame_w);
    const fh: f64 = @floatFromInt(frame_h);
    const x0 = std.math.clamp(@as(f64, @floatFromInt(region.x - origin_x)) * sx, 0, fw);
    const y0 = std.math.clamp(@as(f64, @floatFromInt(region.y - origin_y)) * sy, 0, fh);
    const x1 = std.math.clamp(@as(f64, @floatFromInt(region.x + region.w - origin_x)) * sx, 0, fw);
    const y1 = std.math.clamp(@as(f64, @floatFromInt(region.y + region.h - origin_y)) * sy, 0, fh);

    // yuv420p needs even dimensions and offsets.
    const x: u32 = @as(u32, @intFromFloat(@round(x0))) & ~@as(u32, 1);
    const y: u32 = @as(u32, @intFromFloat(@round(y0))) & ~@as(u32, 1);
    const right: u32 = @intFromFloat(@round(x1));
    const bottom: u32 = @intFromFloat(@round(y1));
    if (right <= x + 16 or bottom <= y + 16) return null;
    return .{ .x = x, .y = y, .w = (right - x) & ~@as(u32, 1), .h = (bottom - y) & ~@as(u32, 1) };
}

/// A frozen frame shown under the area picker. Pixels are BGRx (cairo RGB24).
pub const Still = struct {
    data: []u8,
    width: u32,
    height: u32,
    stride: u32,
    /// Logical geometry of the captured monitor, when the backend knows it.
    origin: ?[2]i32 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Still) void {
        self.allocator.free(self.data);
    }
};

pub const Config = struct {
    output_path: []const u8,
    framerate: u32,
    video_bitrate_kbps: u32,
    pix_fmt: []const u8,
    /// Size of each raw frame written to stdin (stride-padded width allowed).
    in_w: u32,
    in_h: u32,
    /// Region of the input frame to keep.
    crop: Rect,
};

pub fn spawn(allocator: std.mem.Allocator, cfg: Config) !std.process.Child {
    var size_buf: [32]u8 = undefined;
    const size_str = try std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ cfg.in_w, cfg.in_h });
    var fr_buf: [16]u8 = undefined;
    const fr_str = try std.fmt.bufPrint(&fr_buf, "{d}", .{cfg.framerate});
    var br_buf: [16]u8 = undefined;
    const br_str = try std.fmt.bufPrint(&br_buf, "{d}k", .{cfg.video_bitrate_kbps});
    var crop_buf: [64]u8 = undefined;
    const crop_str = try std.fmt.bufPrint(&crop_buf, "crop={d}:{d}:{d}:{d}", .{
        cfg.crop.w, cfg.crop.h, cfg.crop.x, cfg.crop.y,
    });

    // Fragmented mp4 writes moov upfront and a moof per keyframe, so a
    // kill/crash mid-record still leaves a file playable to the last fragment.
    const argv = [_][]const u8{
        "ffmpeg",     "-y",
        "-loglevel",  "warning",
        "-f",         "rawvideo",
        "-pix_fmt",   cfg.pix_fmt,
        "-s",         size_str,
        "-framerate", fr_str,
        "-i",         "-",
        "-vf",        crop_str,
        "-c:v",       "libx264",
        "-preset",    "ultrafast",
        "-tune",      "zerolatency",
        "-pix_fmt",   "yuv420p",
        "-b:v",       br_str,
        "-movflags",  "+frag_keyframe+empty_moov+default_base_moof",
        cfg.output_path,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

/// Closes stdin so ffmpeg flushes and finalizes, then waits for it.
pub fn finish(child: *std.process.Child) void {
    if (child.stdin) |stdin| {
        stdin.close();
        child.stdin = null;
    }
    _ = child.wait() catch {};
}

test "regionToCrop scales and evens" {
    const r = Region{ .x = 101, .y = 51, .w = 501, .h = 301, .monitor_index = 0, .mon_x = 0, .mon_y = 0, .mon_w = 1920, .mon_h = 1080 };
    const c = regionToCrop(r, 0, 0, 1920, 1080, 3840, 2160).?;
    try std.testing.expectEqual(@as(u32, 202), c.x);
    try std.testing.expectEqual(@as(u32, 102), c.y);
    try std.testing.expect(c.w % 2 == 0 and c.h % 2 == 0);
    try std.testing.expectEqual(@as(u32, 1002), c.w);
}

test "regionToCrop outside frame" {
    const r = Region{ .x = 2000, .y = 0, .w = 300, .h = 300, .monitor_index = 1, .mon_x = 1920, .mon_y = 0, .mon_w = 1920, .mon_h = 1080 };
    try std.testing.expect(regionToCrop(r, 0, 0, 1920, 1080, 1920, 1080) == null);
}
