import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case cursor
    case deepSeek = "deepseek"
    case commandCode = "command-code"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .deepSeek: "DeepSeek API"
        case .commandCode: "Command Code GOAT"
        }
    }
}

enum UsageUnit: String, Codable, Sendable {
    case percent, usd, credits, tokens, unknown
}

struct UsageBucket: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let label: String
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let resetAt: Date?
    let unit: UsageUnit

    var fractionUsed: Double? {
        if unit == .percent, let used { return min(max(used / 100, 0), 1) }
        guard let used, let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }
}

enum SnapshotState: String, Codable, Sendable {
    case live, stale, unavailable
}

struct UsageSnapshot: Identifiable, Codable, Sendable, Equatable {
    var id: ProviderID { provider }
    let provider: ProviderID
    let buckets: [UsageBucket]
    let fetchedAt: Date
    let source: String
    let state: SnapshotState
    let message: String?

    static func unavailable(_ provider: ProviderID, _ message: String) -> Self {
        .init(provider: provider, buckets: [], fetchedAt: .now, source: "none", state: .unavailable, message: message)
    }
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async -> UsageSnapshot
}
