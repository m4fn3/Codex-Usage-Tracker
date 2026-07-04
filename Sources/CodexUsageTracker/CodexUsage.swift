//
//  CodexUsage.swift
//  Codex Usage Tracker
//
//  Data model for Codex rate-limit windows.
//

import AppKit

/// Usage status level for color coding — mirrors Claude Usage Tracker's used-mode
/// thresholds: 0–50% green, 50–80% orange, 80–100% red.
enum UsageStatusLevel {
    case safe       // < 50% used
    case moderate   // 50–80% used
    case critical   // >= 80% used

    var nsColor: NSColor {
        switch self {
        case .safe:     return .systemGreen
        case .moderate: return .systemOrange
        case .critical: return .systemRed
        }
    }

    static func from(usedPercent: Double) -> UsageStatusLevel {
        switch usedPercent {
        case ..<50:  return .safe
        case ..<80:  return .moderate
        default:     return .critical
        }
    }
}

/// One rate-limit window as reported by Codex (`rate_limits.primary` / `.secondary`).
struct CodexRateWindow {
    /// Percentage of the window already consumed (0–100).
    var usedPercent: Double
    /// Window length in minutes (300 = 5h session, 10080 = weekly).
    var windowMinutes: Int
    /// Absolute time at which this window resets.
    var resetsAt: Date

    var duration: TimeInterval { TimeInterval(windowMinutes) * 60 }

    var status: UsageStatusLevel { .from(usedPercent: usedPercent) }

    /// Fraction (0…1) of the window that has elapsed, derived from the reset time.
    /// Used to draw the "how far the current window has progressed" tick.
    var elapsedFraction: Double {
        guard duration > 0 else { return 1 }
        let remaining = resetsAt.timeIntervalSinceNow
        if remaining <= 0 { return 1 }
        let elapsed = duration - remaining
        return min(max(elapsed / duration, 0), 1)
    }

    /// Seconds until this window resets (never negative).
    var secondsUntilReset: TimeInterval { max(0, resetsAt.timeIntervalSinceNow) }
}

/// A full snapshot of Codex usage taken from the freshest session record.
struct CodexUsage {
    /// Primary window (5-hour rolling session).
    var session: CodexRateWindow
    /// Secondary window (weekly, across all models).
    var weekly: CodexRateWindow
    /// Plan identifier reported by Codex (e.g. "plus", "pro", "team").
    var planType: String?
    /// Timestamp of the record this snapshot was read from.
    var lastUpdated: Date
}
