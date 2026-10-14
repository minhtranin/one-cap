//! Tiny floating GTK3 control window. Shows live recording timer + Pause /
//! Stop / Mic / Cursor buttons. Counter freezes while paused (cumulative
//! paused time is subtracted).
//! Owns the GTK main loop on the calling thread (must be the OS main thread).
//! All callbacks toggle atomic flags on the shared State, which the recorder
//! controller thread polls/observes.

const std = @import("std");

const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("glib-unix.h");
});

const encoder = @import("encoder.zig");


pub const State = struct {
    /// Set true after the user clicks Play for the first time. Capture pipelines
    /// (screen + audio + mic) are only initialized on this transition, so a
    /// Stop-without-Play exits cleanly without spawning ffmpeg / PulseAudio.
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mic_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cursor_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    /// Playback-speed multiplier ×100 (100 = 1×, 125 = 1.25×, 150 = 1.5×, 200 = 2×).
    /// Read once at finalize/mux time; not applied during capture.
    speed_x100: std.atomic.Value(u32) = std.atomic.Value(u32).init(100),

    // Counter math. Recorder sets recording_start_ns once on launch. UI thread
    // owns pause_started_ns + total_paused_ns under the GTK main loop.
    recording_start_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    pause_started_ns: i64 = 0,
    total_paused_ns: i64 = 0,

    // 0 = open-ended.
    duration_seconds: u32 = 0,

    /// Cursor capture can only be toggled live on backends that support it.
    cursor_toggle: bool = true,

    pub fn requestStop(self: *State) void {
        self.stop_requested.store(true, .release);
    }

    pub fn togglePause(self: *State) bool {
        const was = self.paused.load(.acquire);
        self.paused.store(!was, .release);
        return !was;
    }

    pub fn isPaused(self: *State) bool {
        return self.paused.load(.acquire);
    }

    pub fn isStarted(self: *State) bool {
        return self.started.load(.acquire);
    }

    pub fn markStarted(self: *State) void {
        self.started.store(true, .release);
    }

    pub fn toggleMic(self: *State) bool {
        const was = self.mic_enabled.load(.acquire);
        self.mic_enabled.store(!was, .release);
        return !was;
    }

    pub fn isMicEnabled(self: *State) bool {
        return self.mic_enabled.load(.acquire);
    }

    pub fn toggleCursor(self: *State) bool {
        const was = self.cursor_enabled.load(.acquire);
        self.cursor_enabled.store(!was, .release);
        return !was;
    }

    pub fn isCursorEnabled(self: *State) bool {
        return self.cursor_enabled.load(.acquire);
    }

    pub fn setSpeedX100(self: *State, v: u32) void {
        self.speed_x100.store(v, .release);
    }

    pub fn speedX100(self: *State) u32 {
        return self.speed_x100.load(.acquire);
    }
};

const Widgets = struct {
    window: *c.GtkWidget,
    status: *c.GtkWidget,
    pause_btn: *c.GtkWidget,
    mic_btn: *c.GtkWidget,
    cursor_btn: *c.GtkWidget,
    state: *State,
};

var widgets_global: ?*Widgets = null;

var signals_installed = false;

fn initGtk() !void {
    c.g_set_prgname("one-cap");
    if (c.gtk_init_check(null, null) == 0) return error.GtkInitFailed;
    c.gdk_set_program_class("one-cap");
    if (!signals_installed) {
        signals_installed = true;
        _ = c.g_unix_signal_add(std.posix.SIG.TERM, @ptrCast(&onStopSignal), null);
        _ = c.g_unix_signal_add(std.posix.SIG.INT, @ptrCast(&onStopSignal), null);
    }
}

/// SIGTERM/SIGINT (e.g. a toggle hotkey running `pkill onecap`): cancel the
/// area picker, or stop and save like the Stop button.
fn onStopSignal(_: c.gpointer) callconv(.c) c.gboolean {
    if (overlay_active) {
        finishOverlay(.cancelled);
    } else {
        if (widgets_global) |w| w.state.requestStop();
        c.gtk_main_quit();
    }
    return 1;
}

