import Foundation

/// A notification Meter should post.
public struct UsageAlert: Equatable, Sendable {
    /// Also the notification's identifier, so a repeat replaces rather than stacks.
    public let id: String
    public let account: Account
    public let title: String
    public let body: String
}

/// Percents at which a usage window notifies, once each.
///
/// Typed as a comma-separated list in Settings. Empty or unreadable text falls back to
/// the default rather than firing at every refresh or never.
public enum AlertPercents: Sendable {
    public static let defaultValues = [25, 50, 75, 80, 85, 90, 95, 97, 99, 100]
    public static var defaultText: String { display(defaultValues) }

    /// `nil` when nothing in `text` is a percent from 1 to 100.
    public static func parse(_ text: String) -> [Int]? {
        var seen = Set<Int>()
        var values: [Int] = []
        for raw in text.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let token = trimmed.hasSuffix("%") ? trimmed.dropLast() : Substring(trimmed)
            guard let n = Int(token), (1...100).contains(n) else { return nil }
            if seen.insert(n).inserted { values.append(n) }
        }
        return values.isEmpty ? nil : values.sorted()
    }

    public static func display(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: ", ")
    }

    public static func thresholds(from text: String) -> [Double] {
        (parse(text) ?? defaultValues).map { Double($0) / 100 }
    }
}

/// Decides which alerts are due, and remembers which have been sent.
///
/// Pure, so the rules can be tested without a notification centre. Each alert has a key,
/// and an alert is due when its condition holds and its key was not already sent. A key is
/// kept while its condition holds and dropped when it stops — a window falling back below
/// its threshold, a sign-in that works again — so the next time it happens is news again.
/// A rolling reset time is not a new period: Claude's five-hour window moves its reset
/// every refresh, and that used to look like a new window and fire again.
public enum UsageAlerts {
    public static let defaultThresholds: [Double] = AlertPercents.defaultValues.map { Double($0) / 100 }
    /// The tiles' own levels: outlined orange, then red. Kept for callers that still
    /// mean "the two old steps" rather than the configurable list.
    public static let thresholds = [TightestLimit.threshold, TightestLimit.critical]

    public static func evaluate(
        _ snapshots: [UsageSnapshot],
        sent: Set<String>,
        muted: Set<BucketKey> = [],
        thresholds: [Double] = defaultThresholds,
        now: Date = .now
    ) -> (alerts: [UsageAlert], sent: Set<String>) {
        let levels = (thresholds.isEmpty ? defaultThresholds : thresholds).sorted()
        var alerts: [UsageAlert] = []
        var kept: Set<String> = []

        for snapshot in snapshots {
            let account = snapshot.accountID
            let prefix = "\(account.rawValue)|"

            switch snapshot.issue {
            case .signInRequired:
                let key = prefix + "sign-in"
                kept.insert(key)
                if !sent.contains(key) {
                    alerts.append(.init(
                        id: key, account: account,
                        title: "\(account.title): sign in again",
                        body: account.provider.signInFix?.instruction ?? snapshot.message ?? "Its credential was refused."
                    ))
                }
            case .expiresSoon(let expiry):
                let key = prefix + "expires|\(Int(expiry.timeIntervalSince1970))"
                kept.insert(key)
                if !sent.contains(key) {
                    let when = relative(expiry, now)
                    alerts.append(.init(
                        id: key, account: account,
                        title: "\(account.title): sign-in ends \(when)",
                        body: account.provider.signInFix?.instruction ?? "Sign in again before it does."
                    ))
                }
            case .notConnected, nil:
                break
            }

            // Figures that did not arrive this time say nothing new: keep what was sent for
            // them, so a refresh that fails and then recovers does not alert twice.
            guard snapshot.state == .live else {
                kept.formUnion(sent.filter { $0.hasPrefix(prefix + "limit|") })
                continue
            }
            for bucket in snapshot.buckets {
                guard !muted.contains(BucketKey(account: account, bucketID: bucket.id)),
                      let fraction = bucket.fractionUsed,
                      let crossed = levels.last(where: { fraction >= $0 }) else { continue }
                func key(_ threshold: Double) -> String {
                    prefix + "limit|\(bucket.id)|\(Int((threshold * 100).rounded()))"
                }
                // Every level crossed is kept, so dropping from 96% to 90% does not bring
                // the 80% alert back.
                for threshold in levels where threshold <= crossed { kept.insert(key(threshold)) }
                // Only the highest level crossed alerts: a window found at 97% says so once,
                // not once per step below it.
                guard !sent.contains(key(crossed)) else { continue }
                let percent = Int((crossed * 100).rounded())
                var body = "\(Int((fraction * 100).rounded()))% used"
                if let reset = bucket.resetAt {
                    body += " · resets \(relative(reset, now))"
                }
                alerts.append(.init(
                    id: key(crossed), account: account,
                    title: "\(account.title): \(bucket.label) \(percent)%",
                    body: body
                ))
            }
        }
        return (alerts, kept)
    }

    private static func relative(_ date: Date, _ now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
