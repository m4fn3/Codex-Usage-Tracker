//
//  CodexUsageAPI.swift
//  Codex Usage Tracker
//
//  Fetches the CURRENT account's usage straight from the ChatGPT backend — the
//  same endpoint the Codex CLI itself uses — so the numbers always match the
//  logged-in account (unlike the local rollout files, which aren't account-tagged).
//  This mirrors CodexBar's CodexOAuthUsageFetcher and codex-switcher's usage.rs.
//
//    GET https://chatgpt.com/backend-api/wham/usage
//    Authorization: Bearer <access_token>
//    ChatGPT-Account-Id: <account_id>
//
//  Response:
//    { "plan_type": "plus",
//      "rate_limit": {
//        "primary_window":   { "used_percent": 100, "reset_at": 1785385688, "limit_window_seconds": 604800 },
//        "secondary_window": null } }
//
//  As with the rollout files, the primary/secondary slots aren't role-stable, so
//  we classify each window by its length (`limit_window_seconds`).
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexUsageAPIError: Error, Sendable {
    case unauthorized
    case http(Int)
    case invalidResponse
    case transport(String)
}

public enum CodexUsageAPI {

    static let defaultBaseURL = "https://chatgpt.com/backend-api"
    static let usagePath = "/wham/usage"

    /// Honors `CODEX_USAGE_BASE_URL` (rare self-hosted setups); defaults to ChatGPT.
    static func usageURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = env["CODEX_USAGE_BASE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: trimmed + usagePath) ?? URL(string: defaultBaseURL + usagePath)!
    }

    // MARK: - Fetch

    public static func fetch(
        auth: CodexAuth,
        now: Date = Date(),
        session: URLSession = .shared
    ) async throws -> CodexUsage? {
        var request = URLRequest(url: usageURL(), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsageTracker", forHTTPHeaderField: "User-Agent")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        if let accountId = auth.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexUsageAPIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw CodexUsageAPIError.invalidResponse }
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw CodexUsageAPIError.unauthorized
        default:
            throw CodexUsageAPIError.http(http.statusCode)
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CodexUsageAPIError.invalidResponse
        }
        return map(decoded, auth: auth, now: now)
    }

    // MARK: - Mapping (pure, unit-tested)

    /// Maps a decoded API response into a `CodexUsage`, classifying each window by
    /// its length. Returns nil when the response carries no usable window.
    static func map(_ response: Response, auth: CodexAuth?, now: Date) -> CodexUsage? {
        var session: CodexRateWindow?
        var weekly: CodexRateWindow?

        for snapshot in [response.rateLimit?.primaryWindow, response.rateLimit?.secondaryWindow] {
            guard let (role, window) = window(from: snapshot) else { continue }
            switch role {
            case .session: if session == nil { session = window }
            case .weekly:  if weekly == nil { weekly = window }
            }
        }
        guard session != nil || weekly != nil else { return nil }

        return CodexUsage(
            session: session,
            weekly: weekly,
            planType: response.planType ?? auth?.planType,
            lastUpdated: now,
            accountId: auth?.accountId,
            accountEmail: auth?.email,
            source: .liveAPI
        )
    }

    static func window(from snapshot: Response.Window?) -> (WindowRole, CodexRateWindow)? {
        guard let snapshot,
              let used = snapshot.usedPercent,
              let seconds = snapshot.limitWindowSeconds, seconds > 0 else { return nil }
        // Round up to whole minutes (matches codex-switcher's `(s + 59) / 60`).
        let minutes = (seconds + 59) / 60
        guard let role = WindowRole.classify(windowMinutes: minutes) else { return nil }
        let resetsAt: Date? = (snapshot.resetAt ?? 0) > 0
            ? Date(timeIntervalSince1970: snapshot.resetAt!)
            : nil
        return (role, CodexRateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt))
    }

    // MARK: - Response model

    public struct Response: Decodable, Sendable {
        public let planType: String?
        public let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }

        public struct RateLimit: Decodable, Sendable {
            public let primaryWindow: Window?
            public let secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }

        public struct Window: Decodable, Sendable {
            public let usedPercent: Double?
            public let resetAt: Double?
            public let limitWindowSeconds: Int?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
                case limitWindowSeconds = "limit_window_seconds"
            }
        }
    }
}
