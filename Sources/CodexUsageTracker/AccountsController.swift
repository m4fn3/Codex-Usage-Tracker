//
//  AccountsController.swift
//  Codex Usage Tracker
//
//  App-side state for multi-account support. Wraps the pure CodexAccountService:
//  reconciles the stored accounts with the active CLI login, fetches each
//  account's usage, and drives switch / add / capture / remove / force-close.
//

import Foundation
import SwiftUI
import CodexUsageCore

@MainActor
final class AccountsController: ObservableObject {

    struct Row: Identifiable, Equatable {
        var account: CodexAccount
        var usage: CodexUsage?
        /// The account's tokens are dead; it needs `codex login` again.
        var needsReauth: Bool = false
        /// `usage` is the last-known-good snapshot because this fetch failed
        /// (network error) — shown as-is with an "outdated" note.
        var isStale: Bool = false
        /// When `usage` was last fetched successfully.
        var lastFetchedAt: Date?
        var id: String { account.id }
    }

    /// Active account first, then the rest by most-recently-used.
    @Published private(set) var rows: [Row] = []
    @Published private(set) var activeId: String?
    @Published private(set) var didLoad = false
    @Published private(set) var isBusy = false
    @Published private(set) var loginInProgress = false
    /// Number of running Codex CLI processes (shown on the "close all" button).
    @Published private(set) var runningCodexCount = 0
    @Published var statusMessage: String?

    /// Called after a reload changes the account rows so the menu-bar ring (owned
    /// by MenuBarController, not by SwiftUI) can re-render the active account.
    var onStateChange: (() -> Void)?

    private var store = CodexAccountStore.load()
    /// Last-known-good usage per account, so a failed fetch shows the previous
    /// numbers instead of blanking out.
    private var usageCache = CodexUsageCache.load()
    private var loginTask: Task<Void, Never>?

    /// What the weekly-reset auto-start has already done, per account. Persisted,
    /// because "exactly once per window" has to survive relaunches.
    private var autoStartState = CodexAutoStartState.load()
    /// Set while the auto-start pass runs, so the reload it triggers on success
    /// (and any overlapping reload) can't start a second request for the same
    /// window before the first one is recorded.
    private var autoStartInFlight = false

    /// The currently active account's row — what the popover details.
    var activeRow: Row? { rows.first { $0.id == activeId } }
    var otherRows: [Row] { rows.filter { $0.id != activeId } }

    /// Every account in the fixed order the menu bar draws them in. Unlike `rows`
    /// (active first, then most-recently-used) this never reorders on a switch, so
    /// a given account keeps its position in the status bar.
    var menuBarRows: [Row] {
        rows.sorted { CodexAccount.presentationOrder($0.account, $1.account) }
    }

    // MARK: - Load

