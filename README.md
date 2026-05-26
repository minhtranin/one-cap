# one-cap

Wayland screen + audio recorder. Pure Zig + libwayland + ffmpeg. Tiny
floating control window with cursor / mic / pause / stop toggles.

![icon](packaging/one-cap.png)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/minhtranin/one-cap/main/install.sh | bash
```

Drops a portable AppImage in `~/.local/bin/one-cap` and registers a desktop
entry + icon, so `one-cap` shows up in your app launcher. No sudo.

Runtime deps:

```bash
# Arch (wlroots: niri/sway/Hyprland/KDE)
sudo pacman -S ffmpeg libpulse gtk3
# Arch (GNOME — adds the portal helper deps)
sudo pacman -S ffmpeg libpulse gtk3 python python-dbus python-gobject \
  gst-plugins-good gst-plugin-pipewire gst-plugins-ugly

# Ubuntu / Debian (works for both compositor families)
sudo apt install ffmpeg libpulse0 libgtk-3-0 \
  python3 python3-dbus python3-gi gir1.2-gstreamer-1.0 \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly \
  gstreamer1.0-pipewire x264
```

Supported:
- wlroots-style compositors (niri, sway, Hyprland, wayfire, river,
  KDE on wlroots) → in-process libwayland wlr-screencopy capture.
- GNOME / Ubuntu Wayland → xdg-desktop-portal ScreenCast via the
  bundled Python helper + GStreamer pipeline.

## Usage

```bash
one-cap                       # record to ~/Videos/onecap-<ts>.mkv, system audio
one-cap demo.mkv -d 10        # 10s clip
one-cap -q medium             # quality preset: low / medium / high / ultra
one-cap -b 30000              # explicit 30 Mbps
one-cap --mic                 # mic instead of system audio
one-cap --no-ui -d 5 out.mkv  # headless, no GTK window
```

GUI buttons while recording: 🖱 cursor on/off, 🎤 mic on/off, ⏸ pause, ⏹ stop.

## Build from source

Zig 0.14.1 (Arch ships 0.16; install pinned version manually):

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/one-cap --help
```

System build deps: `libpulse libwayland wayland-protocols wlr-protocols
gtk3 ffmpeg x264`.

## Architecture

```
main.zig
  └─ recorder.zig         orchestrator: screen + audio + ui + mux
       ├─ screencopy.zig         libwayland wlr-screencopy v3 capture (in-process)
       ├─ screencopy_backend.zig pipes raw frames to ffmpeg subprocess for H264 encode
       ├─ audio.zig              libpulse capture loop (mic + monitor)
       └─ ui.zig                 GTK3 floating control window
```

See [CLAUDE.md](CLAUDE.md) for full architecture + gotchas.

## License

MIT