pub fn run(state: *State) !void {
    try initGtk();

    const css =
        \\button { padding: 2px 6px; min-height: 0px; min-width: 0px; font-size: 14px; }
        \\combobox button { padding: 2px 4px; }
        \\label { font-size: 13px; }
    ;
    const provider = c.gtk_css_provider_new();
    _ = c.gtk_css_provider_load_from_data(provider, css, css.len, null);
    c.gtk_style_context_add_provider_for_screen(
        c.gdk_screen_get_default(),
        @ptrCast(provider),
        c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    const win = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL) orelse return error.WindowCreateFailed;
    c.gtk_window_set_title(@ptrCast(win), "one-cap");
    c.gtk_window_set_default_size(@ptrCast(win), 1, 1);
    c.gtk_window_set_keep_above(@ptrCast(win), 1);
    c.gtk_window_set_resizable(@ptrCast(win), 0);
    c.gtk_window_set_decorated(@ptrCast(win), 0);
    c.gtk_window_set_skip_taskbar_hint(@ptrCast(win), 1);
    c.gtk_window_set_role(@ptrCast(win), "one-cap-control");
    c.gtk_window_set_gravity(@ptrCast(win), c.GDK_GRAVITY_NORTH_EAST);
    c.gtk_window_move(@ptrCast(win), 10, 10);

    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    c.gtk_widget_set_margin_top(box, 3);
    c.gtk_widget_set_margin_bottom(box, 3);
    c.gtk_widget_set_margin_start(box, 8);
    c.gtk_widget_set_margin_end(box, 4);
    c.gtk_container_add(@ptrCast(win), box);

    const drag_area = c.gtk_event_box_new();
    c.gtk_widget_add_events(drag_area, c.GDK_BUTTON_PRESS_MASK);
    c.gtk_box_pack_start(@ptrCast(box), drag_area, 1, 1, 0);
    _ = c.g_signal_connect_data(drag_area, "button-press-event", @ptrCast(&onDragPress), win, null, 0);

    const drag_inner = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    c.gtk_container_add(@ptrCast(drag_area), drag_inner);

    const status = c.gtk_label_new(null);
    c.gtk_label_set_xalign(@ptrCast(status), 0.0);
    c.gtk_box_pack_start(@ptrCast(drag_inner), status, 1, 1, 0);

    const cursor_btn = c.gtk_button_new_with_label("🖱");
    const mic_btn = c.gtk_button_new_with_label("🔇");
    const pause_btn = c.gtk_button_new_with_label("⏸");
    const stop_btn = c.gtk_button_new_with_label("⏹");
    c.gtk_widget_set_size_request(cursor_btn, 32, 28);
    c.gtk_widget_set_size_request(mic_btn, 32, 28);
    c.gtk_widget_set_size_request(pause_btn, 32, 28);
    c.gtk_widget_set_size_request(stop_btn, 32, 28);
    c.gtk_widget_set_tooltip_text(cursor_btn, "Toggle cursor capture");
    c.gtk_widget_set_tooltip_text(mic_btn, "Toggle microphone");
    c.gtk_widget_set_tooltip_text(pause_btn, "Pause / Resume");
    c.gtk_widget_set_tooltip_text(stop_btn, "Stop and close");

    const speed_combo = c.gtk_combo_box_text_new();
    c.gtk_combo_box_text_append_text(@ptrCast(speed_combo), "1×");
    c.gtk_combo_box_text_append_text(@ptrCast(speed_combo), "1.25×");
    c.gtk_combo_box_text_append_text(@ptrCast(speed_combo), "1.5×");
    c.gtk_combo_box_text_append_text(@ptrCast(speed_combo), "2×");
    c.gtk_combo_box_set_active(@ptrCast(speed_combo), 0);
    c.gtk_widget_set_size_request(speed_combo, 56, 28);
    c.gtk_widget_set_tooltip_text(speed_combo, "Playback speed (applied on Stop)");

    c.gtk_box_pack_start(@ptrCast(box), cursor_btn, 0, 0, 0);
    c.gtk_box_pack_start(@ptrCast(box), speed_combo, 0, 0, 0);
    c.gtk_box_pack_start(@ptrCast(box), mic_btn, 0, 0, 0);
    c.gtk_box_pack_start(@ptrCast(box), pause_btn, 0, 0, 0);
    c.gtk_box_pack_start(@ptrCast(box), stop_btn, 0, 0, 0);

    var widgets = Widgets{
        .window = win,
        .status = status,
        .pause_btn = pause_btn,
        .mic_btn = mic_btn,
        .cursor_btn = cursor_btn,
        .state = state,
    };
    widgets_global = &widgets;

    _ = c.g_signal_connect_data(cursor_btn, "clicked", @ptrCast(&onCursorClicked), null, null, 0);
    _ = c.g_signal_connect_data(mic_btn, "clicked", @ptrCast(&onMicClicked), null, null, 0);
    _ = c.g_signal_connect_data(pause_btn, "clicked", @ptrCast(&onPauseClicked), null, null, 0);
    _ = c.g_signal_connect_data(stop_btn, "clicked", @ptrCast(&onStopClicked), null, null, 0);
    _ = c.g_signal_connect_data(speed_combo, "changed", @ptrCast(&onSpeedChanged), null, null, 0);
    _ = c.g_signal_connect_data(win, "destroy", @ptrCast(&onDestroy), null, null, 0);

    refreshLabel();
    _ = c.g_timeout_add(200, @ptrCast(&onTick), null);

    c.gtk_widget_show_all(win);
    if (!state.cursor_toggle) c.gtk_widget_hide(cursor_btn);
    c.gtk_main();

    widgets_global = null;
}

