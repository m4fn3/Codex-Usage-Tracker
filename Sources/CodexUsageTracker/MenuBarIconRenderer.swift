//
//  MenuBarIconRenderer.swift
//  Codex Usage Tracker
//
//  Draws the menu-bar rings. Ported from Claude Usage Tracker's `.icon` style
//  (createIconWithBarStyle): a background ring, a status-colored progress ring
//  starting at 12 o'clock going clockwise, an outer tick marking elapsed time,
//  and the usage percentage as a bare number in the center.
//
//  Supports one or more rings side by side (e.g. Session + Weekly), each with an
//  optional short label (S / W) beneath it.
//

import AppKit

/// One ring's inputs.
struct RingSpec {
    let percent: Double
    let status: UsageStatusLevel
    /// 0…1 position of the elapsed-time tick, or nil to hide it.
    let elapsedFraction: Double?
    /// Short caption drawn under the ring (e.g. "S"/"W"), or nil for none.
    let label: String?
}

enum MenuBarIconRenderer {

    private static let ringSize: CGFloat = 22
    private static let strokeWidth: CGFloat = 3
    private static let gapBetweenRings: CGFloat = 6

    /// Renders a row of rings into a single menu-bar image. When `borderColor` is
    /// set, an oval outline is drawn around the whole group (used to brand/identify
    /// the app — light blue for Codex).
    static func ringsImage(_ specs: [RingSpec], isDark: Bool, borderColor: NSColor? = nil) -> NSImage {
        let radius = (ringSize - 4.0) / 2
        let hasLabels = specs.contains { ($0.label?.isEmpty == false) }
        let labelHeight: CGFloat = hasLabels ? 9 : 0

        let count = CGFloat(max(specs.count, 1))
        let ringsWidth = count * ringSize + (count - 1) * gapBetweenRings
        // Extra room around the rings so the surrounding outline stays clear of them.
        let padX: CGFloat = borderColor != nil ? 4 : 1
        let padY: CGFloat = borderColor != nil ? 3 : 0
        let width = ringsWidth + 2 * padX
        let height = ringSize + labelHeight + 2 * padY

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        let foreground: NSColor = isDark ? .white : .black

        // Soft brand-colored background chip (identifier) behind the rings.
        if let borderColor {
            let inset: CGFloat = 0.75
            let chipRect = NSRect(x: inset, y: inset, width: width - 2 * inset, height: height - 2 * inset)
            let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: 6, yRadius: 6)
            borderColor.withAlphaComponent(0.16).setFill()
            chipPath.fill()
        }

        let ringCenterY = padY + labelHeight + ringSize / 2

        var x: CGFloat = padX
        for spec in specs {
            let center = NSPoint(x: x + ringSize / 2, y: ringCenterY)
            drawRing(center: center, radius: radius, spec: spec, foreground: foreground)

            if hasLabels, let label = spec.label, !label.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                    .foregroundColor: foreground.withAlphaComponent(0.85)
                ]
                let text = label as NSString
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: center.x - size.width / 2, y: 0), withAttributes: attrs)
            }
            x += ringSize + gapBetweenRings
        }
        return image
    }

    /// Convenience for a single ring (no label).
    static func ringImage(
        percent: Double,
        status: UsageStatusLevel,
        elapsedFraction: Double?,
        isDark: Bool
    ) -> NSImage {
        ringsImage(
            [RingSpec(percent: percent, status: status, elapsedFraction: elapsedFraction, label: nil)],
            isDark: isDark
        )
    }

    // MARK: - Drawing

    /// Draws one ring (background, colored progress, elapsed tick, center number)
    /// centered at `center` into the current graphics context.
    private static func drawRing(
        center: NSPoint,
        radius: CGFloat,
        spec: RingSpec,
        foreground: NSColor
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

        // Progress ring (clockwise from 12 o'clock)
        if fraction > 0 {
            let startAngle: CGFloat = 90
            let endAngle = startAngle - 360 * fraction
            let arcPath = NSBezierPath()
            arcPath.appendArc(withCenter: center, radius: radius,
                              startAngle: startAngle, endAngle: endAngle, clockwise: true)
            spec.status.nsColor.setStroke()
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
        let valueText = "\(Int(clamped.rounded()))" as NSString
        let fontSize: CGFloat = valueText.length >= 3 ? 7.0 : 9.0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: foreground
        ]
        let textSize = valueText.size(withAttributes: attrs)
        valueText.draw(
            at: NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2),
            withAttributes: attrs
        )
    }
}
