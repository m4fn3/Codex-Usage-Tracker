//
//  PopoverView.swift
//  Codex Usage Tracker
//
//  The panel shown when the menu-bar icon is clicked:
//   • The active account at the top with its full Session / All-Models usage.
//   • Other logged-in accounts below as compact rows (email + used% + reset),
//     tap to switch.
//   • Controls to add an account (official codex login), capture the current
//     login, and force-close all Codex processes.
//

import SwiftUI
import CodexUsageCore

struct PopoverView: View {
    @ObservedObject var accounts: AccountsController
    var onRefresh: () -> Void
    var onQuit: () -> Void

    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if !accounts.didLoad {
                loadingState
            } else if accounts.rows.isEmpty {
                emptyState
            } else {
                if let active = accounts.activeRow {
                    activeAccount(active)
                }
                if !accounts.otherRows.isEmpty {
                    otherAccountsSection
                }
            }

            controls
            Divider().padding(.vertical, 1)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Codex Usage")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if let plan = accounts.activeRow?.account.planType, !plan.isEmpty {
                planBadge(plan)
            }
        }
        .padding(.bottom, 2)
    }

    private func planBadge(_ plan: String) -> some View {
        Text(plan.uppercased())
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(Color.accentColor)
    }

    // MARK: - Active account

    private func activeAccount(_ row: AccountsController.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(row.account.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("現在")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.green.opacity(0.18)))
                    .foregroundStyle(.green)
                Spacer()
            }

            if row.needsReauth {
                reauthNotice
            } else if let usage = row.usage, usage.hasAnyWindow {
                if let session = usage.session {
                    UsageRow(title: "Session Usage", subtitle: "5-hour window", window: session)
                }
                if let weekly = usage.weekly {
                    UsageRow(title: "All Models",
                             tag: Self.longWindowTag(minutes: weekly.windowMinutes),
                             subtitle: nil,
                             window: weekly)
                }
            } else {
                Text("利用状況を取得できませんでした（通信エラーの可能性）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reauthNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("再ログインが必要です", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text("このアカウントのセッションは終了しています。codex login でログインし直してください。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { accounts.addAccount() }) {
                Label("再ログイン", systemImage: "arrow.clockwise.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(accounts.loginInProgress)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }

    // MARK: - Other accounts

    private var otherAccountsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("別のアカウント")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ForEach(accounts.otherRows) { row in
                AccountSwitchRow(
                    row: row,
                    disabled: accounts.isBusy,
                    onTap: {
                        if row.needsReauth { accounts.addAccount() }
                        else { Task { await accounts.switchTo(row.id) } }
                    },
                    onRemove: { Task { await accounts.remove(row.id) } }
                )
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if accounts.loginInProgress {
                    ProgressView().controlSize(.small)
                    Button("キャンセル") { accounts.cancelAdd() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                } else {
                    Button(action: { accounts.addAccount() }) {
                        Label("アカウントを追加", systemImage: "plus.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(accounts.isBusy)

                    Button(action: { Task { await accounts.captureCurrent() } }) {
                        Label("取り込む", systemImage: "arrow.down.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(accounts.isBusy)
                }
                Spacer()
            }

            Button(action: { Task { await accounts.forceCloseAll() } }) {
                Label("すべての Codex を閉じる", systemImage: "xmark.octagon")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(accounts.isBusy)

            if let message = accounts.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Loading / empty

    private var loadingState: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("読み込み中…").font(.system(size: 12))
        }
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ログイン中の Codex アカウントが見つかりません")
                .font(.system(size: 12, weight: .medium))
            Text("『アカウントを追加』から codex login でログインしてください。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Start at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .onChange(of: launchAtLogin) { newValue in
                    LaunchAtLogin.setEnabled(newValue)
                }
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")

            Button(action: onQuit) {
                Text("Quit").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Quit Codex Usage")
        }
        .padding(.top, 2)
    }

    /// Human label for the long window, derived from its length: weekly (10080)
    /// on paid plans, ~monthly (43200) on the free plan.
    static func longWindowTag(minutes: Int) -> String {
        switch minutes {
        case 0:        return "Rolling"
        case ..<8640:  return "Rolling"
        case ..<20160: return "Weekly"     // ~7 days
        default:       return "Monthly"    // ~30 days (free plan)
        }
    }
}

// MARK: - Compact switch row for other accounts

private struct AccountSwitchRow: View {
    let row: AccountsController.Row
    let disabled: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    private var headline: CodexRateWindow? { row.usage?.weekly ?? row.usage?.session }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(row.account.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if row.needsReauth {
                    Text("要再ログイン")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                } else if let window = headline {
                    Text("\(Int(window.effectiveUsedPercent().rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(color(for: window))
                    if let reset = Self.resetCountdown(window) {
                        Text(reset)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help("クリックでこのアカウントに切り替え")
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("このアカウントを削除", systemImage: "trash")
            }
        }
    }

    private func color(for window: CodexRateWindow) -> Color {
        switch window.status() {
        case .safe:     return .green
        case .moderate: return .orange
        case .critical: return .red
        }
    }

    static func resetCountdown(_ window: CodexRateWindow, now: Date = Date()) -> String? {
        guard let seconds = window.secondsUntilReset(now: now) else { return nil }
        if seconds <= 0 { return "まもなく" }
        let days = Int(seconds / 86400)
        if days >= 1 { return "あと\(days)日" }
        let hours = Int(seconds / 3600)
        if hours >= 1 { return "あと\(hours)時間" }
        return "あと\(max(1, Int(seconds / 60)))分"
    }
}

// MARK: - Usage Row (flat, native style — matches Claude Usage Tracker)

private struct UsageRow: View {
    let title: String
    var tag: String? = nil
    let subtitle: String?
    let window: CodexRateWindow

    private var displayPercentage: Double { window.effectiveUsedPercent() }

    private var statusColor: Color {
        switch window.status() {
        case .safe:     return .green
        case .moderate: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        if let tag {
                            Text(tag)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text("\(Int(displayPercentage.rounded()))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(statusColor)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(statusColor)
                        .frame(width: geometry.size.width * min(displayPercentage / 100.0, 1.0))
                }
                .overlay(alignment: .leading) {
                    if let fraction = window.elapsedFraction() {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(nsColor: .labelColor))
                            .frame(width: 2.5, height: 8)
                            .offset(x: round(geometry.size.width * fraction) - 0.75)
                    }
                }
            }
            .frame(height: 4)

            if let reset = window.effectiveResetsAt() {
                Text("Resets \(reset.resetClockString())")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}

// MARK: - Formatting helpers

enum RelativeTime {
    static func string(from date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
