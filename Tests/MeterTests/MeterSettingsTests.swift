import Foundation
import Testing
@testable import MeterCore

@Test func providerTogglesPersistInSharedSettings() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = MeterSettings(defaults: defaults)
    // Everything Meter can collect without extra software is on out of the box; Cursor
    // needs its desktop app, so it is the one provider the user opts into.
    #expect(!settings.enabled(.cursor))
    for provider in ProviderID.allCases where provider != .cursor {
        #expect(settings.enabled(provider))
    }

    settings.setEnabled(true, for: .cursor)
    settings.setEnabled(false, for: .commandCode)
    #expect(settings.enabled(.cursor))
    #expect(!settings.enabled(.commandCode))

    let restored = MeterSettings(defaults: defaults)
    #expect(restored.enabled(.cursor))
    #expect(!restored.enabled(.commandCode))
}

@Test func anExistingInstallDoesNotSilentlyGainProviders() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // An install from before Claude and the Command Code API key existed: the user had
    // turned Cursor on, and the defaults of the day were Codex and DeepSeek.
    defaults.set(true, forKey: "enabled.cursor")

    let settings = MeterSettings(defaults: defaults)
    settings.migrateIfNeeded()

    // Widening the default must not enrol anyone in providers they never chose - it would
    // add permanently failing cards and flip `meter --strict` from 0 to 1.
    #expect(!settings.enabled(.claude))
    #expect(!settings.enabled(.commandCode))
    #expect(settings.enabled(.codex))
    #expect(settings.enabled(.deepSeek))
    #expect(settings.enabled(.cursor))

    // Running again changes nothing.
    settings.migrateIfNeeded()
    #expect(!settings.enabled(.claude))
}

@Test func aFreshInstallGetsTheCurrentDefaults() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = MeterSettings(defaults: defaults)
    settings.migrateIfNeeded()

    #expect(settings.enabled(.claude))
    #expect(settings.enabled(.commandCode))
    #expect(!settings.enabled(.cursor))
}
