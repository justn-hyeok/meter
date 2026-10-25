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
    #expect(!settings.enabled(.hive))
    for provider in ProviderID.allCases where MeterSettings.defaultEnabled(provider) {
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

@Test func anExistingInstallDoesNotSilentlyGainProviders() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // An install from before Claude and the Command Code API key existed: the user had
    // turned Cursor on, and the defaults of the day were Codex and DeepSeek.
    defaults.set(true, forKey: "enabled.cursor")

    let settings = MeterSettings(defaults: defaults)
    settings.migrateIfNeeded()

    // Widening the default must not enrol anyone in providers they never chose - it would
    // add permanently failing cards and flip `meter --strict` from 0 to 1.
    #expect(!settings.enabled(.claude))
    #expect(!settings.enabled(.commandCode))
    #expect(settings.enabled(.codex))
    #expect(settings.enabled(.deepSeek))
    #expect(settings.enabled(.cursor))

    // Running again changes nothing.
    settings.migrateIfNeeded()
    #expect(!settings.enabled(.claude))
}

@Test func aFreshInstallGetsTheCurrentDefaults() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = MeterSettings(defaults: defaults)
    settings.migrateIfNeeded()

    #expect(settings.enabled(.claude))
    #expect(settings.enabled(.commandCode))
    #expect(!settings.enabled(.cursor))
}

@Test func providerOrderSurvivesRestartsAndAbsorbsNewProviders() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = MeterSettings(defaults: defaults)
    #expect(settings.providerOrder == ProviderID.allCases.filter(\.hasDefaultAccount))

    settings.providerOrder = [.commandCode, .claude, .codex, .cursor, .deepSeek, .openCodeGo, .openRouter, .hive, .openCodeZen, .githubCopilot]
    #expect(MeterSettings(defaults: defaults).providerOrder == [.commandCode, .claude, .codex, .cursor, .deepSeek, .openCodeGo, .openRouter, .hive, .openCodeZen, .githubCopilot])

    // A list saved before a provider existed, with junk and a duplicate in it: the unknown
    // name goes, the duplicate is kept once, and missing providers join at the end.
    defaults.set(["claude", "not-a-provider", "claude", "codex"], forKey: "providers.order")
    #expect(settings.providerOrder == [.claude, .codex, .cursor, .deepSeek, .commandCode, .openCodeGo, .openRouter, .hive, .openCodeZen, .githubCopilot])

    // Enabled providers come back in the arranged order, which is what the CLI prints.
    // Cursor is off by default and DeepSeek is switched off here.
    settings.setEnabled(false, for: .deepSeek)
    #expect(settings.enabledProviders() == [.claude, .codex, .commandCode, .openCodeGo, .openRouter])
}

@Test func savingTheOrderKeepsProvidersFromANewerBuild() throws {
    let suite = "MeterSettingsTests.unknown.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // Written by a newer Meter that knows a provider this one does not.
    defaults.set(["claude", "future-ai", "codex"], forKey: "providers.order")
    let settings = MeterSettings(defaults: defaults)
    #expect(settings.providerOrder.prefix(2) == [.claude, .codex])

    settings.providerOrder = [.codex, .claude, .cursor, .deepSeek, .commandCode, .openCodeGo, .openRouter, .hive, .openCodeZen, .githubCopilot]
    // It stays where the newer build put it: after Claude.
    #expect(defaults.stringArray(forKey: "providers.order")
        == ["codex", "claude", "future-ai", "cursor", "deepseek", "command-code", "opencode-go", "openrouter", "hive", "opencode-zen", "github-copilot"])
}

@Test func anAlreadyMigratedInstallDoesNotGainOpenRouter() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // An install that ran migration 1 before OpenRouter existed, with every switch left
    // at its default: no provider key was ever written.
    defaults.set(1, forKey: "settings.migration")

    let settings = MeterSettings(defaults: defaults)
    settings.migrateIfNeeded()

    #expect(!settings.enabled(.openRouter))
    #expect(settings.enabled(.claude))

    // Switching it on afterwards sticks.
    settings.setEnabled(true, for: .openRouter)
    settings.migrateIfNeeded()
    #expect(settings.enabled(.openRouter))
}
