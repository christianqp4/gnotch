#!/usr/bin/env bash
# Builds "GNotch.app" into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/GNotch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GNotch "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x GNotch 2>/dev/null || true
    # Older builds were called "DeepWork Tracker"; two notch apps would fight over the notch.
    pkill -x DeepWorkTracker 2>/dev/null || true
    rm -rf "/Applications/DeepWork Tracker.app"
    rm -rf "/Applications/GNotch.app"
    cp -R "$APP" /Applications/
    open "/Applications/GNotch.app"
    echo "Installed to /Applications and launched"
fi
