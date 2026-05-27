//! Tiny floating GTK3 control window. Shows live recording timer + Pause /
//! Stop / Mic / Cursor buttons. Counter freezes while paused (cumulative
//! paused time is subtracted).
//! Owns the GTK main loop on the calling thread (must be the OS main thread).
//! All callbacks toggle atomic flags on the shared State, which the recorder
//! controller thread polls/observes.

const std = @import("std");

const c = @cImport({
    @cInclude("gtk/gtk.h");
});

const VERSION: []const u8 = @import("build_options").version;

pub const State = struct {
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mic_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cursor_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    /// Playback-speed multiplier ×100 (100 = 1×, 125 = 1.25×, 150 = 1.5×, 200 = 2×).
    /// Read once at finalize/mux time; not applied during capture.
    speed_x100: std.atomic.Value(u32) = std.atomic.Value(u32).init(100),

    // Counter math. Recorder sets recording_start_ns once on launch. UI thread
    // owns pause_started_ns + total_paused_ns under the GTK main loop.
    recording_start_ns: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),
    pause_started_ns: i128 = 0,
    total_paused_ns: i128 = 0,

    // 0 = open-ended.
    duration_seconds: u32 = 0,

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

pub fn run(state: *State) !void {
    if (c.gtk_init_check(null, null) == 0) return error.GtkInitFailed;

    c.g_set_prgname("one-cap");
    c.gdk_set_program_class("one-cap");

    const css =
        \\button { padding: 6px 10px; min-height: 0px; min-width: 0px; font-size: 18px; }
        \\label { font-size: 16px; }
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
    c.gtk_window_set_default_size(@ptrCast(win), 500, 64);
    c.gtk_window_set_keep_above(@ptrCast(win), 1);
    c.gtk_window_set_resizable(@ptrCast(win), 0);
    c.gtk_window_set_decorated(@ptrCast(win), 0);
    c.gtk_window_set_skip_taskbar_hint(@ptrCast(win), 1);
    c.gtk_window_set_role(@ptrCast(win), "one-cap-control");
    c.gtk_window_set_gravity(@ptrCast(win), c.GDK_GRAVITY_NORTH_EAST);
    c.gtk_window_move(@ptrCast(win), 10, 10);

    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    c.gtk_widget_set_margin_top(box, 6);
    c.gtk_widget_set_margin_bottom(box, 6);
    c.gtk_widget_set_margin_start(box, 14);
    c.gtk_widget_set_margin_end(box, 14);
    c.gtk_container_add(@ptrCast(win), box);

    const drag_area = c.gtk_event_box_new();
    c.gtk_widget_add_events(drag_area, c.GDK_BUTTON_PRESS_MASK);
    c.gtk_box_pack_start(@ptrCast(box), drag_area, 1, 1, 0);
    _ = c.g_signal_connect_data(drag_area, "button-press-event", @ptrCast(&onDragPress), win, null, 0);

    const drag_inner = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    c.gtk_container_add(@ptrCast(drag_area), drag_inner);

    const brand = c.gtk_label_new(null);
    var brand_buf: [128]u8 = undefined;
    const brand_text = std.fmt.bufPrintZ(
        &brand_buf,
        "<span size='medium' foreground='#ccc'>onecap {s}</span>",
        .{VERSION},
    ) catch "onecap";
    c.gtk_label_set_markup(@ptrCast(brand), brand_text.ptr);
    c.gtk_box_pack_start(@ptrCast(drag_inner), brand, 0, 0, 0);

    const status = c.gtk_label_new(null);
    c.gtk_label_set_xalign(@ptrCast(status), 0.0);
    c.gtk_box_pack_start(@ptrCast(drag_inner), status, 1, 1, 0);

    const cursor_btn = c.gtk_button_new_with_label("🖱");
    const mic_btn = c.gtk_button_new_with_label("🔇");
    const pause_btn = c.gtk_button_new_with_label("⏸");
    const stop_btn = c.gtk_button_new_with_label("⏹");
    c.gtk_widget_set_size_request(cursor_btn, 56, 44);
    c.gtk_widget_set_size_request(mic_btn, 56, 44);
    c.gtk_widget_set_size_request(pause_btn, 56, 44);
    c.gtk_widget_set_size_request(stop_btn, 56, 44);
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
    c.gtk_widget_set_size_request(speed_combo, 78, 44);
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
    c.gtk_main();

    widgets_global = null;
}

pub fn closeFromOtherThread() void {
    _ = c.g_idle_add(@ptrCast(&quitMainIdle), null);
}

fn quitMainIdle(_: c.gpointer) callconv(.C) c.gboolean {
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

fn checkFinalizeDone(_: c.gpointer) callconv(.C) c.gboolean {
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

fn onDragPress(_: *c.GtkWidget, event: *c.GdkEventButton, user: c.gpointer) callconv(.C) c.gboolean {
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

fn onPauseClicked(_: *c.GtkButton, _: c.gpointer) callconv(.C) void {
    const w = widgets_global orelse return;
    const now_paused = w.state.togglePause();
    const now_ns = std.time.nanoTimestamp();
    if (now_paused) {
        w.state.pause_started_ns = now_ns;
    } else if (w.state.pause_started_ns != 0) {
        w.state.total_paused_ns += now_ns - w.state.pause_started_ns;
        w.state.pause_started_ns = 0;
    }
    refreshLabel();
}

fn onMicClicked(_: *c.GtkButton, _: c.gpointer) callconv(.C) void {
    if (widgets_global) |w| {
        _ = w.state.toggleMic();
        refreshLabel();
    }
}

fn onCursorClicked(_: *c.GtkButton, _: c.gpointer) callconv(.C) void {
    if (widgets_global) |w| {
        _ = w.state.toggleCursor();
        refreshLabel();
    }
}

fn onStopClicked(_: *c.GtkButton, _: c.gpointer) callconv(.C) void {
    if (widgets_global) |w| w.state.requestStop();
    c.gtk_main_quit();
}

fn onSpeedChanged(combo: *c.GtkComboBox, _: c.gpointer) callconv(.C) void {
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

fn onDestroy(_: *c.GtkWidget, _: c.gpointer) callconv(.C) void {
    if (widgets_global) |w| w.state.requestStop();
    c.gtk_main_quit();
}

fn onTick(_: c.gpointer) callconv(.C) c.gboolean {
    const w = widgets_global orelse return @as(c.gboolean, 0);
    if (w.state.duration_seconds > 0) {
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
    const now = std.time.nanoTimestamp();
    var elapsed_ns: i128 = now - start - state.total_paused_ns;
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
    const text = if (w.state.isPaused())
        std.fmt.bufPrintZ(&buf, "<span size='x-large' weight='bold' foreground='#f7c948'>⏸</span> <span size='large' foreground='#bbb'>{d:0>2}:{d:0>2}</span>", .{ mm, ss }) catch return
    else
        std.fmt.bufPrintZ(&buf, "<span size='x-large' weight='bold' foreground='#e74c3c'>●</span> <span size='large' foreground='#ccc'>{d:0>2}:{d:0>2}</span>", .{ mm, ss }) catch return;

    c.gtk_label_set_markup(@ptrCast(w.status), text.ptr);
    c.gtk_button_set_label(
        @ptrCast(w.pause_btn),
        if (w.state.isPaused()) "▶" else "⏸",
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
