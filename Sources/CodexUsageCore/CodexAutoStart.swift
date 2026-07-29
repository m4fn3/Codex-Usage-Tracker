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
    /// Send the throwaway request for a window that has never been started at all
    /// (see `isUnanchored`). There is no boundary to record it under, so the
    /// outcome goes to the entry's separate unanchored counters.
    case startUnanchored
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
    /// A never-started window was attempted recently. Stands in for the
    /// `alreadyStarted`/`coolingDown` gates, which need a boundary this case
    /// doesn't have.
    case unanchoredCoolingDown
    /// Too many attempts at a never-started window; wait until it is seen running.
    case unanchoredAttemptsExhausted
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

    /// How far the remaining time may fall short of a full window and still count
    /// as "never started". Only absorbs clock skew and the seconds between the
    /// server stamping `reset_at` and us reading it — an unanchored window matches
    /// to the second, so this stays tight.
    public var unanchoredTolerance: TimeInterval
    /// Gap between attempts at anchoring a never-started window. Long, because
    /// such a window has no boundary to enforce exactly-once with: this interval
    /// and `maxAttemptsPerWindow` are the entire bound on how much it can spend.
    public var unanchoredRetryInterval: TimeInterval

    public init(
        maxAttemptsPerWindow: Int = 3,
        retryInterval: TimeInterval = 600,
        unanchoredTolerance: TimeInterval = 120,
        unanchoredRetryInterval: TimeInterval = 1800
    ) {
        self.maxAttemptsPerWindow = maxAttemptsPerWindow
        self.retryInterval = retryInterval
        self.unanchoredTolerance = unanchoredTolerance
        self.unanchoredRetryInterval = unanchoredRetryInterval
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

        if let boundary = expiredBoundary(reported: reported, cached: cached, now: now) {
            guard let state else { return .start(boundary: boundary) }

            // The exactly-once gate: this boundary was already anchored.
            if let started = state.startedBoundary, started == boundary {
                return .skip(.alreadyStarted)
            }

            // Failure bookkeeping applies only to the boundary being attempted; a
            // new window starts with a clean slate.
            if let attempted = state.attemptBoundary, attempted == boundary {
                if state.attemptCount >= maxAttemptsPerWindow { return .skip(.attemptsExhausted) }
                if let last = state.lastAttemptAt, now.timeIntervalSince(last) < retryInterval {
                    return .skip(.coolingDown)
                }
            }
            return .start(boundary: boundary)
        }

        // A window that has never been started needs anchoring just as much as an
        // expired one — and it is the case that actually bites on the accounts the
        // user doesn't type into, which sit at 0% forever.
        if let window = reported?.weekly, isUnanchored(window, now: now) {
            guard let state else { return .startUnanchored }
            if state.unanchoredAttemptCount >= maxAttemptsPerWindow {
                return .skip(.unanchoredAttemptsExhausted)
            }
            if let last = state.unanchoredLastAttemptAt,
               now.timeIntervalSince(last) < unanchoredRetryInterval {
                return .skip(.unanchoredCoolingDown)
            }
            return .startUnanchored
        }

        // Distinguish "the window is alive" from "we have no idea", purely so the
        // reason is honest in logs; both mean: do nothing. `.windowRunning` is also
        // the signal the caller clears the unanchored counters on.
        if reported?.weekly?.resetsAt != nil { return .skip(.windowRunning) }
        return .skip(.noWindow)
    }

    /// True when the server is describing a window no request has ever started.
    ///
    /// Rolling windows anchor on the first request, so until one lands the server
    /// has nothing to anchor to and simply projects: zero usage, and a `reset_at`
    /// exactly one full window ahead of *now* — a value that slides forward on
    /// every poll rather than staying put. Verified against the live API: an
    /// anchored week reports `remaining / window ≈ 0.94`, an unanchored one
    /// reports exactly `1.0000`.
    ///
    /// Such a window never satisfies `expiredBoundary` (its reset is always in the
    /// future), which is why it used to be mistaken for a healthy running window
    /// and left un-anchored indefinitely.
    func isUnanchored(_ window: CodexRateWindow, now: Date) -> Bool {
        guard window.duration > 0, window.usedPercent <= 0, let resetsAt = window.resetsAt else {
            return false
        }
        let remaining = resetsAt.timeIntervalSince(now)
        return remaining > 0 && remaining >= window.duration - unanchoredTolerance
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

        /// Attempts at anchoring a window that had never been started. Kept apart
        /// from the boundary counters above because such a window has NO stable
        /// identity — its projected `resets_at` moves with every poll, so there is
        /// nothing to key "exactly once" on. A bounded count plus a long cooldown
        /// stands in for that key, and both are cleared the moment the window is
        /// observed actually running.
        public var unanchoredAttemptCount: Int
        public var unanchoredLastAttemptAt: Date?

        public init(
            startedBoundary: Date? = nil,
            startedAt: Date? = nil,
            startedModel: String? = nil,
            attemptBoundary: Date? = nil,
            attemptCount: Int = 0,
            lastAttemptAt: Date? = nil,
            lastError: String? = nil,
            unanchoredAttemptCount: Int = 0,
            unanchoredLastAttemptAt: Date? = nil
        ) {
            self.startedBoundary = startedBoundary
            self.startedAt = startedAt
            self.startedModel = startedModel
            self.attemptBoundary = attemptBoundary
            self.attemptCount = attemptCount
            self.lastAttemptAt = lastAttemptAt
            self.lastError = lastError
            self.unanchoredAttemptCount = unanchoredAttemptCount
            self.unanchoredLastAttemptAt = unanchoredLastAttemptAt
        }

        /// Decoded field by field so a state file written by an older build — one
        /// with no unanchored counters in it — still loads instead of resetting
        /// everyone's "already started" record.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            startedBoundary = try container.decodeIfPresent(Date.self, forKey: .startedBoundary)
            startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
            startedModel = try container.decodeIfPresent(String.self, forKey: .startedModel)
            attemptBoundary = try container.decodeIfPresent(Date.self, forKey: .attemptBoundary)
            attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
            lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
            lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
            unanchoredAttemptCount =
                try container.decodeIfPresent(Int.self, forKey: .unanchoredAttemptCount) ?? 0
            unanchoredLastAttemptAt =
                try container.decodeIfPresent(Date.self, forKey: .unanchoredLastAttemptAt)
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

    // MARK: - Recording (never-started window)

    /// The boundary-less counterparts of the three methods above. `startedBoundary`
    /// is deliberately left alone: there is no boundary this start retires, only a
    /// count and a timestamp keeping it from repeating.
    public mutating func recordUnanchoredAttempt(accountId: String, now: Date) {
        var entry = entries[accountId] ?? Entry()
        entry.unanchoredAttemptCount += 1
        entry.unanchoredLastAttemptAt = now
        entries[accountId] = entry
    }

    public mutating func recordUnanchoredSuccess(accountId: String, now: Date, model: String?) {
        var entry = entries[accountId] ?? Entry()
        entry.startedAt = now
        entry.startedModel = model
        entry.lastError = nil
        entries[accountId] = entry
    }

    public mutating func recordUnanchoredFailure(accountId: String, now: Date, error: String) {
        var entry = entries[accountId] ?? Entry()
        entry.unanchoredLastAttemptAt = now
        entry.lastError = error
        entries[accountId] = entry
    }

    /// Clears the unanchored counters once the window is seen running — proof that
    /// whatever we sent (or the user's own request) landed. Returns true when
    /// something actually changed, so the caller only writes the file when needed.
    @discardableResult
    public mutating func clearUnanchored(accountId: String) -> Bool {
        guard var entry = entries[accountId],
              entry.unanchoredAttemptCount != 0 || entry.unanchoredLastAttemptAt != nil else {
            return false
        }
        entry.unanchoredAttemptCount = 0
        entry.unanchoredLastAttemptAt = nil
        entries[accountId] = entry
        return true
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
