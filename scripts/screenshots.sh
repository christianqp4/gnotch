#!/usr/bin/env bash
# Ubuntu-style screenshots on macOS, together with GNotch.
#
# GNotch does the important part: every new screenshot goes straight onto the clipboard
# (⌘V right away) and into the clipboard history. This script tunes macOS so it's instant:
#
#   enable   turn off the floating thumbnail (macOS otherwise waits ~5 s before saving the file),
#            and optionally save screenshots to a folder instead of cluttering the Desktop
#   disable  put the floating thumbnail back (location is left as is)
#   status   show the current settings
#
# Usage:
#   scripts/screenshots.sh enable                 # instant, keep current folder
#   scripts/screenshots.sh enable ~/Pictures/Screenshots
#   scripts/screenshots.sh disable
#   scripts/screenshots.sh status
#
# Docs: docs/SCREENSHOTS.md
set -euo pipefail

show_status() {
    local thumb location
    thumb=$(defaults read com.apple.screencapture show-thumbnail 2>/dev/null || echo "1 (default)")
    location=$(defaults read com.apple.screencapture location 2>/dev/null || echo "~/Desktop (default)")
    echo "Floating thumbnail: $thumb   (0 = off = instant)"
    echo "Save location:      $location"
    if pgrep -x GNotch >/dev/null; then echo "GNotch:             running"; else echo "GNotch:             not running"; fi
}

case "${1:-status}" in
    enable)
        defaults write com.apple.screencapture show-thumbnail -bool false
        if [[ -n "${2:-}" ]]; then
            folder="${2/#\~/$HOME}"
            mkdir -p "$folder"
            folder="$(cd "$folder" && pwd)"
            defaults write com.apple.screencapture location "$folder"
            killall SystemUIServer 2>/dev/null || true
        fi
        echo "Screenshots are now instant."
        show_status
        ;;
    disable)
        defaults write com.apple.screencapture show-thumbnail -bool true
        echo "Floating thumbnail is back."
        show_status
        ;;
    status)
        show_status
        ;;
    *)
        sed -n '2,20p' "$0"
        exit 1
        ;;
esac
