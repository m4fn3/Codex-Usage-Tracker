//
//  CodexUsageCacheTests.swift
//  Codex Usage Tracker
//
//  The last-known-good fallback: a failed fetch must keep showing the previous
//  numbers (flagged stale) instead of blanking the UI, without ever letting a
//  failure overwrite the cached snapshot.
//

import Foundation
import Testing
@testable import CodexUsageCore

private let t0 = Date(timeIntervalSince1970: 1_785_000_000)

private func usage(session: Double, weekly: Double, at date: Date = t0) -> CodexUsage {
    CodexUsage(
        session: CodexRateWindow(usedPercent: session, windowMinutes: 300,
                                 resetsAt: date.addingTimeInterval(3600)),
        weekly: CodexRateWindow(usedPercent: weekly, windowMinutes: 10080,
                                resetsAt: date.addingTimeInterval(86_400)),
        planType: "plus",
        lastUpdated: date,
        accountId: "acct-1",
        accountEmail: "a@x.com",
        source: .liveAPI
    )
}

struct CodexUsageCacheTests {

    @Test func `a successful fetch is returned fresh and cached`() {
        var cache = CodexUsageCache()
        let fresh = usage(session: 12, weekly: 34)

        let resolved = cache.resolve(fetched: fresh, for: "acct-1", now: t0)

        #expect(resolved.usage == fresh)
        #expect(resolved.isStale == false)
        #expect(resolved.lastFetchedAt == t0)
        #expect(cache.entry(for: "acct-1")?.usage == fresh)
    }

    @Test func `a failed fetch falls back to the last cached snapshot`() {
        var cache = CodexUsageCache()
        let good = usage(session: 12, weekly: 34)
        _ = cache.resolve(fetched: good, for: "acct-1", now: t0)

        // Network error one minute later: nil usage, no re-auth needed.
        let resolved = cache.resolve(fetched: nil, for: "acct-1", now: t0.addingTimeInterval(60))

        #expect(resolved.usage == good)          // previous values, not nil
        #expect(resolved.isStale == true)
        #expect(resolved.lastFetchedAt == t0)    // still the last *successful* fetch
        #expect(cache.entry(for: "acct-1")?.usage == good)   // failure didn't overwrite
    }

    @Test func `nothing cached yet still resolves to nil`() {
        var cache = CodexUsageCache()
        let resolved = cache.resolve(fetched: nil, for: "acct-1", now: t0)
        #expect(resolved.usage == nil)
        #expect(resolved.isStale == false)
        #expect(resolved.lastFetchedAt == nil)
    }

    @Test func `a later success replaces the cached snapshot`() {
        var cache = CodexUsageCache()
        _ = cache.resolve(fetched: usage(session: 12, weekly: 34), for: "acct-1", now: t0)
        _ = cache.resolve(fetched: nil, for: "acct-1", now: t0.addingTimeInterval(60))

        let newer = usage(session: 55, weekly: 66, at: t0.addingTimeInterval(120))
        let resolved = cache.resolve(fetched: newer, for: "acct-1", now: t0.addingTimeInterval(120))

        #expect(resolved.usage == newer)
        #expect(resolved.isStale == false)
        #expect(cache.entry(for: "acct-1")?.fetchedAt == t0.addingTimeInterval(120))
    }

    @Test func `revoked tokens do not fall back to stale numbers`() {
        var cache = CodexUsageCache()
        _ = cache.resolve(fetched: usage(session: 12, weekly: 34), for: "acct-1", now: t0)

        // needsReauth is a real problem the old numbers would mask.
        let resolved = cache.resolve(fetched: nil, for: "acct-1", needsReauth: true,
                                     now: t0.addingTimeInterval(60))

        #expect(resolved.usage == nil)
        #expect(resolved.isStale == false)
        #expect(cache.entry(for: "acct-1") != nil)   // kept for when the re-login lands
    }

    @Test func `snapshots are per account`() {
        var cache = CodexUsageCache()
        _ = cache.resolve(fetched: usage(session: 12, weekly: 34), for: "acct-1", now: t0)

        let other = cache.resolve(fetched: nil, for: "acct-2", now: t0)
        #expect(other.usage == nil)

        let mine = cache.resolve(fetched: nil, for: "acct-1", now: t0)
        #expect(mine.usage?.session?.usedPercent == 12)
    }

    @Test func `prune drops accounts that no longer exist`() {
        var cache = CodexUsageCache()
        _ = cache.resolve(fetched: usage(session: 1, weekly: 2), for: "acct-1", now: t0)
        _ = cache.resolve(fetched: usage(session: 3, weekly: 4), for: "acct-2", now: t0)

        cache.prune(keeping: ["acct-2"])

        #expect(cache.entry(for: "acct-1") == nil)
        #expect(cache.entry(for: "acct-2") != nil)
    }

    @Test func `cache round-trips through JSON on disk`() throws {
        var cache = CodexUsageCache()
        _ = cache.resolve(fetched: usage(session: 12, weekly: 34), for: "acct-1", now: t0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try cache.save(to: url)

        var loaded = CodexUsageCache.load(from: url)
        #expect(loaded == cache)

        // A fetch failure after a relaunch still shows the values from last run.
        let resolved = loaded.resolve(fetched: nil, for: "acct-1", now: t0.addingTimeInterval(300))
        #expect(resolved.isStale == true)
        #expect(resolved.usage?.weekly?.usedPercent == 34)
        #expect(resolved.usage?.source == .liveAPI)
    }

    @Test func `a missing cache file loads as empty`() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        #expect(CodexUsageCache.load(from: url) == CodexUsageCache())
    }
}
