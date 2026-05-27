//! Orchestrate: spawn screen subprocess + audio thread + GTK control window.
//! The GTK loop runs on the calling thread; a controller thread mirrors UI
//! state into the screen child (via stdin commands) and audio capture (via
//! atomic flag). When the user clicks Stop / closes the window / duration
//! elapses, GTK quits and the recorder finalizes + muxes.

const std = @import("std");
const audio = @import("audio.zig");
const screen = @import("screen.zig");
const ui = @import("ui.zig");

pub const Options = struct {
    output_path: []const u8,
    duration_seconds: ?u32,
    framerate: u32 = 30,
    video_bitrate_kbps: u32 = 40000,
    audio_source: audio.Source = .monitor,
    sample_rate: u32 = 48000,
    channels: u8 = 2,
    show_ui: bool = true,
    /// Initial playback-speed multiplier ×100 (100 = 1×). UI may override
    /// before stop; mux reads the final value from state.
    speed_x100: u32 = 100,
};

pub fn record(allocator: std.mem.Allocator, opts: Options) !void {
    if (opts.show_ui) {
        return recordWithUi(allocator, opts);
    }
    return recordHeadless(allocator, opts);
}

fn recordHeadless(allocator: std.mem.Allocator, opts: Options) !void {
    const tmp_audio = "/tmp/one-cap-audio.raw";
    const tmp_mic = "/tmp/one-cap-mic.raw";
    std.fs.cwd().deleteFile(tmp_audio) catch {};
    std.fs.cwd().deleteFile(tmp_mic) catch {};

    const backend = try screen.detectBackend(allocator);
    const tmp_video = switch (backend) {
        .wlr_screencopy, .portal_pipewire => "/tmp/one-cap-video.mkv",
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

    // Mic track: only meaningful when the primary source is monitor (we add
    // mic on top of system audio). If the user passed --mic, the primary
    // source is already mic and the toggle is a no-op — we skip the extra
    // capture in that case.
    const want_mic_track = opts.audio_source == .monitor;
    var mic_cap: ?audio.Capture = null;
    var mic_thread: ?std.Thread = null;
    var mic_file: ?std.fs.File = null;
    if (want_mic_track) {
        var mc = try audio.Capture.init(.{
            .sample_rate = opts.sample_rate,
            .channels = opts.channels,
            .source = .microphone,
        });
        // Start muted (silence written, file stays wall-clock aligned with video).
        mc.setMuted(true);
        mic_cap = mc;
        mic_file = try std.fs.cwd().createFile(tmp_mic, .{});
        mic_thread = try std.Thread.spawn(.{}, audio.captureLoop, .{ &mic_cap.?, mic_file.? });
    }

    std.log.info("recording (headless)... output={s}", .{opts.output_path});

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

    const had_mic_track = mic_cap != null;
    if (mic_cap) |*mc| {
        mc.stop();
        mic_thread.?.join();
        mc.deinit();
        if (mic_file) |mf| mf.close();
    }

    try screen_rec.stop();

    try mux(allocator, tmp_video, tmp_audio, if (had_mic_track) tmp_mic else null, opts, opts.speed_x100);

    std.log.info("done → {s}", .{opts.output_path});
}

/// GUI mode: capture starts immediately on launch (like the old behavior).
/// UI window shows live counter + Pause/Stop/Mic/Cursor buttons. Counter
/// freezes while paused. Stop closes the window and finalizes the file.
fn recordWithUi(allocator: std.mem.Allocator, opts: Options) !void {
    const tmp_audio = "/tmp/one-cap-audio.raw";
    const tmp_mic = "/tmp/one-cap-mic.raw";
    std.fs.cwd().deleteFile(tmp_audio) catch {};
    std.fs.cwd().deleteFile(tmp_mic) catch {};

    const backend = try screen.detectBackend(allocator);
    const tmp_video = switch (backend) {
        .wlr_screencopy, .portal_pipewire => "/tmp/one-cap-video.mkv",
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

    const want_mic_track = opts.audio_source == .monitor;
    var mic_cap: ?audio.Capture = null;
    var mic_thread: ?std.Thread = null;
    var mic_file: ?std.fs.File = null;
    if (want_mic_track) {
        var mc = try audio.Capture.init(.{
            .sample_rate = opts.sample_rate,
            .channels = opts.channels,
            .source = .microphone,
        });
        mc.setMuted(true);
        mic_cap = mc;
        mic_file = try std.fs.cwd().createFile(tmp_mic, .{});
        mic_thread = try std.Thread.spawn(.{}, audio.captureLoop, .{ &mic_cap.?, mic_file.? });
    }

    std.log.info("recording... output={s}", .{opts.output_path});

    var state = ui.State{
        .duration_seconds = opts.duration_seconds orelse 0,
    };
    state.setSpeedX100(opts.speed_x100);
    state.recording_start_ns.store(std.time.nanoTimestamp(), .release);

    const ctrl = try std.Thread.spawn(.{}, controllerLoop, .{
        &state, &screen_rec, &audio_cap, if (mic_cap != null) &mic_cap.? else null,
    });

    ui.run(&state) catch |e| {
        std.log.err("ui error: {} — stopping", .{e});
        state.requestStop();
    };
    ctrl.join();

    const final_speed_x100 = state.speedX100();

    // If the user stopped while paused, resume the screen pipeline before
    // shutting it down. GStreamer's PAUSED state freezes the dataflow, so
    // an EOS sent while paused gets stuck and forces the helper's 5s safety
    // timeout — a visible hang on Stop. Resuming first lets EOS propagate
    // cleanly and Stop returns in well under a second.
    if (state.isPaused()) {
        screen_rec.sendCommand("RESUME\n") catch |e| std.log.err("pre-stop resume failed: {}", .{e});
        std.time.sleep(50 * std.time.ns_per_ms); // let pipeline finish the PAUSED→PLAYING transition
    }

    std.log.info("stopping capture...", .{});
    audio_cap.stop();
    audio_thread.join();
    audio_cap.deinit();
    audio_file.close();

    const had_mic_track = mic_cap != null;
    if (mic_cap) |*mc| {
        mc.stop();
        mic_thread.?.join();
        mc.deinit();
        if (mic_file) |mf| mf.close();
    }

    try screen_rec.stop();

    // Mux runs on a worker thread so the GTK main thread can show a small
    // "Finalizing…" dialog with a spinner — long captures + non-1× speed used
    // to look like the app froze on Stop.
    var mux_ctx = MuxCtx{
        .allocator = allocator,
        .video_path = tmp_video,
        .audio_path = tmp_audio,
        .mic_path = if (had_mic_track) tmp_mic else null,
        .opts = opts,
        .speed_x100 = final_speed_x100,
    };
    const mux_thread = try std.Thread.spawn(.{}, muxThread, .{&mux_ctx});
    const msg: [:0]const u8 = if (final_speed_x100 != 100)
        "Finalizing video…"
    else
        "Saving video…";
    ui.runFinalizing(msg);
    mux_thread.join();
    ui.closeFinalizing();
    if (mux_ctx.err) |e| return e;

    std.log.info("done → {s}", .{opts.output_path});
}

const MuxCtx = struct {
    allocator: std.mem.Allocator,
    video_path: []const u8,
    audio_path: []const u8,
    mic_path: ?[]const u8,
    opts: Options,
    speed_x100: u32,
    err: ?anyerror = null,
};

fn muxThread(ctx: *MuxCtx) void {
    mux(ctx.allocator, ctx.video_path, ctx.audio_path, ctx.mic_path, ctx.opts, ctx.speed_x100) catch |e| {
        ctx.err = e;
    };
    ui.signalFinalizeDone();
}

fn controllerLoop(
    state: *ui.State,
    screen_rec: *screen.Recorder,
    audio_cap: *audio.Capture,
    mic_cap: ?*audio.Capture,
) void {
    var last_paused = false;
    var last_mic = false;
    var last_cursor = true;
    while (!state.stop_requested.load(.acquire)) {
        const now_paused = state.isPaused();
        if (now_paused != last_paused) {
            // Global pause: drop samples on both tracks so audio shrinks with the
            // frozen video PTS — keeps wall-clock alignment intact across resume.
            audio_cap.setPaused(now_paused);
            if (mic_cap) |mc| mc.setPaused(now_paused);
            const cmd: []const u8 = if (now_paused) "PAUSE\n" else "RESUME\n";
            screen_rec.sendCommand(cmd) catch |e| std.log.err("send cmd failed: {}", .{e});
            last_paused = now_paused;
        }
        const now_mic = state.isMicEnabled();
        if (now_mic != last_mic) {
            // Mic toggle is independent of pause: when disabled we write silence
            // (not drop) so the mic file stays aligned to the video timeline and
            // speech captured after the toggle lands at the correct moment.
            if (mic_cap) |mc| mc.setMuted(!now_mic);
            last_mic = now_mic;
        }
        const now_cursor = state.isCursorEnabled();
        if (now_cursor != last_cursor) {
            screen_rec.setShowCursor(now_cursor);
            last_cursor = now_cursor;
        }
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

fn mux(
    allocator: std.mem.Allocator,
    video_path: []const u8,
    audio_path: []const u8,
    mic_path: ?[]const u8,
    opts: Options,
    speed_x100: u32,
) !void {
    const sr = try std.fmt.allocPrint(allocator, "{d}", .{opts.sample_rate});
    defer allocator.free(sr);
    const ch = try std.fmt.allocPrint(allocator, "{d}", .{opts.channels});
    defer allocator.free(ch);

    const audio_codec: []const u8 = if (std.mem.endsWith(u8, opts.output_path, ".webm"))
        "libopus"
    else
        "aac";

    const speed_active = speed_x100 != 100;
    // Speed-up path uses `-itsscale 1/N` to rewrite input PTS in-place on the
    // video container, then stream-copies the video bytes (no re-encode → no
    // quality loss and finalize stays in seconds even for hour-long captures).
    // Audio is sped via `atempo` which still requires re-encoding (cheap on raw
    // PCM input) — without atempo the audio would shift pitch like a chipmunk.
    const speed_n: f64 = @as(f64, @floatFromInt(speed_x100)) / 100.0;
    const itsscale: f64 = 1.0 / speed_n;

    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    // itsscale only applies to the *next* input — must come before `-i video`.
    var itsscale_str: ?[]u8 = null;
    defer if (itsscale_str) |s| allocator.free(s);
    if (speed_active) {
        itsscale_str = try std.fmt.allocPrint(allocator, "{d:.6}", .{itsscale});
        try argv.appendSlice(&.{ "ffmpeg", "-y", "-itsscale", itsscale_str.?, "-i", video_path });
    } else {
        try argv.appendSlice(&.{ "ffmpeg", "-y", "-i", video_path });
    }
    try argv.appendSlice(&.{ "-f", "s16le", "-ar", sr, "-ac", ch, "-i", audio_path });
    if (mic_path) |mp| {
        try argv.appendSlice(&.{ "-f", "s16le", "-ar", sr, "-ac", ch, "-i", mp });
    }

    if (speed_active) {
        const atempo_str = try std.fmt.allocPrint(allocator, "{d:.6}", .{speed_n});
        defer allocator.free(atempo_str);

        const filter = if (mic_path != null)
            try std.fmt.allocPrint(
                allocator,
                "[1:a][2:a]amix=inputs=2:duration=longest:dropout_transition=0,atempo={s}[aout]",
                .{atempo_str},
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "[1:a]atempo={s}[aout]",
                .{atempo_str},
            );
        defer allocator.free(filter);

        try argv.appendSlice(&.{
            "-filter_complex", filter,
            "-map",            "0:v",
            "-map",            "[aout]",
            "-c:v",            "copy",
            "-c:a",            audio_codec,
            "-b:a",            "192k",
            "-shortest",
            opts.output_path,
        });

        var child = std.process.Child.init(argv.items, allocator);
        child.stderr_behavior = .Inherit;
        try child.spawn();
        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) {
                std.log.err("ffmpeg mux (speed={d}) exit code {d}", .{ speed_x100, code });
                return error.MuxFailed;
            },
            else => return error.MuxFailed,
        }
        return;
    }

    // Fast path: 1× speed → stream-copy video, encode audio only.
    if (mic_path != null) {
        try argv.appendSlice(&.{
            "-filter_complex",
            "[1:a][2:a]amix=inputs=2:duration=longest:dropout_transition=0[aout]",
            "-map",      "0:v",
            "-map",      "[aout]",
        });
    } else {
        try argv.appendSlice(&.{ "-map", "0:v", "-map", "1:a" });
    }

    try argv.appendSlice(&.{
        "-c:v", "copy",
        "-c:a", audio_codec,
        "-b:a", "192k",
        "-shortest",
        opts.output_path,
    });

    var child = std.process.Child.init(argv.items, allocator);
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
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    while (!interrupted.load(.acquire)) {
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}
