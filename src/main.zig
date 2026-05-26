const std = @import("std");
const recorder = @import("recorder.zig");
const audio = @import("audio.zig");

const c = @cImport({
    @cInclude("time.h");
});

const usage =
    \\one-cap — simple Wayland screen+audio recorder (Zig)
    \\
    \\USAGE:
    \\    one-cap [output-file] [options]
    \\
    \\If output-file is omitted, it defaults to ~/Videos/onecap-<timestamp>.mkv
    \\(MKV+H264 = much faster encode than .webm/VP8 at 1440p, no frame drops)
    \\
    \\DEFAULTS: system audio (monitor) + ultra quality (40 Mbps)
    \\
    \\OPTIONS:
    \\    -d, --duration <secs>   Record for N seconds (default: until Ctrl+C)
    \\    -r, --framerate <fps>   Video framerate (default: 30)
    \\    -b, --bitrate <kbps>    Video bitrate in kbps (default: 40000 = 40 Mbps)
    \\    -q, --quality <name>    Preset: low (8M) | medium (15M) | high (25M) | ultra (40M)
    \\        --mic               Capture microphone instead of system audio
    \\        --monitor           Capture system audio (default — explicit override)
    \\    -h, --help              Print this help
    \\
    \\EXAMPLES:
    \\    one-cap                          # → ~/Videos/onecap-<ts>.mkv (H264 ultra, sys audio)
    \\    one-cap demo.mp4 -d 10
    \\    one-cap clip.webm                # webm/VP8 (slower, may drop frames at 1440p)
    \\    one-cap clip.mkv --mic
    \\    one-cap clip.mkv -q medium       # 15 Mbps
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = recorder.Options{
        .output_path = "",
        .duration_seconds = null,
    };

    var positional: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std.io.getStdOut().writer().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--duration")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.duration_seconds = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--framerate")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.framerate = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "-b") or std.mem.eql(u8, a, "--bitrate")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.video_bitrate_kbps = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--quality")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const q = args[i];
            opts.video_bitrate_kbps = if (std.mem.eql(u8, q, "low"))
                8000
            else if (std.mem.eql(u8, q, "medium"))
                15000
            else if (std.mem.eql(u8, q, "high"))
                25000
            else if (std.mem.eql(u8, q, "ultra"))
                40000
            else
                return error.UnknownQualityPreset;
        } else if (std.mem.eql(u8, a, "--monitor")) {
            opts.audio_source = .monitor;
        } else if (std.mem.eql(u8, a, "--mic")) {
            opts.audio_source = .microphone;
        } else if (std.mem.eql(u8, a, "--no-ui")) {
            opts.show_ui = false;
        } else if (a.len > 0 and a[0] == '-') {
            std.log.err("unknown flag: {s}", .{a});
            return error.UnknownFlag;
        } else {
            if (positional != null) return error.TooManyArgs;
            positional = a;
        }
    }

    var default_path_buf: ?[]u8 = null;
    defer if (default_path_buf) |b| allocator.free(b);

    if (positional) |p| {
        opts.output_path = p;
    } else {
        default_path_buf = try defaultOutputPath(allocator);
        opts.output_path = default_path_buf.?;
    }

    try recorder.record(allocator, opts);
}

/// ~/Videos/onecap-YYYYMMDD-HHMMSS.webm — creates ~/Videos if missing.
fn defaultOutputPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeEnv;
    const dir = try std.fmt.allocPrint(allocator, "{s}/Videos", .{home});
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};

    var raw: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&raw, &tm);

    return std.fmt.allocPrint(allocator, "{s}/onecap-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.mkv", .{
        dir,
        @as(u32, @intCast(tm.tm_year + 1900)),
        @as(u32, @intCast(tm.tm_mon + 1)),
        @as(u32, @intCast(tm.tm_mday)),
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
    });
}

test "compile audio module" {
    _ = audio;
    _ = recorder;
}
