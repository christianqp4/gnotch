# Changelog

GNotch ships as two apps sharing one data format: the macOS app (tags `vX.Y.Z`) and the Ubuntu / GNOME Shell extension (tags `gnome-vX.Y.Z`). Downloads are on the repo's Releases page.

## Ubuntu 0.6.1 · 2026-10-17

**Fixed: switching to the clipboard page froze GNOME 42 and ended the session.**
- *Cause:* the clipboard and vision board pages hold a scrolling list. On GNOME 42–45 a scroll view only lays out its content when it's attached with `add_actor()`; 0.6.0 used `set_child()` (the GNOME 46 way), so GNOME never sized or drew the list and got stuck on it. Because GNOME Shell is also what draws the screen on Ubuntu, a stuck extension takes the whole session down.
- *Fix:* the extension now attaches scroll content the way each GNOME version expects (`add_actor()` on 42–45, `set_child()` on 46+), checked against GNOME's source.

**Hardened against freezes**
- Images in the clipboard and vision board are shown as small thumbnails made in a background thread and cached in `~/.cache/gnotch/thumbs` (before, St decoded every screenshot at full size on the shell's main thread).
- Rebuilding the card waits until the click that caused it has finished, and merges several changes into one rebuild; keyboard focus leaves text entries before they're removed.
- Heatmap cells share stylesheet classes instead of ~400 inline styles; clipboard search waits for a pause in typing; clipboard images are saved in the background; texts over 200,000 characters aren't kept.

**New: GNotch in your apps**
- Search "GNotch" (or "deep work", "clipboard") in Activities to open the timer. Pin it to the dock; right-click for Timer, Clipboard, Vision board and *I drifted*. Same icon as the Mac app.
- `./install.sh --uninstall` removes the extension and the launcher (data stays).

## macOS 0.6.0 · Ubuntu 0.6.0 · 2026-10-13

- **Heatmap, two views**: the GitHub-style year (month names, week numbers 1/10/20/…/this week) or month calendars read left to right with every ISO week numbered and days ahead outlined. "Week 42/53" in the header.
- **Hover a day** for its date, total and each block's time and intensity.
- **Mac**: the progress line is drawn just outside the notch, so the camera housing no longer hides it.
- **Ubuntu**: clipboard and vision board pages (⌃⌥V, ⌃⌥B), big mode (⤢), the block's progress traced around the top bar indicator, the breathing guide fixed (it didn't move on GNOME 42).

## Ubuntu 0.5.1 · 2026-10-13

- Works on GNOME 42–44 (Ubuntu 22.04): a second build with GNOME 42's module system; `install.sh` picks the right one.
- The timer sits right after the clock by default, with a switch to move it next to the system icons.

## Ubuntu 0.5.0 · 2026-10-13

- First Ubuntu version, as a GNOME Shell extension: timer, drift tracker with breathing guide, finish form with places, 24-week heatmap. Same `sessions.json` format as the Mac.

## macOS 0.5.0 · 2026-10-05 to 2026-10-06

- **Drift tracker**: pausing logs a drift, with a breathing guide (⌃⌥P); drifts per focused hour on the dashboard.
- **Place tags**: where each block happened, compared on the dashboard.

## macOS 0.4.0 · 2026-10-03

- Renamed from DeepWork Tracker to GNotch. Notch pages: timer, clipboard (with Ubuntu-style screenshots), vision board. Progress traced along the notch, sounds, big timer mode, past blocks.
