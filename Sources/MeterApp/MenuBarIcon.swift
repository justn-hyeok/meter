import AppKit
import MeterCore

/// The menu bar gauge: the tiles' 270° arc, filled to the window closest to its limit.
///
/// Drawn as an image because MenuBarExtra paints images but not arbitrary views. Always a
/// template image, so it takes the menu bar's own colour in light and dark like the icons
/// beside it: a red icon was too loud for a window that can sit at 100% for days, and the
/// fill already says how full it is. Colour is left to the tiles and the alerts.
@MainActor
enum MenuBarIcon {
    /// Usage is drawn in 5% steps, so the image is rebuilt only when the arc would move.
    static func image(usage: Double?, unavailable: Bool) -> NSImage {
        let step = usage.map { (min(max($0, 0), 1) * 20).rounded() / 20 }
        let key = "\(step.map { String($0) } ?? "none")-\(unavailable)"
        if let cached = cache[key] { return cached }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY - 0.5)
            let radius: CGFloat = 7
            let start: CGFloat = 225
            func arc(to fraction: Double) -> NSBezierPath {
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius, startAngle: start,
                               endAngle: start - 270 * CGFloat(fraction), clockwise: true)
                path.lineWidth = 2.2
                path.lineCapStyle = .round
                return path
            }
            let ink = NSColor.black
            ink.withAlphaComponent(0.3).setStroke()
            arc(to: 1).stroke()
            if unavailable {
                // No figures anywhere: an exclamation mark where the needle would be.
                ink.setFill()
                NSBezierPath(roundedRect: NSRect(x: center.x - 1, y: center.y - 1, width: 2, height: 5.5),
                             xRadius: 1, yRadius: 1).fill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 1.1, y: center.y - 4.2, width: 2.2, height: 2.2)).fill()
                return true
            }
            if let step, step > 0 {
                ink.setStroke()
                arc(to: step).stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = usage.map { "Meter, highest usage \(Int(($0 * 100).rounded())) percent" } ?? "Meter"
        cache[key] = image
        return image
    }

    private static var cache: [String: NSImage] = [:]
}
