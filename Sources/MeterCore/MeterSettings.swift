import Foundation

public struct MeterSettings {
    public static let suiteName = "com.justn.meter"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: MeterSettings.suiteName) ?? .standard) {
        self.defaults = defaults
    }

    func enabled(_ provider: ProviderID) -> Bool {
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

    func enabledProviders() -> [ProviderID] {
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
        var previous: String?
        for name in defaults.stringArray(forKey: Self.orderKey) ?? [] {
            if !names.contains(name) {
                let index = previous.flatMap { names.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                names.insert(name, at: index)
            }
            if names.contains(name) { previous = name }
        }
        defaults.set(names, forKey: Self.orderKey)
    }

    /// The default accounts alone. Internal: code that picked this up would leave named
    /// accounts out without noticing.
    var providerOrder: [ProviderID] {
        get { order(of: ProviderID.allCases.filter(\.hasDefaultAccount).map { Account($0) }).map(\.provider) }
        nonmutating set { saveOrder(newValue.map { Account($0) }) }
    }

    func setEnabled(_ enabled: Bool, for provider: ProviderID) {
        setEnabled(enabled, for: Account(provider))
    }

    public func setEnabled(_ enabled: Bool, for account: Account) {
        defaults.set(enabled, forKey: key(for: account))
    }

    /// Drops a removed account's switch, so adding it again brings it back on, as a new
    /// account is. Left behind, a re-added account came back switched off with no word why.
    public func forget(_ account: Account) {
        guard account.name != nil else { return }
        defaults.removeObject(forKey: key(for: account))
    }

    /// On a new install, everything but Cursor, which needs its desktop app, and Hive, which
    /// needs a browser signed in to its portal: most people have neither, and a tile that can
    /// only say "not connected" would be noise. Both are one click away under the tiles.
    public static func defaultEnabled(_ provider: ProviderID) -> Bool {
        ![.cursor, .hive, .openCodeZen, .githubCopilot, .custom].contains(provider)
    }

    // MARK: - Refresh and shortcut

    private static let refreshIntervalKey = "refresh.interval"
    private static let hotKeyKey = "hotkey"

    /// The choices the settings window offers, in seconds.
    public static let refreshIntervals: [TimeInterval] = [60, 120, 300, 600, 900, 1_800]

    /// How often the app refreshes in the background. Five minutes unless changed; a stored
    /// value outside the offered choices falls back to it.
    public var refreshInterval: TimeInterval {
        get {
            let stored = defaults.double(forKey: Self.refreshIntervalKey)
            return Self.refreshIntervals.contains(stored) ? stored : 300
        }
        nonmutating set { defaults.set(newValue, forKey: Self.refreshIntervalKey) }
    }

    /// The global shortcut that opens the menu. Nil means the default, ⌃⌥M.
    public var hotKey: HotKeySetting? {
        get {
            guard let data = defaults.data(forKey: Self.hotKeyKey) else { return nil }
            return try? JSONDecoder().decode(HotKeySetting.self, from: data)
        }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.hotKeyKey)
            } else {
                defaults.removeObject(forKey: Self.hotKeyKey)
            }
        }
    }

    // MARK: - Layout

    private static let tileSizesKey = "tiles.sizes"
    private static let fillGapsKey = "tiles.fillGaps"
    private static let menuWidthKey = "menu.width"
    private static let menuHeightKey = "menu.height"
    private static let hiddenSuggestionsKey = "menu.hiddenSuggestions"
    private static let customProvidersKey = "custom.providers"

    /// Each account's tile size; an account not listed is 2×2.
    public var tileSizes: [Account: TileSize] {
        get {
            let stored = defaults.dictionary(forKey: Self.tileSizesKey) as? [String: String] ?? [:]
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                guard let account = Account(rawValue: key), let size = TileSize(rawValue: value) else { return nil }
                return (account, size)
            })
        }
        nonmutating set {
            defaults.set(Dictionary(uniqueKeysWithValues: newValue.filter { $0.value != .full }.map { ($0.key.rawValue, $0.value.rawValue) }),
                         forKey: Self.tileSizesKey)
        }
    }

    /// Whether a later tile may move up into a hole a bigger one left. On unless switched off.
    public var fillGaps: Bool {
        get { defaults.object(forKey: Self.fillGapsKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.fillGapsKey) }
    }

    public var menuWidth: MenuWidth {
        get { defaults.string(forKey: Self.menuWidthKey).flatMap(MenuWidth.init(rawValue:)) ?? .standard }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.menuWidthKey) }
    }

    public var menuHeight: MenuHeight {
        get { defaults.string(forKey: Self.menuHeightKey).flatMap(MenuHeight.init(rawValue:)) ?? .standard }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.menuHeightKey) }
    }

    /// Switched-off accounts whose "+" chip the user put away; they come back from Settings.
    public var hiddenSuggestions: Set<Account> {
        get { Set((defaults.stringArray(forKey: Self.hiddenSuggestionsKey) ?? []).compactMap(Account.init(rawValue:))) }
        nonmutating set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.hiddenSuggestionsKey) }
    }

    /// Custom OpenAI-compatible providers, by account name. Their keys live in the key file
    /// under `custom#<name>`, like any named account.
    public var customProviders: [String: CustomProviderConfig] {
        get {
            guard let data = defaults.data(forKey: Self.customProvidersKey) else { return [:] }
            return (try? JSONDecoder().decode([String: CustomProviderConfig].self, from: data)) ?? [:]
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.customProvidersKey) }
        }
    }

    // MARK: - Muted windows

    private static let mutedKey = "windows.muted"

    /// Windows not to warn about, shared with the CLI: a window that sits at 100% by design
    /// would otherwise be red in the menu and bold in `meter` for good.
    public var mutedWindows: Set<BucketKey> {
        get { Set((defaults.stringArray(forKey: Self.mutedKey) ?? []).compactMap(BucketKey.init(rawValue:))) }
        nonmutating set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.mutedKey) }
    }

    // MARK: - Alerts

    private static let alertsEnabledKey = "alerts.enabled"
    private static let alertsSentKey = "alerts.sent"
    private static let alertPercentsKey = "alerts.percents"

    /// On unless switched off: an alert is only ever sent for a limit nearly reached or a
    /// sign-in that stopped working.
    public var alertsEnabled: Bool {
        get { defaults.object(forKey: Self.alertsEnabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.alertsEnabledKey) }
    }

    /// The alerts already sent, kept so a relaunch does not send them again.
    public var alertsSent: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.alertsSentKey) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Self.alertsSentKey) }
    }

    /// Comma-separated percents, normalised when a readable list is saved. Junk is ignored
    /// so a half-typed field cannot wipe the last good list.
    public var alertPercentsText: String {
        get { defaults.string(forKey: Self.alertPercentsKey) ?? AlertPercents.defaultText }
        nonmutating set {
            if let values = AlertPercents.parse(newValue) {
                defaults.set(AlertPercents.display(values), forKey: Self.alertPercentsKey)
            }
        }
    }

    public var alertThresholds: [Double] {
        AlertPercents.thresholds(from: alertPercentsText)
    }

    private static let alertPercentsAccountsKey = "alerts.percents.accounts"
    private static let alertPercentsWindowsKey = "alerts.percents.windows"

    /// Provider-wide override, keyed by `account.rawValue`. Missing means the global list.
    public var accountAlertPercents: [String: String] {
        get { defaults.dictionary(forKey: Self.alertPercentsAccountsKey) as? [String: String] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: Self.alertPercentsAccountsKey) }
    }

    /// One window's override, keyed by `BucketKey.rawValue`. Wins over the account list.
    public var windowAlertPercents: [String: String] {
        get { defaults.dictionary(forKey: Self.alertPercentsWindowsKey) as? [String: String] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: Self.alertPercentsWindowsKey) }
    }

    public func alertPercentsText(for account: Account) -> String? {
        accountAlertPercents[account.rawValue]
    }

    /// Empty text clears the override. Unreadable text is ignored.
    public func setAlertPercentsText(_ text: String, for account: Account) {
        accountAlertPercents = written(accountAlertPercents, key: account.rawValue, text: text)
    }

    public func alertPercentsText(for window: BucketKey) -> String? {
        windowAlertPercents[window.rawValue]
    }

    public func setAlertPercentsText(_ text: String, for window: BucketKey) {
        windowAlertPercents = written(windowAlertPercents, key: window.rawValue, text: text)
    }

    public func alertThresholds(for account: Account, bucketID: String) -> [Double] {
        let window = BucketKey(account: account, bucketID: bucketID)
        if let text = windowAlertPercents[window.rawValue] {
            return AlertPercents.thresholds(from: text)
        }
        if let text = accountAlertPercents[account.rawValue] {
            return AlertPercents.thresholds(from: text)
        }
        return alertThresholds
    }

    public var accountAlertThresholds: [String: [Double]] {
        Dictionary(uniqueKeysWithValues: accountAlertPercents.compactMap { key, text in
            AlertPercents.parse(text).map { (key, $0.map { Double($0) / 100 }) }
        })
    }

    public var windowAlertThresholds: [String: [Double]] {
        Dictionary(uniqueKeysWithValues: windowAlertPercents.compactMap { key, text in
            AlertPercents.parse(text).map { (key, $0.map { Double($0) / 100 }) }
        })
    }

    private func written(_ stored: [String: String], key: String, text: String) -> [String: String] {
        var stored = stored
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            stored.removeValue(forKey: key)
        } else if let values = AlertPercents.parse(trimmed) {
            stored[key] = AlertPercents.display(values)
        }
        return stored
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
        let version = defaults.integer(forKey: Self.migrationKey)
        guard version < Self.migrationVersion else { return }
        defer { defaults.set(Self.migrationVersion, forKey: Self.migrationKey) }

        // A recorded version is an install that has run before, even if every provider
        // key has since been left at its default.
        let isExistingInstall = version > 0
            || ProviderID.allCases.contains { defaults.object(forKey: key(for: $0)) != nil }
        guard isExistingInstall else { return }

        if version < 1 {
            for provider in ProviderID.allCases where defaults.object(forKey: key(for: provider)) == nil {
                defaults.set(provider == .codex || provider == .deepSeek, forKey: key(for: provider))
            }
        }
        // Each provider added after an install was made starts off for that install.
        for provider in Self.addedInVersion where provider.version > version {
            if defaults.object(forKey: key(for: provider.id)) == nil {
                defaults.set(false, forKey: key(for: provider.id))
            }
        }
    }

    /// The providers added since migration 1, with the migration version that added them.
    private static let addedInVersion: [(id: ProviderID, version: Int)] = [(.openRouter, 2), (.hive, 3), (.openCodeZen, 4), (.githubCopilot, 4)]
    private static let migrationVersion = 4

    private func key(for provider: ProviderID) -> String {
        key(for: Account(provider))
    }

    private func key(for account: Account) -> String {
        "enabled.\(account.rawValue)"
    }
}

/// A global shortcut as Carbon registers it, with how it reads on screen.
public struct HotKeySetting: Codable, Equatable, Sendable {
    /// A virtual key code, such as `kVK_ANSI_M`.
    public var keyCode: Int
    /// Carbon modifier flags: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    public var modifiers: Int
    /// What the settings window and the menu footer show, such as "⌃⌥M".
    public var display: String
    /// False switches the shortcut off without forgetting it.
    public var isEnabled: Bool

    public init(keyCode: Int, modifiers: Int, display: String, isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
        self.isEnabled = isEnabled
    }

    /// ⌃⌥M: kVK_ANSI_M with controlKey | optionKey.
    public static let standard = HotKeySetting(keyCode: 0x2E, modifiers: 0x1000 | 0x0800, display: "⌃⌥M")
}

/// A custom OpenAI-compatible provider: where it lives. Its key is a named account's key.
public struct CustomProviderConfig: Codable, Equatable, Sendable {
    /// The API's base URL, such as `https://api.moonshot.ai/v1`.
    public var baseURL: String

    public init(baseURL: String) {
        self.baseURL = baseURL
    }
}
