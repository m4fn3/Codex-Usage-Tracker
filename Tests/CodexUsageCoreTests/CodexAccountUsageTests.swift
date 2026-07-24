//
//  CodexAccountUsageTests.swift
//  Codex Usage Tracker
//
//  Tests for the account-aware, live-API path added to fix the "89% shown while
//  the logged-in account is actually at 100%" bug: usage must come from the
//  currently logged-in account (auth.json), not the freshest local file (which may
//  belong to a different, switched-away account).
//

import Foundation
import Testing
@testable import CodexUsageCore

private let now = Date(timeIntervalSince1970: 1_785_000_000)

// MARK: - Live API response mapping

struct CodexUsageAPIMapTests {
    private func decode(_ json: String) throws -> CodexUsageAPI.Response {
        try JSONDecoder().decode(CodexUsageAPI.Response.self, from: Data(json.utf8))
    }

    @Test func `maps the real 100%-weekly response for the current account`() throws {
        // Captured from a live wham/usage call for a plus account at 100%.
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 100, "reset_at": 1785385688, "limit_window_seconds": 604800 },
            "secondary_window": null
          },
          "credits": { "has_credits": false, "unlimited": false, "balance": "0" }
        }
        """
        let usage = try #require(CodexUsageAPI.map(decode(json), auth: nil, now: now))
        #expect(usage.planType == "plus")
        #expect(usage.source == .liveAPI)
        // 604800s = 10080 min → weekly window, at 100%.
        #expect(usage.weekly?.effectiveUsedPercent(now: now) == 100)
        #expect(usage.weekly?.status(now: now) == .critical)
        #expect(usage.session == nil)  // no 5-hour window in this response
    }

    @Test func `classifies windows by length regardless of slot`() throws {
        // Session in the SECONDARY slot, weekly in PRIMARY — must still be placed
        // by length, not position.
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window":   { "used_percent": 42, "reset_at": 1785600000, "limit_window_seconds": 604800 },
            "secondary_window": { "used_percent": 88, "reset_at": 1785010000, "limit_window_seconds": 18000 }
          }
        }
        """
        let usage = try #require(CodexUsageAPI.map(decode(json), auth: nil, now: now))
        #expect(usage.session?.effectiveUsedPercent(now: now) == 88)   // 18000s = 300 min
        #expect(usage.session?.windowMinutes == 300)
        #expect(usage.weekly?.effectiveUsedPercent(now: now) == 42)    // 604800s = 10080 min
        #expect(usage.weekly?.windowMinutes == 10080)
    }

    @Test func `carries account identity from auth`() throws {
        let json = """
        { "plan_type": "plus",
          "rate_limit": { "primary_window": { "used_percent": 10, "reset_at": 1785600000, "limit_window_seconds": 604800 } } }
        """
        let auth = CodexAuth(accessToken: "t", refreshToken: nil, accountId: "acct-123",
                             planType: "plus", email: "me@example.com", accessTokenExpiry: nil)
        let usage = try #require(CodexUsageAPI.map(decode(json), auth: auth, now: now))
        #expect(usage.accountId == "acct-123")
        #expect(usage.accountEmail == "me@example.com")
    }

    @Test func `an empty rate_limit maps to nil so the caller can fall back`() throws {
        let usage = CodexUsageAPI.map(try decode(#"{ "plan_type": "pro", "rate_limit": null }"#),
                                      auth: nil, now: now)
        #expect(usage == nil)
    }
}

// MARK: - auth.json / JWT parsing

struct CodexAuthTests {
    /// Builds a minimal unsigned JWT with the given payload dictionary.
    private func jwt(_ payload: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(Data(#"{"alg":"none"}"#.utf8))
        let body = b64url(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).sig"
    }

    @Test func `loads account id, plan, email and expiry from auth.json`() throws {
        let exp = now.addingTimeInterval(3600).timeIntervalSince1970
        let access = jwt([
            "exp": exp,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-xyz",
                "chatgpt_plan_type": "plus",
            ],
        ])
        let id = jwt(["email": "user@example.com"])
        let authJSON = """
        { "tokens": { "id_token": "\(id)", "access_token": "\(access)",
                      "refresh_token": "rt.abc", "account_id": "acct-xyz" },
          "last_refresh": "2026-07-23T15:37:49Z" }
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("auth.json")
        try Data(authJSON.utf8).write(to: url)

        let auth = try #require(CodexAuth.load(from: url))
        #expect(auth.accountId == "acct-xyz")
        #expect(auth.planType == "plus")
        #expect(auth.email == "user@example.com")
        #expect(auth.isAccessTokenValid(now: now) == true)
        #expect(auth.isAccessTokenValid(now: now.addingTimeInterval(7200)) == false)
    }

    @Test func `missing auth.json yields nil`() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        #expect(CodexAuth.load(from: url) == nil)
    }
}

// MARK: - Local fallback honors the current account's plan

struct FallbackPlanScopeTests {
    private func line(ts: TimeInterval, used: Double, minutes: Int, resets: TimeInterval, plan: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = iso.string(from: Date(timeIntervalSince1970: 1_785_000_000 + ts))
        return """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{\
        "primary":{"used_percent":\(used),"window_minutes":\(minutes),"resets_at":\(Int(1_785_000_000 + resets))},\
        "secondary":null,"plan_type":"\(plan)"}}}
        """
    }

    @Test func `preferredPlan overrides the newest observation's plan`() {
        // The NEWEST line is a free 30-day window (a switched-away account); an
        // older line is the plus weekly at 100%. With preferredPlan = plus, the
        // resolver must report the plus 100%, not the free window.
        let freeNewer = line(ts: 500, used: 89, minutes: 43200, resets: 9_000_000, plan: "free")
        let plusOlder = line(ts: 0, used: 100, minutes: 10080, resets: 600_000, plan: "plus")
        var obs = CodexUsageReader.fileObservations(fromContent: freeNewer)
        obs += CodexUsageReader.fileObservations(fromContent: plusOlder)

        let at = Date(timeIntervalSince1970: 1_785_000_000 + 600)
        let usage = CodexUsageReader.resolve(observations: obs, preferredPlan: "plus", now: at)
        #expect(usage?.planType == "plus")
        #expect(usage?.weekly?.effectiveUsedPercent(now: at) == 100)
        #expect(usage?.source == .localFiles)

        // Without the preference, the newest (free) observation would win instead.
        let unscoped = CodexUsageReader.resolve(observations: obs, now: at)
        #expect(unscoped?.planType == "free")
    }
}
