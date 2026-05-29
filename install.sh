#!/usr/bin/env bash
# one-cap installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/minhtranin/one-cap/main/install.sh | bash
#
# What this does (all user-scoped, no sudo needed):
#   1. Downloads the latest one-cap AppImage from GitHub releases.
#   2. Drops it in ~/.local/bin/one-cap and chmod +x.
#   3. Installs a freedesktop .desktop entry + 512x512 sheep icon so the
#      app shows up in your application launcher.
#   4. Refreshes the desktop DB so the entry is picked up immediately.
#
# Override the release tag with: ONECAP_VERSION=v27.05.26 bash install.sh
# Uninstall: rm ~/.local/bin/one-cap \
#               ~/.local/share/applications/one-cap.desktop \
#               ~/.local/share/icons/hicolor/512x512/apps/one-cap.png

set -euo pipefail

REPO="minhtranin/one-cap"
VERSION="${ONECAP_VERSION:-latest}"

BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"

mkdir -p "$BIN_DIR" "$APP_DIR" "$ICON_DIR"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31merr\033[0m %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { err "missing dependency: $1"; exit 1; }; }

need curl

# Resolve download URLs. For `latest` we hit the redirect endpoint; otherwise
# we point at the explicit tag. Both forms hand back the AppImage and icon.
if [[ "$VERSION" == "latest" ]]; then
    APPIMAGE_URL="https://github.com/$REPO/releases/latest/download/one-cap-x86_64.AppImage"
    ICON_URL="https://raw.githubusercontent.com/$REPO/main/packaging/one-cap.png"
    DESKTOP_URL="https://raw.githubusercontent.com/$REPO/main/packaging/one-cap.desktop"
else
    APPIMAGE_URL="https://github.com/$REPO/releases/download/$VERSION/one-cap-x86_64.AppImage"
    ICON_URL="https://raw.githubusercontent.com/$REPO/$VERSION/packaging/one-cap.png"
    DESKTOP_URL="https://raw.githubusercontent.com/$REPO/$VERSION/packaging/one-cap.desktop"
fi

log "downloading one-cap ($VERSION)…"
curl -fsSL -o "$BIN_DIR/one-cap" "$APPIMAGE_URL"
chmod +x "$BIN_DIR/one-cap"

log "installing icon → $ICON_DIR/one-cap.png"
curl -fsSL -o "$ICON_DIR/one-cap.png" "$ICON_URL"

log "installing launcher entry → $APP_DIR/one-cap.desktop"
# We rewrite the upstream .desktop's Exec= line so it points at the AppImage
# we just dropped in ~/.local/bin, not the bare "one-cap" name. This way the
# launcher works whether or not ~/.local/bin is on the user's PATH.
TMP_DESK=$(mktemp)
curl -fsSL -o "$TMP_DESK" "$DESKTOP_URL"
sed "s|^Exec=.*|Exec=$BIN_DIR/one-cap|" "$TMP_DESK" > "$APP_DIR/one-cap.desktop"
rm -f "$TMP_DESK"

# update-desktop-database is in `desktop-file-utils`. Refreshing the db is
# best-effort; most desktops also pick up changes via inotify.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
fi

# Friendly PATH hint when ~/.local/bin isn't already on PATH.
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) log "note: $BIN_DIR is not on \$PATH; add it to your shell rc to run 'one-cap' from a terminal." ;;
esac


log "done. launch 'one-cap' from your app menu, or run: $BIN_DIR/one-cap --help"
log "you also need ffmpeg, libpulse, libgtk-3, and a Wayland compositor that advertises wlr-screencopy"
log "  arch:   sudo pacman -S ffmpeg libpulse gtk3"
log "  ubuntu: sudo apt install ffmpeg libpulse0 libgtk-3-0"
