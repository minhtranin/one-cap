//! PipeWire video consumer for a portal ScreenCast stream.
//!
//! Mutter only delivers a frame when the screen changes, so frames land in a
//! "latest" buffer and a writer thread pushes it to ffmpeg at a fixed rate.
//! The crop is applied while copying, so ffmpeg only sees the selected area.
//!
//! SPA pods are built and parsed by hand: translate-c can't compile the
//! spa/pod inline helpers.

const std = @import("std");
const encoder = @import("encoder.zig");

const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("spa/param/video/raw.h");
    @cInclude("spa/param/format.h");
    @cInclude("spa/param/buffers.h");
    @cInclude("spa/buffer/buffer.h");
});

pub const Error = error{
    PipeWireInitFailed,
    StreamConnectFailed,
    FormatTimeout,
    UnsupportedFormat,
    OutOfMemory,
};

pub const spa_bgrx: u32 = c.SPA_VIDEO_FORMAT_BGRx;
pub const spa_bgra: u32 = c.SPA_VIDEO_FORMAT_BGRA;
pub const spa_rgbx: u32 = c.SPA_VIDEO_FORMAT_RGBx;
pub const spa_rgba: u32 = c.SPA_VIDEO_FORMAT_RGBA;

pub const Format = struct {
    width: u32,
    height: u32,
    spa_format: u32,
};

pub const Capture = struct {
    allocator: std.mem.Allocator,
    loop: *c.pw_thread_loop,
    context: *c.pw_context,
    core: *c.pw_core,
    stream: *c.pw_stream,
    hook: c.spa_hook = std.mem.zeroes(c.spa_hook),
    events: c.pw_stream_events = std.mem.zeroes(c.pw_stream_events),

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    format: ?Format = null,
    stream_error: bool = false,

    crop: ?encoder.Rect = null,
    latest: []u8 = &.{},
    has_frame: bool = false,

    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    framerate: u32,

    /// Takes ownership of `fd`. Result must not move (callbacks hold a pointer).
    pub fn create(allocator: std.mem.Allocator, fd: c_int, node_id: u32, framerate: u32) Error!*Capture {
        c.pw_init(null, null);

        const loop = c.pw_thread_loop_new("one-cap-pw", null) orelse return Error.PipeWireInitFailed;
        errdefer c.pw_thread_loop_destroy(loop);
        const context = c.pw_context_new(c.pw_thread_loop_get_loop(loop), null, 0) orelse return Error.PipeWireInitFailed;
        errdefer c.pw_context_destroy(context);

        if (c.pw_thread_loop_start(loop) < 0) return Error.PipeWireInitFailed;
        c.pw_thread_loop_lock(loop);
        var locked = true;
        defer if (locked) c.pw_thread_loop_unlock(loop);

        const core = c.pw_context_connect_fd(context, fd, null, 0) orelse return Error.PipeWireInitFailed;
        const props = c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE,
            "Video",
            c.PW_KEY_MEDIA_CATEGORY,
            "Capture",
            c.PW_KEY_MEDIA_ROLE,
            "Screen",
            @as(?*anyopaque, null),
        );
        const stream = c.pw_stream_new(core, "one-cap", props) orelse return Error.PipeWireInitFailed;

        const self = allocator.create(Capture) catch return Error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .loop = loop,
            .context = context,
            .core = core,
            .stream = stream,
            .framerate = framerate,
        };
        self.events.version = c.PW_VERSION_STREAM_EVENTS;
        self.events.state_changed = onStateChanged;
        self.events.param_changed = onParamChanged;
        self.events.process = onProcess;
        c.pw_stream_add_listener(stream, &self.hook, &self.events, self);

        var pod_buf: [1024]u8 align(8) = undefined;
        var b = PodBuilder{ .buf = &pod_buf };
        const enum_format = buildEnumFormat(&b, framerate);
        var params = [_]?*const c.spa_pod{enum_format};

        const flags = c.PW_STREAM_FLAG_AUTOCONNECT | c.PW_STREAM_FLAG_MAP_BUFFERS;
        if (c.pw_stream_connect(stream, c.PW_DIRECTION_INPUT, node_id, flags, @ptrCast(&params), params.len) < 0) {
            c.pw_stream_destroy(stream);
            _ = c.pw_core_disconnect(core);
            c.pw_thread_loop_unlock(loop);
            locked = false;
            allocator.destroy(self);
            return Error.StreamConnectFailed;
        }
        return self;
    }

    /// Blocks until the stream format is negotiated.
    pub fn waitFormat(self: *Capture, timeout_ns: u64) Error!Format {
        self.mutex.lock();
        defer self.mutex.unlock();
        var timer = std.time.Timer.start() catch unreachable;
        while (self.format == null and !self.stream_error) {
            const elapsed = timer.read();
            if (elapsed >= timeout_ns) return Error.FormatTimeout;
            self.cond.timedWait(&self.mutex, timeout_ns - elapsed) catch {};
        }
        if (self.stream_error) return Error.StreamConnectFailed;
        return self.format.?;
    }

    pub fn setCrop(self: *Capture, rect: encoder.Rect) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const size = @as(usize, rect.w) * rect.h * 4;
        self.latest = self.allocator.alloc(u8, size) catch return Error.OutOfMemory;
        @memset(self.latest, 0);
        self.crop = rect;
    }

    pub fn setPaused(self: *Capture, p: bool) void {
        self.paused.store(p, .release);
    }

    pub fn stop(self: *Capture) void {
        self.running.store(false, .release);
    }

    pub fn destroy(self: *Capture) void {
        c.pw_thread_loop_stop(self.loop);
        c.pw_stream_destroy(self.stream);
        _ = c.pw_core_disconnect(self.core);
        c.pw_context_destroy(self.context);
        c.pw_thread_loop_destroy(self.loop);
        if (self.latest.len > 0) self.allocator.free(self.latest);
        self.allocator.destroy(self);
    }

    fn copyFrame(self: *Capture, src: [*]const u8, src_len: usize, stride: u32) void {
        const crop = self.crop orelse return;
        const fmt = self.format orelse return;
        const row_bytes = @as(usize, crop.w) * 4;
        if (crop.x + crop.w > fmt.width or crop.y + crop.h > fmt.height) return;
        var row: u32 = 0;
        while (row < crop.h) : (row += 1) {
            const off = @as(usize, crop.y + row) * stride + @as(usize, crop.x) * 4;
            if (off + row_bytes > src_len) return;
            @memcpy(self.latest[@as(usize, row) * row_bytes ..][0..row_bytes], src[off..][0..row_bytes]);
        }
        self.has_frame = true;
    }
};

