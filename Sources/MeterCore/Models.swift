import Foundation

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case cursor
    case deepSeek = "deepseek"
    case commandCode = "command-code"
    case openCodeGo = "opencode-go"
    case openRouter = "openrouter"
    case hive
    case openCodeZen = "opencode-zen"
    case githubCopilot = "github-copilot"
    /// OpenAI-compatible providers the user adds: every account is a named one.
    case custom

    public var id: String { rawValue }

    /// Whether Meter is handed this provider's credential rather than finding it on the
    /// machine. Those are the only ones `meter set-key` applies to.
    public var acceptsStoredKey: Bool {
        self == .deepSeek || self == .commandCode || self == .claude || self == .openCodeGo || self == .openRouter
            || self == .openCodeZen
    }

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .deepSeek: "DeepSeek API"
        case .commandCode: "Command Code GOAT"
        case .openCodeGo: "OpenCode Go"
        case .openRouter: "OpenRouter"
        case .hive: "Hive"
        case .openCodeZen: "OpenCode Zen"
        case .githubCopilot: "GitHub Copilot"
        case .custom: "Custom"
        }
    }
}

extension ProviderID {
    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Providers that can hold more than one account. Only those Meter is handed an API key
    /// for: the rest belong to an app or CLI that is signed in to one account at a time, and
    /// Meter reads that login rather than keeping one of its own.
    public var acceptsNamedAccounts: Bool {
        self == .deepSeek || self == .commandCode || self == .openCodeGo || self == .openRouter
            || self == .openCodeZen || self == .custom
    }

    /// The default account and named ones, together. Custom providers are all named, and
    /// people add several.
    public var accountLimit: Int { self == .custom ? 12 : Account.limitPerProvider }

    /// False for `custom`, which has no default account of its own: only the ones added.
    public var hasDefaultAccount: Bool { self != .custom }
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
    /// A custom provider is called by the name it was added under.
    public var title: String {
        if provider == .custom, let name { return name }
        return name.map { "\(provider.title) · \($0)" } ?? provider.title
    }

    /// The default account and two named ones.
    public static let limitPerProvider = 3

    /// Letters, digits, `-`, `_` and `.`, up to 20 characters, not starting with `-`.
    ///
    /// Letters in any script, so `회사` works. Nothing that needs quoting in a shell: Meter
    /// prints commands with the name in them to be copied, and `deepseek#name` has to stay
    /// one argument. A space, `$` or `;` used to pass, and the printed commands then failed
    /// when pasted; a control character went straight into the terminal.
    public static func isValid(name: String) -> Bool {
        guard !name.isEmpty, name.count <= 20, name.first != "-" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    /// Every account on this machine: each provider's default, then the named accounts in
    /// the key file.
    public static func all(in secrets: SecretStore) -> [Account] {
        ProviderID.allCases.filter(\.hasDefaultAccount).map { Account($0) } + secrets.namedAccounts()
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

    /// How full the window is for alerts. Dollars with a real cap count here, without
    /// becoming a menu-bar percentage: that ratio has been the wrong number before.
    public var alertFraction: Double? {
        if let fraction = fractionUsed { return fraction }
        guard unit == .usd, let used, let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }
}

public enum SnapshotState: String, Codable, Sendable {
    case live, stale, unavailable
}

/// Something the user can act on, beside the figures. Carried as data rather than read out
/// of `message`, so the menu can offer the fix and an alert can fire once on the change.
public enum SnapshotIssue: Codable, Sendable, Equatable {
    /// The credential was refused or has expired; signing in again is the fix.
    case signInRequired
    /// Switched on but never connected: the tile explains how, and nothing alerts.
    case notConnected
    /// The session works now but ends at this time, and nothing on this Mac will renew it.
    case expiresSoon(Date)
}

/// How to sign in again, for the providers whose session belongs to another app or CLI.
/// Providers Meter holds a key for are fixed in the key field instead.
public struct SignInFix: Sendable, Equatable {
    public let instruction: String
    public let command: String?
    public let url: URL?
}

extension ProviderID {
    public var signInFix: SignInFix? {
        switch self {
        case .claude: SignInFix(instruction: "Run claude and type /login", command: "claude", url: nil)
        case .codex: SignInFix(instruction: "Run codex login", command: "codex login", url: nil)
        case .cursor: SignInFix(instruction: "Run cursor-agent login, or sign in to the Cursor app",
                                command: "cursor-agent login", url: URL(string: "https://cursor.com/dashboard"))
        case .openCodeGo: SignInFix(instruction: "Sign in at opencode.ai and copy a new key",
                                    command: nil, url: URL(string: "https://opencode.ai/auth"))
        case .commandCode: SignInFix(instruction: "Sign in again at commandcode.ai",
                                     command: nil, url: URL(string: "https://commandcode.ai"))
        case .hive: SignInFix(instruction: "Sign in at portal.thehive.ai in your browser; Meter picks the session up from there",
                              command: nil, url: URL(string: "https://portal.thehive.ai"))
        case .openCodeZen: SignInFix(instruction: "Sign in at opencode.ai and copy a new key",
                                     command: nil, url: URL(string: "https://opencode.ai/auth"))
        case .githubCopilot: SignInFix(instruction: "Run gh auth login", command: "gh auth login",
                                       url: URL(string: "https://github.com/settings/copilot"))
        case .deepSeek, .openRouter, .custom: nil
        }
    }
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
    /// Absent from JSON written before it existed, and ignored by builds that predate it.
    public var issue: SnapshotIssue?

    public init(provider: ProviderID, buckets: [UsageBucket], fetchedAt: Date, source: String, state: SnapshotState,
                message: String?, issue: SnapshotIssue? = nil) {
        self.provider = provider
        self.buckets = buckets
        self.fetchedAt = fetchedAt
        self.source = source
        self.state = state
        self.message = message
        self.issue = issue
    }

    public var accountID: Account { Account(provider, name: account) }

    /// Last-good figures younger than this still look live. A failed refresh 45 seconds
    /// later used to dim the tile and add "From 45 sec. ago", which stole a row and made
    /// numbers that had just arrived look broken.
    public static let staleVisibleAfter: TimeInterval = 60

    public func isVisiblyStale(now: Date = .now) -> Bool {
        state == .stale && now.timeIntervalSince(fetchedAt) >= Self.staleVisibleAfter
    }

    /// The same snapshot, filed under `account`.
    public func `for`(_ account: Account) -> Self {
        var copy = self
        copy.provider = account.provider
        copy.account = account.name
        return copy
    }

    public static func unavailable(_ provider: ProviderID, _ message: String, issue: SnapshotIssue? = nil) -> Self {
        .init(provider: provider, buckets: [], fetchedAt: .now, source: "none", state: .unavailable, message: message, issue: issue)
    }

    /// The one place a provider's failure becomes a snapshot, so a refused credential is
    /// marked as a sign-in problem whichever provider it came from.
    public static func unavailable(_ provider: ProviderID, _ what: String, error: any Error) -> Self {
        let signIn = (error as? CredentialError).map { if case .signInRequired = $0 { true } else { false } } ?? false
        return unavailable(provider, "\(what): \(error.localizedDescription)", issue: signIn ? .signInRequired : nil)
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async -> UsageSnapshot
}
