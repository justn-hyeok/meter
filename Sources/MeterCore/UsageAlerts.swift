import Foundation

/// A notification Meter should post.
public struct UsageAlert: Equatable, Sendable {
    /// Also the notification's identifier, so a repeat replaces rather than stacks.
    public let id: String
    public let account: Account
    public let title: String
    public let body: String
}

/// Decides which alerts are due, and remembers which have been sent.
///
/// Pure, so the rules can be tested without a notification centre. Each alert has a key,
/// and an alert is due when its condition holds and its key was not already sent. A key is
/// kept while its condition holds and dropped when it stops - a window falling back below
/// its threshold, a reset that starts a new period, a sign-in that works again - so the
/// next time it happens is news again.
public enum UsageAlerts {
    /// The tiles' own levels: outlined orange, then red.
    public static let thresholds = [TightestLimit.threshold, TightestLimit.critical]

    public static func evaluate(
        _ snapshots: [UsageSnapshot],
        sent: Set<String>,
        now: Date = .now
    ) -> (alerts: [UsageAlert], sent: Set<String>) {
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
            case nil:
                break
            }

            // Figures that did not arrive this time say nothing new: keep what was sent for
            // them, so a refresh that fails and then recovers does not alert twice.
            guard snapshot.state == .live else {
                kept.formUnion(sent.filter { $0.hasPrefix(prefix + "limit|") })
                continue
            }
            for bucket in snapshot.buckets {
                guard let fraction = bucket.fractionUsed,
                      let crossed = thresholds.last(where: { fraction >= $0 }) else { continue }
                // To the hour: some services report a reset that drifts by seconds between
                // reads, and that must not count as a new period.
                let period = bucket.resetAt.map { String(Int(($0.timeIntervalSince1970 / 3_600).rounded())) } ?? "none"
                func key(_ threshold: Double) -> String {
                    prefix + "limit|\(bucket.id)|\(Int(threshold * 100))|\(period)"
                }
                // Every level crossed is kept, so dropping from 96% to 90% does not bring
                // the 80% alert back.
                for threshold in thresholds where threshold <= crossed { kept.insert(key(threshold)) }
                // Only the highest level crossed alerts: a window found at 97% says so once.
                guard !sent.contains(key(crossed)) else { continue }
                var body = "\(Int((fraction * 100).rounded()))% used"
                if let reset = bucket.resetAt {
                    body += " · resets \(relative(reset, now))"
                }
                alerts.append(.init(
                    id: key(crossed), account: account,
                    title: "\(account.title): \(bucket.label) \(crossed >= TightestLimit.critical ? "almost used up" : "running low")",
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
