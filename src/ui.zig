//! Tiny floating GTK3 control window: status label + Pause/Resume + Stop.
//! Owns the GTK main loop on the calling thread (must be the OS main thread).
//! All callbacks toggle atomic flags on the shared State, which the recorder
//! thread polls/observes.

const std = @import("std");

const c = @cImport({
    @cInclude("gtk/gtk.h");
});

pub const State = struct {
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mic_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cursor_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    // Set by the recorder once duration_seconds is known. 0 = open-ended.
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
};

const Widgets = struct {
    window: *c.GtkWidget,
    status: *c.GtkWidget,
    pause_btn: *c.GtkWidget,
    mic_btn: *c.GtkWidget,
    cursor_btn: *c.GtkWidget,
    state: *State,
    start_ns: i128,
};

var widgets_global: ?*Widgets = null;

/// Blocks until the user clicks Stop, closes the window, or duration elapses.
/// Returns when GTK main loop has quit. Caller then finalizes capture.
pub fn run(state: *State) !void {
    if (c.gtk_init_check(null, null) == 0) return error.GtkInitFailed;

    // Set Wayland app-id so compositor rules can target the window
    // (e.g. niri `match app-id="one-cap"`). GTK uses program class.
    c.g_set_prgname("one-cap");
    c.gdk_set_program_class("one-cap");

    // CSS: strip GTK button padding so the icon-only buttons stay tiny.
    const css =
        \\button { padding: 4px 10px; min-height: 0px; min-width: 0px; font-size: 13px; }
        \\label { font-size: 12px; }
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
    c.gtk_window_set_default_size(@ptrCast(win), 340, 42);
    c.gtk_window_set_keep_above(@ptrCast(win), 1);
    c.gtk_window_set_resizable(@ptrCast(win), 0);
    c.gtk_window_set_decorated(@ptrCast(win), 0);
    c.gtk_window_set_skip_taskbar_hint(@ptrCast(win), 1);

    // Wayland forbids client positioning; on niri use a window rule by
    // app_id="one-cap" to pin to top-right. X11 honors the move below.
    c.gtk_window_set_role(@ptrCast(win), "one-cap-control");
    c.gtk_window_set_gravity(@ptrCast(win), c.GDK_GRAVITY_NORTH_EAST);
    c.gtk_window_move(@ptrCast(win), 10, 10);

    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 3);
    c.gtk_widget_set_margin_top(box, 2);
    c.gtk_widget_set_margin_bottom(box, 2);
    c.gtk_widget_set_margin_start(box, 5);
    c.gtk_widget_set_margin_end(box, 5);
    c.gtk_container_add(@ptrCast(win), box);

    // Drag handle: an EventBox wraps the brand+status labels. Pressing on
    // it triggers gtk_window_begin_move_drag — that's the GTK way to make
    // a decoration-less window draggable on both X11 and Wayland.
    const drag_area = c.gtk_event_box_new();
    c.gtk_widget_add_events(drag_area, c.GDK_BUTTON_PRESS_MASK);
    c.gtk_box_pack_start(@ptrCast(box), drag_area, 1, 1, 0);
    _ = c.g_signal_connect_data(
        drag_area,
        "button-press-event",
        @ptrCast(&onDragPress),
        win,
        null,
        0,
    );

    const drag_inner = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_container_add(@ptrCast(drag_area), drag_inner);

    const brand = c.gtk_label_new(null);
    c.gtk_label_set_markup(@ptrCast(brand), "<span size='small' foreground='#888'>onecap v27.05.26</span>");
    c.gtk_box_pack_start(@ptrCast(drag_inner), brand, 0, 0, 0);

    const status = c.gtk_label_new(null);
    c.gtk_label_set_xalign(@ptrCast(status), 0.0);
    c.gtk_box_pack_start(@ptrCast(drag_inner), status, 1, 1, 0);

    const cursor_btn = c.gtk_button_new_with_label("🖱");
    const mic_btn = c.gtk_button_new_with_label("🎤");
    const pause_btn = c.gtk_button_new_with_label("⏸");
    const stop_btn = c.gtk_button_new_with_label("⏹");
    c.gtk_widget_set_size_request(cursor_btn, 36, 28);
    c.gtk_widget_set_size_request(mic_btn, 36, 28);
    c.gtk_widget_set_size_request(pause_btn, 36, 28);
    c.gtk_widget_set_size_request(stop_btn, 36, 28);
    c.gtk_widget_set_tooltip_text(cursor_btn, "Toggle cursor capture");
    c.gtk_widget_set_tooltip_text(mic_btn, "Toggle microphone");
    c.gtk_button_set_relief(@ptrCast(cursor_btn), c.GTK_RELIEF_NORMAL);
    c.gtk_button_set_relief(@ptrCast(mic_btn), c.GTK_RELIEF_NORMAL);
    c.gtk_button_set_relief(@ptrCast(pause_btn), c.GTK_RELIEF_NORMAL);
    c.gtk_button_set_relief(@ptrCast(stop_btn), c.GTK_RELIEF_NORMAL);
    c.gtk_box_pack_start(@ptrCast(box), cursor_btn, 0, 0, 0);
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
        .start_ns = std.time.nanoTimestamp(),
    };
    widgets_global = &widgets;

    _ = c.g_signal_connect_data(
        cursor_btn,
        "clicked",
        @ptrCast(&onCursorClicked),
        null,
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        mic_btn,
        "clicked",
        @ptrCast(&onMicClicked),
        null,
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        pause_btn,
        "clicked",
        @ptrCast(&onPauseClicked),
        null,
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        stop_btn,
        "clicked",
        @ptrCast(&onStopClicked),
        null,
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        win,
        "destroy",
        @ptrCast(&onDestroy),
        null,
        null,
        0,
    );

    refreshLabel();

    // Tick every 200ms: update elapsed-time status, check auto-stop on duration.
    _ = c.g_timeout_add(200, @ptrCast(&onTick), null);

    c.gtk_widget_show_all(win);
    c.gtk_main();

    widgets_global = null;
}

