import Foundation

/// How a usage bucket reads in the menu.
///
/// Lives here rather than in the app so it can be tested: the reset formatting is the part
/// that turns a bare percentage into something you can act on, and it was worth pinning.
public enum UsageFormat {
    public static func value(_ bucket: UsageBucket) -> String {
        if let percentage = bucket.percentageUsed { return String(format: "%.0f%%", percentage) }
        if bucket.unit == .usd {
            if let remaining = bucket.remaining { return String(format: "$%.2f left", remaining) }
            if let used = bucket.used, let limit = bucket.limit {
                return String(format: "$%.2f / $%.2f", used, limit)
            }
            if let used = bucket.used { return String(format: "$%.2f", used) }
        }
        if let remaining = bucket.remaining { return "\(number(remaining)) \(bucket.unit.rawValue)" }
        if let used = bucket.used { return "\(number(used)) \(bucket.unit.rawValue) used" }
        return "—"
    }

    /// Two decimals only when they say something. "0.00 credits" spends three characters
    /// insisting on a precision the value does not have, and it was enough to wrap the row.
    static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        // NumberFormatter rounds half to even by default, so a balance of 64.725 would
        // display as 64.72. Money-shaped figures are expected to round up on a tie.
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// How long until the window clears, in the shortest form that is still exact enough to
    /// act on. A percentage without this is not a decision: 92% with five days left is
    /// trouble and 92% with two hours left is nothing.
    /// Returns nil only when the provider reports no reset at all. A blank column reads as
    /// a rendering fault next to neighbours that have one, so callers show an em dash.
    public static func reset(_ bucket: UsageBucket, now: Date = .now) -> String? {
        guard let resetAt = bucket.resetAt else { return nil }
        let seconds = Int(resetAt.timeIntervalSince(now))
        guard seconds > 0 else { return "due" }
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        return "\(max(1, seconds / 60))m"
    }

    public static func detail(_ bucket: UsageBucket, now: Date = .now) -> String {
        guard let resetAt = bucket.resetAt else { return bucket.label }
        return "\(bucket.label) · resets \(resetAt.formatted(.relative(presentation: .named)))"
    }
}
