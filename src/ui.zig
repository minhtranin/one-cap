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
};

const Widgets = struct {
    window: *c.GtkWidget,
    status: *c.GtkWidget,
    pause_btn: *c.GtkWidget,
    state: *State,
    start_ns: i128,
};

var widgets_global: ?*Widgets = null;

/// Blocks until the user clicks Stop, closes the window, or duration elapses.
/// Returns when GTK main loop has quit. Caller then finalizes capture.
pub fn run(state: *State) !void {
    if (c.gtk_init_check(null, null) == 0) return error.GtkInitFailed;

    const win = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL) orelse return error.WindowCreateFailed;
    c.gtk_window_set_title(@ptrCast(win), "one-cap");
    c.gtk_window_set_default_size(@ptrCast(win), 220, 90);
    c.gtk_window_set_keep_above(@ptrCast(win), 1);
    c.gtk_window_set_resizable(@ptrCast(win), 0);
    c.gtk_window_set_skip_taskbar_hint(@ptrCast(win), 1);

    // Wayland ignores explicit position; on X11 this nudges it.
    c.gtk_window_set_gravity(@ptrCast(win), c.GDK_GRAVITY_NORTH_EAST);
    c.gtk_window_move(@ptrCast(win), 100, 60);

    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8);
    c.gtk_widget_set_margin_top(box, 10);
    c.gtk_widget_set_margin_bottom(box, 10);
    c.gtk_widget_set_margin_start(box, 14);
    c.gtk_widget_set_margin_end(box, 14);
    c.gtk_container_add(@ptrCast(win), box);

    const status = c.gtk_label_new(null);
    c.gtk_label_set_xalign(@ptrCast(status), 0.5);
    c.gtk_box_pack_start(@ptrCast(box), status, 0, 0, 0);

    const btns = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_box_pack_start(@ptrCast(box), btns, 0, 0, 0);

    const pause_btn = c.gtk_button_new_with_label("⏸  Pause");
    const stop_btn = c.gtk_button_new_with_label("⏹  Stop");
    c.gtk_box_pack_start(@ptrCast(btns), pause_btn, 1, 1, 0);
    c.gtk_box_pack_start(@ptrCast(btns), stop_btn, 1, 1, 0);

    var widgets = Widgets{
        .window = win,
        .status = status,
        .pause_btn = pause_btn,
        .state = state,
        .start_ns = std.time.nanoTimestamp(),
    };
    widgets_global = &widgets;

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

fn onPauseClicked(_: *c.GtkButton, _: c.gpointer) callconv(.C) void {
    if (widgets_global) |w| {
        _ = w.state.togglePause();
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
        std.fmt.bufPrintZ(&buf, "<span size='large' weight='bold' foreground='#f7c948'>⏸  PAUSED</span>  <span foreground='#888'>{d:0>2}:{d:0>2}</span>", .{ mm, ss }) catch return
    else
        std.fmt.bufPrintZ(&buf, "<span size='large' weight='bold' foreground='#e74c3c'>●  REC</span>  <span foreground='#aaa'>{d:0>2}:{d:0>2}</span>", .{ mm, ss }) catch return;

    c.gtk_label_set_markup(@ptrCast(w.status), text.ptr);
    c.gtk_button_set_label(
        @ptrCast(w.pause_btn),
        if (w.state.isPaused()) "▶  Resume" else "⏸  Pause",
    );
}
