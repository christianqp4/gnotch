#!/usr/bin/env bash
# Installs GNotch for GNOME Shell for the current user, picking the build that fits this GNOME:
# build/42 for GNOME 42–44 (Ubuntu 22.04), build/45 for GNOME 45+ (Ubuntu 23.10 and later).
# Run it from an unzipped release, or from a clone of the repo (needs Node.js there to build first).
set -euo pipefail
UUID="gnotch@christianqp4.github.io"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.local/share/gnome-shell/extensions/$UUID"

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
echo "Installed GNotch for GNOME $MAJOR to $DEST"

gnome-extensions enable "$UUID" 2>/dev/null || true
echo
echo "Next: log out and back in. Then GNotch shows up next to the clock."
echo "If it doesn't:  gnome-extensions enable $UUID"
echo "Still nothing:  gnome-extensions info $UUID   (and send the output)"