pub fn closeFromOtherThread() void {
    _ = c.g_idle_add(@ptrCast(&quitMainIdle), null);
}

fn quitMainIdle(_: c.gpointer) callconv(.c) c.gboolean {
    c.gtk_main_quit();
    return @as(c.gboolean, 0);
}

var finalize_done = std.atomic.Value(bool).init(false);
var finalize_win: ?*c.GtkWidget = null;

/// Show small floating "Finalizing..." dialog and enter GTK main loop. Returns
/// when `signalFinalizeDone()` is called from another thread. Caller must call
/// `closeFinalizing()` afterwards to destroy the window.
pub fn runFinalizing(message: [:0]const u8) void {
    finalize_done.store(false, .release);
    const win = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL) orelse return;
    finalize_win = win;
    c.gtk_window_set_title(@ptrCast(win), "one-cap");
    c.gtk_window_set_default_size(@ptrCast(win), 280, 80);
    c.gtk_window_set_keep_above(@ptrCast(win), 1);
    c.gtk_window_set_resizable(@ptrCast(win), 0);
    c.gtk_window_set_decorated(@ptrCast(win), 0);
    c.gtk_window_set_skip_taskbar_hint(@ptrCast(win), 1);
    c.gtk_window_set_position(@ptrCast(win), c.GTK_WIN_POS_CENTER);

    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    c.gtk_widget_set_margin_top(box, 16);
    c.gtk_widget_set_margin_bottom(box, 16);
    c.gtk_widget_set_margin_start(box, 20);
    c.gtk_widget_set_margin_end(box, 20);
    c.gtk_container_add(@ptrCast(win), box);

    const spinner = c.gtk_spinner_new();
    c.gtk_spinner_start(@ptrCast(spinner));
    c.gtk_box_pack_start(@ptrCast(box), spinner, 0, 0, 0);

    const lbl = c.gtk_label_new(message.ptr);
    c.gtk_box_pack_start(@ptrCast(box), lbl, 1, 1, 0);

    c.gtk_widget_show_all(win);
    _ = c.g_timeout_add(100, @ptrCast(&checkFinalizeDone), null);
    c.gtk_main();
}

fn checkFinalizeDone(_: c.gpointer) callconv(.c) c.gboolean {
    if (finalize_done.load(.acquire)) {
        c.gtk_main_quit();
        return @as(c.gboolean, 0);
    }
    return @as(c.gboolean, 1);
}

pub fn signalFinalizeDone() void {
    finalize_done.store(true, .release);
}

pub fn closeFinalizing() void {
    if (finalize_win) |w| {
        c.gtk_widget_destroy(w);
        finalize_win = null;
    }
}

