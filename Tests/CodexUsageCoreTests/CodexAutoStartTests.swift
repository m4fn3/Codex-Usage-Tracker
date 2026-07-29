//
//  CodexAutoStartTests.swift
//  Codex Usage Tracker
//
//  The auto-start spends real quota, so the interesting property isn't "does it
//  fire" — it's "does it fire EXACTLY once per window". These tests walk the
//  60-second poll loop across a reset boundary, a relaunch, failures and the next
//  week, asserting that at most one request comes out of each window.
//

import Foundation
import Testing
@testable import CodexUsageCore

private let t0 = Date(timeIntervalSince1970: 1_785_000_000)
private let week: TimeInterval = 7 * 24 * 3600

private func usage(
    weeklyResetsAt: Date?,
    weeklyUsed: Double = 0,
    session: CodexRateWindow? = nil
) -> CodexUsage {
    CodexUsage(
        session: session,
        weekly: weeklyResetsAt.map {
            CodexRateWindow(usedPercent: weeklyUsed, windowMinutes: 10080, resetsAt: $0)
        },
        planType: "plus",
        lastUpdated: t0,
        accountId: "acct-1",
        accountEmail: "a@x.com",
        source: .liveAPI
    )
}

/// A live snapshot that carries no window at all (the API maps to nil when it
/// reports none).
private let noWindows: CodexUsage? = nil

private func decide(
    policy: CodexAutoStartPolicy = .default,
    enabled: Bool = true,
    needsReauth: Bool = false,
    fetchSucceeded: Bool = true,
    reported: CodexUsage?,
    cached: CodexUsage? = nil,
    state: CodexAutoStartState.Entry? = nil,
    now: Date = t0
) -> CodexAutoStartDecision {
    policy.decide(
        enabled: enabled,
        needsReauth: needsReauth,
        fetchSucceeded: fetchSucceeded,
        reported: reported,
        cached: cached,
        state: state,
        now: now
    )
}

struct CodexAutoStartPolicyTests {

    // MARK: - When to fire

    @Test func `a window whose reset time has passed is started`() {
        let boundary = t0.addingTimeInterval(-60)
        let decision = decide(reported: usage(weeklyResetsAt: boundary))
        #expect(decision == .start(boundary: boundary))
    }

    @Test func `a running window is left alone`() {
        // resets_at in the future AND short of a full window ⇒ some request already
        // anchored this window. (A reset exactly one full window out is a different
        // animal entirely — see the never-started tests below.)
        let decision = decide(reported: usage(weeklyResetsAt: t0.addingTimeInterval(week - 3600)))
        #expect(decision == .skip(.windowRunning))
    }

    @Test func `a running window with no usage yet is left alone`() {
        // 0% but demonstrably anchored: the clock has visibly moved into it.
        let decision = decide(reported: usage(weeklyResetsAt: t0.addingTimeInterval(week - 600)))
        #expect(decision == .skip(.windowRunning))
    }

    @Test func `the exact reset moment counts as expired`() {
        let decision = decide(reported: usage(weeklyResetsAt: t0))
        #expect(decision == .start(boundary: t0))
    }

    @Test func `a long-lapsed window is still started`() {
        // The user chose no grace period: a reset missed three weeks ago should
        // still be anchored the moment the app sees it.
        let boundary = t0.addingTimeInterval(-3 * week)
        #expect(decide(reported: usage(weeklyResetsAt: boundary)) == .start(boundary: boundary))
    }

    @Test func `a lapsed window is recovered from the cache when the server drops it`() {
        // Live snapshot has no weekly window; the last good snapshot knows when the
        // old one ended.
        let boundary = t0.addingTimeInterval(-120)
        let decision = decide(reported: noWindows, cached: usage(weeklyResetsAt: boundary))
        #expect(decision == .start(boundary: boundary))
    }

    @Test func `a cached window that has not expired yet is not started`() {
        let decision = decide(
            reported: noWindows,
            cached: usage(weeklyResetsAt: t0.addingTimeInterval(3600))
        )
        #expect(decision == .skip(.noWindow))
    }

