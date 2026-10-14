<p align="center">
  <img src="packaging/one-cap.png" alt="one-cap" width="180" />
</p>

# one-cap

Wayland screen + audio recorder in Zig. Floating control bar
(cursor / mic / pause / stop). MKV+H264 by default.

## Install

Two lines per distro: deps, then installer.

**Arch — wlroots (niri, sway, Hyprland, wayfire, river, KDE Wayland)**

```bash
sudo pacman -S --needed ffmpeg libpulse gtk3
curl -fsSL https://raw.githubusercontent.com/minhtranin/one-cap/main/install.sh | bash
```

**Arch — GNOME**

```bash
sudo pacman -S --needed ffmpeg libpulse gtk3 libpipewire
curl -fsSL https://raw.githubusercontent.com/minhtranin/one-cap/main/install.sh | bash
```

**Ubuntu / Debian — any compositor**

```bash
sudo apt install -y ffmpeg libpulse0 libgtk-3-0 libpipewire-0.3-0
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

On start a dimmed overlay appears: drag a rectangle (redraw to adjust),
**Space** starts recording that area, or the full screen if nothing is drawn.
**Esc** cancels. `--full` skips the picker.

Mini bar: timer • 🖱 cursor (wlroots only) • speed • 🎤 mic • ⏸ pause • ⏹ stop.

On GNOME the share dialog appears once; the grant is remembered in
`~/.config/one-cap/portal-restore-token` (delete it to pick another monitor).

## Backends

| Compositor family | Backend |
|---|---|
| niri / sway / Hyprland / wayfire / river / KDE Wayland | in-process libwayland wlr-screencopy v3 |
| GNOME / Ubuntu Wayland | xdg-desktop-portal ScreenCast (GDBus) + libpipewire, in-process |
| X11 / XWayland | ffmpeg x11grab |
| DRM (CAP_SYS_ADMIN) | ffmpeg kmsgrab |

## Build from source

Zig **0.15.x** required (0.15.2 tested).

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/one-cap --help
```

Version is read from the repo-root `VERSION` file by `build.zig` at
compile time (trimmed; falls back to a hard-coded default if missing).

System build deps: `libpulse libwayland wayland-protocols wlr-protocols
gtk3 libpipewire ffmpeg x264` (Ubuntu: `libpulse-dev libgtk-3-dev
libpipewire-0.3-dev libwayland-dev`).

## Architecture

```
main.zig
 └─ recorder.zig          orchestrator: screen + audio + ui + mux
     ├─ screencopy.zig          libwayland wlr-screencopy v3 capture
     ├─ screencopy_backend.zig  wlroots: frames → ffmpeg
     ├─ portal.zig              GNOME: xdg-desktop-portal ScreenCast over GDBus
     ├─ pipewire_capture.zig    GNOME: PipeWire frames (hand-built SPA pods)
     ├─ portal_backend.zig      GNOME: portal + PipeWire → ffmpeg
     ├─ encoder.zig             shared ffmpeg H264 encoder + area crop math
     ├─ audio.zig               libpulse capture (mic + monitor)
     └─ ui.zig                  area-select overlay + GTK3 mini bar
```

See [CLAUDE.md](CLAUDE.md) for deeper notes.

## License

MIT
