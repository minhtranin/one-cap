# one-cap

Wayland screen + audio recorder in Zig. Simple CLI: `one-cap [output] [opts]`.

## Architecture

```
main.zig
  └─ recorder.zig  ── orchestrator: starts screen+audio in parallel, muxes
       ├─ screen.zig            ── backend dispatcher
       │    └─ screencopy.zig          ── pure-Zig wlr-screencopy v3 capture (default on Wayland)
       │    └─ screencopy_backend.zig  ── wraps capture + spawns ffmpeg for encode
       │    └─ wf-recorder subprocess  (wlroots cli fallback)
       │    └─ ffmpeg x11grab/kmsgrab  (X11 / DRM fallback)
       ├─ audio.zig    ── native libpulse, raw PCM s16le to file
       └─ ui.zig       ── GTK3 floating Pause/Stop window
```

**Audio**: native Zig + libpulse, writes PCM bytes to `/tmp/one-cap-audio.raw`.

**Screen** (default, Wayland): in-process Zig binds to compositor via
`libwayland-client`, drives `zwlr_screencopy_manager_v1`, copies frames into
shm buffers, pipes raw pixels to `ffmpeg` (spawned subprocess) which encodes
to H264/MKV on stdin. No Python, no GStreamer.

**Mux**: one `ffmpeg` call — stream-copy video, encode PCM → AAC (mkv/mp4)
or Opus (webm).

## Container / encoder matrix

| Output ext | Video encoder       | Audio codec |
|------------|---------------------|-------------|
| `.mkv`     | x264 ultrafast (sw) | AAC         |
| `.mp4`     | x264 ultrafast (sw) | AAC         |
| `.webm`    | x264 → remux        | Opus        |

Default `.mkv`. Encoder is libx264 ultrafast in the wlr-screencopy path
(via ffmpeg). 1440p30 holds realtime on a modern CPU.

## Build / run

**Zig pin: 0.14.1.** Arch ships 0.16+; use `~/.local/zig/0.14.1/zig`.

```bash
~/.local/zig/0.14.1/zig build                          # debug
~/.local/zig/0.14.1/zig build -Doptimize=ReleaseFast   # release
./zig-out/bin/one-cap --help
./zig-out/bin/one-cap -d 5         # 5s to ~/Videos/onecap-<ts>.mkv
```

System deps (Arch):
```
libpulse ffmpeg wayland wayland-protocols wlr-protocols
gtk3 glib2 x264
```

Ubuntu 24.04 equivalents:
```
libpulse-dev ffmpeg libwayland-dev wayland-protocols
libgtk-3-dev libx264-dev
# wlr-protocols → fetch wlr-screencopy-unstable-v1.xml from upstream
```

Wayland protocol bindings are pre-generated in `src/wayland_gen/` (committed).
Regenerate after upgrading `wlr-protocols`:
```bash
wayland-scanner client-header /usr/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml src/wayland_gen/wlr-screencopy-client-protocol.h
wayland-scanner private-code  /usr/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml src/wayland_gen/wlr-screencopy-protocol.c
```

## Conventions / gotchas

- **Zig 0.14.1 pinned.** 0.15+ Writergate breaks `std.fs.File`, `argsAlloc`,
  `ArrayList.init`. 0.13 has older posix sigset shape. Stick to 0.14.x.
- `build.zig` sets `use_lld = true` because gcc 16's `crt1.o` carries an
  `.sframe` section the Zig self-linker can't relocate (`R_X86_64_PC64`).
- `screencopy.zig` declares `extern fn memfd_create` manually — translate-c
  hides it behind `_GNU_SOURCE` which `@cImport` doesn't apply cleanly.
- `screencopy_backend.zig` probes one frame via `firstFrameInfo()` to
  discover dims/format BEFORE spawning ffmpeg, so the ffmpeg `-s WxH
  -pix_fmt X` flags match what the compositor delivers.
- wlr-screencopy strides are sometimes wider than `width * 4` (driver-dependent).
  Pipeline tells ffmpeg `-s <stride_pixels>x<h>` then `-vf crop=W:H:0:0` to trim.
- Backend detection (`screen.detectBackend`) order:
  1. Wayland + ffmpeg → `wlr_screencopy` (in-process Zig)
  2. Wlroots-style compositor + wf-recorder → `wf_recorder`
  3. X11 + ffmpeg → `ffmpeg_x11grab`
  4. ffmpeg present → `ffmpeg_kmsgrab` (needs `CAP_SYS_ADMIN`)
- The wlr-screencopy path captures the FIRST `wl_output` advertised. No
  selector UI yet — multi-monitor users get whichever output comes first.
- Quality presets in `main.zig`: low=8M, medium=15M, high=25M, ultra=40M.
  Defaults: system audio (monitor), 40 Mbps.

## Reference projects

- `~/workspace/personal/zigy/zig-april-captions/src/pulse.zig` — origin of
  the libpulse capture code.