fn onDragPress(_: *c.GtkWidget, event: *c.GdkEventButton, user: c.gpointer) callconv(.c) c.gboolean {
    if (event.button != 1) return @as(c.gboolean, 0);
    const win: *c.GtkWidget = @ptrCast(@alignCast(user));
    c.gtk_window_begin_move_drag(
        @ptrCast(win),
        @intCast(event.button),
        @intFromFloat(event.x_root),
        @intFromFloat(event.y_root),
        event.time,
    );
    return @as(c.gboolean, 1);
}

fn onPauseClicked(_: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    const w = widgets_global orelse return;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    if (!w.state.isStarted()) {
        // First click = start capture. Mark started + un-pause + set the
        // recording origin so the counter begins ticking.
        w.state.markStarted();
        w.state.paused.store(false, .release);
        w.state.recording_start_ns.store(now_ns, .release);
        w.state.pause_started_ns = 0;
        w.state.total_paused_ns = 0;
        refreshLabel();
        return;
    }
    const now_paused = w.state.togglePause();
    if (now_paused) {
        w.state.pause_started_ns = now_ns;
    } else if (w.state.pause_started_ns != 0) {
        w.state.total_paused_ns += now_ns - w.state.pause_started_ns;
        w.state.pause_started_ns = 0;
    }
    refreshLabel();
}

fn onMicClicked(_: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    if (widgets_global) |w| {
        _ = w.state.toggleMic();
        refreshLabel();
    }
}

fn onCursorClicked(_: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    if (widgets_global) |w| {
        _ = w.state.toggleCursor();
        refreshLabel();
    }
}

fn onStopClicked(_: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    if (widgets_global) |w| w.state.requestStop();
    c.gtk_main_quit();
}

fn onSpeedChanged(combo: *c.GtkComboBox, _: c.gpointer) callconv(.c) void {
    const w = widgets_global orelse return;
    const idx = c.gtk_combo_box_get_active(combo);
    const v: u32 = switch (idx) {
        1 => 125,
        2 => 150,
        3 => 200,
        else => 100,
    };
    w.state.setSpeedX100(v);
}

fn onDestroy(_: *c.GtkWidget, _: c.gpointer) callconv(.c) void {
    if (widgets_global) |w| w.state.requestStop();
    c.gtk_main_quit();
}

fn onTick(_: c.gpointer) callconv(.c) c.gboolean {
    const w = widgets_global orelse return @as(c.gboolean, 0);
    if (w.state.isStarted() and w.state.duration_seconds > 0) {
        const elapsed_s = elapsedRecordingSeconds(w.state);
        if (elapsed_s >= w.state.duration_seconds) {
            w.state.requestStop();
            c.gtk_main_quit();
            return @as(c.gboolean, 0);
        }
    }
    refreshLabel();
    return @as(c.gboolean, 1);
}

/// Wall-clock recording time minus total paused time. Used by the label
/// and duration enforcement. Returns 0 if recording hasn't started yet.
fn elapsedRecordingSeconds(state: *State) u64 {
    const start = state.recording_start_ns.load(.acquire);
    if (start == 0) return 0;
    const now: i64 = @intCast(std.time.nanoTimestamp());
    var elapsed_ns: i64 = now - start - state.total_paused_ns;
    if (state.pause_started_ns != 0) {
        elapsed_ns -= now - state.pause_started_ns;
    }
    if (elapsed_ns < 0) elapsed_ns = 0;
    return @intCast(@divFloor(elapsed_ns, std.time.ns_per_s));
}

