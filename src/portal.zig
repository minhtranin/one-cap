//! xdg-desktop-portal ScreenCast client over GDBus. Negotiates a session and
//! hands back a PipeWire remote fd + stream node id.
//!
//! The portal's restore_token (persist_mode=2) is saved under
//! $XDG_CONFIG_HOME/one-cap/ so the share dialog only appears on first use.

const std = @import("std");

const c = @cImport({
    @cInclude("gio/gio.h");
    @cInclude("gio/gunixfdlist.h");
});

const bus_name = "org.freedesktop.portal.Desktop";
const object_path = "/org/freedesktop/portal/desktop";
const screencast_iface = "org.freedesktop.portal.ScreenCast";

const source_monitor: u32 = 1;
const source_window: u32 = 2;
const cursor_embedded: u32 = 2;
const persist_until_revoked: u32 = 2;

pub const Error = error{
    BusConnectFailed,
    PortalCallFailed,
    PortalCancelled,
    PortalNoStreams,
    PipeWireRemoteFailed,
    OutOfMemory,
};

pub const Stream = struct {
    node_id: u32,
    /// Logical position/size of the captured monitor. Absent for windows.
    position: ?[2]i32 = null,
    size: ?[2]i32 = null,
};

pub const Session = struct {
    conn: *c.GDBusConnection,
    handle: [:0]u8,
    pw_fd: c_int,
    stream: Stream,
    allocator: std.mem.Allocator,

    pub fn close(self: *Session) void {
        var err: ?*c.GError = null;
        const ret = c.g_dbus_connection_call_sync(
            self.conn,
            bus_name,
            self.handle.ptr,
            "org.freedesktop.portal.Session",
            "Close",
            null,
            null,
            c.G_DBUS_CALL_FLAGS_NONE,
            1000,
            null,
            &err,
        );
        if (ret) |r| c.g_variant_unref(r);
        if (err) |e| c.g_error_free(e);
        self.allocator.free(self.handle);
        c.g_object_unref(self.conn);
    }
};

pub const Options = struct {
    /// Only offer monitors (needed when cropping to a drawn area).
    monitor_only: bool = false,
};

