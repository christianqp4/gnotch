# GNotch

The Gears notch app for macOS: a deep-work timer with intensity log and heatmap, clipboard history with Ubuntu-style screenshots, and a vision board. Formerly "DeepWork Tracker".

## Status
<!-- gears:status: read by the GearsOS dashboard. Update it at the end of any session that changes where this project stands. -->
- **Stage:** v0.6.0 · installed in /Applications · timer with drift tracker (pause = drift, breathing guide, ⌃⌥P), place tags, heatmap in year or calendar view (ISO week numbers, hover a day for its blocks), clipboard with Ubuntu-style screenshots, widget vision board · Ubuntu: GNOME Shell extension (GNOME 42–49) with the same three pages, big mode and progress around the indicator in `linux/gnome-extension`; 0.6.0 froze GNOME 42 and ended the session when switching to the clipboard page (scroll view attached with set_child); 0.6.1 fixes that, hardens rendering and adds an app launcher; 0.6.2 also ships as a .deb (built and test-installed in CI; on 22.04 install it with apt, double-click only opens Archive Manager; xz-compressed since 0.6.3); not yet tried on Ubuntu
- **Gate:** in-use
- **Next:** Try GNOME 0.6.3 on Ubuntu (.deb install too) (clipboard, vision board, hover, breathing) and fix what breaks. Log a week of real deep-work blocks (watch drifts per hour), then decide whether the Gears HUD watch companion is worth building.
- **Updated:** 2026-10-17
<!-- /gears:status -->

## Part of GearsOS
Hub and project map: `~/gears_OS` ([GitHub](https://github.com/christianqp4/GearsOS)), registry id `gnotch`.
- Connects to: `gears-hud-wearos`: planned companion (start/stop from the watch, share `sessions.json`; see the README roadmap). `gearsos`: deep-work blocks are a stats source for Gears.

## Working here
- Read [README.md](README.md) first: features, data format, source layout, roadmap. Add each release to [CHANGELOG.md](CHANGELOG.md).
- Swift package, macOS 14+. Build `./scripts/build-app.sh`; install and relaunch with `./scripts/build-app.sh --install`.
- Ubuntu version: [linux/gnome-extension/README.md](linux/gnome-extension/README.md). Logic tests: `node --test linux/gnome-extension/test/core.test.mjs`. It must keep writing dates without milliseconds (the Mac decoder rejects them). Read the GNOME-version pitfalls in its README before touching the UI (scroll views, images, re-rendering).
- Check UI changes without touching real data: `swift build -c release && GNOTCH_SNAPSHOT=/tmp/gnotch-shots .build/release/GNotch`. README screenshots in `docs/` are crops of those snapshots. (`scripts/screenshots.sh` is unrelated: it changes the user's macOS screenshot settings, so don't run it.)
- User data lives outside the repo in `~/Library/Application Support/GNotch/`. Never commit it, never break the `sessions.json` format (other clients will read it), and keep the migration from DeepWork Tracker working.
- The clipboard skips password managers and concealed items. Keep it that way.
- Private repository. Commit or push only when Chris asks.
