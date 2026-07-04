# Codex Usage Tracker

A minimal macOS **menu-bar** app that shows your OpenAI **Codex** usage, using the
same display style as [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker): a circular
ring with the usage percentage in the center.

## What it shows

**Menu bar (the ring):**
- **Center number** — current session usage percent (the 5-hour window).
- **Ring color** — green (< 50%), orange (50–80%), red (≥ 80%).
- **Outer tick** — how far the current 5-hour window has elapsed.

**Popover (click the icon):**
- **Session** — usage of the 5-hour window, with time until reset.
- **Weekly** — usage across all models, with time until reset.
- Plan badge (e.g. `PLUS`), last-updated time, Refresh, and Quit.

## Where the data comes from

No network calls, no credentials. Codex's CLI writes session "rollout" logs under
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Each API turn appends a
`token_count` event carrying a `rate_limits` object:

```json
"rate_limits": {
  "primary":   { "used_percent": 90.0, "window_minutes": 300,   "resets_at": 1783176273 },
  "secondary": { "used_percent": 19.0, "window_minutes": 10080, "resets_at": 1783410496 },
  "plan_type": "plus"
}
```

`primary` is the 5-hour session window; `secondary` is the weekly window. The app
scans the most recently modified rollout files and uses the entry with the newest
timestamp (a resumed/idle session may contain none, so it looks across several).

Set `CODEX_HOME` to override the `~/.codex` location.

> The numbers are only as fresh as your last Codex API call. If you haven't used
> Codex in a while, the popover's "Updated …" line tells you how stale they are.

## Build & run

Requires Swift 6 / Xcode command-line tools.

```sh
./build-app.sh          # build + bundle -> build/Codex Usage.app
./build-app.sh run      # build, bundle, and (re)launch
./build-app.sh install  # build, bundle, and copy to /Applications
```

The app runs as an `LSUIElement` (menu-bar only, no Dock icon). Quit it from the
popover's **Quit** button.

## Note on notched Macs

macOS hides menu-bar items that don't fit around the notch. If you run many
menu-bar apps, this icon may be hidden — free up space or use a manager like
[Ice](https://github.com/jordanbaird/Ice)/Bartender to reveal it.

## Layout

```
Sources/CodexUsageTracker/
  main.swift                 App entry (accessory activation policy)
  AppDelegate.swift          Creates the menu-bar controller
  CodexUsage.swift           Model: rate windows, status thresholds, elapsed fraction
  CodexUsageReader.swift     Reads ~/.codex rollout logs -> freshest rate_limits
  MenuBarIconRenderer.swift  Draws the ring (center %, color, elapsed tick)
  MenuBarController.swift     NSStatusItem + refresh timer + popover
  UsageStore.swift           ObservableObject bridging to SwiftUI
  PopoverView.swift          SwiftUI detail panel
```
