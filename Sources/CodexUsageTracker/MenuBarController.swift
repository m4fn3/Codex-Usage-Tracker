//
//  MenuBarController.swift
//  Codex Usage Tracker
//
//  Owns the NSStatusItem, refreshes usage on a timer, renders the ring, and
//  shows the SwiftUI detail popover on click.
//

import AppKit
import SwiftUI

final class MenuBarController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store = UsageStore()
    private var refreshTimer: Timer?

    /// Menu-bar icon refresh cadence.
    private let refreshInterval: TimeInterval = 30

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
                store: store,
                onRefresh: { [weak self] in self?.refresh() },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        // Re-render the ring when the system theme flips (menu-bar text color changes).
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        DistributedNotificationCenter.default.removeObserver(self)
    }

    // MARK: - Appearance

    private var isDarkMenuBar: Bool {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    @objc private func themeChanged() {
        DispatchQueue.main.async { [weak self] in self?.updateButton() }
    }

    // MARK: - Refresh

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = CodexUsageReader.loadLatest()
            DispatchQueue.main.async {
                guard let self else { return }
                self.store.usage = usage
                self.store.didLoad = true
                self.updateButton()
            }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        guard let usage = store.usage else {
            button.image = nil
            button.title = "—"   // no data yet
            return
        }
        // Two rings side by side (no letters, like Claude Usage Tracker):
        // left = session (5-hour window), right = weekly (all models).
        // Each ring shows its percentage in the center, its status color, and
        // an outer tick for how far its window has elapsed.
        let image = MenuBarIconRenderer.ringsImage(
            [
                // Left = Weekly (W), right = Session (S).
                RingSpec(percent: usage.weekly.effectiveUsedPercent,
                         status: usage.weekly.status,
                         elapsedFraction: usage.weekly.elapsedFraction,
                         label: nil),
                RingSpec(percent: usage.session.effectiveUsedPercent,
                         status: usage.session.status,
                         elapsedFraction: usage.session.elapsedFraction,
                         label: nil),
            ],
            isDark: isDarkMenuBar,
            borderColor: Self.codexBorderColor
        )
        image.isTemplate = false   // rings use status colors, so not a template
        button.image = image
        button.title = ""
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
