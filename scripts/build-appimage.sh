#!/usr/bin/env bash
# Build an AppImage for one-cap.
#
# Expects:
#   - zig-out/bin/one-cap already built (release mode)
#   - linuxdeploy + linuxdeploy-plugin-gtk available on PATH
#
# Output: one-cap-<arch>.AppImage in repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN=zig-out/bin/one-cap
if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN not found. Run: zig build -Doptimize=ReleaseFast" >&2
    exit 1
fi

APPDIR=AppDir
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"

cp "$BIN" "$APPDIR/usr/bin/one-cap"

# Bundle the GNOME/portal screen-capture helper next to the binary.
# screen.zig's findPortalHelper() looks for a sibling portal_screencast.py
# first, so this path resolves before any system fallback.
cp src/portal_screencast.py "$APPDIR/usr/bin/portal_screencast.py"
chmod +x "$APPDIR/usr/bin/portal_screencast.py"

# NOTE: ffmpeg is a runtime dep, but bundling it pulls in 60+ transitive
# shared libs (libplacebo, libass, libva, libvpl, libmysofa, libflite_*,
# libopenmpt, ...) ballooning the AppImage to ~150MB and slowing builds
# by an order of magnitude. one-cap shells out to `ffmpeg` from $PATH, so
# we require the host to have it installed instead — same expectation
# every screen recorder on Linux makes. AppRun adds a friendly error.
# To bundle anyway: copy a static ffmpeg into $APPDIR/usr/bin/ffmpeg and
# DELETE the libs that linuxdeploy then drags in.

# linuxdeploy assembles the AppDir with the binary as its entry point,
# discovers needed shared libs (libpulse, libwayland-client, libgtk-3, ...)
# via ldd, copies them into AppDir/usr/lib, and writes AppRun.
# The gtk plugin additionally copies icon themes, GdkPixbuf loaders, GLib
# schemas and gio modules so the GTK control window renders correctly when
# the host system lacks them.
export DEPLOY_GTK_VERSION=3
# linuxdeploy ships an older `strip` that chokes on newer ELF section types
# (e.g. `.relr.dyn` produced by recent binutils on Arch). Disable stripping;
# AppImages get squashfs-compressed anyway so size cost is minimal.
export NO_STRIP=1

# Bake the icon's mime entry so the AppImage shows the sheep, not a generic
# wrench, in app launchers.
linuxdeploy \
    --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/one-cap" \
    --desktop-file packaging/one-cap.desktop \
    --icon-file packaging/one-cap.png \
    --plugin gtk \
    --output appimage

# linuxdeploy writes one-cap-x86_64.AppImage in the cwd. Rename for clarity.
GENERATED=$(ls -1 one-cap-*.AppImage | head -n1)
echo "built: $GENERATED"
