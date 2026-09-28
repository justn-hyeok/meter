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
