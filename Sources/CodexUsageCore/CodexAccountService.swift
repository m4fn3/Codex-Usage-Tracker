//
//  CodexAccountService.swift
//  Codex Usage Tracker
//
//  Orchestration for multi-account support (no UI dependency):
//   • reconcile()      — keep the store in sync with the account in ~/.codex/auth.json
//   • usage(for:)      — fetch an account's usage, refreshing its token if needed
//   • switchTo(_:)     — make an account the active CLI login (writes auth.json)
//   • captureCurrent() — import whatever account is currently logged in
//   • addViaLogin()    — run the official `codex login` and import the new account
//

import Foundation

public enum CodexAccountError: Error, Sendable {
    case codexNotFound
    case loginFailed
    case timedOut
    case noAccount
}

public enum CodexAccountService {

    // MARK: - Reconcile

    /// Ensures the account currently in auth.json is present in `store` (auto-import
    /// of the active login), returning the updated store and the active account id.
    public static func reconcile(
        store: CodexAccountStore,
        now: Date = Date()
    ) -> (store: CodexAccountStore, activeId: String?) {
        var store = store
        guard let auth = CodexAuth.load(), let account = CodexAccount.from(auth: auth, now: now) else {
            return (store, nil)
        }
        store.upsert(account)
        return (store, account.id)
    }

    /// The account id currently written to auth.json, if any.
    public static func activeAccountId() -> String? {
        CodexAuth.load()?.accountId
    }

    // MARK: - Usage

    /// Fetches an account's usage, refreshing its access token first when it's
    /// expired/near expiry. Returns the usage plus the (possibly refreshed) account
    /// so the caller can persist new credentials.
    public static func usage(
        for account: CodexAccount,
        now: Date = Date(),
        session: URLSession = .shared
    ) async -> (usage: CodexUsage?, account: CodexAccount) {
        var account = account
        if !account.auth.isAccessTokenValid(now: now) {
            if let fresh = try? await CodexTokenRefresher.refresh(account: account, now: now, session: session) {
                account = account.updatingCredentials(from: fresh)
            }
        }
        let usage = try? await CodexUsageAPI.fetch(auth: account.auth, now: now, session: session)
        return (usage, account)
    }

    // MARK: - Switch

    /// Makes `account` the active CLI login by writing its (freshened) tokens to
    /// ~/.codex/auth.json. Returns the account with refreshed credentials and an
    /// updated `lastUsedAt` for the caller to persist.
    public static func switchTo(
        _ account: CodexAccount,
        now: Date = Date(),
        session: URLSession = .shared
    ) async throws -> CodexAccount {
        var account = account
        // Best-effort refresh so the CLI receives a valid token; a network failure
        // shouldn't block switching (the stored refresh token still works later).
        if !account.auth.isAccessTokenValid(now: now) {
            if let fresh = try? await CodexTokenRefresher.refresh(account: account, now: now, session: session) {
                account = account.updatingCredentials(from: fresh)
            }
        }
        try CodexAuth.writeActive(
            idToken: account.idToken,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            accountId: account.id,
            now: now
        )
        account.lastUsedAt = now
        return account
    }

    // MARK: - Capture

    /// Imports whatever account is currently in auth.json.
    public static func captureCurrent(now: Date = Date()) -> CodexAccount? {
        guard let auth = CodexAuth.load() else { return nil }
        return CodexAccount.from(auth: auth, now: now)
    }

    // MARK: - Add via `codex login`

    /// Runs the official `codex login` (browser flow) and returns the newly
    /// logged-in account once auth.json changes. Honors Task cancellation and a
    /// timeout; the login subprocess is terminated on exit.
    public static func addViaLogin(
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 1
    ) async throws -> CodexAccount {
        guard let codex = locateCodex() else { throw CodexAccountError.codexNotFound }

        let before = authFingerprint()
        let process = Process()
        process.executableURL = codex
        process.arguments = ["login"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do { try process.run() } catch { throw CodexAccountError.loginFailed }
        defer { if process.isRunning { process.terminate() } }

        let start = Date()
        while true {
            do {
                try Task.checkCancellation()
            } catch {
                if process.isRunning { process.terminate() }
                throw error
            }

            if let account = newlyLoggedInAccount(since: before) {
                return account
            }
            if !process.isRunning {
                // Give the final write a beat, then decide.
                if let account = newlyLoggedInAccount(since: before) { return account }
                throw CodexAccountError.loginFailed
            }
            if Date().timeIntervalSince(start) > timeout {
                throw CodexAccountError.timedOut
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    // MARK: - Helpers

    private struct AuthFingerprint: Equatable {
        var accountId: String?
        var modified: Date?
    }

    private static func authFingerprint() -> AuthFingerprint {
        let url = CodexAuth.authFileURL
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return AuthFingerprint(accountId: CodexAuth.load()?.accountId, modified: modified)
    }

    private static func newlyLoggedInAccount(since before: AuthFingerprint) -> CodexAccount? {
        guard let auth = CodexAuth.load(), let account = CodexAccount.from(auth: auth, now: Date()) else {
            return nil
        }
        let now = authFingerprint()
        let idChanged = now.accountId != before.accountId
        let fileChanged: Bool = {
            guard let a = now.modified, let b = before.modified else { return now.modified != before.modified }
            return a > b
        }()
        return (idChanged || fileChanged) ? account : nil
    }

    /// Finds the `codex` executable in common locations or via a login shell.
    static func locateCodex() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex",
            "/usr/bin/codex",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to a login shell so user PATH customizations are honored.
        if let resolved = whichViaLoginShell(), fm.isExecutableFile(atPath: resolved) {
            return URL(fileURLWithPath: resolved)
        }
        return nil
    }

    private static func whichViaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
    }
}
