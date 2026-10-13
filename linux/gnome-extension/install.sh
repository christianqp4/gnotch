#!/usr/bin/env bash
# Installs GNotch for GNOME Shell (Ubuntu 23.10+ / GNOME 45+) for the current user.
# Run from a clone of the repo, or next to an unpacked release zip.
set -euo pipefail
UUID="gnotch@christianqp4.github.io"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/$UUID"
DEST="$HOME/.local/share/gnome-shell/extensions/$UUID"

[ -d "$SRC" ] || { echo "Can't find $SRC" >&2; exit 1; }
mkdir -p "$DEST"
cp -r "$SRC"/. "$DEST"/
echo "Installed to $DEST"

if gnome-extensions enable "$UUID" 2>/dev/null; then
  echo "Enabled. If you don't see the icon in the top bar, log out and back in (Wayland needs that the first time)."
else
  echo "Now log out and back in, then run:  gnome-extensions enable $UUID"
fi