    @Test func `a window without a reset time is never started`() {
        // No reset time ⇒ no proof it lapsed, and no key to make "once" mean
        // anything.
        #expect(decide(reported: usage(weeklyResetsAt: nil)) == .skip(.noWindow))
    }

    // MARK: - Windows that were never started

    // The bug this covers, seen live: an account the user never types into sits at
    // 0% with `reset_at` exactly one full window ahead of *now* — a projection that
    // slides forward on every poll because no request has anchored it. Its reset is
    // always in the future, so it used to be filed under "running" and left alone
    // forever, which is precisely the drift the auto-start exists to prevent.

    @Test func `a window that has never been started is anchored`() {
        let decision = decide(reported: usage(weeklyResetsAt: t0.addingTimeInterval(week)))
        #expect(decision == .startUnanchored)
    }

    @Test func `a reset time a hair under a full window still counts as never started`() {
        // The seconds between the server stamping reset_at and us reading it.
        let decision = decide(reported: usage(weeklyResetsAt: t0.addingTimeInterval(week - 90)))
        #expect(decision == .startUnanchored)
    }

    @Test func `a window with usage on it is never treated as unstarted`() {
        // Anything consumed proves a request anchored it, whatever the reset says.
        let decision = decide(reported: usage(weeklyResetsAt: t0.addingTimeInterval(week), weeklyUsed: 3))
        #expect(decision == .skip(.windowRunning))
    }

    @Test func `a never-started window is not re-sent on the next poll`() {
        // The killer case: an unanchored window has NO stable boundary to dedupe
        // on (its reset_at moves every minute), so without the cooldown this would
        // spend a request every 60 seconds.
        var state = CodexAutoStartState()
        state.recordUnanchoredAttempt(accountId: "acct-1", now: t0)
        state.recordUnanchoredSuccess(accountId: "acct-1", now: t0, model: "gpt-5.6-luna")

        for minute in 1...20 {
            let now = t0.addingTimeInterval(Double(minute) * 60)
            // The server keeps projecting from `now` until the send registers.
            let decision = decide(
                reported: usage(weeklyResetsAt: now.addingTimeInterval(week)),
                state: state.entry(for: "acct-1"),
                now: now
            )
            #expect(decision == .skip(.unanchoredCoolingDown))
        }
    }

