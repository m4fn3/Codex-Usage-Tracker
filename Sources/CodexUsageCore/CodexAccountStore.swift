//
//  CodexAccountStore.swift
//  Codex Usage Tracker
//
//  Persists the set of known accounts to
//  ~/Library/Application Support/CodexUsageTracker/accounts.json (0600).
//  Contains tokens, so the file is written owner-only like ~/.codex/auth.json.
//

import Foundation

public struct CodexAccountStore: Codable, Sendable, Equatable {
    /// Accounts in display order; index 0 is treated as most-recently-added.
    public var accounts: [CodexAccount]

    public init(accounts: [CodexAccount] = []) {
        self.accounts = accounts
    }

    // MARK: - Mutation

    /// Inserts or replaces the account with the same id, preserving the existing
    /// label/addedAt/lastUsedAt when replacing (only credentials/plan/email move).
    public mutating func upsert(_ account: CodexAccount) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            var merged = account
            merged.label = accounts[idx].label ?? account.label
            merged.addedAt = accounts[idx].addedAt
            merged.lastUsedAt = accounts[idx].lastUsedAt ?? account.lastUsedAt
            accounts[idx] = merged
        } else {
            accounts.append(account)
        }
    }

    public mutating func remove(id: String) {
        accounts.removeAll { $0.id == id }
    }

    public func account(id: String) -> CodexAccount? {
        accounts.first { $0.id == id }
    }

    // MARK: - Persistence

    public static var storeURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("CodexUsageTracker", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    public static func load(from url: URL = storeURL) -> CodexAccountStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(CodexAccountStore.self, from: data) else {
            return CodexAccountStore()
        }
        return store
    }

    public func save(to url: URL = storeURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