/// Runs CreateSession → SelectSources → Start → OpenPipeWireRemote.
/// Blocks until the user answers the portal dialog (if one is shown).
/// Must be called from a thread without a GLib main loop of its own.
pub fn open(allocator: std.mem.Allocator, opts: Options) Error!Session {
    const ctx = c.g_main_context_new() orelse return Error.OutOfMemory;
    c.g_main_context_push_thread_default(ctx);
    defer {
        c.g_main_context_pop_thread_default(ctx);
        c.g_main_context_unref(ctx);
    }

    var err: ?*c.GError = null;
    const conn = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &err) orelse {
        logGError("session bus", err);
        return Error.BusConnectFailed;
    };
    errdefer c.g_object_unref(conn);
    registerAppId(conn);

    var p = Portal{ .allocator = allocator, .conn = conn, .ctx = ctx };
    try p.initSender();

    var session_token_buf: [32]u8 = undefined;
    const session_token = randomToken(&session_token_buf, "onecap_s");

    // CreateSession
    {
        const opts_v = dict(&.{
            .{ "session_handle_token", c.g_variant_new_string(session_token.ptr) },
        });
        const res = try p.request("CreateSession", null, opts_v);
        defer c.g_variant_unref(res);
        const handle_v = c.g_variant_lookup_value(res, "session_handle", null) orelse return Error.PortalCallFailed;
        defer c.g_variant_unref(handle_v);
        const handle = std.mem.span(c.g_variant_get_string(handle_v, null));
        p.session = allocator.dupeZ(u8, handle) catch return Error.OutOfMemory;
    }
    errdefer allocator.free(p.session.?);

    const token_path = restoreTokenPath(allocator) catch null;
    defer if (token_path) |tp| allocator.free(tp);
    const saved_token = if (token_path) |tp| readToken(allocator, tp) else null;
    defer if (saved_token) |t| allocator.free(t);

    // SelectSources
    {
        const types: u32 = if (opts.monitor_only) source_monitor else source_monitor | source_window;
        var entries: [5]DictEntry = undefined;
        var n: usize = 0;
        entries[n] = .{ "types", c.g_variant_new_uint32(types) };
        n += 1;
        entries[n] = .{ "multiple", c.g_variant_new_boolean(0) };
        n += 1;
        entries[n] = .{ "cursor_mode", c.g_variant_new_uint32(cursor_embedded) };
        n += 1;
        entries[n] = .{ "persist_mode", c.g_variant_new_uint32(persist_until_revoked) };
        n += 1;
        if (saved_token) |t| {
            entries[n] = .{ "restore_token", c.g_variant_new_string(t.ptr) };
            n += 1;
        }
        const res = try p.request("SelectSources", c.g_variant_new_object_path(p.session.?.ptr), dict(entries[0..n]));
        c.g_variant_unref(res);
    }

    // Start
    var stream: Stream = undefined;
    {
        const res = try p.requestWithParent("Start", c.g_variant_new_object_path(p.session.?.ptr), dict(&.{}));
        defer c.g_variant_unref(res);

        if (c.g_variant_lookup_value(res, "restore_token", c.G_VARIANT_TYPE("s"))) |tv| {
            defer c.g_variant_unref(tv);
            if (token_path) |tp| writeToken(tp, std.mem.span(c.g_variant_get_string(tv, null)));
        }

        const streams = c.g_variant_lookup_value(res, "streams", null) orelse return Error.PortalNoStreams;
        defer c.g_variant_unref(streams);
        if (c.g_variant_n_children(streams) == 0) return Error.PortalNoStreams;
        const first = c.g_variant_get_child_value(streams, 0);
        defer c.g_variant_unref(first);
        const node_v = c.g_variant_get_child_value(first, 0);
        defer c.g_variant_unref(node_v);
        const props = c.g_variant_get_child_value(first, 1);
        defer c.g_variant_unref(props);

        stream = .{ .node_id = c.g_variant_get_uint32(node_v) };
        stream.position = lookupPair(props, "position");
        stream.size = lookupPair(props, "size");
    }

    const fd = try p.openPipeWireRemote();

    return .{
        .conn = conn,
        .handle = p.session.?,
        .pw_fd = fd,
        .stream = stream,
        .allocator = allocator,
    };
}

var app_id_registered = false;

/// Host apps get their portal app id from the launcher's systemd scope, so a
/// hotkey launch and a terminal launch look like different apps and the
/// restore token is rejected. Registering a fixed id keeps it stable.
/// Must precede any other portal call on the connection.
fn registerAppId(conn: *c.GDBusConnection) void {
    if (app_id_registered) return;
    app_id_registered = true;
    var args = [_]*c.GVariant{ c.g_variant_new_string("one-cap").?, dict(&.{}) };
    var err: ?*c.GError = null;
    const ret = c.g_dbus_connection_call_sync(
        conn,
        bus_name,
        object_path,
        "org.freedesktop.host.portal.Registry",
        "Register",
        c.g_variant_new_tuple(@ptrCast(&args), args.len),
        null,
        c.G_DBUS_CALL_FLAGS_NONE,
        1000,
        null,
        &err,
    );
    if (ret) |r| c.g_variant_unref(r);
    if (err) |e| {
        std.log.warn("portal app id registration skipped: {s}", .{std.mem.span(e.message)});
        c.g_error_free(e);
    }
}

const DictEntry = struct { [*:0]const u8, ?*c.GVariant };

fn dict(entries: []const DictEntry) *c.GVariant {
    const b = c.g_variant_builder_new(c.G_VARIANT_TYPE("a{sv}"));
    defer c.g_variant_builder_unref(b);
    for (entries) |e| c.g_variant_builder_add_value(b, c.g_variant_new_dict_entry(
        c.g_variant_new_string(e[0]),
        c.g_variant_new_variant(e[1]),
    ));
    return c.g_variant_builder_end(b).?;
}

