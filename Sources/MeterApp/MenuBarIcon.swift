import AppKit
import MeterCore

/// The menu bar gauge: the tiles' 270° arc, filled to the window closest to its limit.
///
/// Drawn as an image because MenuBarExtra paints images but not arbitrary views. Below the
/// warning threshold it is a template image, so it takes the menu bar's own colour in light
/// and dark; at the warning and critical levels it switches to the tiles' orange and red,
/// so a limit about to run out is seen without opening the menu.
@MainActor
enum MenuBarIcon {
    enum Level: Equatable { case normal, warning, critical }

    /// Usage is drawn in 5% steps, so the image is rebuilt only when the arc would move.
    static func image(usage: Double?, unavailable: Bool) -> NSImage {
        let step = usage.map { (min(max($0, 0), 1) * 20).rounded() / 20 }
        let level = level(usage)
        let key = "\(step.map { String($0) } ?? "none")-\(unavailable)-\(level)"
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
            let ink = color(level)
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
        image.isTemplate = level == .normal
        image.accessibilityDescription = usage.map { "Meter, highest usage \(Int(($0 * 100).rounded())) percent" } ?? "Meter"
        cache[key] = image
        return image
    }

    static func level(_ usage: Double?) -> Level {
        guard let usage else { return .normal }
        if usage >= TightestLimit.critical { return .critical }
        if usage >= TightestLimit.threshold { return .warning }
        return .normal
    }

    private static func color(_ level: Level) -> NSColor {
        switch level {
        case .normal: .black
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    private static var cache: [String: NSImage] = [:]
}
