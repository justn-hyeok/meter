import Foundation
import Testing
@testable import MeterCore

@MainActor
private func makeStore() throws -> (UsageStore, SecretStore, MeterSettings, () -> Void) {
    let suiteName = "MeterSettingsStore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterSettingsStore-\(UUID().uuidString)")
    let secrets = SecretStore(fileURL: directory.appending(path: "credentials.json"))
    let settings = MeterSettings(defaults: defaults)
    let store = UsageStore(settings: settings, service: UsageService(providers: [:]), refreshOnEnable: false,
                           secrets: secrets, cache: UsageCache(fileURL: directory.appending(path: "usage-cache.json")))
    return (store, secrets, settings, {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    })
}

@MainActor
@Test func addingAndRemovingANamedAccount() throws {
    let (store, secrets, _, cleanup) = try makeStore()
    defer { cleanup() }

    try store.addAccount(.deepSeek, name: " work ", key: " sk-1 ")
    let work = Account(.deepSeek, name: "work")
    #expect(secrets.secret(for: work) == "sk-1")
    #expect(store.accounts.contains(work))
    #expect(store.enabled(work))

    #expect(throws: AccountError.exists(work)) { try store.addAccount(.deepSeek, name: "work", key: "sk-2") }
    #expect(throws: AccountError.invalidName("-bad")) { try store.addAccount(.deepSeek, name: "-bad", key: "k") }
    #expect(throws: AccountError.emptyKey) { try store.addAccount(.deepSeek, name: "home", key: "  ") }
    #expect(throws: AccountError.namesNotSupported(.claude)) { try store.addAccount(.claude, name: "x", key: "k") }

    try store.removeAccount(work)
    #expect(secrets.secret(for: work) == nil)
    #expect(!store.accounts.contains(work))
    #expect(throws: AccountError.cannotRemoveDefault(.deepSeek)) { try store.removeAccount(Account(.deepSeek)) }
}

/// An account added from the terminal since the store last loaded still counts.
@MainActor
@Test func theAccountLimitCountsAccountsAddedElsewhere() throws {
    let (store, secrets, _, cleanup) = try makeStore()
    defer { cleanup() }
    try secrets.setSecret("a", for: Account(.openRouter, name: "one"))
    try secrets.setSecret("b", for: Account(.openRouter, name: "two"))
    #expect(throws: AccountError.full(.openRouter)) { try store.addAccount(.openRouter, name: "three", key: "c") }
    #expect(throws: AccountError.exists(Account(.openRouter, name: "one"))) {
        try store.addAccount(.openRouter, name: "one", key: "x")
    }
}

@MainActor
@Test func clearingAStoredKeyShowsAtOnce() throws {
    let (store, secrets, _, cleanup) = try makeStore()
    defer { cleanup() }
    try store.storeKey("sk", for: .deepSeek)
    #expect(store.hasStoredKey(for: .deepSeek))
    try store.clearKey(for: .deepSeek)
    #expect(!store.hasStoredKey(for: .deepSeek))
    #expect(secrets.secret(for: .deepSeek) == nil)
}

@MainActor
@Test func theRefreshIntervalIsSaved() throws {
    let (store, _, settings, cleanup) = try makeStore()
    defer { cleanup() }
    #expect(store.refreshInterval == 300)
    store.refreshInterval = 60
    #expect(settings.refreshInterval == 60)
    // A value the settings window does not offer reads back as the default.
    settings.refreshInterval = 7
    #expect(settings.refreshInterval == 300)
}
