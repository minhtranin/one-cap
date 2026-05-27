//! PulseAudio capture → raw PCM s16le stereo @ 48kHz, written to file.
//! Ported from zigy/zig-april-captions/src/pulse.zig.

const std = @import("std");

const c = @cImport({
    @cInclude("pulse/simple.h");
    @cInclude("pulse/error.h");
});

pub const Error = error{
    ConnectionFailed,
    ReadFailed,
    WriteFailed,
    Terminated,
};

pub const Source = enum {
    microphone,
    monitor,
};

pub const Config = struct {
    sample_rate: u32 = 48000,
    channels: u8 = 2,
    source: Source = .microphone,
    fragment_ms: u32 = 50,
};

pub const Capture = struct {
    simple: *c.pa_simple,
    cfg: Config,
    running: std.atomic.Value(bool),
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(cfg: Config) Error!Capture {
        var spec = c.pa_sample_spec{
            .format = c.PA_SAMPLE_S16LE,
            .rate = cfg.sample_rate,
            .channels = cfg.channels,
        };

        const frag = (cfg.sample_rate * @as(u32, cfg.channels) * 2 * cfg.fragment_ms) / 1000;
        var buf = c.pa_buffer_attr{
            .maxlength = std.math.maxInt(u32),
            .tlength = std.math.maxInt(u32),
            .prebuf = std.math.maxInt(u32),
            .minreq = std.math.maxInt(u32),
            .fragsize = frag,
        };

        const device: ?[*:0]const u8 = switch (cfg.source) {
            .microphone => null,
            .monitor => "@DEFAULT_MONITOR@",
        };

        const stream_name: [*:0]const u8 = switch (cfg.source) {
            .microphone => "one-cap mic",
            .monitor => "one-cap monitor",
        };

        var err: c_int = 0;
        const simple = c.pa_simple_new(
            null,
            "one-cap",
            c.PA_STREAM_RECORD,
            device,
            stream_name,
            &spec,
            null,
            &buf,
            &err,
        );

        if (simple == null) {
            std.log.err("pulse connect failed: {s}", .{std.mem.span(c.pa_strerror(err))});
            return Error.ConnectionFailed;
        }

        return .{
            .simple = simple.?,
            .cfg = cfg,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *Capture) void {
        self.running.store(false, .release);
        c.pa_simple_free(self.simple);
    }

    pub fn stop(self: *Capture) void {
        self.running.store(false, .release);
    }

    pub fn isRunning(self: *Capture) bool {
        return self.running.load(.acquire);
    }

    pub fn setPaused(self: *Capture, p: bool) void {
        self.paused.store(p, .release);
    }

    pub fn isPaused(self: *Capture) bool {
        return self.paused.load(.acquire);
    }

    /// Fill buffer with raw bytes from pulse. Buffer size = fragsize works well.
    pub fn readBytes(self: *Capture, buf: []u8) Error!void {
        if (!self.running.load(.acquire)) return Error.Terminated;
        var err: c_int = 0;
        const r = c.pa_simple_read(self.simple, buf.ptr, buf.len, &err);
        if (r < 0) {
            std.log.err("pulse read failed: {s}", .{std.mem.span(c.pa_strerror(err))});
            return Error.ReadFailed;
        }
    }
};

/// Thread entrypoint: capture until stop flag, write all bytes to writer.
/// While paused we still drain pulse (so the server's ring buffer doesn't
/// back up and overrun on resume) but we DROP the samples instead of
/// writing them. This matches what the video pipeline does: GStreamer
/// PAUSED state freezes PTS, so when we resume, the next video frame
/// continues from where the last one left off — video duration equals
/// wall_clock - total_pause_time. Audio must mirror that or ffmpeg's
/// `-shortest` mux cuts off whichever stream is longer.
///
/// Earlier this loop wrote silence during pause to keep the audio file's
/// time axis aligned with wall clock. That broke the single-track + video
/// mux path: audio file ended up longer than video by the pause duration,
/// so `-shortest` truncated the audio to the video length, dropping
/// everything captured after resume.
pub fn captureLoop(cap: *Capture, file: std.fs.File) void {
    const bytes_per_chunk = (cap.cfg.sample_rate * @as(u32, cap.cfg.channels) * 2 * cap.cfg.fragment_ms) / 1000;
    var buf: [16384]u8 = undefined;
    const chunk = if (bytes_per_chunk > buf.len) buf.len else bytes_per_chunk;

    while (cap.isRunning()) {
        cap.readBytes(buf[0..chunk]) catch |e| {
            if (e == Error.Terminated) break;
            std.log.err("audio loop error: {}", .{e});
            break;
        };
        if (cap.isPaused()) continue; // drained but not written
        _ = file.writeAll(buf[0..chunk]) catch |e| {
            std.log.err("audio file write failed: {}", .{e});
            break;
        };
    }
}
