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

Usage is read live from the ChatGPT backend — the same endpoint the Codex CLI
uses — with the token of each account the app knows about:

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access_token>      # from ~/.codex/auth.json
ChatGPT-Account-Id: <account_id>
```

Windows are classified by their length (`limit_window_seconds`), never by their
`primary`/`secondary` slot, because Codex does not keep them in fixed slots.

When the API can't be reached (and as a backstop for accounts with no auth),
the app falls back to the CLI's local session "rollout" logs under
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

## Auto-start at reset

Codex's limits are **rolling** windows: a new window does not begin when the old
one expires, it begins on the **first request after** that — the server stamps
`reset_at` then and never moves it (polling `/wham/usage` does not re-anchor it).
So a week you don't touch until Friday now resets the *following* Friday, and the
reset drifts later every cycle.

With **自動開始** ticked in the popover footer (on by default), the app watches for
a window whose `reset_at` has passed and sends one throwaway request — `"hi"`, no
tools, `store: false` — so the new window is anchored right away. It's the same
trick as Claude Usage Tracker's auto-start-session, keyed on the weekly window
instead of the 5-hour one.

The request is pinned to **`gpt-5.6-luna` at `low` effort**. That model is checked
against the account's own catalog (`GET /backend-api/codex/models?client_version=…`);
if it's ever gone, the ranking falls back to the cheapest models the plan allows
(`mini`/`nano` first, cheapest supported effort), then to the `model` in
`~/.codex/config.toml`. A 400 — the request was refused before it ran, so nothing
was charged — moves on to the next candidate.

**Exactly once per window** is the whole game, since this is the only thing in the
app that spends quota. The rules, all in `CodexAutoStartPolicy` (pure, unit-tested):

- The expired window's `reset_at` is the key. Once a start is recorded against it
  in `~/Library/Application Support/CodexUsageTracker/auto-start.json`, that
  boundary can never fire again — across polls, relaunches, and sleep/wake.
- A window with `reset_at` in the future is already running: nothing is sent.
- A failed usage fetch never triggers a send (an offline cache looks "expired"
  forever).
- Attempts are counted *before* the request goes out, capped at 3 per window and
  spaced 10 minutes apart, so a crash or a persistent failure can't turn into a
  stream of requests.
- Only a stream that reports a completed response counts as a start; a 2xx that
  died mid-stream anchored nothing and is retried within that cap.

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
Sources/CodexUsageCore/        Pure Foundation, no AppKit — unit-tested
  CodexUsage.swift             Model: rate windows, status thresholds, elapsed fraction
  CodexUsageAPI.swift          Live /wham/usage fetch + window classification
  CodexUsageReader.swift       Reads ~/.codex rollout logs -> freshest rate_limits
  CodexUsageProvider.swift     Live API first, local files as fallback
  CodexUsageCache.swift        Last-known-good usage per account
  CodexAuth.swift              Reads/writes ~/.codex/auth.json, decodes JWT claims
  CodexAccount.swift           A stored account (identity + tokens)
  CodexAccountStore.swift      accounts.json persistence
  CodexAccountService.swift    Reconcile / fetch usage / switch / add via codex login
  CodexTokenRefresher.swift    OAuth refresh
  CodexAutoStart.swift         Exactly-once policy + state for the reset auto-start
  CodexSessionStarter.swift    The one throwaway request that anchors a window
  CodexProcessKiller.swift     Finds and force-closes running Codex processes

Sources/CodexUsageTracker/     AppKit / SwiftUI
  main.swift                   App entry (accessory activation policy)
  AppDelegate.swift            Creates the menu-bar controller
  MenuBarController.swift      NSStatusItem + refresh timer + wake observer + popover
  MenuBarIconRenderer.swift    Draws the rings (center %, color, elapsed tick)
  AccountsController.swift     App-side state: reload, switch, auto-start pass
  PopoverView.swift            SwiftUI detail panel
  AutoStartSettings.swift      The auto-start on/off switch
  LaunchAtLogin.swift          Start-at-login toggle
```
