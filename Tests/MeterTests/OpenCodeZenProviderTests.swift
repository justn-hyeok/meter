import Foundation
import Testing
@testable import MeterCore

private func parseZen(_ json: String) throws -> UsageSnapshot {
    try OpenCodeZenUsageParser.parse(Data(json.utf8))
}

private func temporaryAuthFile(_ contents: String) throws -> (URL, () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterZen-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "auth.json")
    try Data(contents.utf8).write(to: file)
    return (file, { try? FileManager.default.removeItem(at: directory) })
}

@Test func zenModelCountIsReportedAsAWorkingKey() throws {
    // `/zen/v1/models` is OpenAI-shaped: the models arrive in `data`.
    let snapshot = try parseZen(#"{"object":"list","data":[{"id":"claude-sonnet-4"},{"id":"gpt-5"},{"id":"kimi-k2"}]}"#)

    #expect(snapshot.provider == .openCodeZen)
    #expect(snapshot.state == .live)
    #expect(snapshot.buckets.count == 1)
    let key = try #require(snapshot.buckets.first)
    #expect(key.id == "key")
    #expect(key.label == "Key works")
    #expect(key.unit == .unknown)
    #expect(key.used == nil && key.limit == nil && key.remaining == nil)
    #expect(snapshot.message == "3 models")
}

@Test func zenReadsABalanceWhenAResponseCarriesOne() throws {
    let top = try parseZen(#"{"data":[{"id":"a"},{"id":"b"}],"balance":12.5}"#)
    #expect(top.buckets.map(\.id) == ["key", "balance"])
    let balance = try #require(top.buckets.last)
    #expect(balance.label == "Balance (USD)")
    #expect(balance.remaining == 12.5)
    #expect(balance.unit == .usd)
    #expect(balance.percentageUsed == nil)
    #expect(top.message == "2 models")

    // Nested under `usage`, and sent as a string.
    let nested = try parseZen(#"{"models":["a"],"usage":{"credits":"7.25"}}"#)
    #expect(nested.buckets.last?.remaining == 7.25)

    // `credits` as an object is not a balance; it must be passed over, not crash the parse.
    let objectCredits = try parseZen(#"{"data":[],"credits":{"amount":5}}"#)
    #expect(objectCredits.buckets.map(\.id) == ["key"])
    #expect(objectCredits.message == "0 models")
}

@Test func zenRejectsAResponseThatIsNotAnObject() {
    #expect(throws: URLError.self) { try parseZen("[]") }
    // Not JSON at all surfaces as JSONSerialization's own error.
    #expect(throws: (any Error).self) { try parseZen("not json") }
}

@Test func zenCredentialPrefersEnvThenStoredThenOpenCodesEntry() throws {
    let (auth, cleanup) = try temporaryAuthFile(
        #"{"opencode-go":{"type":"api","key":"go-key"},"opencode":{"type":"api","key":"zen-key"}}"#
    )
    defer { cleanup() }

    let store = SecretStore.forTests
    #expect(OpenCodeZenCredential(store: store, environment: ["OPENCODE_API_KEY": "env-key"], cliAuthFile: auth).apiKey() == "env-key")

    try store.setSecret("stored-key", for: .openCodeZen)
    #expect(OpenCodeZenCredential(store: store, environment: [:], cliAuthFile: auth).apiKey() == "stored-key")

    try store.setSecret(nil, for: .openCodeZen)
    #expect(OpenCodeZenCredential(store: store, environment: [:], cliAuthFile: auth).apiKey() == "zen-key")
}

/// Go's route refuses Zen's key, so each credential may only read its own entry.
@Test func zenAndGoReadDifferentEntriesOfOneAuthFile() throws {
    let (auth, cleanup) = try temporaryAuthFile(
        #"{"opencode-go":{"type":"api","key":"go-key"},"opencode":{"type":"api","key":"zen-key"}}"#
    )
    defer { cleanup() }

    let store = SecretStore.forTests
    #expect(OpenCodeZenCredential(store: store, environment: [:], cliAuthFile: auth).apiKey() == "zen-key")
    #expect(OpenCodeGoCredential(store: store, environment: [:], cliAuthFile: auth).apiKey() == "go-key")
}

@Test func zenNamedAccountsUseOnlyTheirStoredKey() throws {
    let (auth, cleanup) = try temporaryAuthFile(#"{"opencode":{"type":"api","key":"zen-key"}}"#)
    defer { cleanup() }

    let store = SecretStore.forTests
    let work = Account(.openCodeZen, name: "work")
    let credential = OpenCodeZenCredential(store: store, environment: ["OPENCODE_API_KEY": "env-key"], cliAuthFile: auth, account: work)
    #expect(credential.apiKey() == nil)

    try store.setSecret("work-key", for: work)
    #expect(credential.apiKey() == "work-key")
}

@Test func zenWithoutAKeyAsksForOneAtOpenCode() throws {
    let (auth, cleanup) = try temporaryAuthFile("{}")
    defer { cleanup() }

    let missing = OpenCodeZenCredential(store: SecretStore.forTests, environment: [:], cliAuthFile: auth)
    #expect(throws: CredentialError.signInRequired("opencode.ai")) { try missing.authHeaders() }

    try Data(#"{"opencode":{"type":"api","key":"zen-key"}}"#.utf8).write(to: auth)
    #expect(try missing.authHeaders() == ["Authorization": "Bearer zen-key"])
}

/// Both accounts used to resolve to a provider that only said "not supported yet".
@Test func zenAndCopilotAccountsGetTheirOwnProviders() {
    let store = SecretStore.forTests
    #expect(UsageService.provider(for: Account(.openCodeZen), secrets: store)?.id == .openCodeZen)
    #expect(UsageService.provider(for: Account(.openCodeZen, name: "work"), secrets: store)?.id == .openCodeZen)
    #expect(UsageService.provider(for: Account(.githubCopilot), secrets: store)?.id == .githubCopilot)
    // Copilot belongs to one `gh` login, so it has no named accounts to read.
    #expect(UsageService.provider(for: Account(.githubCopilot, name: "work"), secrets: store) == nil)
}

@Test func doctorReportsWhereAZenKeyWouldComeFrom() throws {
    func machine(_ secrets: SecretStore, environment: [String: String] = [:], files: Set<String> = []) -> DiagnosticEnvironment {
        DiagnosticEnvironment(
            environment: environment,
            secrets: secrets,
            fileExists: { files.contains($0.lastPathComponent) }
        )
    }

    let empty = SecretStore.forTests
    let missing = CredentialDoctor.diagnose([.openCodeZen], in: machine(empty))[0]
    #expect(missing.availability == .missing)
    #expect(missing.source == "API key (env, stored, or OpenCode)")
    #expect(missing.detail.contains("/connect"))

    // OpenCode's auth file may hold either key, so its presence is what the doctor sees.
    let fromOpenCode = CredentialDoctor.diagnose([.openCodeZen], in: machine(empty, files: ["auth.json"]))[0]
    #expect(fromOpenCode.availability == .ready)
    #expect(fromOpenCode.detail.contains("auth.json"))

    let stored = SecretStore.forTests
    try stored.setSecret("zen-key", for: .openCodeZen)
    #expect(CredentialDoctor.diagnose([.openCodeZen], in: machine(stored))[0].detail == "stored key present")

    let environmentOnly = CredentialDoctor.diagnose(
        [.openCodeZen], in: machine(SecretStore.forTests, environment: ["OPENCODE_API_KEY": "shell-key"])
    )[0]
    #expect(environmentOnly.availability == .blocked)
    #expect(environmentOnly.detail.contains("this shell only"))
}
