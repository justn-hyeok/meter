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
        ProviderID.allCases.filter(enabled)
    }

    public func setEnabled(_ enabled: Bool, for provider: ProviderID) {
        defaults.set(enabled, forKey: key(for: provider))
    }

    public static func defaultEnabled(_ provider: ProviderID) -> Bool {
        provider == .codex || provider == .deepSeek
    }

    private func key(for provider: ProviderID) -> String {
        "enabled.\(provider.rawValue)"
    }
}
