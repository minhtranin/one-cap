# one-cap

Simple Wayland screen + audio recorder, written in Zig.

Combines:
- **Audio**: native libpulse capture (ported from [zigy](../zigy/zig-april-captions/src/pulse.zig))
- **Screen**: `ffmpeg` / `wf-recorder` subprocess (inspired by [zig-oneshot](../oneshot/zig-oneshot/src/wayland/portal.zig))
- **Mux**: `ffmpeg` to combine into final mp4

## Requirements

System packages:

```bash
sudo apt install libpulse-dev ffmpeg \
    python3-dbus python3-gi gir1.2-gstreamer-1.0 \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-pipewire gstreamer1.0-x x264
# Optional for wlroots compositors (Sway/Hyprland):
sudo apt install wf-recorder
```

Zig 0.13.0.

**Note:** On first run on GNOME/KDE Wayland, a permission dialog appears
asking which monitor to share. Click **Share** (not Cancel). Subsequent
runs may reuse the grant for that session.

## Build

```bash
zig build -Doptimize=ReleaseFast
```

Binary lands at `zig-out/bin/one-cap`.

## Usage

```bash
# Record 10 seconds, mic + screen
./zig-out/bin/one-cap out.mp4 -d 10

# Record until Ctrl+C
./zig-out/bin/one-cap demo.mp4

# Capture system audio (instead of mic)
./zig-out/bin/one-cap demo.mp4 --monitor -d 5

# Custom framerate
./zig-out/bin/one-cap demo.mp4 -r 60 -d 5
```

## How it works

1. Spawn screen recorder subprocess → `/tmp/one-cap-video.mp4` (silent)
2. Start audio capture thread → `/tmp/one-cap-audio.raw` (PCM s16le)
3. On stop: SIGINT to ffmpeg, join audio thread
4. Mux: `ffmpeg -i video.mp4 -i audio.raw -c:v copy -c:a aac out.mp4`

## Backend detection

Auto-selected at runtime:

| Compositor | Backend used |
|---|---|
| GNOME/KDE Wayland (any) | `portal+pipewire` (xdg-desktop-portal + GStreamer) |
| Sway, Hyprland, Wayfire | `wf-recorder` |
| X11 sessions | `ffmpeg -f x11grab` |
| Fallback | `ffmpeg -f kmsgrab` (needs `CAP_SYS_ADMIN`) |

The portal+pipewire backend spawns `src/portal_screencast.py` which does the
DBus dance, gets a PipeWire stream from the compositor, and pipes it through
GStreamer's `pipewiresrc → x264enc → matroskamux` to `/tmp/one-cap-video.mkv`.

## Layout

```
src/
  main.zig               — CLI
  recorder.zig           — orchestrator
  audio.zig              — libpulse capture (Zig)
  screen.zig             — backend dispatcher (subprocess wrapper)
  portal_screencast.py   — xdg-desktop-portal + GStreamer helper
```
