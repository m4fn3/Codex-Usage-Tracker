//
//  MenuBarIconRenderer.swift
//  Codex Usage Tracker
//
//  Draws the menu-bar rings. Ported from Claude Usage Tracker's `.icon` style
//  (createIconWithBarStyle): a background ring, a status-colored progress ring
//  starting at 12 o'clock going clockwise, an outer tick marking elapsed time,
//  and the usage percentage as a bare number in the center.
//
//  Every logged-in account gets its own group of rings, drawn side by side in a
//  fixed order. The light-blue brand chip encloses the whole row — that's what
//  identifies the icon as this app's, so it belongs to the row and not to any one
//  account.
//
//  Which account the `codex` CLI is actually logged in as is shown by color, not
//  by an extra glyph: only the active account's arc is drawn in its status color,
//  the rest go grey. That costs zero menu-bar width — the scarcest thing here —
//  and reads at a glance.
//

import AppKit
import CodexUsageCore

/// Drawn in place of a percentage when there is no number to show. The progress
/// arc and the elapsed tick are skipped for these.
enum RingPlaceholder {
    /// No usable window came back for this account.
    case unknown
    /// The account's tokens are dead; it needs `codex login` again.
    case needsReauth
}

/// One ring's inputs.
struct RingSpec {
    let percent: Double
    let status: UsageStatusLevel
    /// 0…1 position of the elapsed-time tick, or nil to hide it.
    let elapsedFraction: Double?
    /// Short caption drawn under the ring (e.g. "S"/"W"), or nil for none.
    let label: String?
    var placeholder: RingPlaceholder? = nil
}

/// One account's rings, drawn as a unit so the whole account can be highlighted
/// or dimmed together.
struct RingGroup {
    let specs: [RingSpec]
    /// The account currently written to ~/.codex/auth.json. Exactly one group
    /// should carry this — it is the only cue telling the user which login the
    /// CLI would use right now.
    let isActive: Bool
}

enum MenuBarIconRenderer {

    private static let ringSize: CGFloat = 22
    private static let strokeWidth: CGFloat = 3
    private static let gapBetweenRings: CGFloat = 6
    private static let gapBetweenGroups: CGFloat = 4

    /// Padding between the brand chip and the rings inside it.
    private static let padX: CGFloat = 4
    private static let padY: CGFloat = 3

    /// How far the accounts you're not logged in as fade back, on top of losing
    /// their color. The fade is what carries the signal at 0%, where there is no
    /// arc to be colored or greyed; low enough to read as "not this one", high
    /// enough that the numbers stay legible.
    private static let inactiveAlpha: CGFloat = 0.55

    /// Renders one group of rings per account into a single menu-bar image.
    /// `chipColor` is the brand tint (light blue for Codex) washed behind the whole
    /// row — one chip for the icon, not one per account.
    static func groupsImage(_ groups: [RingGroup], isDark: Bool, chipColor: NSColor) -> NSImage {
        let hasLabels = groups.contains { group in
            group.specs.contains { ($0.label?.isEmpty == false) }
        }
        let labelHeight: CGFloat = hasLabels ? 9 : 0
        let height = ringSize + labelHeight + 2 * padY
        let width = groups.map(groupWidth).reduce(0, +)
            + CGFloat(max(groups.count - 1, 0)) * gapBetweenGroups
            + 2 * padX

        let image = NSImage(size: NSSize(width: max(width, 1), height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        let foreground: NSColor = isDark ? .white : .black
        let context = NSGraphicsContext.current?.cgContext

        // The brand chip, around everything: it marks the icon as this app's, so it
        // belongs to the row rather than to any one account.
        let chip = NSRect(x: 0, y: 0, width: width, height: height).insetBy(dx: 0.75, dy: 0.75)
        chipColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()

        var groupX: CGFloat = padX
        for group in groups {
            context?.saveGState()
            // Applied to the whole group — rings, tick and number alike — so an
            // inactive account recedes as one object.
            if !group.isActive { context?.setAlpha(inactiveAlpha) }

            var ringX = groupX
            for spec in group.specs {
                let center = NSPoint(x: ringX + ringSize / 2, y: padY + labelHeight + ringSize / 2)
                drawRing(center: center, radius: (ringSize - 4.0) / 2, spec: spec,
                         foreground: foreground, colored: group.isActive)

                if hasLabels, let label = spec.label, !label.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                        .foregroundColor: foreground.withAlphaComponent(0.85)
                    ]
                    let text = label as NSString
                    let size = text.size(withAttributes: attrs)
                    text.draw(at: NSPoint(x: center.x - size.width / 2, y: padY), withAttributes: attrs)
                }
                ringX += ringSize + gapBetweenRings
            }
            context?.restoreGState()

            groupX += groupWidth(group) + gapBetweenGroups
        }
        return image
    }

