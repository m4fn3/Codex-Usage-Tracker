//
//  CodexAuth.swift
//  Codex Usage Tracker
//
//  Reads the currently logged-in Codex CLI account from ~/.codex/auth.json.
//
//  This is the key to showing the RIGHT numbers: the rollout session files under
//  ~/.codex/sessions are NOT tagged with an account, so when the user switches
//  accounts (e.g. with codex-switcher) the freshest rollout file can belong to a
//  different account than the one currently logged in. auth.json always reflects
//  the account the CLI is using right now, keyed by `tokens.account_id` — the same
//  identity other tools dedupe accounts on.
//
//  auth.json shape:
//    { "tokens": { "id_token": "<jwt>", "access_token": "<jwt>",
//                  "refresh_token": "...", "account_id": "<uuid>" },
//      "last_refresh": "2026-07-23T15:37:49Z" }
//
//  The access token is a JWT whose claims carry the plan type, email and expiry,
//  so we can identify the account without a network round-trip.
//

import Foundation

public struct CodexAuth: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let accountId: String?
    public let planType: String?
    public let email: String?
    /// Expiry of `accessToken` (from its `exp` claim), or nil if undecodable.
    public let accessTokenExpiry: Date?

    public init(
        accessToken: String,
        refreshToken: String?,
        idToken: String? = nil,
        accountId: String?,
        planType: String?,
        email: String?,
        accessTokenExpiry: Date?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.planType = planType
        self.email = email
        self.accessTokenExpiry = accessTokenExpiry
    }

    /// True when the access token has not yet expired (with a small safety skew).
    /// Unknown expiry ⇒ assume usable and let the API reject it if stale.
    public func isAccessTokenValid(now: Date = Date(), skew: TimeInterval = 60) -> Bool {
        guard let accessTokenExpiry else { return true }
        return accessTokenExpiry.timeIntervalSince(now) > skew
    }

    // MARK: - Loading

    public static var authFileURL: URL {
        CodexUsageReader.codexHome.appendingPathComponent("auth.json")
    }

    /// ISO-8601 with fractional seconds, matching the CLI's `last_refresh` format.
    private static let lastRefreshFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Writes the given tokens into ~/.codex/auth.json so the Codex CLI uses this
    /// account. Written atomically and owner-only (0600), mirroring the shape the
    /// CLI expects: `{ "tokens": {...}, "last_refresh": "<iso8601>" }`.
    public static func writeActive(
        idToken: String?,
        accessToken: String,
        refreshToken: String?,
        accountId: String?,
        now: Date = Date(),
        to url: URL = authFileURL
    ) throws {
        var tokens: [String: Any] = ["access_token": accessToken]
        if let idToken { tokens["id_token"] = idToken }
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let accountId { tokens["account_id"] = accountId }

        let root: [String: Any] = [
            "tokens": tokens,
            "last_refresh": lastRefreshFormatter.string(from: now),
        ]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL = authFileURL) -> CodexAuth? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            return nil
        }

        return from(
            accessToken: accessToken,
            refreshToken: tokens["refresh_token"] as? String,
            idToken: tokens["id_token"] as? String,
            accountIdFallback: tokens["account_id"] as? String
        )
    }

    /// Builds an identity by decoding the JWT claims of the given tokens. Used both
    /// when reading auth.json and after refreshing tokens.
    public static func from(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        accountIdFallback: String?
    ) -> CodexAuth {
        let accessClaims = decodeJWTClaims(accessToken)
        let idClaims = idToken.flatMap(decodeJWTClaims)
        return CodexAuth(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountIdFallback
                ?? authClaim(accessClaims, "chatgpt_account_id")
                ?? authClaim(idClaims, "chatgpt_account_id"),
            planType: authClaim(accessClaims, "chatgpt_plan_type")
                ?? authClaim(idClaims, "chatgpt_plan_type"),
            email: emailClaim(idClaims) ?? emailClaim(accessClaims),
            accessTokenExpiry: (accessClaims?["exp"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }

    // MARK: - JWT

    /// Decodes a JWT's payload claims WITHOUT verifying the signature (we only read
    /// non-secret identity/expiry claims from the CLI's own token).
    static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Reads a claim nested under the OpenAI `.../auth` namespace.
    private static func authClaim(_ claims: [String: Any]?, _ key: String) -> String? {
        guard let claims else { return nil }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let value = auth[key] as? String { return value }
        return claims[key] as? String
    }

    private static func emailClaim(_ claims: [String: Any]?) -> String? {
        guard let claims else { return nil }
        if let email = claims["email"] as? String { return email }
        if let profile = claims["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String { return email }
        return nil
    }
}
