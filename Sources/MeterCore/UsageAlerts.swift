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
                let reached = thresholds.last { Double($0) <= percentage }

                // A new window, or usage that fell back below what was announced, re-arms
                // the bucket so the next crossing is reported again.
                if let previous = fired[key],
                   previous.resetAt != bucket.resetAt || (reached ?? 0) < previous.threshold {
                    fired[key] = nil
                }

                guard let reached else { continue }
                if let previous = fired[key], previous.threshold >= reached { continue }

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
