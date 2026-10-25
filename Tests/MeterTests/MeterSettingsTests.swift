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

/// What 0.6.3 left on disk, opened by 0.7: nothing the user chose is lost, the providers 0.7
/// added start off, and the layout settings it introduced read as their defaults.
@Test func anInstallFromBeforeTilesKeepsItsChoicesAndStartsNewProvidersOff() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(3, forKey: "settings.migration")
    defaults.set(true, forKey: "enabled.cursor")
    defaults.set(false, forKey: "enabled.command-code")
    defaults.set(["deepseek", "claude", "codex"], forKey: "providers.order")
    defaults.set(["claude|limit|weekly_all|25"], forKey: "alerts.sent")
    defaults.set(["cursor|other-models"], forKey: "windows.muted")
    defaults.set(15 * 60, forKey: "refresh.interval")

    let settings = MeterSettings(defaults: defaults)
    settings.migrateIfNeeded()

    // Kept.
    #expect(settings.enabled(.cursor))
    #expect(!settings.enabled(.commandCode))
    #expect(settings.enabled(.claude))
    #expect(settings.enabled(.codex))
    #expect(Array(settings.providerOrder.prefix(3)) == [.deepSeek, .claude, .codex])
    #expect(defaults.stringArray(forKey: "alerts.sent") == ["claude|limit|weekly_all|25"])
    #expect(defaults.stringArray(forKey: "windows.muted") == ["cursor|other-models"])

    // New in 0.7: off, and nothing else turned on.
    #expect(!settings.enabled(.openCodeZen))
    #expect(!settings.enabled(.githubCopilot))
    #expect(settings.providerOrder.contains(.openCodeZen))
    #expect(settings.providerOrder.contains(.githubCopilot))
    #expect(!settings.providerOrder.contains(.custom))

    // Layout settings that did not exist: the 0.6 menu, unchanged.
    #expect(settings.tileSizes.isEmpty)
    #expect(settings.menuWidth == .standard)
    #expect(settings.menuHeight == .standard)
    #expect(settings.fillGaps)
    #expect(settings.hiddenSuggestions.isEmpty)
    #expect(settings.customProviders.isEmpty)
    #expect(settings.alertPercentsText == AlertPercents.defaultText)

    // Running it again changes nothing.
    settings.migrateIfNeeded()
    #expect(!settings.enabled(.openCodeZen))
    #expect(defaults.integer(forKey: "settings.migration") == 4)
}

@Test func alertPercentsDefaultAndIgnoreJunk() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = MeterSettings(defaults: defaults)
    #expect(settings.alertPercentsText == AlertPercents.defaultText)
    #expect(settings.alertThresholds == UsageAlerts.defaultThresholds)

    settings.alertPercentsText = "100, 80"
    #expect(MeterSettings(defaults: defaults).alertPercentsText == "80, 100")

    settings.alertPercentsText = "nope"
    #expect(MeterSettings(defaults: defaults).alertPercentsText == "80, 100")
}

@Test func alertPercentsOverridesPreferWindowThenAccount() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = MeterSettings(defaults: defaults)
    let claude = Account(.claude)
    let window = BucketKey(provider: .claude, bucketID: "week")

    settings.alertPercentsText = "80, 95"
    settings.setAlertPercentsText("50", for: claude)
    #expect(settings.alertPercentsText(for: claude) == "50")
    #expect(settings.alertThresholds(for: claude, bucketID: "week") == [0.5])

    settings.setAlertPercentsText("100", for: window)
    #expect(settings.alertPercentsText(for: window) == "100")
    #expect(settings.alertThresholds(for: claude, bucketID: "week") == [1.0])
    #expect(settings.alertThresholds(for: Account(.cursor), bucketID: "week") == [0.8, 0.95])

    settings.setAlertPercentsText("junk", for: claude)
    #expect(settings.alertPercentsText(for: claude) == "50")

    settings.setAlertPercentsText("  ", for: window)
    #expect(settings.alertPercentsText(for: window) == nil)
    #expect(settings.alertThresholds(for: claude, bucketID: "week") == [0.5])

    settings.setAlertPercentsText("", for: claude)
    #expect(settings.alertPercentsText(for: claude) == nil)
    #expect(settings.alertThresholds(for: claude, bucketID: "week") == [0.8, 0.95])
}
