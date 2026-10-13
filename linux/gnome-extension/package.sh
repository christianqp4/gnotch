#!/usr/bin/env bash
# Builds dist/gnotch-gnome-<version>.zip: the extension folder plus install.sh.
set -euo pipefail
cd "$(dirname "$0")"
UUID="gnotch@christianqp4.github.io"
VERSION="$(python3 -c "import json;print(json.load(open('$UUID/metadata.json'))['version-name'])")"
rm -rf dist && mkdir -p dist
zip -qr "dist/gnotch-gnome-$VERSION.zip" "$UUID" install.sh README.md -x '*.DS_Store'
echo "dist/gnotch-gnome-$VERSION.zip"