fn refreshLabel() void {
    const w = widgets_global orelse return;
    const elapsed_s = elapsedRecordingSeconds(w.state);
    const mm = elapsed_s / 60;
    const ss = elapsed_s % 60;

    var buf: [256]u8 = undefined;
    const text = if (!w.state.isStarted() or w.state.isPaused())
        std.fmt.bufPrintZ(&buf, "<span weight='bold' foreground='#f7c948'>⏸</span> <span foreground='#bbb'>{d:0>2}:{d:0>2}</span>", .{ mm, ss }) catch return
    else
        std.fmt.bufPrintZ(&buf, "<span weight='bold' foreground='#e74c3c'>●</span> <span foreground='#ccc'>{d:0>2}:{d:0>2}</span>", .{ mm, ss }) catch return;

    c.gtk_label_set_markup(@ptrCast(w.status), text.ptr);
    c.gtk_button_set_label(
        @ptrCast(w.pause_btn),
        if (!w.state.isStarted() or w.state.isPaused()) "▶" else "⏸",
    );
    c.gtk_button_set_label(
        @ptrCast(w.mic_btn),
        if (w.state.isMicEnabled()) "🎤" else "🔇",
    );
    c.gtk_button_set_label(
        @ptrCast(w.cursor_btn),
        if (w.state.isCursorEnabled()) "🖱" else "🚫",
    );
}

// --- area selection overlay ---

pub const Selection = union(enum) {
    cancelled,
    full,
    region: encoder.Region,
};

const max_monitors = 8;

const Overlay = struct {
    windows: [max_monitors]?*c.GtkWidget = [_]?*c.GtkWidget{null} ** max_monitors,
    geo: [max_monitors]c.GdkRectangle = undefined,
    n: usize = 0,
    dragging: bool = false,
    has_rect: bool = false,
    active: usize = 0,
    sx: f64 = 0,
    sy: f64 = 0,
    cx: f64 = 0,
    cy: f64 = 0,
    result: Selection = .cancelled,
    done: bool = false,
    bg: ?*c.cairo_surface_t = null,
    bg_monitor: usize = 0,
    bg_w: f64 = 0,
    bg_h: f64 = 0,
};

var overlay: Overlay = .{};
var overlay_active = false;

/// Fullscreen overlay on every monitor, showing `still` (a frozen frame) under
/// it when available. Drag a rectangle (redraw to adjust), Space/Enter records
/// it, or the full screen if nothing is drawn; Esc cancels. Runs its own GTK
/// main loop until the user decides.
pub fn selectRegion(still: ?*const encoder.Still) !Selection {
    try initGtk();
    overlay = .{};
    defer if (overlay.bg) |bg| c.cairo_surface_destroy(bg);

    const display = c.gdk_display_get_default() orelse return error.NoDisplay;
    const screen = c.gdk_screen_get_default();
    const visual = c.gdk_screen_get_rgba_visual(screen);
    const n: usize = @intCast(@min(c.gdk_display_get_n_monitors(display), max_monitors));
    overlay.n = n;

    for (0..n) |i| {
        const mon = c.gdk_display_get_monitor(display, @intCast(i));
        c.gdk_monitor_get_geometry(mon, &overlay.geo[i]);
    }
    if (still) |st| {
        overlay.bg = c.cairo_image_surface_create_for_data(
            st.data.ptr,
            c.CAIRO_FORMAT_RGB24,
            @intCast(st.width),
            @intCast(st.height),
            @intCast(st.stride),
        );
        overlay.bg_w = @floatFromInt(st.width);
        overlay.bg_h = @floatFromInt(st.height);
        if (st.origin) |o| {
            for (0..n) |i| {
                if (overlay.geo[i].x == o[0] and overlay.geo[i].y == o[1]) overlay.bg_monitor = i;
            }
        }
    }

    for (0..n) |i| {

        const win = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL) orelse return error.WindowCreateFailed;
        overlay.windows[i] = win;
        c.gtk_window_set_title(@ptrCast(win), "one-cap select");
        c.gtk_window_set_decorated(@ptrCast(win), 0);
        c.gtk_window_set_keep_above(@ptrCast(win), 1);
        c.gtk_window_set_skip_taskbar_hint(@ptrCast(win), 1);
        c.gtk_widget_set_app_paintable(win, 1);
        if (visual != null) c.gtk_widget_set_visual(win, visual);
        c.gtk_window_move(@ptrCast(win), overlay.geo[i].x, overlay.geo[i].y);
        c.gtk_window_set_default_size(@ptrCast(win), overlay.geo[i].width, overlay.geo[i].height);
        c.gtk_widget_add_events(win, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK |
            c.GDK_POINTER_MOTION_MASK | c.GDK_KEY_PRESS_MASK);

        const idx: c.gpointer = @ptrFromInt(i + 1);
        _ = c.g_signal_connect_data(win, "draw", @ptrCast(&onOverlayDraw), idx, null, 0);
        _ = c.g_signal_connect_data(win, "button-press-event", @ptrCast(&onOverlayPress), idx, null, 0);
        _ = c.g_signal_connect_data(win, "button-release-event", @ptrCast(&onOverlayRelease), idx, null, 0);
        _ = c.g_signal_connect_data(win, "motion-notify-event", @ptrCast(&onOverlayMotion), idx, null, 0);
        _ = c.g_signal_connect_data(win, "key-press-event", @ptrCast(&onOverlayKey), null, null, 0);
        _ = c.g_signal_connect_data(win, "realize", @ptrCast(&onOverlayRealize), null, null, 0);
        _ = c.g_signal_connect_data(win, "delete-event", @ptrCast(&onOverlayDelete), null, null, 0);

        c.gtk_window_fullscreen_on_monitor(@ptrCast(win), screen, @intCast(i));
        c.gtk_widget_show_all(win);
    }

    overlay_active = true;
    c.gtk_main();
    overlay_active = false;
    return overlay.result;
}

