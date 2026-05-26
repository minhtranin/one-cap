//! Wayland wlr-screencopy v3 capture loop (pure Zig + libwayland-client).
//! Captures frames from the first wl_output into shm buffers and pushes raw
//! pixel bytes to a writer (typically ffmpeg's stdin).
//!
//! The frame rate is enforced by a sleep between captures. wlr-screencopy is
//! pull-based: client requests a frame, compositor delivers one. No "stream".

const std = @import("std");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-client-protocol.h");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("string.h");
    @cInclude("wlr-screencopy-client-protocol.h");
});

// memfd_create lives behind _GNU_SOURCE in libc and is not exposed by Zig's
// translate-c default. Declare it explicitly.
extern "c" fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;

pub const Error = error{
    DisplayConnectFailed,
    NoCompositorGlobals,
    NoOutput,
    NoShm,
    NoScreencopyManager,
    FrameCaptureFailed,
    BufferAllocFailed,
    MmapFailed,
    WriteFailed,
    Terminated,
};

pub const Frame = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: u32, // wl_shm format enum (matches drm fourcc)
};

const State = struct {
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    shm: ?*c.wl_shm = null,
    output: ?*c.wl_output = null,
    manager: ?*c.zwlr_screencopy_manager_v1 = null,

    // Frame-in-flight state, reset per capture
    frame: ?*c.zwlr_screencopy_frame_v1 = null,
    got_buffer: bool = false,
    got_ready: bool = false,
    failed: bool = false,
    info: Frame = .{ .width = 0, .height = 0, .stride = 0, .format = 0 },

    // Reusable buffer
    shm_fd: c_int = -1,
    shm_size: usize = 0,
    shm_ptr: ?[*]u8 = null,
    wl_pool: ?*c.wl_shm_pool = null,
    wl_buffer: ?*c.wl_buffer = null,
};

