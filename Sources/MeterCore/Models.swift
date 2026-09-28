import Foundation

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case cursor
    case deepSeek = "deepseek"
    case commandCode = "command-code"

    public var id: String { rawValue }

    /// Whether Meter is handed this provider's credential rather than finding it on the
    /// machine. Those are the only ones `meter set-key` applies to.
    public var acceptsStoredKey: Bool { self == .deepSeek || self == .commandCode }

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .deepSeek: "DeepSeek API"
        case .commandCode: "Command Code GOAT"
        }
    }
}

public enum UsageUnit: String, Codable, Sendable {
    case percent, usd, credits, tokens, unknown
}

public struct UsageBucket: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let used: Double?
    public let limit: Double?
    public let remaining: Double?
    public let resetAt: Date?
    public let unit: UsageUnit

    public init(id: String, label: String, used: Double?, limit: Double?, remaining: Double?, resetAt: Date?, unit: UsageUnit) {
        self.id = id
        self.label = label
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
        self.unit = unit
    }

    public var percentageUsed: Double? {
        if unit == .percent, let used { return min(max(used, 0), 100) }
        // Money is reported as money. Twice a dollar figure was paired with a "limit" that
        // was not a spending cap - Cursor's plan allowance against bonus-inclusive spend,
        // Claude's extra-usage cap - and the ratio drove the menu bar needle. A spend gauge
        // needs its own deliberate design, not this accident.
        guard unit != .usd, let used, let limit, limit > 0 else { return nil }
        return min(max(used / limit * 100, 0), 100)
    }

    public var fractionUsed: Double? {
        percentageUsed.map { $0 / 100 }
    }
}

public enum SnapshotState: String, Codable, Sendable {
    case live, stale, unavailable
}

public struct UsageSnapshot: Identifiable, Codable, Sendable, Equatable {
    public var id: ProviderID { provider }
    public let provider: ProviderID
    public let buckets: [UsageBucket]
    public let fetchedAt: Date
    public let source: String
    public let state: SnapshotState
    public let message: String?

    public init(provider: ProviderID, buckets: [UsageBucket], fetchedAt: Date, source: String, state: SnapshotState, message: String?) {
        self.provider = provider
        self.buckets = buckets
        self.fetchedAt = fetchedAt
        self.source = source
        self.state = state
        self.message = message
    }

    public static func unavailable(_ provider: ProviderID, _ message: String) -> Self {
        .init(provider: provider, buckets: [], fetchedAt: .now, source: "none", state: .unavailable, message: message)
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async -> UsageSnapshot
}