/// Writes the latest frame to `file` at the configured rate until stopped.
pub fn writerLoop(cap: *Capture, file: std.fs.File) void {
    const frame_ns: u64 = std.time.ns_per_s / cap.framerate;
    const scratch = cap.allocator.alloc(u8, cap.latest.len) catch {
        std.log.err("pipewire: out of memory for frame buffer", .{});
        return;
    };
    defer cap.allocator.free(scratch);

    var next_ns: i128 = std.time.nanoTimestamp();
    while (cap.running.load(.acquire)) {
        next_ns += frame_ns;
        const paused = cap.paused.load(.acquire);
        cap.mutex.lock();
        const ready = cap.has_frame;
        if (ready and !paused) @memcpy(scratch, cap.latest);
        cap.mutex.unlock();

        if (paused or !ready) {
            std.Thread.sleep(frame_ns);
            next_ns = std.time.nanoTimestamp();
            continue;
        }
        file.writeAll(scratch) catch |e| {
            std.log.err("pipewire: write to encoder failed: {t}", .{e});
            return;
        };
        const now = std.time.nanoTimestamp();
        if (now < next_ns) {
            std.Thread.sleep(@intCast(next_ns - now));
        } else {
            next_ns = now;
        }
    }
}

pub fn pixFmtName(spa_format: u32) ?[]const u8 {
    return switch (spa_format) {
        c.SPA_VIDEO_FORMAT_BGRx => "bgr0",
        c.SPA_VIDEO_FORMAT_BGRA => "bgra",
        c.SPA_VIDEO_FORMAT_RGBx => "rgb0",
        c.SPA_VIDEO_FORMAT_RGBA => "rgba",
        c.SPA_VIDEO_FORMAT_xRGB => "0rgb",
        c.SPA_VIDEO_FORMAT_xBGR => "0bgr",
        else => null,
    };
}

// --- stream callbacks (run on the PipeWire thread) ---

fn onStateChanged(data: ?*anyopaque, _: c.enum_pw_stream_state, state: c.enum_pw_stream_state, err: [*c]const u8) callconv(.c) void {
    const self: *Capture = @ptrCast(@alignCast(data));
    if (state == c.PW_STREAM_STATE_ERROR or state == c.PW_STREAM_STATE_UNCONNECTED) {
        if (err != null) std.log.err("pipewire stream: {s}", .{std.mem.span(err)});
        self.mutex.lock();
        self.stream_error = true;
        self.cond.broadcast();
        self.mutex.unlock();
    }
}

