//
//  CodexAutoStart.swift
//  Codex Usage Tracker
//
//  "Anchor the new window the moment the old one runs out."
//
//  Codex's limits are ROLLING windows, not calendar ones: a window doesn't begin
//  when the previous one expires, it begins on the FIRST REQUEST made after that.
//  The server stamps `reset_at` then and never moves it again (polling
//  /wham/usage does not re-anchor it — verified). So a week you don't touch until
//  Friday now resets on the following Friday, and the reset time drifts later and
//  later every cycle.
//
//  This mirrors Claude Usage Tracker's auto-start-session feature: as soon as the
//  window is seen expired, send ONE throwaway request so the fresh window starts
//  immediately and the reset cadence stays tight. (On plans that also have a
//  5-hour window, the same request anchors that one too.)
//
//  The hard part is not sending the request — it's sending it *exactly once* per
//  window, across a 60-second poll loop, app relaunches, sleep/wake and failures.
//  `CodexAutoStartPolicy` decides; `CodexAutoStartState` remembers.
//

import Foundation

// MARK: - Decision

/// What to do for one account on one refresh tick.
public enum CodexAutoStartDecision: Sendable, Equatable {
    /// Send the throwaway request now. `boundary` is the expired window's
    /// `resets_at` — the identity of the window we're replacing, and the key the
    /// outcome must be recorded under.
    case start(boundary: Date)
    case skip(CodexAutoStartSkip)
}

/// Why no request was sent. String-backed so it can be logged/asserted readably.
public enum CodexAutoStartSkip: String, Sendable, Equatable {
    /// The user turned the feature off.
    case disabled
    /// Dead tokens — a request would only produce a 401.
    case needsReauth
    /// This tick's usage fetch failed. Stale numbers must never trigger a send:
    /// a cached snapshot looks "expired" forever while offline.
    case fetchFailed
    /// Neither the live snapshot nor the cache says when a weekly window ends.
    case noWindow
    /// The window is still running — there is nothing to anchor.
    case windowRunning
    /// Already sent for this exact boundary. This is the exactly-once guarantee.
    case alreadyStarted
    /// A recent attempt for this boundary failed; waiting before the next try.
    case coolingDown
    /// Too many failed attempts for this boundary; give up until the next window.
    case attemptsExhausted
}

// MARK: - Policy

/// Pure decision logic — no I/O, no clock of its own, so every branch is testable.
public struct CodexAutoStartPolicy: Sendable, Equatable {

    /// How many times a single window boundary may be attempted before we stop
    /// trying. Bounds the damage when the request keeps failing for a reason a
    /// retry can't fix (unsupported model, server-side block…).
    public var maxAttemptsPerWindow: Int
    /// Minimum gap between attempts for the same boundary, so a failing send
    /// can't be retried on every 60-second poll.
    public var retryInterval: TimeInterval

    public init(maxAttemptsPerWindow: Int = 3, retryInterval: TimeInterval = 600) {
        self.maxAttemptsPerWindow = maxAttemptsPerWindow
        self.retryInterval = retryInterval
    }

    public static let `default` = CodexAutoStartPolicy()

    /// Decides whether to send the window-anchoring request for one account.
    ///
    /// - Parameters:
    ///   - enabled: the user's setting.
    ///   - needsReauth: the account's tokens are dead (re-login required).
    ///   - fetchSucceeded: this tick's `/wham/usage` call actually reached the
    ///     server. Distinct from `reported != nil`, because a successful fetch can
    ///     legitimately carry no usable window at all.
    ///   - reported: the snapshot the server just returned, if any.
    ///   - cached: the last-known-good snapshot from previous runs. Used only to
    ///     recover the boundary when the server stops reporting the expired window.
    ///   - state: what we already did for this account.
    public func decide(
        enabled: Bool,
        needsReauth: Bool,
        fetchSucceeded: Bool,
        reported: CodexUsage?,
        cached: CodexUsage?,
        state: CodexAutoStartState.Entry?,
        now: Date
    ) -> CodexAutoStartDecision {
        guard enabled else { return .skip(.disabled) }
        guard !needsReauth else { return .skip(.needsReauth) }
        guard fetchSucceeded else { return .skip(.fetchFailed) }

        guard let boundary = expiredBoundary(reported: reported, cached: cached, now: now) else {
            // Distinguish "the window is alive" from "we have no idea", purely so
            // the reason is honest in logs; both mean: do nothing.
            if reported?.weekly?.resetsAt != nil { return .skip(.windowRunning) }
            return .skip(.noWindow)
        }

        guard let state else { return .start(boundary: boundary) }

        // The exactly-once gate: this boundary was already anchored.
        if let started = state.startedBoundary, started == boundary {
            return .skip(.alreadyStarted)
        }

        // Failure bookkeeping applies only to the boundary being attempted; a new
        // window starts with a clean slate.
        if let attempted = state.attemptBoundary, attempted == boundary {
            if state.attemptCount >= maxAttemptsPerWindow { return .skip(.attemptsExhausted) }
            if let last = state.lastAttemptAt, now.timeIntervalSince(last) < retryInterval {
                return .skip(.coolingDown)
            }
        }
        return .start(boundary: boundary)
    }

