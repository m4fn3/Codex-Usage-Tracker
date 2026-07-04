//
//  PopoverView.swift
//  Codex Usage Tracker
//
//  The detail panel shown when the menu-bar icon is clicked. Mirrors the
//  Claude Usage Tracker popover: flat bordered "UsageRow" cards with a title,
//  optional tag, right-aligned percentage, a progress bar with an elapsed-time
//  marker, and the reset clock time below.
//   • Session — 5-hour window
//   • All models — weekly window
//

import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    var onRefresh: () -> Void
    var onQuit: () -> Void

    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if let usage = store.usage {
                UsageRow(
                    title: "Session Usage",
                    subtitle: "5-hour window",
                    window: usage.session
                )
                UsageRow(
                    title: "All Models",
                    tag: "Weekly",
                    subtitle: nil,
                    window: usage.weekly
                )
                footer(usage)
            } else {
                emptyState
                footer(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
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
            if let plan = store.usage?.planType, !plan.isEmpty {
                Text(plan.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.didLoad ? "No Codex usage data found" : "Loading…")
                .font(.system(size: 13, weight: .medium))
            if store.didLoad {
                Text("Run Codex at least once so it records rate limits under ~/.codex/sessions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ usage: CodexUsage?) -> some View {
        VStack(spacing: 6) {
            if let usage {
                HStack {
                    Text("Updated \(RelativeTime.string(from: usage.lastUpdated))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
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
        }
        .padding(.top, 2)
    }
}

// MARK: - Usage Row (flat, native style — matches Claude Usage Tracker)

private struct UsageRow: View {
    let title: String
    var tag: String? = nil
    let subtitle: String?
    let window: CodexRateWindow

    private var displayPercentage: Double { window.effectiveUsedPercent }

    private var statusColor: Color {
        switch window.status {
        case .safe:     return .green
        case .moderate: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title row with percentage
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

            // Progress bar with elapsed-time marker
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(statusColor)
                        .frame(width: geometry.size.width * min(displayPercentage / 100.0, 1.0))
                }
                .overlay(alignment: .leading) {
                    let fraction = window.elapsedFraction
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(nsColor: .labelColor))
                        .frame(width: 2.5, height: 8)
                        .offset(x: round(geometry.size.width * fraction) - 0.75)
                }
            }
            .frame(height: 4)

            // Reset clock time (like Claude: "Resets Today 3:59am")
            Text("Resets \(window.effectiveResetsAt.resetClockString())")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
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
    /// "just now", "5m ago", "2h ago", "3d ago".
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
