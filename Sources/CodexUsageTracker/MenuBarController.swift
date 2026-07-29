//
//  MenuBarController.swift
//  Codex Usage Tracker
//
//  Owns the NSStatusItem, refreshes usage on a timer, renders the ring for the
//  ACTIVE account, and shows the SwiftUI account/detail popover on click.
//

import AppKit
import SwiftUI
import CodexUsageCore

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let accounts = AccountsController()
    private var refreshTimer: Timer?

    /// Menu-bar icon refresh cadence. The provider makes a network call per account
    /// for live usage, so we poll gently.
    private let refreshInterval: TimeInterval = 60

    /// Light-blue oval outline that brands the Codex icon (水色).
    static let codexBorderColor = NSColor(srgbRed: 0.31, green: 0.76, blue: 0.97, alpha: 1.0)

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Codex Usage"
            button.title = "…"
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                accounts: accounts,
                onRefresh: { [weak self] in self?.refresh() },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        // Keep the menu-bar ring in sync when the popover switches accounts.
        accounts.onStateChange = { [weak self] in self?.updateButton() }

        // Re-render the ring when the system theme flips (menu-bar text color changes).
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        // A limit can reset while the Mac is asleep, and the auto-start should not
        // have to wait for the next timer tick to notice.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop, so we're already on the main actor.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        DistributedNotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func systemDidWake() {
        refresh()
    }

    // MARK: - Appearance

    private var isDarkMenuBar: Bool {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    @objc private func themeChanged() {
        updateButton()
    }

    // MARK: - Refresh

    func refresh() {
        Task { [weak self] in
            await self?.accounts.reload()
            self?.updateButton()
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        // EVERY logged-in account, one ring each for the long (weekly / 30-day)
        // window, always in the same order. The 5-hour session window is left to
        // the popover: the menu bar's budget is horizontal space, and doubling the
        // rings to show it would cost more than it tells.
        let now = Date()
        let rows = accounts.menuBarRows

        guard !rows.isEmpty else {
            button.image = nil
            button.title = accounts.didLoad ? "—" : "…"
            button.toolTip = "Codex Usage"
            return
        }

        let groups = rows.map { row in
            RingGroup(specs: [ringSpec(for: row, now: now)], isActive: row.id == accounts.activeId)
        }
        let image = MenuBarIconRenderer.groupsImage(
            groups,
            isDark: isDarkMenuBar,
            chipColor: Self.codexBorderColor
        )
        image.isTemplate = false   // rings use status colors, so not a template
        button.image = image
        button.title = ""
        button.toolTip = tooltip(for: rows, now: now)
    }

    /// One ring per account: the long window when we have it, the session window
    /// as a stand-in, and a marker when there is nothing to show at all.
    private func ringSpec(for row: AccountsController.Row, now: Date) -> RingSpec {
        if row.needsReauth {
            return RingSpec(percent: 0, status: .moderate, elapsedFraction: nil,
                            label: nil, placeholder: .needsReauth)
        }
        guard let window = row.usage?.weekly ?? row.usage?.session else {
            return RingSpec(percent: 0, status: .safe, elapsedFraction: nil,
                            label: nil, placeholder: .unknown)
        }
        return RingSpec(
            percent: window.effectiveUsedPercent(now: now),
            status: window.status(now: now),
            elapsedFraction: window.elapsedFraction(now: now),
            label: nil
        )
    }

    /// Names every account in drawing order, so the dimmed rings can be told apart
    /// without opening the popover. The active one is marked, and a fetch we failed
    /// to make is called out rather than passed off as current.
    private func tooltip(for rows: [AccountsController.Row], now: Date) -> String {
        let lines = rows.map { row -> String in
            let marker = row.id == accounts.activeId ? "● " : "　"
            let detail: String
            if row.needsReauth {
                detail = "要再ログイン"
            } else if let window = row.usage?.weekly ?? row.usage?.session {
                let percent = Int(window.effectiveUsedPercent(now: now).rounded())
                detail = row.isStale
                    ? "\(percent)%（前回の値"
                        + (row.lastFetchedAt.map { "・\(RelativeTime.string(from: $0))" } ?? "")
                        + "）"
                    : "\(percent)%"
            } else {
                detail = "取得できません"
            }
            return marker + row.account.displayName + " — " + detail
        }
        return (["Codex Usage（● = ログイン中）"] + lines).joined(separator: "\n")
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
