import Foundation
import Testing
@testable import Meter

@Test @MainActor func providerTogglesRemainObservableAndPersisted() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = UsageStore(defaults: defaults, refreshOnEnable: false)
    #expect(!store.enabled(.cursor))
    #expect(!store.enabled(.commandCode))

    store.setEnabled(true, for: .cursor)
    store.setEnabled(true, for: .commandCode)
    #expect(store.enabled(.cursor))
    #expect(store.enabled(.commandCode))

    let restored = UsageStore(defaults: defaults, refreshOnEnable: false)
    #expect(restored.enabled(.cursor))
    #expect(restored.enabled(.commandCode))
}
