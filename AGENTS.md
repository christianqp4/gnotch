# GNotch

The Gears notch app for macOS: a deep-work timer with intensity log and heatmap, clipboard history with Ubuntu-style screenshots, and a vision board. Formerly "DeepWork Tracker".

## Status
<!-- gears:status: read by the GearsOS dashboard. Update it at the end of any session that changes where this project stands. -->
- **Stage:** v0.5.0 · installed in /Applications · timer with drift tracker (pause = drift, breathing guide, ⌃⌥P) and place tags, clipboard with Ubuntu-style screenshots, widget vision board · Ubuntu: GNOME Shell extension (timer, drifts, places, heatmap) in `linux/gnome-extension`, not yet run on a real Ubuntu machine
- **Gate:** in-use
- **Next:** Install the GNOME extension on Ubuntu and fix whatever breaks there (first real run). Log a week of real deep-work blocks (watch drifts per hour), then decide whether the Gears HUD watch companion is worth building.
- **Updated:** 2026-10-12
<!-- /gears:status -->

## Part of GearsOS
Hub and project map: `~/gears_OS` ([GitHub](https://github.com/christianqp4/GearsOS)), registry id `gnotch`.
- Connects to: `gears-hud-wearos`: planned companion (start/stop from the watch, share `sessions.json`; see the README roadmap). `gearsos`: deep-work blocks are a stats source for Gears.

## Working here
- Read [README.md](README.md) first: features, data format, source layout, roadmap.
- Swift package, macOS 14+. Build `./scripts/build-app.sh`; install and relaunch with `./scripts/build-app.sh --install`.
- Ubuntu version: [linux/gnome-extension/README.md](linux/gnome-extension/README.md). Logic tests: `node --test linux/gnome-extension/test/core.test.mjs`. It must keep writing dates without milliseconds (the Mac decoder rejects them).
- Check UI changes without touching real data: `swift build -c release && GNOTCH_SNAPSHOT=/tmp/gnotch-shots .build/release/GNotch`. README screenshots in `docs/` are crops of those snapshots. (`scripts/screenshots.sh` is unrelated: it changes the user's macOS screenshot settings, so don't run it.)
- User data lives outside the repo in `~/Library/Application Support/GNotch/`. Never commit it, never break the `sessions.json` format (other clients will read it), and keep the migration from DeepWork Tracker working.
- The clipboard skips password managers and concealed items. Keep it that way.
- Private repository. Commit or push only when Chris asks.
