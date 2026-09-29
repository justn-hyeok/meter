import Foundation
import Testing
@testable import MeterCore

private func temporaryStore() -> (SecretStore, URL, () -> Void) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "MeterTests-\(UUID().uuidString)")
    let file = directory.appending(path: "credentials.json")
    return (SecretStore(fileURL: file), file, { try? FileManager.default.removeItem(at: directory) })
}

@Test func storesAndReadsBackAProviderKey() throws {
    let (store, file, cleanup) = temporaryStore()
    defer { cleanup() }

    #expect(store.secret(for: .deepSeek) == nil)
    #expect(!store.hasSecret(for: .deepSeek))

    try store.setSecret("sk-example", for: .deepSeek)
    #expect(store.secret(for: .deepSeek) == "sk-example")
    #expect(store.hasSecret(for: .deepSeek))
    // The app and the CLI are separate processes, so a second reader must see the same file.
    #expect(SecretStore(fileURL: file).secret(for: .deepSeek) == "sk-example")
}

@Test func writesTheKeyFileUnreadableByOtherUsers() throws {
    let (store, file, cleanup) = temporaryStore()
    defer { cleanup() }

    try store.setSecret("sk-example", for: .deepSeek)
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    // An atomic write replaces the file, so this also proves the mode is reapplied.
    #expect(mode?.int16Value == 0o600)

    try store.setSecret("sk-second", for: .deepSeek)
    let modeAfterRewrite = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(modeAfterRewrite?.int16Value == 0o600)
}

@Test func trimsWhitespaceAndTreatsBlankAsRemoval() throws {
    let (store, _, cleanup) = temporaryStore()
    defer { cleanup() }

    try store.setSecret("  sk-padded \n", for: .deepSeek)
    #expect(store.secret(for: .deepSeek) == "sk-padded")

    try store.setSecret("   ", for: .deepSeek)
    #expect(store.secret(for: .deepSeek) == nil)
}

@Test func keepsOtherProvidersWhenOneIsRemoved() throws {
    let (store, _, cleanup) = temporaryStore()
    defer { cleanup() }

    try store.setSecret("sk-deepseek", for: .deepSeek)
    try store.setSecret("sk-other", for: .commandCode)
    try store.setSecret(nil, for: .deepSeek)

    #expect(store.secret(for: .deepSeek) == nil)
    #expect(store.secret(for: .commandCode) == "sk-other")
}

@Test func deepSeekPrefersTheEnvironmentAndFallsBackToTheStoredKey() throws {
    let (store, _, cleanup) = temporaryStore()
    defer { cleanup() }

    let withoutAnything = DeepSeekUsageProvider(store: store, environment: [:])
    #expect(withoutAnything.apiKey() == nil)

    try store.setSecret("sk-stored", for: .deepSeek)
    #expect(DeepSeekUsageProvider(store: store, environment: [:]).apiKey() == "sk-stored")

    // An existing shell setup keeps winning so nothing changes for it.
    let withEnvironment = DeepSeekUsageProvider(store: store, environment: ["DEEPSEEK_API_KEY": "sk-env"])
    #expect(withEnvironment.apiKey() == "sk-env")

    // An empty variable is not a key.
    let blankEnvironment = DeepSeekUsageProvider(store: store, environment: ["DEEPSEEK_API_KEY": ""])
    #expect(blankEnvironment.apiKey() == "sk-stored")
}

private func temporaryAuthFile(_ contents: String?) -> (URL, () -> Void) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "MeterTests-\(UUID().uuidString)")
    let file = directory.appending(path: "auth.json")
    if let contents {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(contents.utf8).write(to: file)
    }
    return (file, { try? FileManager.default.removeItem(at: directory) })
}

