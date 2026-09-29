import Foundation

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case cursor
    case deepSeek = "deepseek"
    case commandCode = "command-code"
    case openCodeGo = "opencode-go"

    public var id: String { rawValue }

    /// Whether Meter is handed this provider's credential rather than finding it on the
    /// machine. Those are the only ones `meter set-key` applies to.
    public var acceptsStoredKey: Bool {
        self == .deepSeek || self == .commandCode || self == .claude || self == .openCodeGo
    }

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .deepSeek: "DeepSeek API"
        case .commandCode: "Command Code GOAT"
        case .openCodeGo: "OpenCode Go"
        }
    }
}

extension ProviderID {
    /// Providers that can hold more than one account. Only those Meter is handed an API key
    /// for: the rest belong to an app or CLI that is signed in to one account at a time, and
    /// Meter reads that login rather than keeping one of its own.
    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public var acceptsNamedAccounts: Bool {
        self == .deepSeek || self == .commandCode || self == .openCodeGo
    }
}

/// One account of one provider: what a card, a toggle and a place in the order belong to.
///
/// The default account has no name and is written exactly as the provider always was, so
/// settings, the key file and JSON from before accounts existed all still mean the same.
/// A named account is written `provider#name`.
public struct Account: Hashable, Sendable, Identifiable, CustomStringConvertible {
    public let provider: ProviderID
    public let name: String?

    public init(_ provider: ProviderID, name: String? = nil) {
        self.provider = provider
        self.name = name
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let provider = ProviderID(rawValue: String(parts[0])) else { return nil }
        if parts.count == 1 {
            self.init(provider)
        } else {
            let name = String(parts[1])
            guard provider.acceptsNamedAccounts, Self.isValid(name: name) else { return nil }
            self.init(provider, name: name)
        }
    }

    public var rawValue: String { name.map { "\(provider.rawValue)#\($0)" } ?? provider.rawValue }
    public var id: String { rawValue }
    public var description: String { rawValue }
    public var title: String { name.map { "\(provider.title) · \($0)" } ?? provider.title }

    /// The default account and two named ones.
    public static let limitPerProvider = 3

    /// Short enough for a card title, and free of the separator and of anything that would
    /// need quoting in a shell.
    public static func isValid(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed == name && name.count <= 20
            && !name.contains("#") && !name.contains(where: \.isNewline)
    }

    /// Every account on this machine: each provider's default, then the named accounts in
    /// the key file.
    public static func all(in secrets: SecretStore) -> [Account] {
        ProviderID.allCases.map { Account($0) } + secrets.namedAccounts()
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
    public var id: Account { accountID }
    public private(set) var provider: ProviderID
    /// The account's name, absent for the default account so its JSON is unchanged.
    public private(set) var account: String?
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

    public var accountID: Account { Account(provider, name: account) }

    /// The same snapshot, filed under `account`.
    public func `for`(_ account: Account) -> Self {
        var copy = self
        copy.provider = account.provider
        copy.account = account.name
        return copy
    }

    public static func unavailable(_ provider: ProviderID, _ message: String) -> Self {
        .init(provider: provider, buckets: [], fetchedAt: .now, source: "none", state: .unavailable, message: message)
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async -> UsageSnapshot
}