    private static func groupWidth(_ group: RingGroup) -> CGFloat {
        let count = CGFloat(max(group.specs.count, 1))
        return count * ringSize + (count - 1) * gapBetweenRings
    }

    // MARK: - Drawing

    /// Draws one ring (background, progress arc, elapsed tick, center number)
    /// centered at `center` into the current graphics context.
    ///
    /// `colored` is what separates the account you're logged in as from the rest:
    /// only it gets the green/orange/red status arc. The others draw the same arc
    /// in plain grey, so the row still reports every account's usage while leaving
    /// exactly one of them looking live.
    private static func drawRing(
        center: NSPoint,
        radius: CGFloat,
        spec: RingSpec,
        foreground: NSColor,
        colored: Bool
    ) {
        let clamped = max(0, min(spec.percent, 100))
        let fraction = CGFloat(clamped / 100.0)

        // Background ring
        let bgPath = NSBezierPath()
        bgPath.appendArc(withCenter: center, radius: radius,
                         startAngle: 0, endAngle: 360, clockwise: false)
        foreground.withAlphaComponent(0.15).setStroke()
        bgPath.lineWidth = strokeWidth
        bgPath.lineCapStyle = .round
        bgPath.stroke()

        // A ring with nothing to report shows a marker instead of a number, and
        // no arc — a 0% arc would read as "fine" when we simply don't know.
        if let placeholder = spec.placeholder {
            let (text, color): (String, NSColor) = switch placeholder {
            case .unknown:      ("–", foreground.withAlphaComponent(0.55))
            // Kept colored even when dimmed: it is an alert, not a usage level, and
            // an account that has fallen out of login is worth noticing wherever
            // it sits in the row.
            case .needsReauth:  ("!", .systemOrange)
            }
            draw(centerText: text, at: center, size: 10, color: color)
            return
        }

        // Progress ring (clockwise from 12 o'clock)
        if fraction > 0 {
            let startAngle: CGFloat = 90
            let endAngle = startAngle - 360 * fraction
            let arcPath = NSBezierPath()
            arcPath.appendArc(withCenter: center, radius: radius,
                              startAngle: startAngle, endAngle: endAngle, clockwise: true)
            (colored ? spec.status.nsColor : foreground.withAlphaComponent(0.45)).setStroke()
            arcPath.lineWidth = strokeWidth
            arcPath.lineCapStyle = .round
            arcPath.stroke()
        }

        // Elapsed-time tick on the outer edge of the ring
        if let elapsed = spec.elapsedFraction {
            let angle = (90 - 360 * elapsed) * .pi / 180
            let innerR = radius - 2.0
            let outerR = radius + 2.0
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: center.x + innerR * cos(angle),
                                  y: center.y + innerR * sin(angle)))
            tick.line(to: NSPoint(x: center.x + outerR * cos(angle),
                                  y: center.y + outerR * sin(angle)))
            foreground.setStroke()
            tick.lineWidth = 2.0
            tick.lineCapStyle = .round
            tick.stroke()
        }

        // Center percentage (bare number; smaller font for 3-digit values)
        let value = "\(Int(clamped.rounded()))"
        draw(centerText: value, at: center, size: value.count >= 3 ? 7.0 : 9.0, color: foreground)
    }

    private static func draw(centerText: String, at center: NSPoint, size: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
            .foregroundColor: color
        ]
        let text = centerText as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2),
            withAttributes: attrs
        )
    }
}
