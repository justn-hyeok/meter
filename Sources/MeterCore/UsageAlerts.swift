import Foundation

public struct UsageAlert: Sendable, Equatable {
    public let provider: ProviderID
    public let bucketID: String
    public let label: String
    public let threshold: Int
    public let percentageUsed: Double

    public var title: String { "\(provider.title) at \(threshold)%" }
    public var body: String {
        "\(label) is \(String(format: "%.0f", percentageUsed))% used."
    }
}

/// Decides when a usage window deserves a notification, and remembers what it already
/// said so a window that sits above a threshold is announced once rather than every
/// five minutes.
public struct UsageAlertTracker: Sendable {
    public static let defaultThresholds = [80, 95]

    private struct Fired: Equatable {
        var threshold: Int
        var resetAt: Date?
    }

    private let thresholds: [Int]
    private var fired: [String: Fired] = [:]

    public init(thresholds: [Int] = UsageAlertTracker.defaultThresholds) {
        self.thresholds = thresholds.sorted()
    }

    public mutating func alerts(for snapshots: [UsageSnapshot]) -> [UsageAlert] {
        var alerts: [UsageAlert] = []
        for snapshot in snapshots where snapshot.state != .unavailable {
            for bucket in snapshot.buckets {
                guard let percentage = bucket.percentageUsed else { continue }
                let key = "\(snapshot.provider.rawValue)/\(bucket.id)"
                // A new window starts the bucket over.
                if let previous = fired[key], previous.resetAt != bucket.resetAt {
                    fired[key] = nil
                }

                guard let reached = thresholds.last(where: { Double($0) <= percentage }) else {
                    // Back under every threshold: the next crossing is worth announcing again.
                    fired[key] = nil
                    continue
                }

                // Only an escalation is news. Rolling windows decay as old usage ages out, so
                // sliding from the 95 band back into the 80 band is not a crossing, and
                // announcing it made an oscillating window notify on every refresh forever.
                if let previous = fired[key], reached <= previous.threshold { continue }

                fired[key] = Fired(threshold: reached, resetAt: bucket.resetAt)
                alerts.append(.init(
                    provider: snapshot.provider,
                    bucketID: bucket.id,
                    label: bucket.label,
                    threshold: reached,
                    percentageUsed: percentage
                ))
            }
        }
        return alerts
    }
}