fn lookupPair(props: ?*c.GVariant, key: [*:0]const u8) ?[2]i32 {
    const v = c.g_variant_lookup_value(props, key, null) orelse return null;
    defer c.g_variant_unref(v);
    if (c.g_variant_n_children(v) != 2) return null;
    const a = c.g_variant_get_child_value(v, 0);
    defer c.g_variant_unref(a);
    const b = c.g_variant_get_child_value(v, 1);
    defer c.g_variant_unref(b);
    return .{ c.g_variant_get_int32(a), c.g_variant_get_int32(b) };
}

const Portal = struct {
    allocator: std.mem.Allocator,
    conn: *c.GDBusConnection,
    ctx: *c.GMainContext,
    sender: [64]u8 = undefined,
    sender_len: usize = 0,
    session: ?[:0]u8 = null,

    fn initSender(self: *Portal) Error!void {
        // ":1.234" → "1_234", as used in portal request object paths.
        const unique = std.mem.span(c.g_dbus_connection_get_unique_name(self.conn) orelse return Error.BusConnectFailed);
        const trimmed = if (unique.len > 0 and unique[0] == ':') unique[1..] else unique;
        if (trimmed.len > self.sender.len) return Error.BusConnectFailed;
        for (trimmed, 0..) |ch, i| self.sender[i] = if (ch == '.') '_' else ch;
        self.sender_len = trimmed.len;
    }

    fn request(self: *Portal, method: [*:0]const u8, first: ?*c.GVariant, options: *c.GVariant) Error!*c.GVariant {
        return self.call(method, first, null, options);
    }

    /// Start takes (o session, s parent_window, a{sv} options).
    fn requestWithParent(self: *Portal, method: [*:0]const u8, first: ?*c.GVariant, options: *c.GVariant) Error!*c.GVariant {
        return self.call(method, first, c.g_variant_new_string(""), options);
    }

    /// Issues a portal method that answers via a Request.Response signal and
    /// waits for it. Returns the results dict (caller unrefs).
    fn call(self: *Portal, method: [*:0]const u8, first: ?*c.GVariant, second: ?*c.GVariant, options_in: *c.GVariant) Error!*c.GVariant {
        var token_buf: [32]u8 = undefined;
        const token = randomToken(&token_buf, "onecap_r");

        // handle_token goes into the options dict; rebuild it with the token.
        const b = c.g_variant_builder_new(c.G_VARIANT_TYPE("a{sv}"));
        c.g_variant_builder_add_value(b, c.g_variant_new_dict_entry(
            c.g_variant_new_string("handle_token"),
            c.g_variant_new_variant(c.g_variant_new_string(token.ptr)),
        ));
        var iter: c.GVariantIter = undefined;
        _ = c.g_variant_iter_init(&iter, options_in);
        while (c.g_variant_iter_next_value(&iter)) |entry| {
            c.g_variant_builder_add_value(b, entry);
            c.g_variant_unref(entry);
        }
        const options = c.g_variant_builder_end(b);
        c.g_variant_builder_unref(b);
        c.g_variant_unref(c.g_variant_ref_sink(options_in));

        var path_buf: [192]u8 = undefined;
        const req_path = std.fmt.bufPrintZ(&path_buf, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{
            self.sender[0..self.sender_len], token,
        }) catch return Error.PortalCallFailed;

        var waiter = Waiter{};
        // Subscribe before calling so a fast Response can't be missed.
        const sub = c.g_dbus_connection_signal_subscribe(
            self.conn,
            bus_name,
            "org.freedesktop.portal.Request",
            "Response",
            req_path.ptr,
            null,
            c.G_DBUS_SIGNAL_FLAGS_NONE,
            onResponse,
            &waiter,
            null,
        );
        defer c.g_dbus_connection_signal_unsubscribe(self.conn, sub);

        var args: [3]*c.GVariant = undefined;
        var n: usize = 0;
        if (first) |f| {
            args[n] = f;
            n += 1;
        }
        if (second) |s| {
            args[n] = s;
            n += 1;
        }
        args[n] = options.?;
        n += 1;

        var err: ?*c.GError = null;
        const ret = c.g_dbus_connection_call_sync(
            self.conn,
            bus_name,
            object_path,
            screencast_iface,
            method,
            c.g_variant_new_tuple(@ptrCast(&args), n),
            c.G_VARIANT_TYPE("(o)"),
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            &err,
        ) orelse {
            logGError(std.mem.span(method), err);
            return Error.PortalCallFailed;
        };
        c.g_variant_unref(ret);

        while (!waiter.done) _ = c.g_main_context_iteration(self.ctx, 1);

        if (waiter.code != 0) {
            c.g_variant_unref(waiter.results.?);
            std.log.warn("portal {s}: response code {d}", .{ std.mem.span(method), waiter.code });
            return if (waiter.code == 1) Error.PortalCancelled else Error.PortalCallFailed;
        }
        return waiter.results.?;
    }

    fn openPipeWireRemote(self: *Portal) Error!c_int {
        var out_fds: ?*c.GUnixFDList = null;
        var err: ?*c.GError = null;
        var args = [_]*c.GVariant{
            c.g_variant_new_object_path(self.session.?.ptr).?,
            dict(&.{}),
        };
        const ret = c.g_dbus_connection_call_with_unix_fd_list_sync(
            self.conn,
            bus_name,
            object_path,
            screencast_iface,
            "OpenPipeWireRemote",
            c.g_variant_new_tuple(@ptrCast(&args), args.len),
            c.G_VARIANT_TYPE("(h)"),
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            &out_fds,
            null,
            &err,
        ) orelse {
            logGError("OpenPipeWireRemote", err);
            return Error.PipeWireRemoteFailed;
        };
        defer c.g_variant_unref(ret);
        const fds = out_fds orelse return Error.PipeWireRemoteFailed;
        defer c.g_object_unref(fds);

        const hv = c.g_variant_get_child_value(ret, 0);
        defer c.g_variant_unref(hv);
        const fd = c.g_unix_fd_list_get(fds, c.g_variant_get_handle(hv), &err);
        if (fd < 0) {
            logGError("g_unix_fd_list_get", err);
            return Error.PipeWireRemoteFailed;
        }
        return fd;
    }
};

