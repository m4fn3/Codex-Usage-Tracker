//
//  CodexAccount.swift
//  Codex Usage Tracker
//
//  A stored Codex/ChatGPT account the user can switch between. Accounts are keyed
//  by ChatGPT `account_id` — the same identity Codex Switcher dedupes on. We keep
//  the full token set so we can (a) fetch that account's usage and (b) switch to it
//  by writing its tokens into ~/.codex/auth.json.
//

import Foundation

public struct CodexAccount: Codable, Sendable, Equatable, Identifiable {
    /// ChatGPT account id (the dedup / identity key).
    public var id: String
    public var email: String?
    public var planType: String?

    // Credentials (as last known — refreshed on demand).
    public var idToken: String?
    public var accessToken: String
    public var refreshToken: String?
    public var accessTokenExpiry: Date?
    /// When the paid subscription lapses, if known (for the "N days left" display).
    public var subscriptionEndsAt: Date?

    /// Optional user-set label; falls back to email / id for display.
    public var label: String?
    public var addedAt: Date
    public var lastUsedAt: Date?

    public init(
        id: String,
        email: String?,
        planType: String?,
        idToken: String?,
        accessToken: String,
        refreshToken: String?,
        accessTokenExpiry: Date?,
        subscriptionEndsAt: Date? = nil,
        label: String? = nil,
        addedAt: Date,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.planType = planType
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiry = accessTokenExpiry
        self.subscriptionEndsAt = subscriptionEndsAt
        self.label = label
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
    }

    /// Human label for the account row. Prefers a user label, then the email,
    /// then a short id.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        if let email, !email.isEmpty { return email }
        return "ChatGPT (" + id.prefix(8) + ")"
    }

    /// Auth view used by the usage API and token refresh.
    public var auth: CodexAuth {
        CodexAuth(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: id,
            planType: planType,
            email: email,
            accessTokenExpiry: accessTokenExpiry
        )
    }

    /// Builds an account from a resolved auth identity (e.g. captured from
    /// auth.json or produced by a token refresh).
    public static func from(auth: CodexAuth, now: Date, label: String? = nil) -> CodexAccount? {
        guard let id = auth.accountId, !id.isEmpty else { return nil }
        return CodexAccount(
            id: id,
            email: auth.email,
            planType: auth.planType,
            idToken: auth.idToken,
            accessToken: auth.accessToken,
            refreshToken: auth.refreshToken,
            accessTokenExpiry: auth.accessTokenExpiry,
            subscriptionEndsAt: auth.subscriptionEndsAt,
            label: label,
            addedAt: now,
            lastUsedAt: nil
        )
    }

    /// Returns a copy with credentials replaced by a fresher auth (keeps id, label,
    /// addedAt, lastUsedAt).
    public func updatingCredentials(from auth: CodexAuth) -> CodexAccount {
        var copy = self
        copy.accessToken = auth.accessToken
        copy.refreshToken = auth.refreshToken ?? refreshToken
        copy.idToken = auth.idToken ?? idToken
        copy.accessTokenExpiry = auth.accessTokenExpiry
        if let email = auth.email { copy.email = email }
        if let plan = auth.planType { copy.planType = plan }
        if let ends = auth.subscriptionEndsAt { copy.subscriptionEndsAt = ends }
        return copy
    }
}
