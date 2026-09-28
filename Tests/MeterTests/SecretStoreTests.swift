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
