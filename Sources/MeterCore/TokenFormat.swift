import Foundation

/// Token counts as people read them: 950, 12.3k, 4.56M.
public enum TokenFormat {
    /// `fixedWidth` keeps trailing zeros (1.00M, 12.0k) so a column of figures lines up on
    /// its decimal places; the menu drops them.
    public static func compact(_ value: Int, fixedWidth: Bool = false) -> String {
        let magnitude = abs(Double(value))
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let scaled = Double(value) / divisor
            // Three significant figures: enough to compare two rows, few enough to scan.
            let digits = abs(scaled) < 10 ? 2 : abs(scaled) < 100 ? 1 : 0
            let text = String(format: "%.\(digits)f", scaled)
            return (fixedWidth ? text : text.replacingOccurrences(of: #"\.0+$|(\.\d*?)0+$"#, with: "$1", options: .regularExpression)) + suffix
        }
        if magnitude >= 999_500_000 { return scaled(1_000_000_000, "B") }
        if magnitude >= 999_500 { return scaled(1_000_000, "M") }
        if magnitude >= 1_000 { return scaled(1_000, "k") }
        return String(value)
    }
}
