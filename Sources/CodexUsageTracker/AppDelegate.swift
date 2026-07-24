//
//  AppDelegate.swift
//  Codex Usage Tracker
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit calls delegate methods on the main thread; the controller is
        // main-actor isolated, so assert isolation to construct it here.
        MainActor.assumeIsolated {
            // Auto-enable launch-at-login on first run (like Claude Usage Tracker).
            LaunchAtLogin.enableOnFirstLaunchIfNeeded()
            controller = MenuBarController()
        }
    }
}
