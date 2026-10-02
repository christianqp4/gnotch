#!/usr/bin/env bash
# Builds "DeepWork Tracker.app" into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/DeepWork Tracker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DeepWorkTracker "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x DeepWorkTracker 2>/dev/null || true
    rm -rf "/Applications/DeepWork Tracker.app"
    cp -R "$APP" /Applications/
    open "/Applications/DeepWork Tracker.app"
    echo "Installed to /Applications and launched"
fi
