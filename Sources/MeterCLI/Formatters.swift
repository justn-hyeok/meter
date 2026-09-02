import Foundation
import MeterCore

enum CLITextFormatter {
    static func status(_ snapshots: [UsageSnapshot], now: Date = .now) -> String {
        snapshots.map { snapshot in
            var lines = [snapshot.provider.title]
            if snapshot.buckets.isEmpty {
                lines.append("  unavailable  \(snapshot.message ?? "No usage data")")
            } else {
                lines.append(contentsOf: snapshot.buckets.map { bucket in
                    "  \(padded(bucket.label, to: 28)) \(value(bucket, now: now))"
                })
                if snapshot.state != .live, let message = snapshot.message {
                    lines.append("  \(snapshot.state.rawValue): \(message)")
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func providers(settings: MeterSettings) -> String {
        ProviderID.allCases.map { provider in
            "\(settings.enabled(provider) ? "enabled " : "disabled")  \(provider.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(provider.title)"
        }.joined(separator: "\n")
    }

    private static func padded(_ value: String, to width: Int) -> String {
        guard value.count < width else { return value }
        return value + String(repeating: " ", count: width - value.count)
    }

    private static func value(_ bucket: UsageBucket, now: Date) -> String {
        var components: [String] = []
        switch bucket.unit {
        case .percent:
            if let used = bucket.used { components.append("\(number(used, maximumFractionDigits: 1))% used") }
        case .usd:
            if let remaining = bucket.remaining { components.append("$\(number(remaining, maximumFractionDigits: 2)) remaining") }
            else if let used = bucket.used { components.append("$\(number(used, maximumFractionDigits: 2)) used") }
        default:
            if let used = bucket.used, let limit = bucket.limit {
                components.append("\(number(used, maximumFractionDigits: 2)) / \(number(limit, maximumFractionDigits: 2)) \(bucket.unit.rawValue)")
            } else if let remaining = bucket.remaining {
                components.append("\(number(remaining, maximumFractionDigits: 2)) \(bucket.unit.rawValue) remaining")
            } else if let used = bucket.used {
                components.append("\(number(used, maximumFractionDigits: 2)) \(bucket.unit.rawValue) used")
            }
        }

        if let resetAt = bucket.resetAt {
            components.append(resetDescription(resetAt, now: now))
        }
        return components.isEmpty ? "—" : components.joined(separator: " · ")
    }

    private static func number(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func resetDescription(_ resetAt: Date, now: Date) -> String {
        let seconds = Int(resetAt.timeIntervalSince(now))
        guard seconds > 0 else { return "reset due" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(max(1, minutes))m"
    }
}

private struct CLIJSONEnvelope: Encodable {
    let schemaVersion = 1
    let generatedAt: Date
    let snapshots: [UsageSnapshot]
}

enum CLIJSONFormatter {
    static func status(_ snapshots: [UsageSnapshot], now: Date = .now) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(CLIJSONEnvelope(generatedAt: now, snapshots: snapshots))
        return String(decoding: data, as: UTF8.self)
    }
}
