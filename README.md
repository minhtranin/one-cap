# one-cap

Simple Wayland screen + audio recorder, written in Zig. Tiny floating
control window with Pause / Resume / Stop.

- **Audio**: native libpulse capture from Zig (ported from
  [zigy](../zigy/zig-april-captions/src/pulse.zig))
- **Screen**: `xdg-desktop-portal` ScreenCast → GStreamer
  `pipewiresrc → encoder → matroskamux` (works on GNOME/KDE Wayland);
  `wf-recorder` on wlroots; `ffmpeg x11grab/kmsgrab` fallbacks
- **UI**: GTK3 floating window via Zig cImport
  ([zig-oneshot](../oneshot/zig-oneshot/src/ui/window.zig) pattern)
- **Mux**: `ffmpeg` final pass — stream-copy video, encode PCM → AAC/Opus

## Requirements

```bash
sudo apt install libpulse-dev libgtk-3-dev ffmpeg \
    python3-dbus python3-gi gir1.2-gstreamer-1.0 \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-pipewire gstreamer1.0-x x264
# Optional for wlroots compositors (Sway/Hyprland):
sudo apt install wf-recorder
```

Zig 0.13.0.

**First run on GNOME/KDE Wayland:** a permission dialog appears asking
which monitor to share. Click **Share** (not Cancel).

## Build

```bash
zig build -Doptimize=ReleaseFast
```

Binary at `zig-out/bin/one-cap` (~3 MB).

## Usage

Defaults: system audio (monitor), 40 Mbps (ultra), 30 fps, MKV output to
`~/Videos/onecap-<timestamp>.mkv`.

```bash
# Until Stop button / Ctrl+C → ~/Videos/onecap-<ts>.mkv
one-cap

# 10s capture, custom name
one-cap demo.mkv -d 10

# Mic instead of system audio
one-cap clip.mkv --mic

# Quality presets: low / medium / high / ultra (default)
one-cap clip.mkv -q medium

# Or explicit bitrate
one-cap clip.mkv -b 30000     # 30 Mbps

# WebM output (slower VP8 software encode, may drop frames at 1440p)
one-cap clip.webm

# 60 fps
one-cap clip.mkv -r 60
```

### Control window

A small always-on-top window appears once recording starts. Shows
elapsed time. Buttons:

- **⏸ Pause / ▶ Resume** — freezes GStreamer pipeline + drops audio
  samples so the timeline stays in sync
- **⏹ Stop** — finalize + mux to the output file

Closing the window = Stop. Compositor decides window position on
Wayland (`gtk_window_move()` is ignored on Wayland); drag if needed.

## Architecture

```
main.zig
  └─ recorder.zig  ── starts screen child + audio thread + GTK ui
       ├─ screen.zig       — backend dispatcher (Python helper / wf-recorder / ffmpeg)
       │    └─ portal_screencast.py
       ├─ audio.zig        — libpulse capture loop
       └─ ui.zig           — GTK3 window: status + Pause + Stop
```

1. Detect backend, pick intermediate file ext (`.mkv` / `.webm`)
2. Spawn screen helper; wait for `PORTAL_READY` on its stdout
3. Start audio thread → writes `/tmp/one-cap-audio.raw`
4. Run GTK main loop (status updates, Pause/Stop buttons)
5. On exit: stop audio + screen, then ffmpeg mux to final output

## Backend / encoder matrix

| Output | Encoder            | Audio | Backend best fit |
|--------|--------------------|-------|------------------|
| `.mkv` | x264 ultrafast (sw)| AAC   | portal/wf/ffmpeg |
| `.mp4` | x264 ultrafast (sw)| AAC   | portal/wf/ffmpeg |
| `.webm`| VP8 (sw)           | Opus  | portal           |

Compositor → backend:

| Compositor                | Backend           |
|---------------------------|-------------------|
| GNOME/KDE Wayland         | `portal_pipewire` |
| Sway, Hyprland, Wayfire   | `wf-recorder`     |
| X11                       | `ffmpeg x11grab`  |
| Other DRM                 | `ffmpeg kmsgrab` (CAP_SYS_ADMIN) |

## Layout

```
src/
  main.zig               — CLI
  recorder.zig           — orchestrator + controller thread
  audio.zig              — libpulse capture (Zig)
  screen.zig             — backend dispatcher / subprocess wrapper
  ui.zig                 — GTK3 floating control window
  portal_screencast.py   — xdg-desktop-portal + GStreamer helper
```
