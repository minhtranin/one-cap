# one-cap

Wayland screen + audio recorder in Zig. Simple CLI: `one-cap [output] [opts]`.

## Architecture

```
main.zig
  └─ recorder.zig  ── orchestrator: starts screen+audio in parallel, muxes
       ├─ screen.zig            ── backend dispatcher
       │    └─ screencopy.zig          ── pure-Zig wlr-screencopy v3 capture (wlroots)
       │    └─ screencopy_backend.zig  ── wraps capture + spawns ffmpeg for encode
       │    └─ portal.zig / pipewire_capture.zig / portal_backend.zig
       │                               ── GNOME: portal ScreenCast (GDBus) + libpipewire → ffmpeg
       │    └─ encoder.zig             ── shared ffmpeg spawn + region→crop math
       │    └─ wf-recorder subprocess  (wlroots cli fallback)
       │    └─ ffmpeg x11grab/kmsgrab  (X11 / DRM fallback)
       ├─ audio.zig    ── native libpulse, raw PCM s16le to file
       └─ ui.zig       ── area-select overlay, stop dialog, optional mini bar
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

**Zig pin: 0.15.2** (`zig15` fish function → `~/Documents/zig-x86_64-linux-0.15.2/zig`).

```bash
zig15 build                          # debug
zig15 build -Doptimize=ReleaseFast   # release
./zig-out/bin/one-cap --help
./zig-out/bin/one-cap -d 5         # 5s to ~/Videos/onecap-<ts>.mkv
```

System deps (Arch):
```
libpulse ffmpeg wayland wayland-protocols wlr-protocols
gtk3 glib2 libpipewire x264
```

Ubuntu 24.04 equivalents:
```
libpulse-dev ffmpeg libwayland-dev wayland-protocols
libgtk-3-dev libpipewire-0.3-dev libx264-dev
# wlr-protocols → fetch wlr-screencopy-unstable-v1.xml from upstream
```

Wayland protocol bindings are pre-generated in `src/wayland_gen/` (committed).
Regenerate after upgrading `wlr-protocols`:
```bash
wayland-scanner client-header /usr/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml src/wayland_gen/wlr-screencopy-client-protocol.h
wayland-scanner private-code  /usr/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml src/wayland_gen/wlr-screencopy-protocol.c
```

## Conventions / gotchas

- **Zig 0.15.2 pinned.** Uses `std.array_list.Managed` (old ArrayList API),
  `std.Thread.sleep`, `callconv(.c)`. 0.16 has more breaking std changes.
- translate-c can't compile spa/pod inline helpers → `pipewire_capture.zig`
  builds/parses SPA pods by hand. Include `spa/param/param.h`, not
  `buffers.h` (missing in PipeWire 0.3.48 / Ubuntu 22.04).
- GNOME portal: restore token in `~/.config/one-cap/portal-restore-token`
  (share dialog once). `host.portal.Registry.Register("one-cap")` runs first
  so hotkey vs terminal launches share the same app id / grant.
- App id registration is per D-Bus connection. `registerAppId` keeps a ref
  on the shared bus connection; without it the connection dies after the
  first session (still frame) and the recording session comes in as app id
  `''` → grant rejected → share dialog every time.
- Default GUI mode has no bar while recording (Wayland can't place it outside
  the video). Stop = SIGTERM/SIGINT (`g_unix_signal_add`) or portal
  `Session.Closed`; capture stops, then `ui.runFinish` picks speed/save.
  `--bar` keeps the live bar.
- Mutter only sends frames on damage → writer thread repeats the latest frame
  at fixed fps into ffmpeg. Crop happens while copying.
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
  0. GNOME Wayland + ffmpeg → `portal_pipewire` (in-process Zig)
  1. Wayland + ffmpeg → `wlr_screencopy` (in-process Zig)
  2. Wlroots-style compositor + wf-recorder → `wf_recorder`
  3. X11 + ffmpeg → `ffmpeg_x11grab`
  4. ffmpeg present → `ffmpeg_kmsgrab` (needs `CAP_SYS_ADMIN`)
- The wlr-screencopy path captures the FIRST `wl_output` advertised; area
  crop only applies when drawn on GDK monitor 0. Portal path captures the
  monitor picked in the share dialog; crop uses the stream's position/size.
- Quality presets in `main.zig`: low=8M, medium=15M, high=25M, ultra=40M.
  Defaults: system audio (monitor), 40 Mbps.

## Reference projects

- `~/workspace/personal/zigy/zig-april-captions/src/pulse.zig` — origin of
  the libpulse capture code.
