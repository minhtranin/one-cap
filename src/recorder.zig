//! Orchestrate: spawn screen subprocess + audio thread, then mux to final mp4.

const std = @import("std");
const audio = @import("audio.zig");
const screen = @import("screen.zig");

pub const Options = struct {
    output_path: []const u8,
    duration_seconds: ?u32,
    framerate: u32 = 30,
    video_bitrate_kbps: u32 = 20000, // 20 Mbps default — good for 1440p
    audio_source: audio.Source = .microphone,
    sample_rate: u32 = 48000,
    channels: u8 = 2,
};

pub fn record(allocator: std.mem.Allocator, opts: Options) !void {
    const tmp_audio = "/tmp/one-cap-audio.raw";
    std.fs.cwd().deleteFile(tmp_audio) catch {};

    // Detect backend first so we can pick a matching intermediate file extension.
    const backend = try screen.detectBackend(allocator);

    // Intermediate file ext follows the desired output container when possible,
    // so the portal helper writes WebM directly when user asked for WebM (lets
    // mux stream-copy VP8 instead of re-encoding).
    const out_is_webm = std.mem.endsWith(u8, opts.output_path, ".webm");
    const tmp_video = switch (backend) {
        .portal_pipewire => if (out_is_webm) "/tmp/one-cap-video.webm" else "/tmp/one-cap-video.mkv",
        else => "/tmp/one-cap-video.mp4",
    };
    std.fs.cwd().deleteFile(tmp_video) catch {};

    var screen_rec = try screen.Recorder.start(allocator, .{
        .output_path = tmp_video,
        .framerate = opts.framerate,
        .video_bitrate_kbps = opts.video_bitrate_kbps,
        .backend = backend,
    });
    defer screen_rec.deinit();

    var audio_cap = try audio.Capture.init(.{
        .sample_rate = opts.sample_rate,
        .channels = opts.channels,
        .source = opts.audio_source,
    });
    errdefer audio_cap.deinit();

    const audio_file = try std.fs.cwd().createFile(tmp_audio, .{});
    errdefer audio_file.close();

    var audio_thread = try std.Thread.spawn(.{}, audio.captureLoop, .{ &audio_cap, audio_file });

    std.log.info("recording... output={s}", .{opts.output_path});

    if (opts.duration_seconds) |secs| {
        std.time.sleep(@as(u64, secs) * std.time.ns_per_s);
    } else {
        try waitForInterrupt();
    }

    std.log.info("stopping capture...", .{});
    audio_cap.stop();
    audio_thread.join();
    audio_cap.deinit();
    audio_file.close();

    try screen_rec.stop();

    try mux(allocator, tmp_video, tmp_audio, opts);

    std.log.info("done → {s}", .{opts.output_path});
}

fn mux(
    allocator: std.mem.Allocator,
    video_path: []const u8,
    audio_path: []const u8,
    opts: Options,
) !void {
    const sr = try std.fmt.allocPrint(allocator, "{d}", .{opts.sample_rate});
    defer allocator.free(sr);
    const ch = try std.fmt.allocPrint(allocator, "{d}", .{opts.channels});
    defer allocator.free(ch);

    // Stream-copy video always (portal helper picked the right codec for the container).
    // Audio encoder follows container: webm → Opus, mp4/mkv → AAC.
    const audio_codec: []const u8 = if (std.mem.endsWith(u8, opts.output_path, ".webm"))
        "libopus"
    else
        "aac";

    const argv = [_][]const u8{
        "ffmpeg", "-y",
        "-i",     video_path,
        "-f",     "s16le",
        "-ar",    sr,
        "-ac",    ch,
        "-i",     audio_path,
        "-c:v",   "copy",
        "-c:a",   audio_codec,
        "-b:a",   "192k",
        "-shortest",
        opts.output_path,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();

    switch (term) {
        .Exited => |code| if (code != 0) {
            std.log.err("ffmpeg mux exit code {d}", .{code});
            return error.MuxFailed;
        },
        else => return error.MuxFailed,
    }
}

var interrupted = std.atomic.Value(bool).init(false);

fn sigintHandler(_: c_int) callconv(.C) void {
    interrupted.store(true, .release);
}

fn waitForInterrupt() !void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT, &act, null);

    while (!interrupted.load(.acquire)) {
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}
