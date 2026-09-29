import Foundation

public struct MeterSettings {
    public static let suiteName = "com.justn.meter"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: MeterSettings.suiteName) ?? .standard) {
        self.defaults = defaults
    }

    public func enabled(_ provider: ProviderID) -> Bool {
        enabled(Account(provider))
    }

    /// A named account is on until switched off: adding it was the choice to see it.
    public func enabled(_ account: Account) -> Bool {
        let key = key(for: account)
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return account.name == nil ? Self.defaultEnabled(account.provider) : true
    }

    public func enabledProviders() -> [ProviderID] {
        providerOrder.filter(enabled)
    }

    /// `accounts` in the arranged order, switched-off ones left out.
    public func enabledAccounts(_ accounts: [Account]) -> [Account] {
        order(of: accounts).filter(enabled)
    }

    private static let orderKey = "providers.order"

    /// `accounts` in the order the user arranged them, shared by the menu and the CLI.
    ///
    /// Saved names that are not among `accounts` are skipped and duplicates kept once, and
    /// an account the saved list predates - a provider added in a later version, a newly
    /// named account - joins at the end rather than vanishing.
    public func order(of accounts: [Account]) -> [Account] {
        let byName = Dictionary(accounts.map { ($0.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Account>()
        let saved = (defaults.stringArray(forKey: Self.orderKey) ?? [])
            .compactMap { byName[$0] }
            .filter { seen.insert($0).inserted }
        return saved + accounts.filter { !seen.contains($0) }
    }

    /// Saves `order`, keeping every saved name it does not mention, each after the name it
    /// followed. Those are providers from a newer build and accounts whose key was removed:
    /// writing only what this call knows sent a newer build's providers to the bottom of its
    /// list, and would drop a removed account's place for when it comes back.
    public func saveOrder(_ order: [Account]) {
        var names: [String] = []
        for name in order.map(\.rawValue) where !names.contains(name) { names.append(name) }
        let mentioned = Set(names)
        var previous: String?
        for name in defaults.stringArray(forKey: Self.orderKey) ?? [] {
            if !mentioned.contains(name), !names.contains(name) {
                let index = previous.flatMap { names.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                names.insert(name, at: index)
            }
            if names.contains(name) { previous = name }
        }
        defaults.set(names, forKey: Self.orderKey)
    }

    /// The default accounts alone, for callers with no named accounts in view.
    public var providerOrder: [ProviderID] {
        get { order(of: ProviderID.allCases.map { Account($0) }).map(\.provider) }
        nonmutating set { saveOrder(newValue.map { Account($0) }) }
    }

    public func setEnabled(_ enabled: Bool, for provider: ProviderID) {
        setEnabled(enabled, for: Account(provider))
    }

    public func setEnabled(_ enabled: Bool, for account: Account) {
        defaults.set(enabled, forKey: key(for: account))
    }

    /// On a new install, everything but Cursor, which is the only provider needing
    /// software installed rather than a credential Meter can find or be given.
    public static func defaultEnabled(_ provider: ProviderID) -> Bool {
        provider != .cursor
    }

    private static let migrationKey = "settings.migration"

    /// Pins the choices of an install that predates the wider default.
    ///
    /// `enabled(_:)` falls back to `defaultEnabled` whenever a key is absent, so widening
    /// that default would have switched Claude and Command Code on for everyone who had
    /// never heard of them - two permanently failing cards, and `meter --strict` going from
    /// 0 to 1 for anyone scripting it. Any existing provider key means an existing install,
    /// and its missing providers are written out with the defaults of that version.
    public func migrateIfNeeded() {
        guard defaults.object(forKey: Self.migrationKey) == nil else { return }
        defer { defaults.set(1, forKey: Self.migrationKey) }

        let isExistingInstall = ProviderID.allCases.contains { defaults.object(forKey: key(for: $0)) != nil }
        guard isExistingInstall else { return }

        for provider in ProviderID.allCases where defaults.object(forKey: key(for: provider)) == nil {
            defaults.set(provider == .codex || provider == .deepSeek, forKey: key(for: provider))
        }
    }

    private func key(for provider: ProviderID) -> String {
        key(for: Account(provider))
    }

    private func key(for account: Account) -> String {
        "enabled.\(account.rawValue)"
    }
}
