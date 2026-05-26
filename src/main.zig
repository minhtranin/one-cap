const std = @import("std");
const recorder = @import("recorder.zig");
const audio = @import("audio.zig");

const usage =
    \\one-cap — simple Wayland screen+audio recorder (Zig)
    \\
    \\USAGE:
    \\    one-cap <output.mp4> [options]
    \\
    \\OPTIONS:
    \\    -d, --duration <secs>   Record for N seconds (default: until Ctrl+C)
    \\    -r, --framerate <fps>   Video framerate (default: 30)
    \\        --monitor           Capture system audio output (default: microphone)
    \\    -h, --help              Print this help
    \\
    \\EXAMPLES:
    \\    one-cap out.mp4 -d 10
    \\    one-cap demo.mp4 --monitor
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.io.getStdErr().writer().writeAll(usage);
        return error.MissingArgs;
    }

    var opts = recorder.Options{
        .output_path = "",
        .duration_seconds = null,
        .framerate = 30,
        .audio_source = .microphone,
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
        } else if (std.mem.eql(u8, a, "--monitor")) {
            opts.audio_source = .monitor;
        } else if (a.len > 0 and a[0] == '-') {
            std.log.err("unknown flag: {s}", .{a});
            return error.UnknownFlag;
        } else {
            if (positional != null) return error.TooManyArgs;
            positional = a;
        }
    }

    if (positional == null) {
        try std.io.getStdErr().writer().writeAll(usage);
        return error.MissingOutput;
    }
    opts.output_path = positional.?;

    try recorder.record(allocator, opts);
}

test "compile audio module" {
    _ = audio;
    _ = recorder;
}