    /// The `resets_at` of a weekly window that has run out and not been replaced.
    ///
    /// The live snapshot is authoritative: a `resets_at` in the future means the
    /// window is running (someone's request already anchored it), and one in the
    /// past means no request has landed since it expired — exactly our cue. If the
    /// server reports no weekly window at all (some plans drop the field once it
    /// lapses), fall back to the boundary our last good snapshot recorded.
    private func expiredBoundary(reported: CodexUsage?, cached: CodexUsage?, now: Date) -> Date? {
        if let window = reported?.weekly {
            guard let resetsAt = window.resetsAt else { return nil }
            return resetsAt <= now ? resetsAt : nil
        }
        guard let resetsAt = cached?.weekly?.resetsAt, resetsAt <= now else { return nil }
        return resetsAt
    }
}

// MARK: - Persisted state

/// What the auto-start has already done, per account, persisted to
/// ~/Library/Application Support/CodexUsageTracker/auto-start.json.
///
/// This file is the memory that makes "exactly once" survive relaunches — an
/// in-process flag would re-fire the request every time the app starts. It holds
/// no tokens, only window boundaries and outcomes.
public struct CodexAutoStartState: Codable, Sendable, Equatable {

    public struct Entry: Codable, Sendable, Equatable {
        /// The expired window we already anchored a replacement for. Every weekly
        /// window has a unique `resets_at`, so recording it here retires that
        /// boundary for good, however often we poll or relaunch.
        public var startedBoundary: Date?
        public var startedAt: Date?
        /// Model the successful request used — surfaced in the UI so the user can
        /// see what was actually charged.
        public var startedModel: String?

        /// The boundary the failure counters below belong to. Kept separate from
        /// `startedBoundary` so a failed run for window N can't silently count
        /// against window N+1.
        public var attemptBoundary: Date?
        public var attemptCount: Int
        public var lastAttemptAt: Date?
        public var lastError: String?

        public init(
            startedBoundary: Date? = nil,
            startedAt: Date? = nil,
            startedModel: String? = nil,
            attemptBoundary: Date? = nil,
            attemptCount: Int = 0,
            lastAttemptAt: Date? = nil,
            lastError: String? = nil
        ) {
            self.startedBoundary = startedBoundary
            self.startedAt = startedAt
            self.startedModel = startedModel
            self.attemptBoundary = attemptBoundary
            self.attemptCount = attemptCount
            self.lastAttemptAt = lastAttemptAt
            self.lastError = lastError
        }
    }

    /// Keyed by ChatGPT account id — the same identity key the account store uses.
    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public func entry(for accountId: String) -> Entry? { entries[accountId] }

    // MARK: - Recording

    /// Marks an attempt as *started*. Called BEFORE the request goes out, so a
    /// crash or a hung send still burns an attempt instead of leaving a hole the
    /// retry loop could pour requests through.
    public mutating func recordAttempt(accountId: String, boundary: Date, now: Date) {
        var entry = entries[accountId] ?? Entry()
        if entry.attemptBoundary == boundary {
            entry.attemptCount += 1
        } else {
            entry.attemptBoundary = boundary
            entry.attemptCount = 1
        }
        entry.lastAttemptAt = now
        entries[accountId] = entry
    }

    public mutating func recordSuccess(accountId: String, boundary: Date, now: Date, model: String?) {
        var entry = entries[accountId] ?? Entry()
        entry.startedBoundary = boundary
        entry.startedAt = now
        entry.startedModel = model
        entry.lastError = nil
        entries[accountId] = entry
    }

    public mutating func recordFailure(accountId: String, boundary: Date, now: Date, error: String) {
        var entry = entries[accountId] ?? Entry()
        entry.attemptBoundary = boundary
        entry.lastAttemptAt = now
        entry.lastError = error
        entries[accountId] = entry
    }

    /// Drops entries for accounts that no longer exist.
    public mutating func prune(keeping accountIds: some Sequence<String>) {
        let keep = Set(accountIds)
        entries = entries.filter { keep.contains($0.key) }
    }

    // MARK: - Persistence

    public static var stateURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("CodexUsageTracker", isDirectory: true)
            .appendingPathComponent("auto-start.json")
    }

    public static func load(from url: URL = stateURL) -> CodexAutoStartState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(CodexAutoStartState.self, from: data) else {
            return CodexAutoStartState()
        }
        return state
    }

    public func save(to url: URL = stateURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
