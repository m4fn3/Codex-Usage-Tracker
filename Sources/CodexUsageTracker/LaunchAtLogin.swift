//
//  LaunchAtLogin.swift
//  Codex Usage Tracker
//
//  Launch-at-login via ServiceManagement (SMAppService, macOS 13+), the same
//  mechanism Claude Usage Tracker uses. The app registers itself as a login item
//  automatically on first launch; the popover exposes a toggle to change it.
//

import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// True only when running from inside the installed .app. Executing the bare
    /// SwiftPM binary out of .build would otherwise register *that* path as a
    /// login item — and since it is not a bundle, macOS opens it through
    /// Terminal, leaving a second tracker running alongside the installed one.
    private static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Whether the app is currently set to launch at login.
    static var isEnabled: Bool {
        isBundled && SMAppService.mainApp.status == .enabled
    }

    /// Enables or disables launch at login. Returns true on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isBundled else { return false }
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return true }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return true }
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("Codex Usage: Launch at Login change failed: \(error.localizedDescription)")
            return false
        }
    }

    /// On the very first launch, turn launch-at-login on automatically. Later
    /// launches respect whatever the user last chose (via the popover toggle).
    static func enableOnFirstLaunchIfNeeded() {
        // Bail before consuming the first-launch flag, so a dev run does not eat
        // the installed app's one chance to register itself.
        guard isBundled else { return }
        let key = "didConfigureLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }
}
