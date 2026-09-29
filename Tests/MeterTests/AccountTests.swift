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
    #expect(Account(rawValue: "deepseek#" + String(repeating: "x", count: 21)) == nil)
    #expect(Account(rawValue: "nope#work") == nil)
    // Nothing a shell would split or interpret, since Meter prints commands with the name.
    for bad in ["my work", "a$b", "a;b", "-x", "🔥", "a\u{1B}[31m"] {
        #expect(!Account.isValid(name: bad), "\(bad)")
    }
    for good in ["work", "회사", "side-2", "a_b.c", "café"] {
        #expect(Account.isValid(name: good), "\(good)")
    }
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
    let service = UsageService(makeProvider: { account in
        switch account {
        case Account(.deepSeek): FixedProvider(used: 10)
        case work: FixedProvider(used: 70)
        default: nil
        }
    })
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
        service: UsageService(makeProvider: { $0.name == nil ? nil : FixedProvider(used: 40) }),
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

@Test func namedAccountsUseOnlyTheirOwnStoredKey() throws {
    let secrets = SecretStore.forTests
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MeterTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let auth = directory.appending(path: "auth.json")
    try Data(#"{"opencode-go":{"type":"api","key":"cli-key"},"apiKey":"cli-key"}"#.utf8).write(to: auth)
    let environment = ["OPENCODE_GO_API_KEY": "env-key", "COMMAND_CODE_API_KEY": "env-key", "DEEPSEEK_API_KEY": "env-key"]

    let work = Account(.openCodeGo, name: "work")
    #expect(OpenCodeGoCredential(store: secrets, environment: environment, cliAuthFile: auth, account: work).apiKey() == nil)
    #expect(CommandCodeAPIKeyCredential(store: secrets, environment: environment, cliAuthFile: auth, account: Account(.commandCode, name: "work")).apiKey() == nil)
    #expect(DeepSeekUsageProvider(store: secrets, environment: environment, account: Account(.deepSeek, name: "work")).apiKey() == nil)

    try secrets.setSecret("work-key", for: work)
    #expect(OpenCodeGoCredential(store: secrets, environment: environment, cliAuthFile: auth, account: work).apiKey() == "work-key")

    // Its missing key points at the command for that account, not at signing in again.
    #expect(CredentialError.missingKey(for: Account(.commandCode, name: "side"), signInAt: "commandcode.ai").errorDescription
        == "no key stored; run 'meter set-key command-code --name side'")
}

@Test func removingAFileThatIsNotThereCreatesNothing() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MeterTests-\(UUID().uuidString)")
    let secrets = SecretStore(fileURL: directory.appending(path: "credentials.json"))
    try secrets.setSecret(nil, for: Account(.deepSeek, name: "work"))
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@MainActor
@Test func anAccountAddedMidDragWaitsForTheDragToEnd() async throws {
    let suite = "AccountTests.drag.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let secrets = SecretStore.forTests
    let store = UsageStore(settings: MeterSettings(defaults: defaults), service: UsageService(providers: [:]), refreshOnEnable: false, secrets: secrets)
    let before = store.order

    store.isReordering = true
    store.move(Account(.codex), to: Account(.cursor), persist: false)
    let dragged = store.order
    try secrets.setSecret("sk", for: Account(.deepSeek, name: "work"))
    store.reloadSettings(includingOrder: false)
    #expect(store.order == dragged)

    // Esc still restores, and the account arrives once the drag is over.
    store.restoreOrder(before)
    #expect(store.order == before)
    store.isReordering = false
    store.reloadSettings(includingOrder: false)
    #expect(store.order.last == Account(.deepSeek, name: "work"))
}
