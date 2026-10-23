import Foundation

/// Token counts as people read them: 950, 12.3k, 4.56M.
public enum TokenFormat {
    public static func compact(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let scaled = Double(value) / divisor
            // Three significant figures: enough to compare two rows, few enough to scan.
            let digits = abs(scaled) < 10 ? 2 : abs(scaled) < 100 ? 1 : 0
            return String(format: "%.\(digits)f", scaled)
                .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) + suffix
        }
        if magnitude >= 999_500_000 { return scaled(1_000_000_000, "B") }
        if magnitude >= 999_500 { return scaled(1_000_000, "M") }
        if magnitude >= 1_000 { return scaled(1_000, "k") }
        return String(value)
    }
}
