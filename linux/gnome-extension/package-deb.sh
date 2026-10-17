#!/usr/bin/env bash
# Builds dist/gnotch_<version>_all.deb (needs dpkg-deb, so run it on Ubuntu or in CI).
# Installs both builds under /usr/share/gnotch; postinst links the one for this GNOME into
# /usr/share/gnome-shell/extensions. Also: the app launcher, its icon, and `gnotch` on the PATH.
set -euo pipefail
cd "$(dirname "$0")"
UUID="gnotch@christianqp4.github.io"
node build.mjs >/dev/null
VERSION="$(node -p "require('./$UUID/metadata.json')['version-name']")"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/share/gnotch" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/icons/hicolor/256x256/apps" "$ROOT/usr/share/doc/gnotch"
cp -r build "$ROOT/usr/share/gnotch/"
find "$ROOT/usr/share/gnotch" -name '.DS_Store' -delete
install -m 755 "$UUID/gnotch-launch" "$ROOT/usr/bin/gnotch"
install -m 644 "$UUID/icons/gnotch.png" "$ROOT/usr/share/icons/hicolor/256x256/apps/gnotch.png"
sed "s|@LAUNCH@|gnotch|g" gnotch.desktop.in > "$ROOT/usr/share/applications/gnotch.desktop"
install -m 644 README.md "$ROOT/usr/share/doc/gnotch/README.md"
install -m 755 debian/postinst debian/postrm "$ROOT/DEBIAN/"

cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: gnotch
Version: $VERSION
Architecture: all
Maintainer: Christian <christianqp4@users.noreply.github.com>
Depends: gnome-shell (>= 42)
Recommends: libglib2.0-bin, libnotify-bin, zenity
Section: gnome
Priority: optional
Homepage: https://github.com/christianqp4/gnotch
Installed-Size: $(du -sk "$ROOT/usr" | cut -f1)
Description: GNotch: deep-work timer, clipboard and vision board in the top bar
 The GNotch notch app for GNOME Shell: a deep-work timer with drift tracker,
 breathing guide and heatmap, clipboard history and a vision board, next to
 the clock. Shares its data formats with GNotch for macOS.
CONTROL

mkdir -p dist
dpkg-deb --root-owner-group --build "$ROOT" "dist/gnotch_${VERSION}_all.deb" >/dev/null
echo "dist/gnotch_${VERSION}_all.deb"
