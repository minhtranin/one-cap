// OneCap Pin — keeps the one-cap control bar above every window, including
// fullscreen apps. Matches by wm_class / gtk_application_id "one-cap".
// GTK side already calls gdk_set_program_class("one-cap") + g_set_prgname.

import Meta from 'gi://Meta';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const TARGET = 'one-cap';

function matches(win) {
    if (!win) return false;
    const cls = win.get_wm_class?.() ?? '';
    const cls2 = win.get_wm_class_instance?.() ?? '';
    const sandbox = win.get_sandboxed_app_id?.() ?? '';
    const gtkApp = win.get_gtk_application_id?.() ?? '';
    return (
        cls.toLowerCase().includes(TARGET) ||
        cls2.toLowerCase().includes(TARGET) ||
        sandbox === TARGET ||
        gtkApp.toLowerCase().includes(TARGET)
    );
}

function pin(win) {
    try {
        if (!win.above) win.make_above();
        if (!win.on_all_workspaces) win.stick();
        win.raise();
    } catch (_) { /* window may have just closed */ }
}

function raiseAllMatching() {
    for (const actor of global.get_window_actors()) {
        const w = actor.meta_window;
        if (matches(w)) pin(w);
    }
}

export default class OneCapPin extends Extension {
    enable() {
        // New windows: pin immediately.
        this._createdId = global.display.connect('window-created', (_d, win) => {
            if (matches(win)) pin(win);
        });

        // Anything restacks (focus change, new fullscreen, etc.) → re-raise.
        // Cheap because matches() short-circuits on non-onecap windows.
        this._restackedId = global.display.connect('restacked', () => raiseAllMatching());

        // Fullscreen toggles emit in-fullscreen-changed per monitor; lift
        // the bar back on top after Mutter restacks the fullscreen window.
        this._fullscreenId = global.display.connect('in-fullscreen-changed', () => raiseAllMatching());

        // Sweep windows that already exist when the extension loads.
        raiseAllMatching();
    }

    disable() {
        if (this._createdId)   global.display.disconnect(this._createdId);
        if (this._restackedId) global.display.disconnect(this._restackedId);
        if (this._fullscreenId) global.display.disconnect(this._fullscreenId);
        this._createdId = this._restackedId = this._fullscreenId = null;
    }
}
