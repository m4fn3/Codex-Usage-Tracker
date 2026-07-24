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
    /// The account's tokens are revoked/invalidated server-side — it must be
    /// re-logged-in with `codex login` (refresh can't recover it).
    case needsReauth
    /// A transient network failure; the current login was left untouched.
    case network
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

    public struct UsageOutcome: Sendable {
        public var usage: CodexUsage?
        public var account: CodexAccount
        /// Set when the account's tokens are revoked/invalidated and a re-login is
        /// required (refresh could not recover them).
        public var needsReauth: Bool
    }

    /// Fetches an account's usage. Refreshes proactively when the token is expired,
    /// and reactively on a 401 (tokens can be revoked before their JWT expiry, e.g.
    /// after a refresh-token rotation). Returns the (possibly refreshed) account so
    /// the caller can persist new credentials, and a `needsReauth` flag when the
    /// session is dead.
    public static func usage(
        for account: CodexAccount,
        now: Date = Date(),
        session: URLSession = .shared
    ) async -> UsageOutcome {
        var account = account

        // Proactive refresh when the JWT is already expired.
        if !account.auth.isAccessTokenValid(now: now) {
            switch await tryRefresh(account, now: now, session: session) {
            case .refreshed(let updated): account = updated
            case .invalidated: return UsageOutcome(usage: nil, account: account, needsReauth: true)
            case .transient: return UsageOutcome(usage: nil, account: account, needsReauth: false)
            }
        }

        do {
            let usage = try await CodexUsageAPI.fetch(auth: account.auth, now: now, session: session)
            return UsageOutcome(usage: usage, account: account, needsReauth: false)
        } catch CodexUsageAPIError.unauthorized {
            // Revoked despite a valid-looking expiry — try one refresh + retry.
            switch await tryRefresh(account, now: now, session: session) {
            case .refreshed(let updated):
                account = updated
                if let usage = try? await CodexUsageAPI.fetch(auth: account.auth, now: now, session: session) {
                    return UsageOutcome(usage: usage, account: account, needsReauth: false)
                }
                return UsageOutcome(usage: nil, account: account, needsReauth: true)
            case .invalidated:
                return UsageOutcome(usage: nil, account: account, needsReauth: true)
            case .transient:
                return UsageOutcome(usage: nil, account: account, needsReauth: false)
            }
        } catch {
            // Network / parse — not a re-auth situation.
            return UsageOutcome(usage: nil, account: account, needsReauth: false)
        }
    }

    private enum RefreshResult {
        case refreshed(CodexAccount)
        case invalidated   // refresh_token dead → re-login required
        case transient     // network etc.
    }

    private static func tryRefresh(
        _ account: CodexAccount,
        now: Date,
        session: URLSession
    ) async -> RefreshResult {
        guard account.refreshToken?.isEmpty == false else { return .invalidated }
        do {
            let fresh = try await CodexTokenRefresher.refresh(account: account, now: now, session: session)
            return .refreshed(account.updatingCredentials(from: fresh))
        } catch CodexTokenRefreshError.http(let code) where code == 400 || code == 401 || code == 403 {
            return .invalidated
        } catch CodexTokenRefreshError.missingRefreshToken {
            return .invalidated
        } catch {
            return .transient
        }
    }

    // MARK: - Switch

    /// Makes `account` the active CLI login by writing FRESH tokens to
    /// ~/.codex/auth.json. Critically, we refresh first and only write tokens we
    /// just minted — never the stored copy, which may already be a rotated-away
    /// (invalidated) refresh token. Writing a stale token would break the CLI login
    /// (`token_revoked` / `refresh_token_invalidated`).
    ///
    /// Throws `.needsReauth` when the account's refresh token is dead (re-login
    /// required) and `.network` on a transient failure — in both cases auth.json is
    /// left untouched.
    public static func switchTo(
        _ account: CodexAccount,
        now: Date = Date(),
        session: URLSession = .shared
    ) async throws -> CodexAccount {
        var account = account
        switch await tryRefresh(account, now: now, session: session) {
        case .refreshed(let updated):
            account = updated
        case .invalidated:
            throw CodexAccountError.needsReauth
        case .transient:
            throw CodexAccountError.network
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