    @Test func `attempts at a never-started window are capped`() {
        let policy = CodexAutoStartPolicy.default
        var state = CodexAutoStartState()
        var now = t0

        for attempt in 1...policy.maxAttemptsPerWindow {
            #expect(decide(policy: policy,
                           reported: usage(weeklyResetsAt: now.addingTimeInterval(week)),
                           state: state.entry(for: "acct-1"), now: now) == .startUnanchored)
            state.recordUnanchoredAttempt(accountId: "acct-1", now: now)
            state.recordUnanchoredFailure(accountId: "acct-1", now: now, error: "boom \(attempt)")
            now = now.addingTimeInterval(policy.unanchoredRetryInterval + 1)
        }

        #expect(decide(policy: policy,
                       reported: usage(weeklyResetsAt: now.addingTimeInterval(week)),
                       state: state.entry(for: "acct-1"), now: now) == .skip(.unanchoredAttemptsExhausted))
    }

    @Test func `seeing the window run gives the next unstarted spell a fresh budget`() {
        // Once the window is observed running, the earlier send demonstrably landed
        // — clearUnanchored() is what the caller does on .windowRunning.
        var state = CodexAutoStartState()
        for _ in 1...CodexAutoStartPolicy.default.maxAttemptsPerWindow {
            state.recordUnanchoredAttempt(accountId: "acct-1", now: t0)
        }
        let cleared = state.clearUnanchored(accountId: "acct-1")
        #expect(cleared)
        #expect(state.entry(for: "acct-1")?.unanchoredAttemptCount == 0)

        #expect(decide(reported: usage(weeklyResetsAt: t0.addingTimeInterval(week)),
                       state: state.entry(for: "acct-1")) == .startUnanchored)
        // …and it is a no-op the second time, so the file is not rewritten on every poll.
        let clearedAgain = state.clearUnanchored(accountId: "acct-1")
        #expect(!clearedAgain)
    }

    @Test func `an expired window wins over the never-started check`() {
        // Both could describe the same snapshot in principle; the expired branch has
        // a real boundary to dedupe on, so it must be the one that fires.
        let boundary = t0.addingTimeInterval(-60)
        #expect(decide(reported: usage(weeklyResetsAt: boundary)) == .start(boundary: boundary))
    }

    @Test func `the unstarted check respects the disabled and reauth guards`() {
        let running = usage(weeklyResetsAt: t0.addingTimeInterval(week))
        #expect(decide(enabled: false, reported: running) == .skip(.disabled))
        #expect(decide(needsReauth: true, reported: running) == .skip(.needsReauth))
        #expect(decide(fetchSucceeded: false, reported: running) == .skip(.fetchFailed))
    }

    @Test func `an older state file loads with empty unstarted counters`() throws {
        // Written by a build that predates the never-started handling.
        let json = """
        {"entries":{"acct-1":{"attemptCount":2,"startedModel":"gpt-5.6-luna"}}}
        """
        let state = try JSONDecoder().decode(CodexAutoStartState.self, from: Data(json.utf8))
        #expect(state.entry(for: "acct-1")?.attemptCount == 2)
        #expect(state.entry(for: "acct-1")?.unanchoredAttemptCount == 0)
        #expect(state.entry(for: "acct-1")?.unanchoredLastAttemptAt == nil)
    }

    // MARK: - Guards

    @Test func `nothing is sent while the setting is off`() {
        let decision = decide(enabled: false, reported: usage(weeklyResetsAt: t0.addingTimeInterval(-60)))
        #expect(decision == .skip(.disabled))
    }

    @Test func `nothing is sent for an account that needs re-login`() {
        let decision = decide(needsReauth: true, reported: usage(weeklyResetsAt: t0.addingTimeInterval(-60)))
        #expect(decision == .skip(.needsReauth))
    }

    @Test func `a failed fetch never triggers a send`() {
        // Offline, the cached snapshot looks "expired" forever — acting on it would
        // fire a request on every poll as soon as the network came back mid-window.
        let decision = decide(
            fetchSucceeded: false,
            reported: nil,
            cached: usage(weeklyResetsAt: t0.addingTimeInterval(-60))
        )
        #expect(decision == .skip(.fetchFailed))
    }

    // MARK: - Exactly once

    @Test func `the same boundary is never started twice`() {
        let boundary = t0.addingTimeInterval(-60)
        var state = CodexAutoStartState()
        state.recordAttempt(accountId: "acct-1", boundary: boundary, now: t0)
        state.recordSuccess(accountId: "acct-1", boundary: boundary, now: t0, model: "gpt-5.6-sol")

        // The server may need a moment to report the new window; every poll in
        // between still sees the old boundary and must stay quiet.
        for minute in 1...10 {
            let decision = decide(
                reported: usage(weeklyResetsAt: boundary),
                state: state.entry(for: "acct-1"),
                now: t0.addingTimeInterval(Double(minute) * 60)
            )
            #expect(decision == .skip(.alreadyStarted))
        }
    }

    @Test func `a recorded start survives a relaunch`() throws {
        let boundary = t0.addingTimeInterval(-60)
        var state = CodexAutoStartState()
        state.recordAttempt(accountId: "acct-1", boundary: boundary, now: t0)
        state.recordSuccess(accountId: "acct-1", boundary: boundary, now: t0, model: "gpt-5.6-sol")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-start-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try state.save(to: url)

        let reloaded = CodexAutoStartState.load(from: url)
        #expect(reloaded == state)
        let decision = decide(
            reported: usage(weeklyResetsAt: boundary),
            state: reloaded.entry(for: "acct-1"),
            now: t0.addingTimeInterval(3600)
        )
        #expect(decision == .skip(.alreadyStarted))
    }

    @Test func `next week's boundary starts a new window`() {
        let first = t0.addingTimeInterval(-60)
        var state = CodexAutoStartState()
        state.recordAttempt(accountId: "acct-1", boundary: first, now: t0)
        state.recordSuccess(accountId: "acct-1", boundary: first, now: t0, model: "gpt-5.6-sol")

        // Seven days on, the window anchored back then has itself lapsed.
        let second = t0.addingTimeInterval(week)
        let decision = decide(
            reported: usage(weeklyResetsAt: second),
            state: state.entry(for: "acct-1"),
            now: second.addingTimeInterval(30)
        )
        #expect(decision == .start(boundary: second))
    }

    // MARK: - Failure handling

    @Test func `a failed send is not retried immediately`() {
        let boundary = t0.addingTimeInterval(-60)
        var state = CodexAutoStartState()
        state.recordAttempt(accountId: "acct-1", boundary: boundary, now: t0)
        state.recordFailure(accountId: "acct-1", boundary: boundary, now: t0, error: "offline")

        // Next poll, 60 seconds later.
        let decision = decide(
            reported: usage(weeklyResetsAt: boundary),
            state: state.entry(for: "acct-1"),
            now: t0.addingTimeInterval(60)
        )
        #expect(decision == .skip(.coolingDown))
    }

    @Test func `a failed send is retried once the cooldown passes`() {
        let boundary = t0.addingTimeInterval(-60)
        var state = CodexAutoStartState()
        state.recordAttempt(accountId: "acct-1", boundary: boundary, now: t0)
        state.recordFailure(accountId: "acct-1", boundary: boundary, now: t0, error: "offline")

        let decision = decide(
            reported: usage(weeklyResetsAt: boundary),
            state: state.entry(for: "acct-1"),
            now: t0.addingTimeInterval(CodexAutoStartPolicy.default.retryInterval + 1)
        )
        #expect(decision == .start(boundary: boundary))
    }

    @Test func `attempts for one boundary are capped`() {
        let boundary = t0.addingTimeInterval(-60)
        let policy = CodexAutoStartPolicy.default
        var state = CodexAutoStartState()
        var now = t0

        for attempt in 1...policy.maxAttemptsPerWindow {
            #expect(decide(policy: policy, reported: usage(weeklyResetsAt: boundary),
                           state: state.entry(for: "acct-1"), now: now) == .start(boundary: boundary))
            state.recordAttempt(accountId: "acct-1", boundary: boundary, now: now)
            state.recordFailure(accountId: "acct-1", boundary: boundary, now: now, error: "boom \(attempt)")
            now = now.addingTimeInterval(policy.retryInterval + 1)
        }

        // Out of attempts: this window is given up on, however long we keep polling.
        #expect(decide(policy: policy, reported: usage(weeklyResetsAt: boundary),
                       state: state.entry(for: "acct-1"), now: now) == .skip(.attemptsExhausted))
        #expect(decide(policy: policy, reported: usage(weeklyResetsAt: boundary),
                       state: state.entry(for: "acct-1"),
                       now: now.addingTimeInterval(86_400)) == .skip(.attemptsExhausted))
    }

    @Test func `exhausted attempts do not block the next window`() {
        let boundary = t0.addingTimeInterval(-60)
        let policy = CodexAutoStartPolicy.default
        var state = CodexAutoStartState()
        for _ in 1...policy.maxAttemptsPerWindow {
            state.recordAttempt(accountId: "acct-1", boundary: boundary, now: t0)
            state.recordFailure(accountId: "acct-1", boundary: boundary, now: t0, error: "boom")
        }

        let next = t0.addingTimeInterval(week)
        #expect(decide(reported: usage(weeklyResetsAt: next),
                       state: state.entry(for: "acct-1"),
                       now: next.addingTimeInterval(30)) == .start(boundary: next))
    }

    @Test func `a crash mid-request still counts as an attempt`() {
        // recordAttempt runs before the network call, so a process that dies during
        // the send resumes with one attempt already spent instead of starting over.
        let boundary = t0.addingTimeInterval(-60)
        var state = CodexAutoStartState()
        state.recordAttempt(accountId: "acct-1", boundary: boundary, now: t0)

        #expect(state.entry(for: "acct-1")?.attemptCount == 1)
        #expect(decide(reported: usage(weeklyResetsAt: boundary),
                       state: state.entry(for: "acct-1"),
                       now: t0.addingTimeInterval(60)) == .skip(.coolingDown))
    }

    // MARK: - State bookkeeping

    @Test func `state is kept per account`() {
        let boundary = t0.addingTimeInterval(-60)
        var state = CodexAutoStartState()
        state.recordAttempt(accountId: "acct-1", boundary: boundary, now: t0)
        state.recordSuccess(accountId: "acct-1", boundary: boundary, now: t0, model: "m")

        #expect(decide(reported: usage(weeklyResetsAt: boundary),
                       state: state.entry(for: "acct-2")) == .start(boundary: boundary))
    }

    @Test func `prune drops accounts that no longer exist`() {
        var state = CodexAutoStartState()
        state.recordAttempt(accountId: "acct-1", boundary: t0, now: t0)
        state.recordAttempt(accountId: "acct-2", boundary: t0, now: t0)

        state.prune(keeping: ["acct-2"])

        #expect(state.entry(for: "acct-1") == nil)
        #expect(state.entry(for: "acct-2") != nil)
    }

    @Test func `a missing state file loads as empty`() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        #expect(CodexAutoStartState.load(from: url) == CodexAutoStartState())
    }
}