@Test func commandCodePrefersExplicitKeysOverTheOneItsCLILoggedInWith() throws {
    let (store, _, cleanupStore) = temporaryStore()
    defer { cleanupStore() }
    let (authFile, cleanupAuth) = temporaryAuthFile(#"{"apiKey":"key-from-cli","userId":"u"}"#)
    defer { cleanupAuth() }

    func credential(environment: [String: String]) -> CommandCodeAPIKeyCredential {
        CommandCodeAPIKeyCredential(store: store, environment: environment, cliAuthFile: authFile)
    }

    // Nothing explicit yet, so the CLI's own login is what Meter uses.
    #expect(credential(environment: [:]).apiKey() == "key-from-cli")

    try store.setSecret("key-from-user", for: .commandCode)
    #expect(credential(environment: [:]).apiKey() == "key-from-user")

    #expect(credential(environment: ["COMMAND_CODE_API_KEY": "key-from-env"]).apiKey() == "key-from-env")
    #expect(credential(environment: ["COMMAND_CODE_API_KEY": ""]).apiKey() == "key-from-user")
}

@Test func commandCodeSendsTheKeyAsABearerToken() throws {
    let (store, _, cleanup) = temporaryStore()
    defer { cleanup() }
    let (missingAuthFile, cleanupAuth) = temporaryAuthFile(nil)
    defer { cleanupAuth() }

    let credential = CommandCodeAPIKeyCredential(
        store: store,
        environment: ["COMMAND_CODE_API_KEY": "cc-key"],
        cliAuthFile: missingAuthFile
    )
    #expect(try credential.authHeaders() == ["Authorization": "Bearer cc-key"])
}

@Test func commandCodeAsksForSignInWhenNoKeyExists() throws {
    let (store, _, cleanup) = temporaryStore()
    defer { cleanup() }
    let (missingAuthFile, cleanupAuth) = temporaryAuthFile(nil)
    defer { cleanupAuth() }

    let credential = CommandCodeAPIKeyCredential(store: store, environment: [:], cliAuthFile: missingAuthFile)
    #expect(credential.apiKey() == nil)
    #expect(throws: CredentialError.signInRequired("commandcode.ai")) { try credential.authHeaders() }
}

@Test func everyProviderThatCanStoreAKeyIsOfferedByTheCLI() {
    #expect(ProviderID.deepSeek.acceptsStoredKey)
    #expect(ProviderID.commandCode.acceptsStoredKey)
    // Claude accepts one too: `claude setup-token` issues a long-lived token that avoids
    // the keychain, whose permission Claude Code discards every time it rotates its session.
    #expect(ProviderID.claude.acceptsStoredKey)
    // These two have only a credential Meter finds on the machine.
    #expect(!ProviderID.codex.acceptsStoredKey)
    #expect(!ProviderID.cursor.acceptsStoredKey)
}

@Test func claudePrefersAStoredTokenOverTheKeychain() throws {
    let (store, _, cleanup) = temporaryStore()
    defer { cleanup() }

    // Claude Code rewrites its keychain item every few hours and the rewrite discards the
    // permission macOS recorded for Meter, so the keychain path re-prompts about three
    // times a day. A token from `claude setup-token` is read from Meter's own file instead.
    let fromKeychain = ClaudeSubscriptionCredential(store: store) {
        #"{"claudeAiOauth":{"accessToken":"rotating-token"}}"#
    }
    #expect(try fromKeychain.token() == "rotating-token")
    #expect(fromKeychain.sourceDescription == "keychain Claude Code-credentials")

    try store.setSecret("long-lived-token", for: .claude)
    let stored = ClaudeSubscriptionCredential(store: store) {
        Issue.record("the keychain must not be read once a token is stored")
        return "{}"
    }
    #expect(try stored.token() == "long-lived-token")
    #expect(stored.sourceDescription == "stored Claude token")
    #expect(try stored.authHeaders() == [
        "Authorization": "Bearer long-lived-token",
        "anthropic-beta": "oauth-2025-04-20",
    ])
}

@Test func aRejectedClaudeTokenIsDroppedSoCollectionFallsBackToTheKeychain() throws {
    let (store, _, cleanup) = temporaryStore()
    defer { cleanup() }

    // `claude setup-token` issues a token the usage endpoint answers 403 to, and a stored
    // token takes precedence, so keeping it would leave Claude broken with doctor still
    // reporting ready.
    try store.setSecret("wrong-scope-token", for: .claude)
    let credential = ClaudeSubscriptionCredential(store: store) {
        #"{"claudeAiOauth":{"accessToken":"session-token"}}"#
    }
    #expect(try credential.token() == "wrong-scope-token")

    credential.invalidate()
    #expect(store.secret(for: .claude) == nil)
    #expect(try credential.token() == "session-token")
}
