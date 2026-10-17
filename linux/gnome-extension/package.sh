#!/usr/bin/env bash
# Builds dist/gnotch-gnome-<version>.zip: both builds (GNOME 42–44 and 45+), install.sh and the README.
set -euo pipefail
cd "$(dirname "$0")"
UUID="gnotch@christianqp4.github.io"
node build.mjs >/dev/null
VERSION="$(node -p "require('./$UUID/metadata.json')['version-name']")"
rm -rf dist && mkdir -p dist
zip -qr "dist/gnotch-gnome-$VERSION.zip" build install.sh gnotch.desktop.in README.md -x '*.DS_Store'
echo "dist/gnotch-gnome-$VERSION.zip"
