# Screenshots, the Ubuntu way

On Ubuntu a screenshot is saved **and** copied, so you can paste it right away with Ctrl+V.
On macOS you normally have to find the file first. GNotch fixes that.

## What GNotch does

- **Every new screenshot is on your clipboard.** Take one with ⇧⌘3, ⇧⌘4 or ⇧⌘5 and press ⌘V anywhere. The notch flashes 📷 *Copied*.
- **It's in your clipboard history** as an image, so you can copy it again later.
- **All your previous screenshots** are under **Clipboard → Screenshots** in the notch (⌃⌥V). Click one to copy it, drag it into any app, or right-click → *Show in Finder* / *Add to Vision Board*.
- The original file is still saved where macOS normally saves it.

Turn it on or off: menu bar icon → **Screenshots → Clipboard**.

GNotch finds screenshots by the tag macOS puts on every screenshot file (`kMDItemIsScreenCapture`), so it works whatever language your Mac uses for file names. It watches the folder set in the Screenshot app (⇧⌘5 → Options → Save to), or the Desktop.

## Make it instant

By default macOS shows a floating thumbnail for about 5 seconds and only **then** saves the file, so the copy happens 5 seconds late. Turn the thumbnail off:

- menu bar icon → **Instant Screenshots (no floating thumbnail)**, or
- run the script in this repo:

```bash
scripts/screenshots.sh enable                          # instant
scripts/screenshots.sh enable ~/Pictures/Screenshots   # instant, and keep the Desktop clean
scripts/screenshots.sh status
scripts/screenshots.sh disable                         # thumbnail back
```

These are the same settings as ⇧⌘5 → Options; nothing else on the system is touched.

## Built-in alternative

Hold **⌃ (Control)** with any screenshot shortcut (⌃⇧⌘4) and macOS copies to the clipboard **instead of** saving a file. GNotch's clipboard history picks those up too. The difference: with GNotch's approach you get both, the file *and* the clipboard.
