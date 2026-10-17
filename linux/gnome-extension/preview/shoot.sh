#!/usr/bin/env bash
# Renders preview.html in headless Chrome to ../docs/gnome-<state>.png (2x).
set -euo pipefail
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
mkdir -p ../docs
rm -f ../docs/gnome-*.png
while read -r s h; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --virtual-time-budget=4000 --allow-file-access-from-files --window-size=1200,"$h" \
    --screenshot="$PWD/../docs/gnome-$s.png" "file://$PWD/preview.html?s=$s" 2>/dev/null
  echo "docs/gnome-$s.png"
done <<'LIST'
placement 440
launcher 400
dock-menu 420
idle 680
idle-calendar 700
idle-hover 680
running 470
paused 600
finish 800
large 800
large-calendar 1010
large-paused 620
clipboard 720
clipboard-large 700
vision 730
vision-large 1000
LIST
