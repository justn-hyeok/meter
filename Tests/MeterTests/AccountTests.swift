import Foundation
import Testing
@testable import MeterCore

@Test func accountNamesRoundTripAndTheDefaultIsTheBareProvider() {
    #expect(Account(.deepSeek).rawValue == "deepseek")
    #expect(Account(rawValue: "deepseek") == Account(.deepSeek))
    #expect(Account(rawValue: "deepseek#회사") == Account(.deepSeek, name: "회사"))
    #expect(Account(.openCodeGo, name: "side").title == "OpenCode Go · side")

    // Only key-based providers take names, and names stay short and unambiguous.
    #expect(Account(rawValue: "claude#work") == nil)
    #expect(Account(rawValue: "deepseek#") == nil)
    #expect(Account(rawValue: "deepseek# padded") == nil)
    #expect(Account(rawValue: "deepseek#" + String(repeating: "x", count: 21)) == nil)
    #expect(Account(rawValue: "nope#work") == nil)
}

@Test func namedAccountsComeFromTheKeyFileAlone() throws {
    let secrets = SecretStore.forTests
    try secrets.setSecret("sk-default", for: .deepSeek)
    try secrets.setSecret("oc-b", for: Account(.openCodeGo, name: "b"))
    try secrets.setSecret("sk-work", for: Account(.deepSeek, name: "work"))

    #expect(secrets.namedAccounts() == [Account(.deepSeek, name: "work"), Account(.openCodeGo, name: "b")])
    // The default account's key is untouched by a named one.
    #expect(secrets.secret(for: .deepSeek) == "sk-default")
    #expect(secrets.secret(for: Account(.deepSeek, name: "work")) == "sk-work")

    try secrets.setSecret(nil, for: Account(.deepSeek, name: "work"))
    #expect(secrets.namedAccounts() == [Account(.openCodeGo, name: "b")])
}

@Test func aNamedAccountIsOnAndJoinsTheEndUntilPlaced() throws {
    let suite = "AccountTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = MeterSettings(defaults: defaults)
    let work = Account(.deepSeek, name: "work")
    let accounts = ProviderID.allCases.map { Account($0) } + [work]

    #expect(settings.enabled(work))
    #expect(settings.order(of: accounts).last == work)

    settings.saveOrder([work] + ProviderID.allCases.map { Account($0) })
    #expect(settings.order(of: accounts).first == work)

    // Its key removed, the account drops out of the order but keeps its place for later.
    settings.saveOrder(ProviderID.allCases.reversed().map { Account($0) })
    #expect(defaults.stringArray(forKey: "providers.order")?.first == "deepseek#work")
    #expect(!settings.order(of: ProviderID.allCases.map { Account($0) }).contains(work))

    settings.setEnabled(false, for: work)
    #expect(!settings.enabled(work))
    #expect(settings.enabled(.deepSeek))
}

@Test func aNamedAccountIsFetchedWithItsOwnProviderAndFiledUnderItsName() async {
    let work = Account(.deepSeek, name: "work")
    let service = UsageService(
        providers: [.deepSeek: FixedProvider(used: 10)],
        named: { $0 == work ? FixedProvider(used: 70) : nil }
    )
    let snapshots = await service.fetch([work, Account(.deepSeek)])
    #expect(snapshots.map(\.accountID) == [work, Account(.deepSeek)])
    #expect(snapshots.map { $0.buckets.first?.used } == [70, 10])
}

@Test func theDefaultAccountsJSONHasNoAccountField() throws {
    let snapshot = UsageSnapshot(provider: .deepSeek, buckets: [], fetchedAt: .now, source: "test", state: .live, message: nil)
    let plain = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(!plain.contains("account"))
    let named = String(decoding: try JSONEncoder().encode(snapshot.for(Account(.deepSeek, name: "work"))), as: UTF8.self)
    #expect(named.contains(#""account":"work""#))
}

@MainActor
@Test func theMenuTakesUpAnAccountAddedOrRemovedByTheCLI() async throws {
    let suite = "AccountTests.store.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let secrets = SecretStore.forTests
    let work = Account(.openCodeGo, name: "work")
    let store = UsageStore(
        settings: MeterSettings(defaults: defaults),
        service: UsageService(providers: [:], named: { _ in FixedProvider(used: 40) }),
        refreshOnEnable: false,
        secrets: secrets
    )
    #expect(!store.order.contains(work))

    // `meter set-key opencode-go --name work`, then the five-minute refresh.
    try secrets.setSecret("oc-work", for: work)
    await store.refreshAll()
    #expect(store.order.last == work)
    #expect(store.enabled(work))
    #expect(store.snapshots[work]?.buckets.first?.used == 40)
    #expect(store.snapshots[work]?.accountID == work)

    // `meter clear-key opencode-go --name work`: the card and its figures go.
    try secrets.setSecret(nil, for: work)
    store.reloadSettings(includingOrder: false)
    #expect(!store.order.contains(work))
    #expect(store.snapshots[work] == nil)
}

private struct FixedProvider: UsageProvider {
    let used: Double
    var id: ProviderID { .deepSeek }

    func fetch() async -> UsageSnapshot {
        .init(
            provider: .deepSeek,
            buckets: [.init(id: "w", label: "Balance", used: used, limit: 100, remaining: 100 - used, resetAt: nil, unit: .percent)],
            fetchedAt: .now, source: "test", state: .live, message: nil
        )
    }
}