fn finishOverlay(result: Selection) void {
    if (overlay.done) return;
    overlay.done = true;
    overlay.result = result;
    for (overlay.windows[0..overlay.n]) |w| if (w) |win| c.gtk_widget_destroy(win);
    // Let the compositor unmap the overlay before anything is captured.
    const display = c.gdk_display_get_default();
    if (display != null) c.gdk_display_sync(display);
    c.gtk_main_quit();
}

fn monitorIndex(user: c.gpointer) usize {
    return @intFromPtr(user) - 1;
}

fn onOverlayRealize(win: *c.GtkWidget, _: c.gpointer) callconv(.c) void {
    const gdk_win = c.gtk_widget_get_window(win);
    const cursor = c.gdk_cursor_new_from_name(c.gtk_widget_get_display(win), "crosshair");
    if (cursor != null) {
        c.gdk_window_set_cursor(gdk_win, cursor);
        c.g_object_unref(cursor);
    }
}

fn onOverlayDraw(_: *c.GtkWidget, cr: *c.cairo_t, user: c.gpointer) callconv(.c) c.gboolean {
    const i = monitorIndex(user);
    const gw: f64 = @floatFromInt(overlay.geo[i].width);
    const gh: f64 = @floatFromInt(overlay.geo[i].height);
    const show_rect = (overlay.dragging or overlay.has_rect) and overlay.active == i;
    const x = @min(overlay.sx, overlay.cx);
    const y = @min(overlay.sy, overlay.cy);
    const w = @abs(overlay.cx - overlay.sx);
    const h = @abs(overlay.cy - overlay.sy);

    // Frozen frame underneath (physical px scaled to the logical monitor).
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    if (overlay.bg != null and overlay.bg_monitor == i) {
        c.cairo_save(cr);
        c.cairo_scale(cr, gw / overlay.bg_w, gh / overlay.bg_h);
        c.cairo_set_source_surface(cr, overlay.bg, 0, 0);
        c.cairo_paint(cr);
        c.cairo_restore(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    }

    // Dim everything except the selection.
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.45);
    c.cairo_set_fill_rule(cr, c.CAIRO_FILL_RULE_EVEN_ODD);
    c.cairo_rectangle(cr, 0, 0, gw, gh);
    if (show_rect) c.cairo_rectangle(cr, x, y, w, h);
    c.cairo_fill(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
    if (show_rect) {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.9);
        c.cairo_set_line_width(cr, 2);
        c.cairo_rectangle(cr, x + 1, y + 1, @max(w - 2, 0), @max(h - 2, 0));
        c.cairo_stroke(cr);

        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{d} × {d}  ·  Space: record", .{ @as(i32, @intFromFloat(w)), @as(i32, @intFromFloat(h)) }) catch return 0;
        c.cairo_set_font_size(cr, 14);
        drawLabel(cr, label.ptr, x, if (y > 30) y - 10 else y + h + 22);
    } else if (!overlay.dragging and !overlay.has_rect) {
        const hint = "Drag to select area  ·  Space: record full screen  ·  Esc: cancel";
        c.cairo_set_font_size(cr, 18);
        var ext: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(cr, hint, &ext);
        drawLabel(cr, hint, gw / 2 - ext.width / 2, gh / 2);
    }
    return 1;
}