/// Closes window from any thread — schedules destroy on the GTK main loop.
pub fn closeFromOtherThread() void {
    _ = c.g_idle_add(@ptrCast(&quitMainIdle), null);
}

fn quitMainIdle(_: c.gpointer) callconv(.C) c.gboolean {
    c.gtk_main_quit();
    return @as(c.gboolean, 0);
}

fn onDragPress(_: *c.GtkWidget, event: *c.GdkEventButton, user: c.gpointer) callconv(.C) c.gboolean {
    if (event.button != 1) return @as(c.gboolean, 0); // left-click only
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
    if (widgets_global) |w| {
        _ = w.state.togglePause();
        refreshLabel();
    }
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

fn onDestroy(_: *c.GtkWidget, _: c.gpointer) callconv(.C) void {
    if (widgets_global) |w| w.state.requestStop();
    c.gtk_main_quit();
}

fn onTick(_: c.gpointer) callconv(.C) c.gboolean {
    const w = widgets_global orelse return @as(c.gboolean, 0);
    if (w.state.duration_seconds > 0) {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - w.start_ns;
        const elapsed_s: u64 = @intCast(@divFloor(elapsed_ns, std.time.ns_per_s));
        if (elapsed_s >= w.state.duration_seconds) {
            w.state.requestStop();
            c.gtk_main_quit();
            return @as(c.gboolean, 0);
        }
    }
    refreshLabel();
    return @as(c.gboolean, 1);
}

fn refreshLabel() void {
    const w = widgets_global orelse return;
    const elapsed_ns = std.time.nanoTimestamp() - w.start_ns;
    const elapsed_s: u64 = @intCast(@divFloor(elapsed_ns, std.time.ns_per_s));
    const mm = elapsed_s / 60;
    const ss = elapsed_s % 60;

    var buf: [256]u8 = undefined;
    const text = if (w.state.isPaused())
        std.fmt.bufPrintZ(&buf, "<span weight='bold' foreground='#f7c948'>⏸</span> <span foreground='#888'>{d:0>2}:{d:0>2}</span>", .{ mm, ss }) catch return
    else
        std.fmt.bufPrintZ(&buf, "<span weight='bold' foreground='#e74c3c'>●</span> <span foreground='#aaa'>{d:0>2}:{d:0>2}</span>", .{ mm, ss }) catch return;

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
