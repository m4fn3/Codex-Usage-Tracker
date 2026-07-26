//
//  CodexUsageCache.swift
//  Codex Usage Tracker
//
//  Last-known-good usage per account, persisted to
//  ~/Library/Application Support/CodexUsageTracker/usage-cache.json.
//
//  The usage API is a network call, so any hiccup (offline laptop, VPN flap,
//  ChatGPT 5xx) would otherwise blank the menu bar to "—". We keep the newest
//  successful snapshot for every account and fall back to it while the fetch is
//  failing, flagging the result as stale so the UI can say how old it is.
//
//  Only successes are recorded — a failed fetch never overwrites a good snapshot.
//  Tokens are NOT stored here (only percentages / reset times), so unlike
//  accounts.json this file needs no special permissions.
//

import Foundation

/// What to display for one account after a fetch attempt.
public struct ResolvedUsage: Sendable, Equatable {
    /// The snapshot to render, fresh or cached; nil when we have neither.
    public var usage: CodexUsage?
    /// True when `usage` came from the cache because this fetch failed.
    public var isStale: Bool
    /// When `usage` was last fetched successfully, for the "N分前" label.
    public var lastFetchedAt: Date?

    public init(usage: CodexUsage?, isStale: Bool, lastFetchedAt: Date?) {
        self.usage = usage
        self.isStale = isStale
        self.lastFetchedAt = lastFetchedAt
    }
}

public struct CodexUsageCache: Codable, Sendable, Equatable {

    public struct Entry: Codable, Sendable, Equatable {
        public var usage: CodexUsage
        /// Wall-clock time of the successful fetch (not the API's own timestamp).
        public var fetchedAt: Date

        public init(usage: CodexUsage, fetchedAt: Date) {
            self.usage = usage
            self.fetchedAt = fetchedAt
        }
    }

    /// Keyed by ChatGPT account id — the same identity key the account store uses.
    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    // MARK: - Resolution

    /// Decides what to show for `accountId` after a fetch attempt, recording the
    /// result when the fetch succeeded.
    ///
    /// - A successful fetch replaces the cached snapshot and is returned fresh.
    /// - A failed fetch (nil, no re-auth needed) falls back to the cached snapshot,
    ///   marked stale. Nothing cached yet ⇒ nil, exactly as before.
    /// - `needsReauth` is deliberately NOT covered by the fallback: those tokens are
    ///   dead and the old numbers would mask a problem only a re-login can fix.
    public mutating func resolve(
        fetched: CodexUsage?,
        for accountId: String,
        needsReauth: Bool = false,
        now: Date = Date()
    ) -> ResolvedUsage {
        if needsReauth {
            return ResolvedUsage(usage: nil, isStale: false, lastFetchedAt: entries[accountId]?.fetchedAt)
        }
        if let fetched {
            entries[accountId] = Entry(usage: fetched, fetchedAt: now)
            return ResolvedUsage(usage: fetched, isStale: false, lastFetchedAt: now)
        }
        guard let entry = entries[accountId] else {
            return ResolvedUsage(usage: nil, isStale: false, lastFetchedAt: nil)
        }
        return ResolvedUsage(usage: entry.usage, isStale: true, lastFetchedAt: entry.fetchedAt)
    }

    // MARK: - Mutation

    public func entry(for accountId: String) -> Entry? { entries[accountId] }

    public mutating func remove(id: String) {
        entries.removeValue(forKey: id)
    }

    /// Drops snapshots for accounts that no longer exist, so a removed login can't
    /// linger in the cache forever.
    public mutating func prune(keeping accountIds: some Sequence<String>) {
        let keep = Set(accountIds)
        entries = entries.filter { keep.contains($0.key) }
    }

    // MARK: - Persistence

    public static var cacheURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("CodexUsageTracker", isDirectory: true)
            .appendingPathComponent("usage-cache.json")
    }

    public static func load(from url: URL = cacheURL) -> CodexUsageCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CodexUsageCache.self, from: data) else {
            return CodexUsageCache()
        }
        return cache
    }

    public func save(to url: URL = cacheURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
