# Changelog

GNotch ships as two apps sharing one data format: the macOS app (tags `vX.Y.Z`) and the Ubuntu / GNOME Shell extension (tags `gnome-vX.Y.Z`). Downloads are on the repo's Releases page.

## Unreleased (macOS)

**New: turn keep-awake on and off from GNotch.** Click the cup, then 1 h, 2 h, 4 h, 12 h or No limit: GNotch runs `caffeinate -is` (no idle sleep; no system sleep on AC), and the cup turns green with the time left. Pick another length to replace it, or Turn off, which stops every `caffeinate` holding the Mac (only processes named caffeinate). The same choices are in the menu bar under Keep Awake, with the state in its title. The `caffeinate` keeps running if GNotch quits or is reinstalled. A closed lid still sleeps. The cup moved to the right of the top band, next to Today, so the question bubble no longer squeezes it, and the open notch is a bit wider (timer 580, clipboard 600, vision 580, questions 580 pt).

**New: Recordatorios.** A few silent reminders a night, set per weekday (menu bar → *Recordatorios…*): *Cerrar el día* (opens the question queue, only when questions are open), *Desconexión* (sleep kit) and *Último aviso*. Defaults: Mon–Thu 21:30 / 23:30 / 00:00; Fri–Sun shift nights 23:30 / 00:15 / 00:45. After the night's last reminder GNotch stays quiet until 07:00: no question bubble, calendar line or alerts, no goal peek. Plus the calendar: the event on now or coming within 2 hours as one line in the notch, and an optional alert 10 min before, read from macOS Calendar (Google via Internet Accounts) with EventKit. Nothing else notifies; no sound.

**New: questions from the chats.** A quiet queue in the notch for the yes/no questions the Gears chats ask to close tasks. A blue bubble with a count shows in the top band while questions are open; click it or press ⌃⌥Q for one card at a time: Y / N or 1–9 to pick, an optional comment, ↩ for the next. → leaves one for later, ← changes the last answer. Its reminder is *Cerrar el día*, below. Questions live in `~/gears_OS/dashboard/questions.json`; GNotch only shows them and writes the answers back, re-reading the file right before each write so questions a chat just appended are never lost. Long questions and long option labels show in full: the card grows with them instead of cutting the text, and web links in a question are blue and open in the browser on click (10 Nov).

**Fixed: screenshots stopped silently when macOS denied access to their folder.** If the folder can't be opened (for example after "Don't Allow" on the Desktop prompt), the Screenshots tab and the menu bar now say so, with a button to System Settings → Files & Folders, and GNotch retries every 5 s, so screenshots resume as soon as access is allowed.

**New: keep-awake status.** A cup in the notch's top band, on every page, says whether the Mac will stay awake: On when a real `caffeinate` holds it (with the time left), Claude when only the Claude app does, Off otherwise. Other holders like WhatsApp's camera, Handoff or the display being on are listed but don't count. Hover or click for time left, AC or battery, and the conditions for driving chats from the phone. It reads `pmset` when the notch opens and every 30 s while it's open.

**New: Text to .md.** Type a title, paste a long text, press ⌘↩: you get a Markdown file saved in `~/Documents/Journaling` (changeable) and on the clipboard as a file, ready to paste. ⌃⌥M or the **.md** button on the clipboard page. The file is `# title` plus the text byte for byte; the name comes from the title, accents included; an existing name gets ` (2)` instead of being overwritten. The file shows in the history as a file tile and replaces the text entry left by copying the same text.

**New: today's timeline.** Under the notch heatmap, one line says when the Mac was first opened today and when Claude first opened, with a midnight-to-midnight strip of when the Mac was on. Hover it for the full list (screen on/off, sleep/wake, shutdown, boot, login, app opens). GNotch logs these moments to `timeline.jsonl` from now on, and reads the earlier ones from the system: wtmp (boot, shutdown, console login), `pmset -g log` (screen, sleep, wake) and running apps' launch times. No Full Disk Access needed. Other apps: `defaults write com.christianqp4.GNotch timelineApps -array …`.

## Ubuntu 0.6.3 · 2026-10-17

**Fixed: the `.deb` instructions.** On Ubuntu 22.04, double-clicking a `.deb` opens it in the Archive Manager (which just shows `control.tar`, `data.tar` and `debian-binary`) instead of installing it. Install it with:

```
sudo apt install ./gnotch_0.6.3_all.deb
```

Or, for double-click installs, `sudo apt install gdebi` once and open the `.deb` with GDebi.
- The `.deb` is now compressed with xz (it was zstd, the default where CI builds it), which every Ubuntu and Debian version reads.
- No changes in the extension itself.

## Ubuntu 0.6.2 · 2026-10-17

**New: a `.deb` package**, next to the zip. Install it with `sudo apt install ./gnotch_0.6.2_all.deb` (double-clicking only opens it on 22.04, see 0.6.3); remove it with `sudo apt remove gnotch`. It installs for every user, adds GNotch to your apps, and puts `gnotch` on the PATH (`gnotch clipboard` opens the clipboard page). The README explains both ways to install and how installing works on Ubuntu.
- Opening GNotch from your apps right after installing switches the extension on and tells you to log out and back in once.
- No code changes in the extension itself since 0.6.1.

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