    func reload() async {
        // 1. Reconcile with the active CLI login (auto-imports it).
        let reconciled = CodexAccountService.reconcile(store: store)
        store = reconciled.store
        activeId = reconciled.activeId

        // 2. Fetch usage for every account concurrently, capturing any refreshed
        //    credentials so we can persist them, plus whether each needs re-login.
        let accounts = store.accounts
        let outcomes: [CodexAccountService.UsageOutcome] = await withTaskGroup(
            of: CodexAccountService.UsageOutcome.self
        ) { group in
            for account in accounts {
                group.addTask { await CodexAccountService.usage(for: account) }
            }
            var collected: [CodexAccountService.UsageOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        // 3. Persist refreshed credentials.
        for outcome in outcomes { store.upsert(outcome.account) }
        try? store.save()

        // 4. Resolve what to display: fresh usage when the fetch worked, otherwise
        //    the cached snapshot (flagged stale) so a network error doesn't blank
        //    the numbers. Successful fetches refresh the cache.
        let now = Date()
        var resolvedById: [String: ResolvedUsage] = [:]
        var reauthById: [String: Bool] = [:]
        var accountById: [String: CodexAccount] = [:]
        var autoStartInputs: [AutoStartInput] = []
        for outcome in outcomes {
            // Capture the previous snapshot before resolve() overwrites it: it is
            // the only record of the old window's reset time once the server stops
            // reporting a lapsed window.
            let previous = usageCache.entry(for: outcome.account.id)?.usage
            resolvedById[outcome.account.id] = usageCache.resolve(
                fetched: outcome.usage,
                for: outcome.account.id,
                needsReauth: outcome.needsReauth,
                now: now
            )
            reauthById[outcome.account.id] = outcome.needsReauth
            accountById[outcome.account.id] = outcome.account
            autoStartInputs.append(AutoStartInput(
                account: outcome.account,
                needsReauth: outcome.needsReauth,
                fetchSucceeded: outcome.fetchSucceeded,
                reported: outcome.usage,
                cached: previous
            ))
        }
        usageCache.prune(keeping: store.accounts.map(\.id))
        try? usageCache.save()

        // 5. Build ordered rows.
        let ordered = store.accounts.sorted { lhs, rhs in
            if lhs.id == activeId { return true }
            if rhs.id == activeId { return false }
            return (lhs.lastUsedAt ?? lhs.addedAt) > (rhs.lastUsedAt ?? rhs.addedAt)
        }
        rows = ordered.map { account in
            let resolved = resolvedById[account.id]
            return Row(account: accountById[account.id] ?? account,
                       usage: resolved?.usage,
                       needsReauth: reauthById[account.id] ?? false,
                       isStale: resolved?.isStale ?? false,
                       lastFetchedAt: resolved?.lastFetchedAt)
        }
        didLoad = true
        onStateChange?()

        // Refresh the running-Codex count (ps runs off the main actor).
        runningCodexCount = await Task.detached { CodexProcessKiller.findCodexPIDs().count }.value

        // 6. Anchor any window that has run out (at most one request per window).
        await runAutoStartPass(autoStartInputs)
    }

    // MARK: - Weekly-reset auto-start

    /// One account's inputs to the auto-start decision, captured during the fetch.
    private struct AutoStartInput {
        var account: CodexAccount
        var needsReauth: Bool
        var fetchSucceeded: Bool
        var reported: CodexUsage?
        var cached: CodexUsage?
    }

    /// Sends the window-anchoring request for EVERY logged-in account whose weekly
    /// window has lapsed or has never been started. `CodexAutoStartPolicy` owns the
    /// "is this the right moment?" question; this method only performs what it
    /// decides and records the outcome.
    private func runAutoStartPass(_ inputs: [AutoStartInput]) async {
        guard !autoStartInFlight else { return }
        autoStartInFlight = true
        defer { autoStartInFlight = false }

        let enabled = AutoStartSettings.isEnabled
        let policy = CodexAutoStartPolicy.default
        // Collected rather than assigned per account: with several accounts the
        // last one's message used to be the only one the user ever saw.
        var started: [String] = []
        var failed: [String] = []

        for input in inputs {
            let decision = policy.decide(
                enabled: enabled,
                needsReauth: input.needsReauth,
                fetchSucceeded: input.fetchSucceeded,
                reported: input.reported,
                cached: input.cached,
                state: autoStartState.entry(for: input.account.id),
                now: Date()
            )

            /// The expired window this send retires, or nil when the window had
            /// never been started (which has no boundary to record it under).
            let boundary: Date?
            switch decision {
            case .start(let expired):
                boundary = expired
            case .startUnanchored:
                boundary = nil
            case .skip(let reason):
                // Seeing the window run is the proof that an earlier anchoring
                // attempt landed, so the next unanchored spell starts fresh.
                if reason == .windowRunning, autoStartState.clearUnanchored(accountId: input.account.id) {
                    try? autoStartState.save()
                }
                continue
            }

            // Count the attempt BEFORE sending: if the app dies mid-request, the
            // next launch must see that we already spent one, not start over.
            if let boundary {
                autoStartState.recordAttempt(accountId: input.account.id, boundary: boundary, now: Date())
            } else {
                autoStartState.recordUnanchoredAttempt(accountId: input.account.id, now: Date())
            }
            try? autoStartState.save()

            do {
                let result = try await CodexSessionStarter.start(auth: input.account.auth)
                if let boundary {
                    autoStartState.recordSuccess(
                        accountId: input.account.id,
                        boundary: boundary,
                        now: Date(),
                        model: result.model
                    )
                } else {
                    autoStartState.recordUnanchoredSuccess(
                        accountId: input.account.id,
                        now: Date(),
                        model: result.model
                    )
                }
                started.append(input.account.displayName)
            } catch {
                let reason = Self.describe(error)
                if let boundary {
                    autoStartState.recordFailure(
                        accountId: input.account.id,
                        boundary: boundary,
                        now: Date(),
                        error: reason
                    )
                } else {
                    autoStartState.recordUnanchoredFailure(
                        accountId: input.account.id,
                        now: Date(),
                        error: reason
                    )
                }
                failed.append("\(input.account.displayName)（\(reason)）")
            }
            try? autoStartState.save()
        }

        autoStartState.prune(keeping: store.accounts.map(\.id))
        try? autoStartState.save()

        var lines: [String] = []
        if !started.isEmpty { lines.append("新しいウィンドウを開始しました：" + started.joined(separator: "、")) }
        if !failed.isEmpty { lines.append("自動開始に失敗しました：" + failed.joined(separator: "、")) }
        if !lines.isEmpty { statusMessage = lines.joined(separator: "\n") }

        // Show the freshly anchored window right away (the reentrancy guard above
        // keeps this reload from running the pass again).
        if !started.isEmpty { await reload() }
    }

    /// Last successful auto-start for an account, for the popover's status line.
    func lastAutoStart(for accountId: String) -> (date: Date, model: String?)? {
        guard let entry = autoStartState.entry(for: accountId), let date = entry.startedAt else {
            return nil
        }
        return (date, entry.startedModel)
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? CodexSessionStartError else { return error.localizedDescription }
        switch error {
        case .unauthorized:              return "認証エラー"
        case .noModelAvailable:          return "使えるモデルが見つかりません"
        case .rejected(let detail):      return detail ?? "リクエストが拒否されました"
        case .http(let code):            return "HTTP \(code)"
        case .incompleteStream:          return "応答が途中で終了しました"
        case .transport(let message):    return message
        }
    }

    // MARK: - Switch

    func switchTo(_ id: String) async {
        guard !isBusy, id != activeId, let account = store.account(id: id) else { return }
        isBusy = true
        statusMessage = "\(account.displayName) に切り替え中…"
        defer { isBusy = false }
        do {
            let updated = try await CodexAccountService.switchTo(account)
            store.upsert(updated)
            try? store.save()
            statusMessage = nil
            await reload()
        } catch CodexAccountError.needsReauth {
            statusMessage = "\(account.displayName) は再ログインが必要です（「アカウントを追加」から codex login）"
            await reload()
        } catch CodexAccountError.network {
            statusMessage = "ネットワークエラーで切り替えできませんでした"
        } catch {
            statusMessage = "切り替えに失敗しました"
        }
    }

    /// True when any account (typically the active one) needs re-login.
    var needsReauth: Bool { rows.contains { $0.needsReauth } }

    // MARK: - Capture current login

    func captureCurrent() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if CodexAccountService.captureCurrent() == nil {
            statusMessage = "ログイン中の Codex アカウントが見つかりません"
            return
        }
        statusMessage = nil
        await reload()
    }

    // MARK: - Add via codex login

    func addAccount() {
        guard !loginInProgress, !isBusy else { return }
        loginInProgress = true
        statusMessage = "ブラウザで codex login を完了してください…"
        loginTask = Task { [weak self] in
            do {
                _ = try await CodexAccountService.addViaLogin()
                await self?.finishLogin(message: nil)
            } catch is CancellationError {
                await self?.finishLogin(message: "ログインをキャンセルしました")
            } catch CodexAccountError.codexNotFound {
                await self?.finishLogin(message: "codex コマンドが見つかりません")
            } catch CodexAccountError.timedOut {
                await self?.finishLogin(message: "ログインがタイムアウトしました")
            } catch {
                await self?.finishLogin(message: "ログインに失敗しました")
            }
        }
    }

    func cancelAdd() {
        loginTask?.cancel()
    }

    private func finishLogin(message: String?) async {
        loginInProgress = false
        loginTask = nil
        statusMessage = message
        await reload()
    }

    // MARK: - Remove

    func remove(_ id: String) async {
        guard id != activeId else {
            statusMessage = "使用中のアカウントは削除できません"
            return
        }
        store.remove(id: id)
        try? store.save()
        await reload()
    }

    // MARK: - Force-close all Codex processes

    func forceCloseAll() async {
        let outcome = await Task.detached { CodexProcessKiller.forceCloseAll() }.value
        if outcome.count == 0 {
            statusMessage = "実行中の Codex はありません"
        } else if outcome.survived.isEmpty {
            statusMessage = "Codex を \(outcome.count) 件終了しました"
        } else {
            statusMessage = "\(outcome.count) 件終了（\(outcome.survived.count) 件は終了できず）"
        }
        runningCodexCount = await Task.detached { CodexProcessKiller.findCodexPIDs().count }.value
    }
}
