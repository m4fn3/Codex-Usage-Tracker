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
    private var loginTask: Task<Void, Never>?

    /// Usage for the currently active account (what the menu bar shows).
    var activeUsage: CodexUsage? {
        rows.first { $0.id == activeId }?.usage
    }

    var activeRow: Row? { rows.first { $0.id == activeId } }
    var otherRows: [Row] { rows.filter { $0.id != activeId } }

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

        // 4. Build ordered rows.
        var usageById: [String: CodexUsage?] = [:]
        var reauthById: [String: Bool] = [:]
        var accountById: [String: CodexAccount] = [:]
        for outcome in outcomes {
            usageById[outcome.account.id] = outcome.usage
            reauthById[outcome.account.id] = outcome.needsReauth
            accountById[outcome.account.id] = outcome.account
        }
        let ordered = store.accounts.sorted { lhs, rhs in
            if lhs.id == activeId { return true }
            if rhs.id == activeId { return false }
            return (lhs.lastUsedAt ?? lhs.addedAt) > (rhs.lastUsedAt ?? rhs.addedAt)
        }
        rows = ordered.map { account in
            Row(account: accountById[account.id] ?? account,
                usage: usageById[account.id] ?? nil,
                needsReauth: reauthById[account.id] ?? false)
        }
        didLoad = true
        onStateChange?()

        // Refresh the running-Codex count (ps runs off the main actor).
        runningCodexCount = await Task.detached { CodexProcessKiller.findCodexPIDs().count }.value
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