fn onParamChanged(data: ?*anyopaque, id: u32, param: [*c]const c.spa_pod) callconv(.c) void {
    const self: *Capture = @ptrCast(@alignCast(data));
    if (param == null or id != c.SPA_PARAM_Format) return;
    const fmt = parseVideoFormat(param) orelse {
        std.log.err("pipewire: could not parse negotiated format", .{});
        return;
    };

    self.mutex.lock();
    // Frame size can change mid-stream (window capture resize); keep the crop
    // but drop frames that no longer contain it (see copyFrame).
    self.format = fmt;
    self.cond.broadcast();
    self.mutex.unlock();

    var pod_buf: [256]u8 align(8) = undefined;
    var b = PodBuilder{ .buf = &pod_buf };
    const start = b.beginObject(c.SPA_TYPE_OBJECT_ParamBuffers, c.SPA_PARAM_Buffers);
    b.prop(c.SPA_PARAM_BUFFERS_dataType);
    b.int((1 << c.SPA_DATA_MemPtr) | (1 << c.SPA_DATA_MemFd));
    const buffers = b.endObject(start);
    var params = [_]?*const c.spa_pod{buffers};
    _ = c.pw_stream_update_params(self.stream, @ptrCast(&params), params.len);
}

fn onProcess(data: ?*anyopaque) callconv(.c) void {
    const self: *Capture = @ptrCast(@alignCast(data));
    // Drain to the newest buffer; older ones are stale.
    var newest: ?*c.pw_buffer = null;
    while (c.pw_stream_dequeue_buffer(self.stream)) |pb| {
        if (newest) |old| _ = c.pw_stream_queue_buffer(self.stream, old);
        newest = pb;
    }
    const pb = newest orelse return;
    defer _ = c.pw_stream_queue_buffer(self.stream, pb);

    const buf = pb.*.buffer;
    if (buf.*.n_datas < 1) return;
    const d = &buf.*.datas[0];
    if (d.data == null) return;
    const chunk = d.chunk;
    if (chunk.*.size == 0 or (chunk.*.flags & c.SPA_CHUNK_FLAG_CORRUPTED) != 0) return;

    self.mutex.lock();
    defer self.mutex.unlock();
    const fmt = self.format orelse return;
    const stride: u32 = if (chunk.*.stride > 0) @intCast(chunk.*.stride) else fmt.width * 4;
    const base: [*]const u8 = @ptrCast(d.data);
    const off: usize = chunk.*.offset;
    if (off >= d.maxsize) return;
    self.copyFrame(base + off, d.maxsize - off, stride);
}

// --- SPA pod building / parsing ---

const PodBuilder = struct {
    buf: []align(8) u8,
    len: usize = 0,

    fn putU32(self: *PodBuilder, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, .little);
        self.len += 4;
    }

    fn pad(self: *PodBuilder) void {
        while (self.len % 8 != 0) {
            self.buf[self.len] = 0;
            self.len += 1;
        }
    }

    fn header(self: *PodBuilder, size: u32, typ: u32) void {
        self.putU32(size);
        self.putU32(typ);
    }

    fn id(self: *PodBuilder, v: u32) void {
        self.header(4, c.SPA_TYPE_Id);
        self.putU32(v);
        self.pad();
    }

    fn int(self: *PodBuilder, v: u32) void {
        self.header(4, c.SPA_TYPE_Int);
        self.putU32(v);
        self.pad();
    }

    fn prop(self: *PodBuilder, key: u32) void {
        self.putU32(key);
        self.putU32(0);
    }

    fn choice(self: *PodBuilder, kind: u32, child_type: u32, child_size: u32, values: []const u32) void {
        const per = child_size / 4;
        const n: u32 = @intCast(values.len / per);
        self.header(16 + n * child_size, c.SPA_TYPE_Choice);
        self.putU32(kind);
        self.putU32(0);
        self.header(child_size, child_type);
        for (values) |v| self.putU32(v);
        self.pad();
    }

    fn beginObject(self: *PodBuilder, typ: u32, obj_id: u32) usize {
        const start = self.len;
        self.header(0, c.SPA_TYPE_Object);
        self.putU32(typ);
        self.putU32(obj_id);
        return start;
    }

    fn endObject(self: *PodBuilder, start: usize) *const c.spa_pod {
        const size: u32 = @intCast(self.len - start - 8);
        std.mem.writeInt(u32, self.buf[start..][0..4], size, .little);
        return @ptrCast(@alignCast(&self.buf[start]));
    }
};

