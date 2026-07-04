//
//  main.swift
//  Codex Usage Tracker
//
//  A minimal macOS menu-bar app that shows OpenAI Codex usage.
//  Display format mirrors "Claude Usage Tracker": a circular ring with the
//  usage percentage in the center, ring color green/orange/red by usage, and
//  an outer tick marking how far the current window has elapsed.
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory = live in the menu bar only, no Dock icon (same effect as LSUIElement).
app.setActivationPolicy(.accessory)
app.run()
