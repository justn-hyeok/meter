import Foundation

public struct MeterSettings {
    public static let suiteName = "com.justn.meter"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: MeterSettings.suiteName) ?? .standard) {
        self.defaults = defaults
    }

    public func enabled(_ provider: ProviderID) -> Bool {
        let key = key(for: provider)
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return Self.defaultEnabled(provider)
    }

    public func enabledProviders() -> [ProviderID] {
        providerOrder.filter(enabled)
    }

    private static let orderKey = "providers.order"

    /// The order the user arranged the providers in, shared by the menu and the CLI.
    ///
    /// Unknown names are skipped and duplicates kept once, and a provider added in a later
    /// version joins at the end rather than vanishing because the saved list predates it.
    ///
    /// Saving keeps the names this build does not know, after the ones it does. Writing only
    /// the known ones meant that running an older build after a newer one, then dragging a
    /// card, deleted the newer build's providers from the saved order.
    public var providerOrder: [ProviderID] {
        get {
            var seen = Set<ProviderID>()
            let saved = (defaults.stringArray(forKey: Self.orderKey) ?? [])
                .compactMap(ProviderID.init(rawValue:))
                .filter { seen.insert($0).inserted }
            return saved + ProviderID.allCases.filter { !seen.contains($0) }
        }
        nonmutating set {
            var names: [String] = []
            for name in newValue.map(\.rawValue) where !names.contains(name) { names.append(name) }
            let unknown = (defaults.stringArray(forKey: Self.orderKey) ?? [])
                .filter { ProviderID(rawValue: $0) == nil }
            for name in unknown where !names.contains(name) { names.append(name) }
            defaults.set(names, forKey: Self.orderKey)
        }
    }

    public func setEnabled(_ enabled: Bool, for provider: ProviderID) {
        defaults.set(enabled, forKey: key(for: provider))
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
        "enabled.\(provider.rawValue)"
    }
}
