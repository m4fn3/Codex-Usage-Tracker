//
//  CodexUsageResolutionTests.swift
//  Codex Usage Tracker
//
//  Regression tests for the three reported bugs, expressed against the real
//  shapes seen in ~/.codex rollout logs:
//
//    1. When a window is used up, the percentage must show correctly (not vanish
//       or get mislabeled).
//    2. Usage must update reliably even when the freshest line drops the session
//       window / swaps primary & secondary.
//    3. Once a window's reset time passes, it must reset to 0 (and not linger).
//
//  Plus the false-restore guard: a stale, lower late reading inside the same
//  window must not look like a restore.
//

import Foundation
import Testing
@testable import CodexUsageCore

private let base = Date(timeIntervalSince1970: 1_784_000_000)

/// Builds one `token_count` JSONL line. `primary`/`secondary` are (used, minutes,
/// resetsAt) tuples; pass nil to omit / null the slot.
private func line(
    tsOffset: TimeInterval,
    primary: (Double, Int, Date?)?,
    secondary: (Double, Int, Date?)?,
    plan: String = "plus"
) -> String {
    func windowJSON(_ w: (Double, Int, Date?)?) -> String {
        guard let w else { return "null" }
        let resets = w.2.map { Int($0.timeIntervalSince1970) } ?? 0
        return "{\"used_percent\": \(w.0), \"window_minutes\": \(w.1), \"resets_at\": \(resets)}"
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ts = iso.string(from: base.addingTimeInterval(tsOffset))
    return """
    {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","rate_limits":{\
    "primary":\(windowJSON(primary)),"secondary":\(windowJSON(secondary)),"plan_type":"\(plan)"}}}
    """
}

// MARK: - Parsing & role classification

struct RoleClassificationTests {
    @Test func `window minutes decide the role, not slot position`() {
        #expect(WindowRole.classify(windowMinutes: 300) == .session)
        #expect(WindowRole.classify(windowMinutes: 10080) == .weekly)
        #expect(WindowRole.classify(windowMinutes: 43200) == .weekly) // free-plan 30-day
        #expect(WindowRole.classify(windowMinutes: 0) == nil)
        #expect(WindowRole.classify(windowMinutes: 1440) == nil)      // unplaced mid-size
    }

    @Test func `parse extracts both windows regardless of slot order`() {
        // Session in PRIMARY, weekly in SECONDARY (early-line shape).
        let a = CodexUsageReader.parse(line: line(
            tsOffset: 0,
            primary: (15, 300, base.addingTimeInterval(3600)),
            secondary: (36, 10080, base.addingTimeInterval(600000))))
        #expect(a.first(where: { $0.role == .session })?.usedPercent == 15)
        #expect(a.first(where: { $0.role == .weekly })?.usedPercent == 36)

        // Weekly in PRIMARY, secondary null (late-line shape) — must NOT be read
        // as a session window.
        let b = CodexUsageReader.parse(line: line(
            tsOffset: 0,
            primary: (7, 10080, base.addingTimeInterval(600000)),
            secondary: nil))
        #expect(b.count == 1)
        #expect(b[0].role == .weekly)
        #expect(b[0].usedPercent == 7)
    }
}

// MARK: - Bug #2: session survives a last line that drops it

struct SessionSurvivesTests {
    @Test func `session window is kept even when the final line only has weekly`() {
        // File shape observed in real logs: early lines carry the session window
        // (primary) plus the weekly (secondary); the last line only carries the
        // weekly window in primary with secondary = null. Within one short
        // session the weekly boundary is stable and its usage ticks up slowly.
        let sessionBoundary = base.addingTimeInterval(3600)
        let weeklyBoundary = base.addingTimeInterval(600000)
        let content = [
            line(tsOffset: 0,   primary: (15, 300, sessionBoundary),
                 secondary: (36, 10080, weeklyBoundary)),
            line(tsOffset: 60,  primary: (22, 300, sessionBoundary),
                 secondary: (37, 10080, weeklyBoundary)),
            line(tsOffset: 120, primary: (38, 10080, weeklyBoundary),
                 secondary: nil),
        ].joined(separator: "\n")

        let now = base.addingTimeInterval(200)
        let usage = CodexUsageReader.resolve(
            observations: CodexUsageReader.fileObservations(fromContent: content),
            now: now)

        let session = try! #require(usage?.session)
        let weekly = try! #require(usage?.weekly)
        // Session survives at its latest reported value (22%), not lost/mislabeled
        // as the weekly number, even though the final line dropped it.
        #expect(session.effectiveUsedPercent(now: now) == 22)
        #expect(session.windowMinutes == 300)
        // Weekly is the weekly window at its latest value (38%), not a duplicate
        // of the session window.
        #expect(weekly.effectiveUsedPercent(now: now) == 38)
        #expect(weekly.windowMinutes == 10080)
    }
}

// MARK: - Bug #1: used-up window shows correctly

struct UsedUpDisplayTests {
    @Test func `a depleted session with a future reset shows 100, not 0 or weekly`() {
        let content = [
            line(tsOffset: 0,  primary: (80, 300, base.addingTimeInterval(3600)),
                 secondary: (40, 10080, base.addingTimeInterval(600000))),
            // Depleted, and the last line drops the session (weekly-only) — the
            // old code would have shown the weekly number on the session card.
            line(tsOffset: 60, primary: (100, 300, base.addingTimeInterval(3600)),
                 secondary: (41, 10080, base.addingTimeInterval(600000))),
            line(tsOffset: 90, primary: (41, 10080, base.addingTimeInterval(600000)),
                 secondary: nil),
        ].joined(separator: "\n")

        let now = base.addingTimeInterval(120)
        let usage = CodexUsageReader.resolve(
            observations: CodexUsageReader.fileObservations(fromContent: content),
            now: now)
        let session = try! #require(usage?.session)
        #expect(session.effectiveUsedPercent(now: now) == 100)
        #expect(session.status(now: now) == .critical)
    }

    @Test func `used percent is clamped into 0...100`() {
        let w = CodexRateWindow(usedPercent: 150, windowMinutes: 300,
                                resetsAt: base.addingTimeInterval(3600))
        #expect(w.effectiveUsedPercent(now: base) == 100)
    }
}

// MARK: - Bug #3: expired window resets to 0

struct ResetTests {
    @Test func `a window whose reset has passed reads 0 with a projected reset`() {
        // Depleted session whose 5-hour boundary is now in the past and no newer
        // request has refreshed it: must read 0, and project the reset forward.
        let boundary = base.addingTimeInterval(3600)
        let content = line(tsOffset: 0, primary: (100, 300, boundary), secondary: nil)
        let now = boundary.addingTimeInterval(60) // one minute after the reset

        let usage = CodexUsageReader.resolve(
            observations: CodexUsageReader.fileObservations(fromContent: content),
            now: now)
        let session = try! #require(usage?.session)
        #expect(session.effectiveUsedPercent(now: now) == 0)
        // Projected reset is in the future (next 5-hour window), never the past.
        let reset = try! #require(session.effectiveResetsAt(now: now))
        #expect(reset.timeIntervalSince(now) > 0)
    }

    @Test func `an unknown reset time is not treated as expired`() {
        // No resets_at at all ⇒ we can't prove a rollover ⇒ keep the reported %.
        let w = CodexRateWindow(usedPercent: 55, windowMinutes: 300, resetsAt: nil)
        #expect(w.isExpired(now: base) == false)
        #expect(w.effectiveUsedPercent(now: base) == 55)
        #expect(w.effectiveResetsAt(now: base) == nil)
        #expect(w.elapsedFraction(now: base) == nil)
    }
}

// MARK: - False-restore guard

struct FalseRestoreTests {
    @Test func `a stale lower reading in the same window does not lower usage`() {
        // Same boundary (within jitter), a later line reports a LOWER value —
        // a stale replay from a resumed session. Usage must stay at the peak.
        let boundary = base.addingTimeInterval(3600)
        let content = [
            line(tsOffset: 0,  primary: (100, 300, boundary), secondary: nil),
            line(tsOffset: 60, primary: (20, 300, boundary.addingTimeInterval(1)), secondary: nil),
        ].joined(separator: "\n")

        let now = base.addingTimeInterval(120)
        let usage = CodexUsageReader.resolve(
            observations: CodexUsageReader.fileObservations(fromContent: content),
            now: now)
        #expect(usage?.session?.effectiveUsedPercent(now: now) == 100)
    }

    @Test func `a genuinely new window (new boundary) does reset the usage`() {
        // A NEW boundary ~5 hours later with low usage is a real reset, not a
        // stale replay — usage should follow the new window down.
        let oldBoundary = base.addingTimeInterval(600)   // soon-expiring
        let newBoundary = base.addingTimeInterval(600 + 5 * 3600)
        let content = [
            line(tsOffset: 0,   primary: (100, 300, oldBoundary), secondary: nil),
            line(tsOffset: 700, primary: (5, 300, newBoundary), secondary: nil),
        ].joined(separator: "\n")

        let now = base.addingTimeInterval(750)
        let usage = CodexUsageReader.resolve(
            observations: CodexUsageReader.fileObservations(fromContent: content),
            now: now)
        // Current window is the new boundary at 5%.
        #expect(usage?.session?.effectiveUsedPercent(now: now) == 5)
    }
}

// MARK: - Cross-file resolution

struct CrossFileResolutionTests {
    @Test func `the freshest boundary wins across separate session files`() {
        // Two files: one older session at 100% (old boundary), one active session
        // at 30% (newer boundary). The active window is the current one.
        let oldBoundary = base.addingTimeInterval(300)
        let newBoundary = base.addingTimeInterval(300 + 5 * 3600)
        let fileA = line(tsOffset: 0, primary: (100, 300, oldBoundary), secondary: nil)
        let fileB = line(tsOffset: 400, primary: (30, 300, newBoundary), secondary: nil)

        var obs = CodexUsageReader.fileObservations(fromContent: fileA)
        obs += CodexUsageReader.fileObservations(fromContent: fileB)

        let now = base.addingTimeInterval(450)
        let usage = CodexUsageReader.resolve(observations: obs, now: now)
        #expect(usage?.session?.effectiveUsedPercent(now: now) == 30)
    }

    @Test func `no rate-limit data resolves to nil`() {
        #expect(CodexUsageReader.resolve(observations: [], now: base) == nil)
    }

    @Test func `a stale different-plan window does not pollute the current plan`() {
        // Older free-plan 30-day window (also classifies as .weekly) plus a fresher
        // plus-plan session+weekly. The current (newest) plan is plus, so the free
        // 30-day window must be ignored — weekly should be the plus 10080 window.
        let freeFile = line(tsOffset: 0, primary: (95, 43200, base.addingTimeInterval(9_000_000)),
                            secondary: nil, plan: "free")
        let plusFile = line(tsOffset: 500, primary: (12, 300, base.addingTimeInterval(500 + 3600)),
                            secondary: (40, 10080, base.addingTimeInterval(500 + 600000)), plan: "plus")

        var obs = CodexUsageReader.fileObservations(fromContent: freeFile)
        obs += CodexUsageReader.fileObservations(fromContent: plusFile)

        let now = base.addingTimeInterval(600)
        let usage = CodexUsageReader.resolve(observations: obs, now: now)
        #expect(usage?.planType == "plus")
        #expect(usage?.session?.effectiveUsedPercent(now: now) == 12)
        #expect(usage?.weekly?.windowMinutes == 10080)
        #expect(usage?.weekly?.effectiveUsedPercent(now: now) == 40)
    }
}
