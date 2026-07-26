//
//  AutoStartSettings.swift
//  Codex Usage Tracker
//
//  The one user-facing switch for the weekly-reset auto-start (see
//  CodexAutoStart.swift). On by default: the feature only ever spends one tiny
//  request per window, and the whole point is that it happens without anyone
//  having to notice the reset.
//

import Foundation

enum AutoStartSettings {
    private static let key = "autoStartOnWeeklyReset"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
