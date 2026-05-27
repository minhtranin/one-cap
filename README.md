# one-cap

Wayland screen + audio recorder in Zig. Floating control bar
(cursor / mic / pause / stop). MKV+H264 by default.

![icon](packaging/one-cap.png)

## Install

Two lines per distro: deps, then installer.

**Arch — wlroots (niri, sway, Hyprland, wayfire, river, KDE Wayland)**

```bash
sudo pacman -S --needed ffmpeg libpulse gtk3
curl -fsSL https://raw.githubusercontent.com/minhtranin/one-cap/main/install.sh | bash
```

**Arch — GNOME** (adds portal + GStreamer deps)

```bash
sudo pacman -S --needed ffmpeg libpulse gtk3 python python-dbus python-gobject gst-plugins-good gst-plugin-pipewire gst-plugins-ugly
curl -fsSL https://raw.githubusercontent.com/minhtranin/one-cap/main/install.sh | bash
```

**Ubuntu / Debian — any compositor**

```bash
sudo apt install -y ffmpeg libpulse0 libgtk-3-0 python3 python3-dbus python3-gi gir1.2-gstreamer-1.0 gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly gstreamer1.0-pipewire x264
curl -fsSL https://raw.githubusercontent.com/minhtranin/one-cap/main/install.sh | bash
```

The installer drops a portable AppImage in `~/.local/bin/one-cap`,
registers a `.desktop` + icon, and on GNOME also installs the bundled
"OneCap Pin" shell extension so the control bar stays above fullscreen
windows. Idempotent — safe to re-run for upgrades.

## Usage

```bash
one-cap                       # ~/Videos/onecap-<ts>.mkv, system audio
one-cap demo.mkv -d 10        # 10-second clip
one-cap -q medium             # preset: low / medium / high / ultra
one-cap -b 30000              # explicit 30 Mbps
one-cap --mic                 # mic instead of system audio
one-cap --no-ui -d 5 out.mkv  # headless
```

Control bar: 🖱 cursor • 🎤 mic • ⏸ pause • ⏹ stop.

## Backends

| Compositor family | Backend |
|---|---|
| niri / sway / Hyprland / wayfire / river / KDE Wayland | in-process libwayland wlr-screencopy v3 |
| GNOME / Ubuntu Wayland | xdg-desktop-portal ScreenCast + GStreamer (Python helper) |
| X11 / XWayland | ffmpeg x11grab |
| DRM (CAP_SYS_ADMIN) | ffmpeg kmsgrab |

## Build from source

Zig **0.14.1** required.

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/one-cap --help
```

Version is read from the repo-root `VERSION` file by `build.zig` at
compile time (trimmed; falls back to a hard-coded default if missing).
Bump that file to cut a release — `ui.zig` shows it in the brand label.

System build deps: `libpulse libwayland wayland-protocols wlr-protocols
gtk3 ffmpeg x264`.

## Architecture

```
main.zig
 └─ recorder.zig          orchestrator: screen + audio + ui + mux
     ├─ screencopy.zig          libwayland wlr-screencopy v3 capture
     ├─ screencopy_backend.zig  pipes raw frames into ffmpeg for H264
     ├─ audio.zig               libpulse capture (mic + monitor)
     ├─ portal_screencast.py    GNOME fallback (portal + GStreamer)
     └─ ui.zig                  GTK3 floating control bar
```

See [CLAUDE.md](CLAUDE.md) for deeper notes.

## License

MIT
