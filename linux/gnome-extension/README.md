# GNotch for Ubuntu (GNOME Shell extension)

The GNotch deep-work timer in the Ubuntu top bar. Ubuntu has no notch, so the timer lives next to the clock area: an icon, the countdown, and orange dots for drifts. Click it (or press **⌃⌥D**) for the full card.

Works on GNOME 45 to 49: Ubuntu 23.10, **24.04 LTS**, 24.10, 25.04, 25.10.

## What's in it (v0.5.0)

- **Blocks**: 25 / 50 / 90 / 120 min or ∞ open-ended, with a task name. Countdown in the top bar, `+overtime` after the goal (with a chime and a notification).
- **Drift tracker**: *I drifted* (or **⌃⌥P** from anywhere) pauses the block and logs a drift. The card turns into a breathing guide (4 s in, 6 s out) until you go back to focus. The drift bar shows focus in green and drifts in orange. Suspending the computer pauses too, but that isn't counted as a drift.
- **Finish form**: intensity 1–5, sensation tags, place (Library, House, Coworking, Coffee, or your own), notes.
- **Heatmap**: the last 24 weeks (deep score), plus today, this week and your streak.
- **Survives restarts**: a running block is saved and picks up where it left off.

Not in the Ubuntu version yet: the dashboard/log window, adding past blocks, focus sounds, clipboard history and the vision board. For screenshots you don't need GNotch on Ubuntu: Ubuntu's screenshot tool (Print Screen) already copies every screenshot to the clipboard.

## Install

1. Download `gnotch-gnome-<version>.zip` from the repo's **Releases** page (you need to be a collaborator on the private repo).
2. Unzip it and run the installer:
   ```bash
   unzip gnotch-gnome-*.zip -d gnotch && cd gnotch && ./install.sh
   ```
3. **Log out and back in** (on Wayland, GNOME only loads new extensions at login).
4. If the icon isn't in the top bar yet: `gnome-extensions enable gnotch@christianqp4.github.io`

Update: same steps with the new zip. Uninstall: `gnome-extensions uninstall gnotch@christianqp4.github.io`.

From a clone instead of a zip: `./linux/gnome-extension/install.sh`.

## Data

```
~/.local/share/gnotch/sessions.json   the blocks (same format as the Mac app)
~/.local/share/gnotch/state.json      the running block, last place, your places
```

`sessions.json` is the same file format as on the Mac (`~/Library/Application Support/GNotch/sessions.json`), so you can copy it between machines in either direction. Dates are written without milliseconds because the Mac app requires that. The extension re-reads the file before every save, so blocks another client added aren't lost, and a file it can't read is backed up instead of overwritten.

## Development

```
gnotch@christianqp4.github.io/
  extension.js   top bar indicator, popup card, shortcuts, sleep watcher
  core.js        timer state machine, sessions.json format, stats (no GNOME imports)
  stylesheet.css
test/core.test.mjs
install.sh, package.sh
```

```bash
node --test linux/gnome-extension/test/core.test.mjs   # logic tests, run anywhere
linux/gnome-extension/package.sh                       # builds dist/gnotch-gnome-<version>.zip
```

To try changes on Ubuntu: `./install.sh`, then on Wayland run a nested shell (`dbus-run-session -- gnome-shell --nested --wayland` on GNOME 45–48, `--devkit` on 49) or log out and in. Logs: `journalctl -f -o cat /usr/bin/gnome-shell`.

**Release**: push a tag like `gnome-v0.5.0`. The GitHub workflow runs the tests, builds the zip and attaches it to a release.
