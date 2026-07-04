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

    /// True once the reported window's reset time has passed. Codex only refreshes
    /// `rate_limits` when the CLI makes a request, so if the user hasn't used Codex
    /// since the reset, the freshest snapshot still carries the OLD usage with a
    /// `resetsAt` now in the past. In that case the window has actually rolled over.
    var isExpired: Bool { duration > 0 && resetsAt.timeIntervalSinceNow <= 0 }

    /// Usage to display: 0 once the window has reset (no newer snapshot means no
    /// usage in the fresh window), otherwise the reported percentage.
    var effectiveUsedPercent: Double { isExpired ? 0 : usedPercent }

    /// Reset moment for the *current* window. If the reported window already
    /// elapsed, project forward by whole windows so the countdown/tick track the
    /// window that is actually running now.
    var effectiveResetsAt: Date {
        guard isExpired else { return resetsAt }
        let elapsedPeriods = floor(-resetsAt.timeIntervalSinceNow / duration) + 1
        return resetsAt.addingTimeInterval(elapsedPeriods * duration)
    }

    var status: UsageStatusLevel { .from(usedPercent: effectiveUsedPercent) }

    /// Fraction (0…1) of the current window that has elapsed, derived from the
    /// (possibly projected) reset time. Used to draw the elapsed-time tick.
    var elapsedFraction: Double {
        guard duration > 0 else { return 1 }
        let remaining = effectiveResetsAt.timeIntervalSinceNow
        if remaining <= 0 { return 1 }
        let elapsed = duration - remaining
        return min(max(elapsed / duration, 0), 1)
    }

    /// Seconds until the current window resets (never negative).
    var secondsUntilReset: TimeInterval { max(0, effectiveResetsAt.timeIntervalSinceNow) }
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
