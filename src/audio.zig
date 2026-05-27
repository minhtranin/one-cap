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
    muted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

    pub fn setMuted(self: *Capture, m: bool) void {
        self.muted.store(m, .release);
    }

    pub fn isMuted(self: *Capture) bool {
        return self.muted.load(.acquire);
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

/// Thread entrypoint: capture until stop flag, write bytes to file.
///
/// Two distinct gating modes:
///   paused → drop samples entirely (file shrinks vs wall clock). Used when the
///     whole recording is paused — video PTS freezes too, so the audio file
///     and video file both shorten by the pause duration and stay aligned.
///   muted  → write silence in place of the real samples (file keeps growing
///     at wall-clock rate). Used for the mic track when the user has the mic
///     toggled off but recording is otherwise live: the mic file must stay
///     aligned to the video timeline so that when the mic is later enabled,
///     the captured speech lands at the correct moment in the muxed output.
///
/// We always drain pulse on every iteration so the server's ring buffer can't
/// back up and overrun.
pub fn captureLoop(cap: *Capture, file: std.fs.File) void {
    const bytes_per_chunk = (cap.cfg.sample_rate * @as(u32, cap.cfg.channels) * 2 * cap.cfg.fragment_ms) / 1000;
    var buf: [16384]u8 = undefined;
    var silence: [16384]u8 = [_]u8{0} ** 16384;
    const chunk = if (bytes_per_chunk > buf.len) buf.len else bytes_per_chunk;

    while (cap.isRunning()) {
        cap.readBytes(buf[0..chunk]) catch |e| {
            if (e == Error.Terminated) break;
            std.log.err("audio loop error: {}", .{e});
            break;
        };
        if (cap.isPaused()) continue; // drained, not written — file freezes with video
        const payload = if (cap.isMuted()) silence[0..chunk] else buf[0..chunk];
        _ = file.writeAll(payload) catch |e| {
            std.log.err("audio file write failed: {}", .{e});
            break;
        };
    }
}
