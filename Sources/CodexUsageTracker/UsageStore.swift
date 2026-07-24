//
//  UsageStore.swift
//  Codex Usage Tracker
//
//  Observable holder so the SwiftUI popover reacts to refreshes.
//

import SwiftUI
import CodexUsageCore

final class UsageStore: ObservableObject {
    @Published var usage: CodexUsage?
    /// True once at least one load attempt has completed (so we can tell
    /// "still loading" from "genuinely no data").
    @Published var didLoad: Bool = false
}
