#!/usr/bin/env bash
# Installs GNotch for GNOME Shell for the current user, picking the build that fits this GNOME:
# build/42 for GNOME 42–44 (Ubuntu 22.04), build/45 for GNOME 45+ (Ubuntu 23.10 and later).
# Also adds GNotch to the app grid, so you can search for it in Activities and pin it to the dock.
# Run it from an unzipped release, or from a clone of the repo (needs Node.js there to build first).
#   ./install.sh              install or update
#   ./install.sh --uninstall  remove the extension and the launcher (your data stays)
set -euo pipefail
UUID="gnotch@christianqp4.github.io"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.local/share/gnome-shell/extensions/$UUID"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor"
DESKTOP="$APPS/gnotch.desktop"

refresh_launchers() {
  update-desktop-database "$APPS" >/dev/null 2>&1 || true
  gtk-update-icon-cache -f -t "$ICONS" >/dev/null 2>&1 || true
}

if [ -e /usr/share/gnome-shell/extensions/$UUID ] && [ "${1:-}" != "--uninstall" ]; then
  echo "GNotch is already installed from the .deb package. Update it with the new .deb instead" >&2
  echo "(or remove it first: sudo apt remove gnotch)." >&2
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  gnome-extensions disable "$UUID" 2>/dev/null || true
  rm -rf "$DEST"
  rm -f "$DESKTOP" "$ICONS/256x256/apps/gnotch.png"
  refresh_launchers
  echo "GNotch removed. Your data is still in ~/.local/share/gnotch (delete it yourself if you want)."
  exit 0
fi

MAJOR="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
if [ -z "$MAJOR" ]; then
  echo "Couldn't find gnome-shell. GNotch needs the GNOME desktop (Ubuntu's default)." >&2; exit 1
fi
if [ "$MAJOR" -lt 42 ]; then
  echo "GNOME $MAJOR is too old: GNotch needs GNOME 42 or newer (Ubuntu 22.04+)." >&2; exit 1
fi
VARIANT=$([ "$MAJOR" -ge 45 ] && echo 45 || echo 42)

if [ ! -d "$HERE/build/$VARIANT/$UUID" ]; then
  if command -v node >/dev/null; then
    node "$HERE/build.mjs" >/dev/null
  else
    echo "No build/ folder here. Download the release zip instead (it includes it), or install Node.js." >&2; exit 1
  fi
fi

rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$HERE/build/$VARIANT/$UUID"/. "$DEST"/
chmod +x "$DEST/gnotch-launch"
echo "Installed GNotch for GNOME $MAJOR to $DEST"

# App launcher: Activities search, app grid, dock (right-click for the pages).
mkdir -p "$APPS" "$ICONS/256x256/apps"
cp "$DEST/icons/gnotch.png" "$ICONS/256x256/apps/gnotch.png"
LAUNCH="$DEST/gnotch-launch"
sed "s|@LAUNCH@|\"$LAUNCH\"|g" "$HERE/gnotch.desktop.in" > "$DESKTOP"
refresh_launchers
echo "Added GNotch to your apps: search for it in Activities, or pin it to the dock."

gnome-extensions enable "$UUID" 2>/dev/null || true
echo
echo "Next: log out and back in. Then GNotch shows up next to the clock."
echo "If it doesn't:  gnome-extensions enable $UUID"
echo "Still nothing:  gnome-extensions info $UUID   (and send the output)"