// MARK: - Model selection

struct CodexSessionStarterTests {

    private func catalog(_ json: String) throws -> CodexSessionStarter.ModelCatalog {
        try JSONDecoder().decode(
            CodexSessionStarter.ModelCatalog.self,
            from: Data(json.utf8)
        )
    }

    @Test func `hidden models are never offered`() throws {
        let models = try catalog("""
        {"models": [
          {"slug": "codex-auto-review", "visibility": "hide"},
          {"slug": "gpt-5.6-sol", "visibility": "list"}
        ]}
        """)
        let ranked = CodexSessionStarter.rank(models, planType: "plus")
        #expect(ranked.map(\.slug) == ["gpt-5.6-sol"])
    }

    @Test func `the pinned model wins, at the pinned effort`() throws {
        let models = try catalog("""
        {"models": [
          {"slug": "gpt-5.4-mini", "visibility": "list",
           "supported_reasoning_levels": [{"effort": "low"}]},
          {"slug": "gpt-5.6-luna", "visibility": "list",
           "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}]}
        ]}
        """)
        let ranked = CodexSessionStarter.rank(models, planType: "plus")
        #expect(ranked.first == .init(slug: "gpt-5.6-luna", effort: "low"))
        #expect(ranked.map(\.slug) == ["gpt-5.6-luna", "gpt-5.4-mini"])   // mini is the fallback
    }