/// White text on a dark pill so it stays readable over any screenshot.
fn drawLabel(cr: *c.cairo_t, text: [*:0]const u8, x: f64, y: f64) void {
    var ext: c.cairo_text_extents_t = undefined;
    c.cairo_text_extents(cr, text, &ext);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.7);
    c.cairo_rectangle(cr, x - 6, y + ext.y_bearing - 5, ext.width + 12, ext.height + 10);
    c.cairo_fill(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.95);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, text);
}

fn queueRedrawAll() void {
    for (overlay.windows[0..overlay.n]) |w| if (w) |win| c.gtk_widget_queue_draw(win);
}

fn onOverlayPress(_: *c.GtkWidget, ev: *c.GdkEventButton, user: c.gpointer) callconv(.c) c.gboolean {
    if (ev.button != 1) return 0;
    overlay.dragging = true;
    overlay.has_rect = false;
    overlay.active = monitorIndex(user);
    overlay.sx = ev.x;
    overlay.sy = ev.y;
    overlay.cx = ev.x;
    overlay.cy = ev.y;
    queueRedrawAll();
    return 1;
}

fn onOverlayMotion(win: *c.GtkWidget, ev: *c.GdkEventMotion, user: c.gpointer) callconv(.c) c.gboolean {
    if (!overlay.dragging or overlay.active != monitorIndex(user)) return 0;
    overlay.cx = ev.x;
    overlay.cy = ev.y;
    c.gtk_widget_queue_draw(win);
    return 1;
}

fn onOverlayRelease(_: *c.GtkWidget, ev: *c.GdkEventButton, user: c.gpointer) callconv(.c) c.gboolean {
    if (ev.button != 1 or !overlay.dragging or overlay.active != monitorIndex(user)) return 0;
    overlay.dragging = false;
    overlay.cx = ev.x;
    overlay.cy = ev.y;
    // A click without a drag clears the selection (back to full screen).
    overlay.has_rect = @abs(overlay.cx - overlay.sx) >= 16 and @abs(overlay.cy - overlay.sy) >= 16;
    queueRedrawAll();
    return 1;
}

fn selectedRegion() ?encoder.Region {
    if (!overlay.has_rect) return null;
    const g = overlay.geo[overlay.active];
    return .{
        .x = g.x + @as(i32, @intFromFloat(@min(overlay.sx, overlay.cx))),
        .y = g.y + @as(i32, @intFromFloat(@min(overlay.sy, overlay.cy))),
        .w = @intFromFloat(@abs(overlay.cx - overlay.sx)),
        .h = @intFromFloat(@abs(overlay.cy - overlay.sy)),
        .monitor_index = @intCast(overlay.active),
        .mon_x = g.x,
        .mon_y = g.y,
        .mon_w = g.width,
        .mon_h = g.height,
    };
}

/// Leading fields of GdkEventKey; translate-c makes the real struct opaque
/// because of a trailing bitfield.
const EventKey = extern struct {
    type: c_int,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    state: c_uint,
    keyval: c_uint,
};

fn onOverlayKey(_: *c.GtkWidget, ev: *const EventKey, _: c.gpointer) callconv(.c) c.gboolean {
    switch (ev.keyval) {
        c.GDK_KEY_Escape => finishOverlay(.cancelled),
        c.GDK_KEY_space, c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
            if (overlay.dragging) return 1;
            finishOverlay(if (selectedRegion()) |r| .{ .region = r } else .full);
        },
        else => return 0,
    }
    return 1;
}

fn onOverlayDelete(_: *c.GtkWidget, _: ?*anyopaque, _: c.gpointer) callconv(.c) c.gboolean {
    finishOverlay(.cancelled);
    return 1;
}
