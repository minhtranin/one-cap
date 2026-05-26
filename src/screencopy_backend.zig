//! Wlr-screencopy backend: in-process Wayland capture thread feeding raw
//! frames to an ffmpeg subprocess via stdin. Replaces the python+gstreamer
//! portal helper on niri / wlroots.

const std = @import("std");
const screencopy = @import("screencopy.zig");

pub const Config = struct {
    output_path: []const u8,
    framerate: u32,
    video_bitrate_kbps: u32,
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
        std.log.info(
            "screencopy: {d}x{d} stride={d} fmt={d} pix_fmt={s}",
            .{ info.width, info.height, info.stride, info.format, pix_fmt },
        );

        const w_str = try std.fmt.allocPrint(allocator, "{d}", .{info.width});
        defer allocator.free(w_str);
        const h_str = try std.fmt.allocPrint(allocator, "{d}", .{info.height});
        defer allocator.free(h_str);
        const fr_str = try std.fmt.allocPrint(allocator, "{d}", .{cfg.framerate});
        defer allocator.free(fr_str);
        const br_str = try std.fmt.allocPrint(allocator, "{d}k", .{cfg.video_bitrate_kbps});
        defer allocator.free(br_str);
        const size_str = try std.fmt.allocPrint(allocator, "{s}x{s}", .{ w_str, h_str });
        defer allocator.free(size_str);

        // wlr-screencopy can return frames with stride != width * 4 (rare on
        // niri, but possible). Pad-aware: we tell ffmpeg the stride width.
        const stride_pixels = info.stride / 4;
        const stride_w_str = try std.fmt.allocPrint(allocator, "{d}", .{stride_pixels});
        defer allocator.free(stride_w_str);
        const stride_size_str = try std.fmt.allocPrint(allocator, "{s}x{s}", .{ stride_w_str, h_str });
        defer allocator.free(stride_size_str);
        const crop_str = try std.fmt.allocPrint(
            allocator,
            "crop={d}:{d}:0:0",
            .{ info.width, info.height },
        );
        defer allocator.free(crop_str);

        const argv = [_][]const u8{
            "ffmpeg",            "-y",
            "-f",                "rawvideo",
            "-pix_fmt",          pix_fmt,
            "-s",                stride_size_str,
            "-framerate",        fr_str,
            "-i",                "-",
            "-vf",               crop_str,
            "-c:v",              "libx264",
            "-preset",           "ultrafast",
            "-tune",             "zerolatency",
            "-pix_fmt",          "yuv420p",
            "-b:v",              br_str,
            cfg.output_path,
        };

        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        const stdin_file = child.stdin.?;

        const thread = try std.Thread.spawn(.{}, screencopy.captureLoop, .{ capture, stdin_file });

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

        // Close ffmpeg stdin so it flushes + writes trailer cleanly.
        if (self.ffmpeg.stdin) |stdin| {
            stdin.close();
            self.ffmpeg.stdin = null;
        }
        _ = self.ffmpeg.wait() catch {};
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
