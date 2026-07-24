//
//  UsageStatusLevel+AppKit.swift
//  Codex Usage Tracker
//
//  AppKit color mapping for the core (Foundation-only) UsageStatusLevel.
//

import AppKit
import CodexUsageCore

extension UsageStatusLevel {
    var nsColor: NSColor {
        switch self {
        case .safe:     return .systemGreen
        case .moderate: return .systemOrange
        case .critical: return .systemRed
        }
    }
}
