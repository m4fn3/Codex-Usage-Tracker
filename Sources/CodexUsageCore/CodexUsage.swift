//
//  CodexUsage.swift
//  Codex Usage Tracker
//
//  Data model for Codex rate-limit windows.
//
//  Pure Foundation (no AppKit) so the parsing/reset logic is unit-testable.
//  The status→NSColor mapping lives in the app target.
//

import Foundation

/// Usage status level for color coding — mirrors Claude Usage Tracker's used-mode
/// thresholds: 0–50% green, 50–80% orange, 80–100% red.
public enum UsageStatusLevel: Sendable, Equatable {
    case safe       // < 50% used
    case moderate   // 50–80% used
    case critical   // >= 80% used

    public static func from(usedPercent: Double) -> UsageStatusLevel {
        switch usedPercent {
        case ..<50:  return .safe
        case ..<80:  return .moderate
        default:     return .critical
        }
    }
}

/// Which rate-limit window a Codex payload entry represents.
///
/// Codex reports two windows per snapshot, but — critically — it does *not* keep
/// them in fixed `primary`/`secondary` slots: within a single session file the
/// early lines carry `primary = 5-hour session, secondary = weekly`, while later
/// lines carry `primary = weekly, secondary = null`. Trusting the slot position
/// therefore mislabels the windows. We classify by `window_minutes` instead, the
/// same approach CodexBar uses (`CodexRateWindowNormalizer`).
public enum WindowRole: Sendable, Equatable, Hashable {
    /// The rolling ~5-hour session window (Codex reports `window_minutes` 300).
    case session
    /// The long window: weekly (10080) on paid plans, or the ~30-day (43200)
    /// window on the free plan. Both map here since the UI has one "long" slot.
    case weekly

    /// Classifies a window by its length. Returns nil for lengths we don't place
    /// (so an unexpected/mid-size window is ignored rather than mislabeled).
    public static func classify(windowMinutes: Int) -> WindowRole? {
        guard windowMinutes > 0 else { return nil }
        if windowMinutes <= 360 { return .session }            // ≤ 6h  → 5-hour session
        if windowMinutes >= 6 * 24 * 60 { return .weekly }     // ≥ 6d  → weekly / 30-day
        return nil
    }
}

/// One rate-limit window as reported by Codex.
public struct CodexRateWindow: Sendable, Equatable {
    /// Percentage of the window already consumed as last reported (0–100).
    public var usedPercent: Double
    /// Window length in minutes (300 = 5h session, 10080 = weekly, 43200 = 30-day).
    /// 0 means "unknown" (field absent) — we then can't project a rollover.
    public var windowMinutes: Int
    /// Absolute time at which this window resets, or nil when Codex didn't report
    /// one. nil is *not* the same as "already reset": with no reset time we can't
    /// prove a rollover, so we keep showing the reported usage.
    public var resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var duration: TimeInterval { TimeInterval(max(0, windowMinutes)) * 60 }

    /// True once the reported window's reset time has provably passed. Codex only
    /// refreshes `rate_limits` when the CLI makes a request, so if the user hasn't
    /// used Codex since the reset, the freshest snapshot still carries the OLD
    /// usage with a `resets_at` now in the past — the window has actually rolled
    /// over. Unknown reset time ⇒ not expired (we can't prove it).
    public func isExpired(now: Date = Date()) -> Bool {
        guard let resetsAt, duration > 0 else { return false }
        return resetsAt.timeIntervalSince(now) <= 0
    }

    /// Usage to display, clamped to 0…100: 0 once the window has provably reset
    /// (no newer snapshot means no usage in the fresh window), otherwise the
    /// reported percentage.
    public func effectiveUsedPercent(now: Date = Date()) -> Double {
        if isExpired(now: now) { return 0 }
        return min(max(usedPercent, 0), 100)
    }

    /// Reset moment for the *current* window, or nil when unknown. If the reported
    /// window already elapsed, project forward by whole windows so the countdown/
    /// tick track the window that is actually running now.
    public func effectiveResetsAt(now: Date = Date()) -> Date? {
        guard let resetsAt else { return nil }
        guard isExpired(now: now), duration > 0 else { return resetsAt }
        let elapsedPeriods = floor(-resetsAt.timeIntervalSince(now) / duration) + 1
        return resetsAt.addingTimeInterval(elapsedPeriods * duration)
    }

    public func status(now: Date = Date()) -> UsageStatusLevel {
        .from(usedPercent: effectiveUsedPercent(now: now))
    }

    /// Fraction (0…1) of the current window that has elapsed, derived from the
    /// (possibly projected) reset time. nil when there is no reset/duration to
    /// measure against. Used to draw the elapsed-time tick.
    public func elapsedFraction(now: Date = Date()) -> Double? {
        guard duration > 0, let reset = effectiveResetsAt(now: now) else { return nil }
        let remaining = reset.timeIntervalSince(now)
        if remaining <= 0 { return 1 }
        let elapsed = duration - remaining
        return min(max(elapsed / duration, 0), 1)
    }

    /// Seconds until the current window resets (never negative), or nil when unknown.
    public func secondsUntilReset(now: Date = Date()) -> TimeInterval? {
        guard let reset = effectiveResetsAt(now: now) else { return nil }
        return max(0, reset.timeIntervalSince(now))
    }
}

/// A full snapshot of Codex usage resolved from the freshest session records.
///
/// Either window may be nil: the free plan has no 5-hour session window, and a
/// paid session window is absent until Codex reports one.
public struct CodexUsage: Sendable, Equatable {
    /// Primary window (rolling ~5-hour session), if reported.
    public var session: CodexRateWindow?
    /// Long window (weekly, or 30-day on free), if reported.
    public var weekly: CodexRateWindow?
    /// Plan identifier reported by Codex (e.g. "plus", "pro", "free").
    public var planType: String?
    /// Timestamp of the freshest record this snapshot was resolved from.
    public var lastUpdated: Date

    public init(
        session: CodexRateWindow?,
        weekly: CodexRateWindow?,
        planType: String?,
        lastUpdated: Date
    ) {
        self.session = session
        self.weekly = weekly
        self.planType = planType
        self.lastUpdated = lastUpdated
    }

    /// True when we resolved at least one usable window.
    public var hasAnyWindow: Bool { session != nil || weekly != nil }
}