pub const Capture = struct {
    allocator: std.mem.Allocator,
    state: State,
    running: std.atomic.Value(bool),
    paused: std.atomic.Value(bool),
    show_cursor: std.atomic.Value(bool),
    framerate: u32,

    pub fn init(allocator: std.mem.Allocator, framerate: u32) Error!Capture {
        var s = State{};

        s.display = c.wl_display_connect(null) orelse return Error.DisplayConnectFailed;
        s.registry = c.wl_display_get_registry(s.display) orelse return Error.NoCompositorGlobals;

        const listener = c.wl_registry_listener{
            .global = onGlobal,
            .global_remove = onGlobalRemove,
        };
        _ = c.wl_registry_add_listener(s.registry, &listener, &s);

        _ = c.wl_display_roundtrip(s.display);

        if (s.shm == null) return Error.NoShm;
        if (s.output == null) return Error.NoOutput;
        if (s.manager == null) return Error.NoScreencopyManager;

        return .{
            .allocator = allocator,
            .state = s,
            .running = std.atomic.Value(bool).init(true),
            .paused = std.atomic.Value(bool).init(false),
            .show_cursor = std.atomic.Value(bool).init(true),
            .framerate = framerate,
        };
    }

    pub fn setShowCursor(self: *Capture, v: bool) void {
        self.show_cursor.store(v, .release);
    }

    pub fn deinit(self: *Capture) void {
        self.releaseBuffer();
        if (self.state.manager) |m| c.zwlr_screencopy_manager_v1_destroy(m);
        if (self.state.output) |o| c.wl_output_destroy(o);
        if (self.state.shm) |sh| c.wl_shm_destroy(sh);
        if (self.state.registry) |r| c.wl_registry_destroy(r);
        if (self.state.display) |d| c.wl_display_disconnect(d);
    }

    pub fn stop(self: *Capture) void {
        self.running.store(false, .release);
    }

    pub fn setPaused(self: *Capture, p: bool) void {
        self.paused.store(p, .release);
    }

    pub fn isRunning(self: *Capture) bool {
        return self.running.load(.acquire);
    }

    pub fn isPaused(self: *Capture) bool {
        return self.paused.load(.acquire);
    }

    pub fn firstFrameInfo(self: *Capture) Error!Frame {
        // Request one frame just to discover dims/format. Don't consume it for output.
        try self.captureOne();
        return self.state.info;
    }

    /// Captures one frame and writes raw bytes (height * stride) to writer.
    pub fn captureFrame(self: *Capture, file: std.fs.File) Error!void {
        try self.captureOne();
        const total = @as(usize, self.state.info.stride) * @as(usize, self.state.info.height);
        const slice = self.state.shm_ptr.?[0..total];
        file.writeAll(slice) catch return Error.WriteFailed;
    }

    fn captureOne(self: *Capture) Error!void {
        const s = &self.state;
        s.got_buffer = false;
        s.got_ready = false;
        s.failed = false;

        const cursor: i32 = if (self.show_cursor.load(.acquire)) 1 else 0;
        const frame_obj = c.zwlr_screencopy_manager_v1_capture_output(
            s.manager,
            cursor,
            s.output,
        ) orelse return Error.FrameCaptureFailed;
        s.frame = frame_obj;

        const frame_listener = c.zwlr_screencopy_frame_v1_listener{
            .buffer = onFrameBuffer,
            .flags = onFrameFlags,
            .ready = onFrameReady,
            .failed = onFrameFailed,
            .damage = onFrameDamage,
            .linux_dmabuf = onFrameLinuxDmabuf,
            .buffer_done = onFrameBufferDone,
        };
        _ = c.zwlr_screencopy_frame_v1_add_listener(frame_obj, &frame_listener, s);

        // Wait until we know the buffer params + buffer_done
        while (!s.got_buffer and !s.failed) {
            if (c.wl_display_dispatch(s.display) < 0) {
                s.failed = true;
                break;
            }
        }
        if (s.failed) return Error.FrameCaptureFailed;

        // Allocate / resize buffer if needed
        try self.ensureBuffer();

        c.zwlr_screencopy_frame_v1_copy(frame_obj, s.wl_buffer);

        while (!s.got_ready and !s.failed) {
            if (c.wl_display_dispatch(s.display) < 0) {
                s.failed = true;
                break;
            }
        }

        c.zwlr_screencopy_frame_v1_destroy(frame_obj);
        s.frame = null;

        if (s.failed) return Error.FrameCaptureFailed;
    }

    fn ensureBuffer(self: *Capture) Error!void {
        const s = &self.state;
        const total = @as(usize, s.info.stride) * @as(usize, s.info.height);
        if (s.shm_ptr != null and s.shm_size == total) return;

        self.releaseBuffer();

        const fd = memfd_create("one-cap-screencopy", 0);
        if (fd < 0) return Error.BufferAllocFailed;
        if (c.ftruncate(fd, @intCast(total)) < 0) {
            _ = c.close(fd);
            return Error.BufferAllocFailed;
        }
        const ptr = c.mmap(null, total, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (ptr == c.MAP_FAILED) {
            _ = c.close(fd);
            return Error.MmapFailed;
        }
        const pool = c.wl_shm_create_pool(s.shm, fd, @intCast(total)) orelse {
            _ = c.munmap(ptr, total);
            _ = c.close(fd);
            return Error.BufferAllocFailed;
        };
        const buf = c.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(s.info.width),
            @intCast(s.info.height),
            @intCast(s.info.stride),
            s.info.format,
        ) orelse {
            c.wl_shm_pool_destroy(pool);
            _ = c.munmap(ptr, total);
            _ = c.close(fd);
            return Error.BufferAllocFailed;
        };

        s.shm_fd = fd;
        s.shm_size = total;
        s.shm_ptr = @ptrCast(ptr);
        s.wl_pool = pool;
        s.wl_buffer = buf;
    }

    fn releaseBuffer(self: *Capture) void {
        const s = &self.state;
        if (s.wl_buffer) |b| c.wl_buffer_destroy(b);
        if (s.wl_pool) |p| c.wl_shm_pool_destroy(p);
        if (s.shm_ptr != null and s.shm_size > 0) {
            _ = c.munmap(@ptrCast(s.shm_ptr), s.shm_size);
        }
        if (s.shm_fd >= 0) _ = c.close(s.shm_fd);
        s.wl_buffer = null;
        s.wl_pool = null;
        s.shm_ptr = null;
        s.shm_size = 0;
        s.shm_fd = -1;
    }
};

