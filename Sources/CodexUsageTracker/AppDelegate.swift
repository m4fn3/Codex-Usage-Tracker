//
//  AppDelegate.swift
//  Codex Usage Tracker
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Auto-enable launch-at-login on first run (like Claude Usage Tracker).
        LaunchAtLogin.enableOnFirstLaunchIfNeeded()
        controller = MenuBarController()
    }
}