    @Test func `a catalog without the pinned model falls back to the cheapest`() throws {
        let models = try catalog("""
        {"models": [
          {"slug": "gpt-5.6-sol", "visibility": "list"},
          {"slug": "gpt-5.4-mini", "visibility": "list"}
        ]}
        """)
        #expect(CodexSessionStarter.rank(models, planType: "plus").first?.slug == "gpt-5.4-mini")
    }

    @Test func `the cheapest model wins`() throws {
        let models = try catalog("""
        {"models": [
          {"slug": "gpt-5.6-sol", "visibility": "list"},
          {"slug": "gpt-5.4-mini", "visibility": "list"}
        ]}
        """)
        let ranked = CodexSessionStarter.rank(models, planType: "plus")
        #expect(ranked.first?.slug == "gpt-5.4-mini")
        #expect(ranked.map(\.slug).contains("gpt-5.6-sol"))   // still a fallback
    }

    @Test func `models the plan cannot use are filtered out`() throws {
        let models = try catalog("""
        {"models": [
          {"slug": "gpt-5.6-pro", "visibility": "list", "available_in_plans": ["pro"]},
          {"slug": "gpt-5.6-sol", "visibility": "list", "available_in_plans": ["plus", "pro"]}
        ]}
        """)
        #expect(CodexSessionStarter.rank(models, planType: "plus").map(\.slug) == ["gpt-5.6-sol"])
    }

