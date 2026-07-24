//
//  CodexAccountStoreTests.swift
//  Codex Usage Tracker
//
//  Tests for the multi-account building blocks: dedup-by-account_id store,
//  auth.json switch writer round-trip, account credential updates, and the
//  Codex process matcher used by "close all".
//

import Foundation
import Testing
@testable import CodexUsageCore

private let now = Date(timeIntervalSince1970: 1_785_000_000)

private func account(_ id: String, email: String? = nil, label: String? = nil, access: String = "a") -> CodexAccount {
    CodexAccount(id: id, email: email, planType: "plus", idToken: "i", accessToken: access,
                 refreshToken: "r", accessTokenExpiry: nil, label: label, addedAt: now)
}

struct CodexAccountStoreTests {
    @Test func `upsert dedupes by account id and preserves label + addedAt`() {
        var store = CodexAccountStore()
        store.upsert(account("acct-1", email: "a@x.com", label: "Main"))
        #expect(store.accounts.count == 1)

        // Re-upsert with new creds but no label — keep the original label/addedAt.
        var refreshed = account("acct-1", email: "a2@x.com", label: nil, access: "new-token")
        refreshed.addedAt = now.addingTimeInterval(999)
        store.upsert(refreshed)

        #expect(store.accounts.count == 1)
        #expect(store.accounts[0].accessToken == "new-token")
        #expect(store.accounts[0].email == "a2@x.com")
        #expect(store.accounts[0].label == "Main")     // preserved
        #expect(store.accounts[0].addedAt == now)       // preserved
    }

    @Test func `separate ids coexist and remove works`() {
        var store = CodexAccountStore()
        store.upsert(account("acct-1"))
        store.upsert(account("acct-2"))
        #expect(store.accounts.count == 2)
        store.remove(id: "acct-1")
        #expect(store.accounts.map(\.id) == ["acct-2"])
    }

    @Test func `store round-trips through JSON on disk`() throws {
        var store = CodexAccountStore()
        store.upsert(account("acct-1", email: "a@x.com", label: "Main"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.save(to: url)
        let loaded = CodexAccountStore.load(from: url)
        #expect(loaded.accounts.count == 1)
        #expect(loaded.accounts[0].id == "acct-1")
        #expect(loaded.accounts[0].label == "Main")
    }
}

struct AuthWriteRoundTripTests {
    @Test func `writeActive produces an auth.json that load() reads back`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try CodexAuth.writeActive(
            idToken: "id-token",
            accessToken: "access-token",
            refreshToken: "refresh-token",
            accountId: "acct-42",
            now: now,
            to: url)

        let auth = try #require(CodexAuth.load(from: url))
        #expect(auth.accessToken == "access-token")
        #expect(auth.refreshToken == "refresh-token")
        #expect(auth.idToken == "id-token")
        #expect(auth.accountId == "acct-42")

        // The written file must be owner-only.
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }
}

struct CodexAccountCredentialTests {
    @Test func `updatingCredentials keeps identity but swaps tokens`() {
        let base = account("acct-1", email: "old@x.com", label: "Main")
        let fresh = CodexAuth(accessToken: "new-access", refreshToken: "new-refresh", idToken: "new-id",
                              accountId: "acct-1", planType: "pro", email: "new@x.com",
                              accessTokenExpiry: now)
        let updated = base.updatingCredentials(from: fresh)
        #expect(updated.id == "acct-1")
        #expect(updated.label == "Main")
        #expect(updated.accessToken == "new-access")
        #expect(updated.refreshToken == "new-refresh")
        #expect(updated.planType == "pro")
        #expect(updated.email == "new@x.com")
    }
}

struct CodexProcessMatchTests {
    @Test func `matches the codex CLI but never this app or the switcher`() {
        #expect(CodexProcessKiller.isCodexCommand("/opt/homebrew/bin/codex") == true)
        #expect(CodexProcessKiller.isCodexCommand("codex exec --model gpt-5") == true)
        #expect(CodexProcessKiller.isCodexCommand("/usr/local/bin/codex-tui") == true)
        // Our own app must never be matched.
        #expect(CodexProcessKiller.isCodexCommand(
            "/Applications/Codex Usage.app/Contents/MacOS/CodexUsageTracker") == false)
        // The Rust switcher must not be matched.
        #expect(CodexProcessKiller.isCodexCommand("/Applications/codex-switcher.app/codex-switcher") == false)
        // Unrelated processes.
        #expect(CodexProcessKiller.isCodexCommand("/usr/bin/node server.js") == false)
    }
}