const Waiter = struct {
    done: bool = false,
    code: u32 = 2,
    results: ?*c.GVariant = null,
};

fn onResponse(
    _: ?*c.GDBusConnection,
    _: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
    params: ?*c.GVariant,
    user: c.gpointer,
) callconv(.c) void {
    const w: *Waiter = @ptrCast(@alignCast(user));
    if (w.done) return;
    const code_v = c.g_variant_get_child_value(params, 0);
    w.code = c.g_variant_get_uint32(code_v);
    c.g_variant_unref(code_v);
    w.results = c.g_variant_get_child_value(params, 1);
    w.done = true;
}

fn randomToken(buf: *[32]u8, prefix: []const u8) [:0]const u8 {
    var bytes: [6]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.bufPrintZ(buf, "{s}_{s}", .{ prefix, hex }) catch unreachable;
}

fn logGError(what: []const u8, err: ?*c.GError) void {
    if (err) |e| {
        std.log.err("portal {s}: {s}", .{ what, std.mem.span(e.message) });
        c.g_error_free(e);
    } else {
        std.log.err("portal {s} failed", .{what});
    }
}

fn restoreTokenPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |cfg| {
        if (cfg.len > 0) return std.fmt.allocPrint(allocator, "{s}/one-cap/portal-restore-token", .{cfg});
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/one-cap/portal-restore-token", .{home});
}

fn readToken(allocator: std.mem.Allocator, path: []const u8) ?[:0]u8 {
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 256) catch return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupeZ(u8, trimmed) catch null;
}

fn writeToken(path: []const u8, token: []const u8) void {
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    const f = std.fs.cwd().createFile(path, .{ .mode = 0o600 }) catch return;
    defer f.close();
    f.writeAll(token) catch {};
}