    @Test func `an unknown plan does not filter anything away`() throws {
        let models = try catalog("""
        {"models": [{"slug": "gpt-5.6-sol", "visibility": "list", "available_in_plans": ["plus"]}]}
        """)
        #expect(CodexSessionStarter.rank(models, planType: nil).map(\.slug) == ["gpt-5.6-sol"])
    }

    @Test func `the cheapest supported reasoning effort is used`() throws {
        let models = try catalog("""
        {"models": [{"slug": "gpt-5.6-sol", "visibility": "list",
          "supported_reasoning_levels": [{"effort": "medium"}, {"effort": "low"}, {"effort": "high"}]}]}
        """)
        #expect(CodexSessionStarter.rank(models, planType: "plus").first?.effort == "low")
    }

    @Test func `no reasoning effort is sent when the catalog lists none`() throws {
        let models = try catalog("""
        {"models": [{"slug": "gpt-5.6-sol", "visibility": "list"}]}
        """)
        #expect(CodexSessionStarter.rank(models, planType: "plus").first?.effort == nil)
    }

    @Test func `an empty catalog yields no candidates`() throws {
        let empty = try catalog("""
        {"models": []}
        """)
        #expect(CodexSessionStarter.rank(empty, planType: "plus").isEmpty)
    }

    @Test func `candidates are capped so a bad guess costs at most a few 400s`() throws {
        let models = try catalog("""
        {"models": [
          {"slug": "a", "visibility": "list"}, {"slug": "b", "visibility": "list"},
          {"slug": "c", "visibility": "list"}, {"slug": "d", "visibility": "list"}
        ]}
        """)
        #expect(CodexSessionStarter.rank(models, planType: "plus").count == 3)
    }

    // MARK: - config.toml fallback

    @Test func `the CLI's configured model is read from config toml`() {
        let toml = """
        model = "gpt-5.6-luna"
        model_reasoning_effort = "medium"
        """
        #expect(CodexSessionStarter.parseConfiguredModel(toml) == "gpt-5.6-luna")
    }

    @Test func `a model inside a profile table is not mistaken for the default`() {
        let toml = """
        model_reasoning_effort = "medium"

        [profiles.work]
        model = "gpt-5.6-pro"
        """
        #expect(CodexSessionStarter.parseConfiguredModel(toml) == nil)
    }

    @Test func `a config without a model yields nil`() {
        #expect(CodexSessionStarter.parseConfiguredModel("approval_policy = \"never\"") == nil)
    }

    // MARK: - Request shape

    @Test func `the request stays as small as a turn can be`() {
        let body = CodexSessionStarter.body(
            choice: .init(slug: "gpt-5.4-mini", effort: "low"),
            minimal: false,
            conversationId: "abc"
        )
        #expect(body["model"] as? String == "gpt-5.4-mini")
        #expect(body["store"] as? Bool == false)          // never lands in chat history
        #expect((body["tools"] as? [Any])?.isEmpty == true)
        #expect((body["reasoning"] as? [String: String])?["effort"] == "low")
    }

    @Test func `the minimal retry body drops every optional field`() {
        let body = CodexSessionStarter.body(
            choice: .init(slug: "gpt-5.4-mini", effort: "low"),
            minimal: true,
            conversationId: "abc"
        )
        #expect(Set(body.keys) == ["model", "input", "store", "stream"])
    }

    @Test func `only a completed stream counts as a start`() {
        #expect(CodexSessionStarter.streamCompleted(Data("event: response.completed\n".utf8)))
        #expect(CodexSessionStarter.streamCompleted(Data("{\"status\":\"completed\"}".utf8)))
        // A stream that opened and died anchors nothing, so it must not count.
        #expect(!CodexSessionStarter.streamCompleted(Data("event: response.created\n".utf8)))
        #expect(!CodexSessionStarter.streamCompleted(Data()))
    }

    @Test func `error details are pulled out of both backend shapes`() {
        #expect(CodexSessionStarter.errorDetail(Data("{\"detail\":\"nope\"}".utf8)) == "nope")
        #expect(CodexSessionStarter.errorDetail(Data("{\"error\":{\"message\":\"bad\"}}".utf8)) == "bad")
    }
}
