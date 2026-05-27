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

# --- GNOME-only: install + enable the OneCap Pin shell extension. --------
# Mutter ignores `gtk_window_set_keep_above` over fullscreen apps, so the
# control bar disappears when a fullscreen window covers it. The tiny
# bundled GNOME Shell extension re-raises the bar on every restack /
# fullscreen change so it stays visible.
#
# Skipped on niri / Hyprland / sway / wayfire / river / KDE — those
# compositors already honor keep_above + an extension would be dead code.
is_gnome_session() {
    local d="${XDG_CURRENT_DESKTOP:-}${XDG_SESSION_DESKTOP:-}"
    case "${d,,}" in
        *gnome*|*unity*|*ubuntu*) return 0 ;;
        *) return 1 ;;
    esac
}

install_gnome_extension() {
    # Runs only on GNOME. All steps idempotent — safe to re-run after every
    # install/upgrade. Extension files just get overwritten with the latest
    # version; gnome-extensions enable is a no-op if already enabled.
    local EXT_UUID="onecap-pin@local"
    local EXT_DIR="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
    local EXT_BASE
    if [[ "$VERSION" == "latest" ]]; then
        EXT_BASE="https://raw.githubusercontent.com/$REPO/main/extras/gnome-shell-extension/$EXT_UUID"
    else
        EXT_BASE="https://raw.githubusercontent.com/$REPO/$VERSION/extras/gnome-shell-extension/$EXT_UUID"
    fi
    log "GNOME detected → installing/refreshing $EXT_UUID extension"
    mkdir -p "$EXT_DIR"
    # Download to temp first, then move into place atomically. Avoids leaving
    # a half-written extension.js if the second curl fails on a flaky network.
    local tmp_meta tmp_ext
    tmp_meta=$(mktemp) || return 0
    tmp_ext=$(mktemp)  || { rm -f "$tmp_meta"; return 0; }
    if ! curl -fsSL -o "$tmp_meta" "$EXT_BASE/metadata.json" \
        || ! curl -fsSL -o "$tmp_ext"  "$EXT_BASE/extension.js"; then
        rm -f "$tmp_meta" "$tmp_ext"
        log "warn: could not download $EXT_UUID files; skipping (main install OK)"
        return 0
    fi
    mv -f "$tmp_meta" "$EXT_DIR/metadata.json"
    mv -f "$tmp_ext"  "$EXT_DIR/extension.js"

    # Try to enable now. gnome-shell may not have rescanned the extensions
    # dir yet (Wayland sessions can't restart shell without logout), so this
    # often returns "extension does not exist" on first install. The user
    # then re-runs after logout. Either way: never abort.
    if command -v gnome-extensions >/dev/null 2>&1; then
        # Detect re-install: extension already known to gnome-shell. The new
        # extension.js sits on disk but the running shell still has the OLD
        # one loaded — needs a session restart to swap in fresh code.
        local was_known=0
        if gnome-extensions info "$EXT_UUID" >/dev/null 2>&1; then
            was_known=1
        fi

        if gnome-extensions enable "$EXT_UUID" 2>/dev/null; then
            if [[ "$was_known" == "1" ]]; then
                log "$EXT_UUID re-installed (old code still loaded; log out + back in to pick up the new version)"
            else
                log "$EXT_UUID enabled"
            fi
        else
            log "$EXT_UUID files staged; log out + back in once, then run:"
            log "  gnome-extensions enable $EXT_UUID"
        fi
    fi
}

# Wrap in a guard so a non-zero return from anything inside cannot kill the
# whole script (we're under `set -e`). niri / Hyprland / sway / wayfire /
# river / KDE never enter this branch — they already honor keep_above.
if is_gnome_session; then
    install_gnome_extension || true
else
    log "non-GNOME session → skipping GNOME Shell extension (not needed here)"
fi
# -------------------------------------------------------------------------

log "done. launch 'one-cap' from your app menu, or run: $BIN_DIR/one-cap --help"
log "you also need ffmpeg, libpulse, libgtk-3, and a Wayland compositor that advertises wlr-screencopy"
log "  arch:   sudo pacman -S ffmpeg libpulse gtk3"
log "  ubuntu: sudo apt install ffmpeg libpulse0 libgtk-3-0"
