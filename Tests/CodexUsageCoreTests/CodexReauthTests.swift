//
//  CodexReauthTests.swift
//  Codex Usage Tracker
//
//  Regression tests for token revocation handling. A revoked-but-not-expired
//  token must be detected (401), refreshed, and retried — and when the refresh
//  token is also dead, the account must be flagged needsReauth rather than
//  silently failing or (worse) having a stale token written over auth.json.
//

import Foundation
import Testing
@testable import CodexUsageCore

// MARK: - URLProtocol mock

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = MockURLProtocol.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func jwt(exp: Date) -> String {
    func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let payload: [String: Any] = [
        "exp": exp.timeIntervalSince1970,
        "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_account_id": "acct-1"],
    ]
    let body = b64(try! JSONSerialization.data(withJSONObject: payload))
    return "h.\(body).s"
}

private func account(access: String) -> CodexAccount {
    CodexAccount(id: "acct-1", email: "me@x.com", planType: "plus", idToken: "id",
                 accessToken: access, refreshToken: "refresh-1",
                 accessTokenExpiry: Date(timeIntervalSince1970: 4_000_000_000), // far future
                 addedAt: Date(timeIntervalSince1970: 1_785_000_000))
}

private let now = Date(timeIntervalSince1970: 1_785_000_000)

/// Reference box so a @Sendable handler can keep call state. URLSession strips the
/// Authorization header before it reaches a custom URLProtocol, so we branch on
/// call order / URL host, never on the token value.
private final class CallCounter: @unchecked Sendable { var usageCalls = 0 }

// Serialized so the shared global handler isn't clobbered by parallel tests.
@Suite(.serialized)
struct CodexReauthTests {

    @Test func `revoked token + dead refresh flags needsReauth`() async {
        MockURLProtocol.handler = { request in
            if request.url?.host == "auth.openai.com" {
                return (401, Data(#"{"error":{"code":"refresh_token_invalidated"}}"#.utf8))
            }
            return (401, Data(#"{"error":{"code":"token_revoked"}}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await CodexAccountService.usage(for: account(access: "OLD"), now: now, session: mockSession())
        #expect(outcome.usage == nil)
        #expect(outcome.needsReauth == true)
    }

    @Test func `revoked token recovers when refresh succeeds`() async {
        let newAccess = jwt(exp: now.addingTimeInterval(86_400))
        let counter = CallCounter()
        MockURLProtocol.handler = { request in
            if request.url?.host == "auth.openai.com" {
                return (200, Data(#"{"access_token":"\#(newAccess)","refresh_token":"refresh-2"}"#.utf8))
            }
            counter.usageCalls += 1
            if counter.usageCalls == 1 {
                return (401, Data(#"{"error":{"code":"token_revoked"}}"#.utf8)) // first call: revoked
            }
            let usage = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":100,"reset_at":1785385688,"limit_window_seconds":604800}}}"#
            return (200, Data(usage.utf8)) // after refresh: works
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await CodexAccountService.usage(for: account(access: "OLD"), now: now, session: mockSession())
        #expect(outcome.needsReauth == false)
        #expect(outcome.usage?.weekly?.effectiveUsedPercent(now: now) == 100)
        #expect(outcome.account.refreshToken == "refresh-2") // refreshed creds carried back
    }

    @Test func `switch refuses to write a stale token when refresh is dead`() async {
        MockURLProtocol.handler = { _ in (401, Data(#"{"error":{"code":"refresh_token_invalidated"}}"#.utf8)) }
        defer { MockURLProtocol.handler = nil }

        await #expect(throws: CodexAccountError.needsReauth) {
            _ = try await CodexAccountService.switchTo(account(access: "OLD"), now: now, session: mockSession())
        }
    }
}
