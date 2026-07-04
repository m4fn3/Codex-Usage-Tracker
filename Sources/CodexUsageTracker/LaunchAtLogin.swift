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
    /// Whether the app is currently set to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Enables or disables launch at login. Returns true on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
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
        let key = "didConfigureLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }
}
