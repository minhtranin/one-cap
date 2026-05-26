# one-cap

Wayland screen + audio recorder in Zig. Simple CLI: `one-cap [output] [opts]`.

## Architecture

Four layers, one process:

```
main.zig
  └─ recorder.zig  ── orchestrator: starts screen+audio in parallel, muxes
       ├─ screen.zig     ── backend dispatcher → spawns subprocess
       │    └─ portal_screencast.py   (xdg portal + GStreamer, default)
       │    └─ wf-recorder            (wlroots)
       │    └─ ffmpeg x11grab/kmsgrab (X11 / DRM fallback)
       └─ audio.zig      ── native libpulse, raw PCM s16le to file
```

Audio capture is native Zig calling libpulse (ported from
`~/workspace/personal/zigy/zig-april-captions/src/pulse.zig`). It runs in
its own thread, writing PCM bytes to `/tmp/one-cap-audio.raw`.

Screen capture is always a subprocess. On GNOME/KDE Wayland the default is
`portal_screencast.py`: it does the xdg-desktop-portal ScreenCast DBus
dance, gets a PipeWire fd + node id, then runs a GStreamer pipeline
`pipewiresrc → queue → videoconvert → encoder → muxer → filesink`.

Final mux is one `ffmpeg` call: stream-copy video, encode PCM → AAC (mp4/mkv)
or Opus (webm). Output container picked from filename extension.

## Container / encoder matrix

| Output ext | Video encoder       | Audio codec | Why                       |
|------------|---------------------|-------------|---------------------------|
| `.mkv`     | x264 ultrafast (sw) | AAC         | Default. Fast, no drops.  |
| `.mp4`     | x264 ultrafast (sw) | AAC         | Same as mkv, mp4 wrapper. |
| `.webm`    | VP8 (sw)            | Opus        | True WebM. Slower at 1440p. |

VP8 software encoding is the only path that produces true WebM, but at
1440p30 it can lag behind realtime and drop frames. Default ext is `.mkv`
because of this. If user explicitly asks for `.webm`, accept the tradeoff.

## Build / run

```bash
zig build                          # debug
zig build -Doptimize=ReleaseFast   # release
./zig-out/bin/one-cap --help
./zig-out/bin/one-cap -d 5         # 5s to ~/Videos/onecap-<ts>.mkv
```

System deps (Ubuntu 24.04):
```
libpulse-dev ffmpeg python3-dbus python3-gi
gstreamer1.0-plugins-good gstreamer1.0-pipewire gstreamer1.0-x
gir1.2-gstreamer-1.0 x264
```

Optional (for `vaapih264enc` HW encode upgrade — not wired in yet):
`gstreamer1.0-plugins-bad gstreamer1.0-vaapi vainfo`.

## Conventions / gotchas

- Zig 0.13.0. `std.posix.getenv`, `std.process.Child`, `std.atomic.Value`.
- `screen.Recorder` is a plain struct wrapping `std.process.Child` — the
  portal helper blocks for the user's "Share" click, then prints
  `PORTAL_READY` to stdout. `start()` reads stdout until it sees that
  marker before returning, so callers can safely begin the audio thread
  knowing the screen pipeline is live.
- The portal helper path is resolved at runtime by `findPortalHelper()` —
  env var `ONECAP_PORTAL_HELPER` overrides, then a few hardcoded
  candidates. If you move the project, update the dev path in
  `src/screen.zig`.
- Backend detection (`screen.detectBackend`) order:
  1. Wayland + python3 → `portal_pipewire`
  2. Wlroots compositor + wf-recorder → `wf_recorder`
  3. X11 + ffmpeg → `ffmpeg_x11grab`
  4. ffmpeg present → `ffmpeg_kmsgrab` (needs `CAP_SYS_ADMIN`)
- Intermediate file path in `/tmp` follows the *output* extension so the
  portal helper writes the right codec for the final container, and the
  mux step can stream-copy without re-encoding.
- Quality presets in `main.zig`: low=8M, medium=15M, high=25M, ultra=40M.
  Defaults: system audio (monitor), 40 Mbps.

## First run

First time the user records on a session, GNOME pops a portal permission
dialog. They must click **Share**. Response code in `portal_screencast.py`
logs: 0=granted, 1=user-cancelled, 2=other-error.

If the portal service crashed or is in a weird state:
```
systemctl --user restart xdg-desktop-portal xdg-desktop-portal-gnome
```

## Reference projects

- `~/workspace/personal/zigy/zig-april-captions/src/pulse.zig` — original
  libpulse capture this ported from.
- `~/workspace/personal/oneshot/zig-oneshot/src/wayland/portal.zig` — same
  pattern of "write a Python helper to /tmp, exec it" for portal calls.
