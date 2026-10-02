# DeepWork Tracker

A macOS notch timer for deep work blocks, with a log of every block, intensity ratings, notes on how it felt, and a GitHub-style heatmap of the year.

<img src="docs/notch-collapsed.png" width="620" alt="Collapsed notch while a block runs">
<img src="docs/notch-running.png" width="620" alt="Expanded notch while a block runs">

## What it does

- **Lives in the notch.** Hover the notch to expand it. Pick a block length (25 / 50 / 90 / 120 min, or ∞ open-ended), name what you're working on, start.
- **Live activity while you work.** Collapsed, the notch grows two small wings: a progress ring on the left, the countdown on the right. Orange when paused, green once you pass your goal (it chimes and keeps counting overtime, so it never breaks your flow).
- **Log every block.** When you finish, the notch asks for:
  - **Intensity** 1–5 (Shallow · Light · Focused · Deep · Flow)
  - **Sensations** as quick tags (Flow, Energized, Calm, Clear-headed, Distracted, Tired, Restless, Breakthrough)
  - **Notes**: what helped, what pulled you out, how your body felt
  
  `⌘↩` saves.
- **Heatmap + log window.** Menu bar icon → *Log & Heatmap* (or the link in the notch). Three heatmap modes:
  - **Deep score**: minutes × intensity / 5. An hour at Flow counts more than an hour at Light.
  - **Hours**: raw time.
  - **Intensity**: average intensity for the day.
  
  Click a day to filter the log. Click a block to edit it or delete it. Stats: today, week, month, streak, 30-day average intensity, all time.
- **Survives restarts.** A running block is saved, so quitting or rebooting doesn't lose it. The timer auto-pauses when the Mac sleeps.

<img src="docs/notch-finish.png" width="620" alt="Finish form">
<img src="docs/dashboard.png" width="700" alt="Dashboard with heatmap and log">

## Build & install

Requires macOS 14+ and Swift 5.9+. Xcode's Command Line Tools are enough; you don't need full Xcode.

```bash
./scripts/build-app.sh            # builds build/DeepWork Tracker.app
./scripts/build-app.sh --install  # also copies it to /Applications and launches it
```

There's no Dock icon. Look for the 🧠 icon in the menu bar. *Launch at Login* is in that menu.

> If you run another notch app at the same time, they'll draw on top of each other. Quit the other one.

## Data

Everything is local, in one human-readable file:

```
~/Library/Application Support/DeepWorkTracker/sessions.json
```

```json
{
  "version": 1,
  "sessions": [
    {
      "id": "…", "start": "2026-10-03T09:12:00Z", "end": "2026-10-03T10:04:00Z",
      "duration": 3120, "plannedMinutes": 50, "task": "Thesis chapter 3",
      "intensity": 4, "tags": ["Flow", "Calm"], "notes": "Phone in another room helped."
    }
  ]
}
```

`duration` is in active seconds, excluding pauses. The format is deliberately simple so other clients (e.g. the Gears HUD watch app) can read and append to it. You can also export it as CSV from the dashboard.

## Development

```
Sources/DeepWorkTracker/
  AppDelegate.swift      menu bar item, dashboard window, app menu
  NotchController.swift  the floating panel over the notch, hover + click-through
  NotchViews.swift       collapsed / idle / running / finish UI
  TimerEngine.swift      timer state machine (idle → running ⇄ paused → finishing)
  SessionStore.swift     JSON persistence + stats
  DashboardView.swift    stats, heatmap card, log, editor
  HeatmapView.swift      53-week grid
  Components.swift       shared pieces (notch shape, intensity picker, tags…)
  Snapshots.swift        renders UI states to PNG with sample data
```

Render every UI state to PNGs without touching your real data (useful for checking UI changes):

```bash
swift build -c release && DEEPWORK_SNAPSHOT=/tmp/dw-shots .build/release/DeepWorkTracker
```

Regenerate the app icon: `swift scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns`

## Roadmap

- [ ] Gears HUD (Wear OS) companion: start/stop from the watch, sync `sessions.json`
- [ ] Global hotkey to start/finish a block
- [ ] Manual entry for blocks done away from the Mac
- [ ] Weekly review: intensity trends, best time of day, which tags go with high intensity
