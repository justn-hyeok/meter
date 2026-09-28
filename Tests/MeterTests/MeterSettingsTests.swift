import Foundation
import Testing
@testable import MeterCore

@Test func providerTogglesPersistInSharedSettings() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = MeterSettings(defaults: defaults)
    #expect(!settings.enabled(.cursor))
    #expect(!settings.enabled(.commandCode))

    settings.setEnabled(true, for: .cursor)
    settings.setEnabled(true, for: .commandCode)
    #expect(settings.enabled(.cursor))
    #expect(settings.enabled(.commandCode))

    let restored = MeterSettings(defaults: defaults)
    #expect(restored.enabled(.cursor))
    #expect(restored.enabled(.commandCode))
}