fn buildEnumFormat(b: *PodBuilder, framerate: u32) *const c.spa_pod {
    const start = b.beginObject(c.SPA_TYPE_OBJECT_Format, c.SPA_PARAM_EnumFormat);
    b.prop(c.SPA_FORMAT_mediaType);
    b.id(c.SPA_MEDIA_TYPE_video);
    b.prop(c.SPA_FORMAT_mediaSubtype);
    b.id(c.SPA_MEDIA_SUBTYPE_raw);
    b.prop(c.SPA_FORMAT_VIDEO_format);
    b.choice(c.SPA_CHOICE_Enum, c.SPA_TYPE_Id, 4, &.{
        c.SPA_VIDEO_FORMAT_BGRx, // default
        c.SPA_VIDEO_FORMAT_BGRx,
        c.SPA_VIDEO_FORMAT_BGRA,
        c.SPA_VIDEO_FORMAT_RGBx,
        c.SPA_VIDEO_FORMAT_RGBA,
        c.SPA_VIDEO_FORMAT_xRGB,
        c.SPA_VIDEO_FORMAT_xBGR,
    });
    b.prop(c.SPA_FORMAT_VIDEO_size);
    b.choice(c.SPA_CHOICE_Range, c.SPA_TYPE_Rectangle, 8, &.{ 1920, 1080, 1, 1, 16384, 16384 });
    b.prop(c.SPA_FORMAT_VIDEO_framerate);
    b.choice(c.SPA_CHOICE_Range, c.SPA_TYPE_Fraction, 8, &.{ framerate, 1, 0, 1, 1000, 1 });
    return b.endObject(start);
}

fn readU32(p: [*]const u8, off: usize) u32 {
    return std.mem.readInt(u32, p[off..][0..4], .little);
}

/// Extracts format + size from a negotiated SPA_PARAM_Format object.
fn parseVideoFormat(pod: *const c.spa_pod) ?Format {
    const p: [*]const u8 = @ptrCast(pod);
    const size = readU32(p, 0);
    if (readU32(p, 4) != c.SPA_TYPE_Object) return null;
    const end: usize = 8 + size;

    var fmt = Format{ .width = 0, .height = 0, .spa_format = 0 };
    var off: usize = 16; // pod header + object type/id
    while (off + 16 <= end) {
        const key = readU32(p, off);
        var vsize = readU32(p, off + 8);
        var vtype = readU32(p, off + 12);
        var body: usize = off + 16;
        const next = body + std.mem.alignForward(usize, vsize, 8);

        // A fixed value may still be wrapped in a Choice; take its default.
        if (vtype == c.SPA_TYPE_Choice and vsize >= 16) {
            vsize = readU32(p, body + 8);
            vtype = readU32(p, body + 12);
            body += 16;
        }

        if (key == c.SPA_FORMAT_VIDEO_format and vtype == c.SPA_TYPE_Id and vsize >= 4) {
            fmt.spa_format = readU32(p, body);
        } else if (key == c.SPA_FORMAT_VIDEO_size and vtype == c.SPA_TYPE_Rectangle and vsize >= 8) {
            fmt.width = readU32(p, body);
            fmt.height = readU32(p, body + 4);
        }
        off = next;
    }
    if (fmt.width == 0 or fmt.height == 0) return null;
    return fmt;
}

test "enum format pod round-trips size and format via parser" {
    var buf: [1024]u8 align(8) = undefined;
    var b = PodBuilder{ .buf = &buf };
    const start = b.beginObject(c.SPA_TYPE_OBJECT_Format, c.SPA_PARAM_Format);
    b.prop(c.SPA_FORMAT_VIDEO_format);
    b.id(c.SPA_VIDEO_FORMAT_BGRx);
    b.prop(c.SPA_FORMAT_VIDEO_size);
    b.choice(c.SPA_CHOICE_None, c.SPA_TYPE_Rectangle, 8, &.{ 2560, 1440 });
    const pod = b.endObject(start);
    const f = parseVideoFormat(pod).?;
    try std.testing.expectEqual(@as(u32, 2560), f.width);
    try std.testing.expectEqual(@as(u32, 1440), f.height);
    try std.testing.expectEqual(@as(u32, c.SPA_VIDEO_FORMAT_BGRx), f.spa_format);
}
