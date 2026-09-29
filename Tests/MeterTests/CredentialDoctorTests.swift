import Foundation
import Testing
@testable import MeterCore

private func machine(
    environment: [String: String] = [:],
    secrets: SecretStore,
    keychain: @escaping @Sendable (String) -> Keychain.Presence = { _ in .missing },
    files: Set<String> = [],
    codexExecutable: URL? = nil,
    openCodeGoKey: Bool = false
) -> DiagnosticEnvironment {
    DiagnosticEnvironment(
        environment: environment,
        secrets: secrets,
        keychain: keychain,
        fileExists: { files.contains($0.lastPathComponent) },
        codexExecutable: { codexExecutable },
        openCodeGoKey: { openCodeGoKey }
    )
}

private func emptyStore() -> (SecretStore, () -> Void) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MeterTests-\(UUID().uuidString)")
    return (SecretStore(fileURL: directory.appending(path: "credentials.json")),
            { try? FileManager.default.removeItem(at: directory) })
}

private func status(_ provider: ProviderID, _ machine: DiagnosticEnvironment) -> CredentialStatus {
    CredentialDoctor.diagnose([provider], in: machine)[0]
}

@Test func anEnvironmentOnlyKeyIsReportedAsUnusableByTheApp() throws {
    let (store, cleanup) = emptyStore()
    defer { cleanup() }

    // The shell sees it; the app Finder launches does not. Reporting this as ready let
    // `doctor --strict` pass while the DeepSeek card stayed empty forever.
    let environmentOnly = status(.deepSeek, machine(environment: ["DEEPSEEK_API_KEY": "sk-shell"], secrets: store))
    #expect(environmentOnly.availability == .blocked)
    #expect(!environmentOnly.isUsable)
    #expect(environmentOnly.detail.contains("this shell only"))

    try store.setSecret("sk-stored", for: .deepSeek)
    let stored = status(.deepSeek, machine(environment: ["DEEPSEEK_API_KEY": "sk-shell"], secrets: store))
    #expect(stored.availability == .ready)
    #expect(stored.detail == "stored key present")
}

@Test func missingKeysSayHowToSupplyThem() throws {
    let (store, cleanup) = emptyStore()
    defer { cleanup() }
    let result = status(.deepSeek, machine(secrets: store))
    #expect(result.availability == .missing)
    #expect(result.detail.contains("meter set-key deepseek"))
}

@Test func commandCodeAcceptsTheLoginItsOwnCLIWrote() throws {
    let (store, cleanup) = emptyStore()
    defer { cleanup() }

    #expect(status(.commandCode, machine(secrets: store)).availability == .missing)
    let fromCLI = status(.commandCode, machine(secrets: store, files: ["auth.json"]))
    #expect(fromCLI.availability == .ready)
    #expect(fromCLI.detail.contains("auth.json"))
}

@Test func aLockedKeychainIsBlockedRatherThanMissing() throws {
    let (store, cleanup) = emptyStore()
    defer { cleanup() }

    let locked = status(.cursor, machine(secrets: store, keychain: { _ in .blocked }))
    #expect(locked.availability == .blocked)
    // Telling the user to sign in again would have been wrong: the credential is there.
    #expect(!locked.detail.contains("sign in"))

    #expect(status(.cursor, machine(secrets: store, keychain: { _ in .present })).availability == .ready)
    #expect(status(.cursor, machine(secrets: store, keychain: { _ in .missing })).availability == .missing)
    #expect(status(.claude, machine(secrets: store, keychain: { _ in .unknown(-25308) })).availability == .blocked)
}

@Test func codexIsDiagnosedThroughBothPathsAFetchCanTake() throws {
    let (store, cleanup) = emptyStore()
    defer { cleanup() }
    let codex = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")

    // Signed in through the app with no auth file: a fetch succeeds via the app-server, so
    // reporting "missing" turned a working provider into a red CI gate.
    let appServerOnly = status(.codex, machine(secrets: store, codexExecutable: codex))
    #expect(appServerOnly.availability == .ready)
    #expect(appServerOnly.detail.contains("no ~/.codex/auth.json"))

    let fileOnly = status(.codex, machine(secrets: store, files: ["auth.json"]))
    #expect(fileOnly.availability == .ready)
    #expect(fileOnly.detail.contains("no Codex executable"))

    #expect(status(.codex, machine(secrets: store, files: ["auth.json"], codexExecutable: codex)).availability == .ready)
    #expect(status(.codex, machine(secrets: store)).availability == .missing)
}

@Test func everyProviderIsDiagnosedAndNoneClaimReadyWithNothingPresent() throws {
    let (store, cleanup) = emptyStore()
    defer { cleanup() }

    let statuses = CredentialDoctor.diagnose(in: machine(secrets: store))
    #expect(statuses.map(\.provider) == ProviderID.allCases)
    // The point the old version missed: with an empty machine, nothing may be ready.
    #expect(statuses.allSatisfy { $0.availability == .missing })
    #expect(statuses.allSatisfy { !$0.source.isEmpty && !$0.detail.isEmpty })
}