// --- registry handlers ---

fn onGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.C) void {
    const s: *State = @ptrCast(@alignCast(data));
    const iface = std.mem.span(interface);

    if (std.mem.eql(u8, iface, "wl_shm")) {
        s.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, iface, "wl_output") and s.output == null) {
        // Pick the first output.
        const ver = if (version < 4) version else 4;
        s.output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, ver));
    } else if (std.mem.eql(u8, iface, "zwlr_screencopy_manager_v1")) {
        const ver = if (version < 3) version else 3;
        s.manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_screencopy_manager_v1_interface, ver));
    }
}

fn onGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.C) void {}

// --- frame handlers ---

fn onFrameBuffer(
    data: ?*anyopaque,
    _: ?*c.zwlr_screencopy_frame_v1,
    format: u32,
    width: u32,
    height: u32,
    stride: u32,
) callconv(.C) void {
    const s: *State = @ptrCast(@alignCast(data));
    s.info = .{ .width = width, .height = height, .stride = stride, .format = format };
}

fn onFrameBufferDone(
    data: ?*anyopaque,
    _: ?*c.zwlr_screencopy_frame_v1,
) callconv(.C) void {
    const s: *State = @ptrCast(@alignCast(data));
    s.got_buffer = true;
}

fn onFrameLinuxDmabuf(
    _: ?*anyopaque,
    _: ?*c.zwlr_screencopy_frame_v1,
    _: u32,
    _: u32,
    _: u32,
) callconv(.C) void {}

fn onFrameDamage(
    _: ?*anyopaque,
    _: ?*c.zwlr_screencopy_frame_v1,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
) callconv(.C) void {}

fn onFrameFlags(
    _: ?*anyopaque,
    _: ?*c.zwlr_screencopy_frame_v1,
    _: u32,
) callconv(.C) void {}

fn onFrameReady(
    data: ?*anyopaque,
    _: ?*c.zwlr_screencopy_frame_v1,
    _: u32,
    _: u32,
    _: u32,
) callconv(.C) void {
    const s: *State = @ptrCast(@alignCast(data));
    s.got_ready = true;
}

fn onFrameFailed(
    data: ?*anyopaque,
    _: ?*c.zwlr_screencopy_frame_v1,
) callconv(.C) void {
    const s: *State = @ptrCast(@alignCast(data));
    s.failed = true;
}

/// Maps a wl_shm/drm format to ffmpeg pix_fmt name. Most wlroots compositors
/// deliver XRGB8888 / ARGB8888.
pub fn pixFmtName(format: u32) []const u8 {
    return switch (format) {
        c.WL_SHM_FORMAT_XRGB8888 => "bgr0",
        c.WL_SHM_FORMAT_ARGB8888 => "bgra",
        c.WL_SHM_FORMAT_XBGR8888 => "rgb0",
        c.WL_SHM_FORMAT_ABGR8888 => "rgba",
        else => "bgr0",
    };
}

/// Capture loop: blocks, calling captureFrame at framerate. Stops when running=false.
pub fn captureLoop(cap: *Capture, file: std.fs.File) void {
    const frame_ns: u64 = @as(u64, std.time.ns_per_s) / cap.framerate;
    var next_ns: i128 = std.time.nanoTimestamp();
    while (cap.isRunning()) {
        next_ns += @intCast(frame_ns);
        if (cap.isPaused()) {
            std.time.sleep(@intCast(@max(frame_ns, 16_000_000)));
            next_ns = std.time.nanoTimestamp();
            continue;
        }
        cap.captureFrame(file) catch |e| {
            std.log.err("screencopy capture error: {}", .{e});
            break;
        };
        const now = std.time.nanoTimestamp();
        if (now < next_ns) {
            std.time.sleep(@intCast(next_ns - now));
        } else {
            next_ns = now;
        }
    }
}
