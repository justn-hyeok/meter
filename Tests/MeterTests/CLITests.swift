import Foundation
import Testing
@testable import MeterCLI
@testable import MeterCore

@Test func parsesDefaultAndProviderStatusCommands() throws {
    #expect(try CLIArgumentParser.parse([]) == .init(command: .status(.enabled), json: false, strict: false))
    #expect(
        try CLIArgumentParser.parse(["codex", "command-code", "--json", "--strict"])
            == .init(command: .status(.named([.provider(.codex), .provider(.commandCode)])), json: true, strict: true)
    )
    #expect(try CLIArgumentParser.parse(["status", "all"]).command == .status(.all))
    #expect(try CLIArgumentParser.parse(["ALL"]).command == .status(.all))
    // Every name typed out is a named list, not `all`: it prints in the order typed.
    let typed = ProviderID.allCases.map(\.rawValue)
    #expect(try CLIArgumentParser.parse(typed).command == .status(.named(ProviderID.allCases.map { .provider($0) })))
    #expect(try CLIArgumentParser.parse(["--short", "--all-windows", "codex"]) ==
        .init(command: .status(.named([.provider(.codex)])), json: false, strict: false, short: true, allWindows: true))
    #expect(try CLIArgumentParser.parse(["watch", "claude", "--refresh"]).command ==
        .watch(.named([.provider(.claude)])))
    #expect(throws: CLIArgumentError.statusOnlyOption) {
        try CLIArgumentParser.parse(["watch", "--json"])
    }
    #expect(try CLIArgumentParser.parse(["cache", "status"]).command == .cacheStatus)
    #expect(try CLIArgumentParser.parse(["--short", "--show-reset", "--max-age=10m"]).maximumAge == 600)
    #expect(throws: CLIArgumentError.invalidMaximumAge("0m")) {
        try CLIArgumentParser.parse(["--max-age", "0m"])
    }
    #expect(throws: CLIArgumentError.invalidMaximumAge("8d")) {
        try CLIArgumentParser.parse(["--max-age", "8d"])
    }
}

@Test func rejectsUnknownProvidersAndMissingMutationTargets() {
    #expect(throws: CLIArgumentError.unknownCommandOrProvider("wat")) {
        try CLIArgumentParser.parse(["wat"])
    }
    #expect(throws: CLIArgumentError.missingProviders("enable")) {
        try CLIArgumentParser.parse(["enable"])
    }
    #expect(throws: CLIArgumentError.statusOnlyOption) {
        try CLIArgumentParser.parse(["providers", "--json"])
    }
}

@Test func formatsStableJSONDates() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = UsageSnapshot(
        provider: .codex,
        buckets: [.init(id: "weekly", label: "Weekly", used: 42, limit: 100, remaining: 58, resetAt: now, unit: .percent)],
        fetchedAt: now,
        source: "test",
        state: .live,
        message: nil
    )

    let output = try CLIJSONFormatter.status([snapshot], now: now)
    #expect(output.contains(#""schemaVersion" : 4"#))
    #expect(output.contains(#""provider" : "codex""#))
    #expect(output.contains("2023-11-14T22:13:20Z"))
}

@Test func strictStatusFailsWhenOneProviderIsUnavailable() async throws {
    let suiteName = "MeterCLITests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let service = UsageService(providers: [
        .codex: StubProvider(snapshot: .init(
            provider: .codex,
            buckets: [.init(id: "weekly", label: "Weekly", used: 10, limit: 100, remaining: 90, resetAt: nil, unit: .percent)],
            fetchedAt: .now,
            source: "test",
            state: .live,
            message: nil
        )),
        .cursor: StubProvider(snapshot: .unavailable(.cursor, "sign in")),
    ])
    let cache = UsageCache(fileURL: FileManager.default.temporaryDirectory
        .appending(path: "MeterCLI-\(UUID().uuidString)/usage-cache.json"))
    let app = MeterCLIApplication(service: service, settings: MeterSettings(defaults: defaults), cache: cache)
    let result = await app.run(.init(command: .status(.named([.provider(.codex), .provider(.cursor)])), json: false, strict: true, refresh: true))

    #expect(result.exitCode == 1)
    #expect(result.standardOutput.contains("Codex"))
    #expect(result.standardOutput.contains("sign in"))
}

@Test func refreshPopulatesCacheAndShortReadsWithoutAProvider() async throws {
    let suiteName = "MeterCLI.Cache.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterCLI-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "usage-cache.json")
    let cache = UsageCache(fileURL: file)
    let snapshot = UsageSnapshot(provider: .claude, buckets: [
        .init(id: "hour", label: "5-hour", used: 35, limit: 100, remaining: 65, resetAt: nil, unit: .percent),
        .init(id: "week", label: "Weekly", used: 27, limit: 100, remaining: 73, resetAt: nil, unit: .percent),
    ], fetchedAt: .now, source: "test", state: .live, message: nil)
    let selection = CLICommand.status(.named([.provider(.claude)]))
    let fetcher = MeterCLIApplication(service: UsageService(providers: [.claude: StubProvider(snapshot: snapshot)]),
                                      settings: MeterSettings(defaults: defaults), cache: cache)
    #expect((await fetcher.run(.init(command: selection, json: false, strict: false, refresh: true))).exitCode == 0)
    let reader = MeterCLIApplication(service: UsageService(providers: [:]),
                                     settings: MeterSettings(defaults: defaults), cache: cache)
    let compact = await reader.run(.init(command: selection, json: false, strict: false, short: true))
    #expect(compact.standardOutput == "Claude 35%")
    #expect(compact.exitCode == 0)
    let all = await reader.run(.init(command: selection, json: false, strict: false, short: true, allWindows: true))
    #expect(all.standardOutput == "Claude 5-hour 35% · Claude Weekly 27%")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
}

@Test func oldCacheIsMarkedStaleWithoutRefreshingIt() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterCLI-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = UsageCache(fileURL: directory.appending(path: "usage-cache.json"))
    let old = Date.now.addingTimeInterval(-700)
    try cache.save([UsageSnapshot(provider: .codex,
        buckets: [.init(id: "week", label: "Weekly", used: 80, limit: 100, remaining: 20, resetAt: nil, unit: .percent)],
        fetchedAt: old, source: "test", state: .live, message: nil)])
    let snapshot = try #require(cache.read()[Account(.codex)])
    #expect(snapshot.state == .stale)
    #expect(CLITextFormatter.short([snapshot]) == "Codex 80% (stale)")
}

@Test func failedRefreshKeepsPreviousValueButMarksItStaleInCache() async throws {
    let suiteName = "MeterCLI.CacheFailure.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterCLI-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = UsageCache(fileURL: directory.appending(path: "usage-cache.json"))
    try cache.save([UsageSnapshot(provider: .codex,
        buckets: [.init(id: "week", label: "Weekly", used: 51, limit: 100, remaining: 49, resetAt: nil, unit: .percent)],
        fetchedAt: .now, source: "test", state: .live, message: nil)])
    let app = MeterCLIApplication(service: UsageService(providers: [.codex: StubProvider(snapshot: .unavailable(.codex, "offline"))]),
                                  settings: MeterSettings(defaults: defaults), cache: cache)
    let selection = CLICommand.status(.named([.provider(.codex)]))
    let result = await app.run(.init(command: selection, json: false, strict: true, short: true, refresh: true))
    #expect(result.exitCode == 1)
    #expect(result.standardOutput == "Codex 51% (stale)")
    #expect(cache.read()[Account(.codex)]?.state == .stale)
    let diagnostic = await app.run(.init(command: .cacheStatus, json: false, strict: false))
    #expect(diagnostic.standardOutput.contains("codex  stale"))
    #expect(diagnostic.standardOutput.contains("failed: offline"))
}

@Test func maximumAgeOverridesDefaultAndFailsClosedWithoutStrict() async throws {
    let suiteName = "MeterCLI.MaxAge.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterCLI-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = UsageCache(fileURL: directory.appending(path: "usage-cache.json"))
    let reset = Date.now.addingTimeInterval(7_200)
    try cache.save([UsageSnapshot(provider: .codex,
        buckets: [.init(id: "week", label: "Weekly", used: 77, limit: 100, remaining: 23,
                        resetAt: reset, unit: .percent)],
        fetchedAt: .now.addingTimeInterval(-480), source: "test", state: .live, message: nil)])
    let app = MeterCLIApplication(service: UsageService(providers: [:]),
                                  settings: MeterSettings(defaults: defaults), cache: cache)
    let command = CLICommand.status(.named([.provider(.codex)]))
    let tolerant = await app.run(.init(command: command, json: false, strict: false, short: true,
                                        showReset: true, maximumAge: 600))
    #expect(tolerant.exitCode == 0)
    #expect(tolerant.standardOutput.contains("Codex 77% · resets 1h"))
    let limited = await app.run(.init(command: command, json: false, strict: false, short: true,
                                      maximumAge: 300))
    #expect(limited.exitCode == 1)
    #expect(limited.standardOutput == "Codex 77% (stale)")
}

@Test func oldCacheDocumentRemainsReadableAfterMetadataUpgrade() throws {
    struct LegacyDocument: Encodable {
        let version = 1
        let snapshots: [UsageSnapshot]
    }
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterCLI-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "usage-cache.json")
    let cache = UsageCache(fileURL: file)
    let snapshot = UsageSnapshot(provider: .claude,
        buckets: [.init(id: "week", label: "Weekly", used: 20, limit: 100, remaining: 80, resetAt: nil, unit: .percent)],
        fetchedAt: .now, source: "test", state: .live, message: nil)
    try JSONEncoder().encode(LegacyDocument(snapshots: [snapshot])).write(to: file)
    #expect(cache.read()[Account(.claude)]?.buckets.first?.percentageUsed == 20)
    #expect(cache.details(for: [Account(.claude)])[0].lastAttempt == nil)
    try cache.save([snapshot])
    #expect(cache.details(for: [Account(.claude)])[0].lastAttempt?.succeeded == true)
}

private struct StubProvider: UsageProvider {
    let snapshot: UsageSnapshot
    var id: ProviderID { snapshot.provider }
    func fetch() async -> UsageSnapshot { snapshot }
}

@Test func parsesDoctorCommand() throws {
    #expect(try CLIArgumentParser.parse(["doctor"]).command == .doctor)
    #expect(try CLIArgumentParser.parse(["doctor", "--json"]) == .init(command: .doctor, json: true, strict: false))
    #expect(throws: CLIArgumentError.unexpectedArguments("doctor")) {
        try CLIArgumentParser.parse(["doctor", "codex"])
    }
}

@Test func formatsTheDoctorReport() {
    let output = CLITextFormatter.doctor([
        .init(provider: .cursor, source: "keychain cursor-access-token", availability: .ready, detail: "present"),
        .init(
            provider: .commandCode,
            source: "COMMAND_CODE_API_KEY, stored key, or its CLI login",
            availability: .missing,
            detail: "run 'meter set-key command-code'"
        ),
    ])
    let lines = output.split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].hasPrefix("ready    cursor"))
    #expect(lines[1].hasPrefix("missing  command-code"))
    #expect(lines[1].hasSuffix("run 'meter set-key command-code'"))
}

@Test func parsesKeyCommands() throws {
    #expect(try CLIArgumentParser.parse(["set-key", "deepseek"]).command == .setKey(Account(.deepSeek)))
    #expect(try CLIArgumentParser.parse(["clear-key", "deepseek"]).command == .clearKey(Account(.deepSeek)))

    #expect(throws: CLIArgumentError.oneProviderRequired("set-key")) {
        try CLIArgumentParser.parse(["set-key"])
    }
    #expect(throws: CLIArgumentError.oneProviderRequired("set-key")) {
        try CLIArgumentParser.parse(["set-key", "deepseek", "codex"])
    }
    // Meter finds these credentials itself, so there is nothing to store.
    #expect(throws: CLIArgumentError.providerTakesNoKey(.codex)) {
        try CLIArgumentParser.parse(["set-key", "codex"])
    }
    #expect(try CLIArgumentParser.parse(["set-key", "claude"]).command == .setKey(Account(.claude)))
}

@Test func recognisesClaudeAsAProvider() throws {
    #expect(try CLIArgumentParser.parse(["claude"]).command == .status(.named([.provider(.claude)])))
    #expect(ProviderID.allCases.contains(.claude))
    #expect(ProviderID.claude.acceptsStoredKey)
    #expect(ProviderID.deepSeek.acceptsStoredKey)
}

@Test func colourIsOnlyForAPersonAtATerminal() {
    // `meter | grep` and scripts must never see escape codes.
    #expect(TerminalStyle.detect(environment: [:], isTerminal: false) == .plain)
    #expect(TerminalStyle.detect(environment: ["NO_COLOR": "1"], isTerminal: true) == .plain)
    #expect(TerminalStyle.detect(environment: ["TERM": "dumb"], isTerminal: true) == .plain)
    #expect(TerminalStyle.detect(environment: ["COLORTERM": "truecolor"], isTerminal: true) == .color(trueColor: true))
    #expect(TerminalStyle.detect(environment: ["TERM": "xterm-256color"], isTerminal: true) == .color(trueColor: false))
}

@Test func barsResolveToEighthsOfACell() {
    // Ten columns alone would draw 25% and 29% identically.
    #expect(UsageBarRenderer.render(0.25, width: 10, style: .plain) == "██▌░░░░░░░")
    #expect(UsageBarRenderer.render(0.29, width: 10, style: .plain) == "██▉░░░░░░░")
    #expect(UsageBarRenderer.render(0, width: 10, style: .plain) == "░░░░░░░░░░")
    #expect(UsageBarRenderer.render(1, width: 10, style: .plain) == "██████████")
    // No limit to divide by: no bar at all rather than an empty one that looks like 0%.
    #expect(UsageBarRenderer.render(nil, width: 10, style: .plain) == "          ")
}

@Test func colourBarsUseTheMenusPairAndEmitNothingEmpty() {
    let bar = UsageBarRenderer.render(0.25, width: 10, style: .color(trueColor: true))
    #expect(bar.contains("38;2;217;89;38"))          // spent, orange
    #expect(bar.contains("38;2;57;135;229"))         // left, blue
    #expect(bar.contains("48;2;57;135;229m▌"))       // the shared cell: orange on blue
    let empty = UsageBarRenderer.render(0, width: 10, style: .color(trueColor: true))
    #expect(!empty.contains("217;89;38"))            // no zero-width orange run
}

@Test func statusLinesMatchTheMenuLayout() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = UsageSnapshot(
        provider: .codex,
        buckets: [
            .init(id: "w", label: "Weekly", used: 25, limit: 100, remaining: 75,
                  resetAt: now.addingTimeInterval(4 * 86_400 + 3_600), unit: .percent),
            .init(id: "s", label: "Total spend", used: 136.08, limit: nil, remaining: nil, resetAt: nil, unit: .usd),
        ],
        fetchedAt: now, source: "test", state: .live, message: nil
    )
    let lines = CLITextFormatter.status([snapshot], now: now).split(separator: "\n").map(String.init)
    #expect(lines == [
        "Codex",
        "  Weekly                ██▌░░░░░░░         25%   4d",
        "  Total spend                          $136.08    —",
    ])
}

@Test func onlyAWindowPastEightyPercentIsEmphasised() {
    func snapshot(_ used: Double) -> UsageSnapshot {
        .init(provider: .claude,
              buckets: [.init(id: "w", label: "Weekly", used: used, limit: 100, remaining: 100 - used, resetAt: nil, unit: .percent)],
              fetchedAt: .now, source: "test", state: .live, message: nil)
    }
    #expect(CLITextFormatter.tightestWindow(in: [snapshot(79)]) == nil)
    #expect(CLITextFormatter.tightestWindow(in: [snapshot(81)]) == BucketKey(provider: .claude, bucketID: "w"))
    let coloured = CLITextFormatter.status([snapshot(91)], style: .color(trueColor: true))
    #expect(coloured.contains("\u{1B}[1mWeekly"))
}

@Test func aTieGoesToTheWindowListedFirst() {
    func snapshot(_ provider: ProviderID) -> UsageSnapshot {
        .init(provider: provider,
              buckets: [.init(id: "w", label: "Weekly", used: 90, limit: 100, remaining: 10, resetAt: nil, unit: .percent)],
              fetchedAt: .now, source: "test", state: .live, message: nil)
    }
    // The menu and the CLI share this rule, and both list providers in the arranged order.
    #expect(TightestLimit.find(in: [snapshot(.cursor), snapshot(.codex)]) == BucketKey(provider: .cursor, bucketID: "w"))
    #expect(CLITextFormatter.tightestWindow(in: [snapshot(.claude), snapshot(.codex)]) == BucketKey(provider: .claude, bucketID: "w"))
}

@Test func providersListFollowsTheArrangedOrder() throws {
    let suite = "MeterCLITests.order.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = MeterSettings(defaults: defaults)
    settings.providerOrder = [.commandCode, .cursor, .codex, .claude, .deepSeek, .openCodeGo]

    let names = CLITextFormatter.providers(settings: settings, accounts: ProviderID.allCases.map { Account($0) })
        .split(separator: "\n")
        .map { $0.split(separator: " ", omittingEmptySubsequences: true)[1] }
    #expect(names == ["command-code", "cursor", "codex", "claude", "deepseek", "opencode-go"])
}

@Test func parsesNamedAccounts() throws {
    #expect(try CLIArgumentParser.parse(["set-key", "deepseek", "--name", "work"]).command
        == .setKey(Account(.deepSeek, name: "work")))
    #expect(try CLIArgumentParser.parse(["clear-key", "opencode-go", "--name=회사"]).command
        == .clearKey(Account(.openCodeGo, name: "회사")))
    #expect(try CLIArgumentParser.parse(["deepseek#work", "codex"]).command
        == .status(.named([.account(Account(.deepSeek, name: "work")), .provider(.codex)])))
    #expect(try CLIArgumentParser.parse(["disable", "command-code#side"]).command
        == .disable([.account(Account(.commandCode, name: "side"))]))

    // Subscriptions belong to the one login on this Mac.
    #expect(throws: CLIArgumentError.providerTakesNoNamedAccounts(.claude)) {
        try CLIArgumentParser.parse(["set-key", "claude", "--name", "work"])
    }
    #expect(throws: CLIArgumentError.providerTakesNoNamedAccounts(.codex)) {
        try CLIArgumentParser.parse(["codex#work"])
    }
    #expect(throws: CLIArgumentError.invalidAccountName("a#b")) {
        try CLIArgumentParser.parse(["set-key", "deepseek", "--name", "a#b"])
    }
    #expect(throws: CLIArgumentError.missingAccountName) {
        try CLIArgumentParser.parse(["set-key", "deepseek", "--name"])
    }
    #expect(throws: CLIArgumentError.nameOnlyForKeys) {
        try CLIArgumentParser.parse(["deepseek", "--name", "work"])
    }
    #expect(throws: CLIArgumentError.conflictingAccountName(Account(.deepSeek, name: "work"), "home")) {
        try CLIArgumentParser.parse(["set-key", "deepseek#work", "--name", "home"])
    }
}

@Test func aFourthAccountIsRefusedBeforeAnyKeyIsRead() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MeterTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = SecretStore(fileURL: directory.appending(path: "credentials.json"))
    try secrets.setSecret("sk-a", for: Account(.deepSeek, name: "a"))
    try secrets.setSecret("sk-b", for: Account(.deepSeek, name: "b"))
    let suite = "MeterCLITests.limit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let app = MeterCLIApplication(service: UsageService(providers: [:]), settings: MeterSettings(defaults: defaults), secrets: secrets)
    let result = await app.run(.init(command: .setKey(Account(.deepSeek, name: "c")), json: false, strict: false))
    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("already has 3 accounts"))
    #expect(secrets.namedAccounts() == [Account(.deepSeek, name: "a"), Account(.deepSeek, name: "b")])
}

@Test func namedAccountsAreListedAndTitled() throws {
    let suite = "MeterCLITests.named.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = MeterSettings(defaults: defaults)
    let accounts = ProviderID.allCases.map { Account($0) } + [Account(.deepSeek, name: "work")]

    let lines = CLITextFormatter.providers(settings: settings, accounts: accounts).split(separator: "\n")
    #expect(lines.last == "enabled   deepseek#work DeepSeek API · work")
}

@Test func clearingANamedAccountForgetsItsSwitchAndATypoFails() async throws {
    let secrets = SecretStore.forTests
    let work = Account(.deepSeek, name: "work")
    try secrets.setSecret("sk", for: work)
    let suite = "MeterCLITests.clear.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = MeterSettings(defaults: defaults)
    settings.setEnabled(false, for: work)
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterCLI-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = UsageCache(fileURL: directory.appending(path: "usage-cache.json"))
    try cache.save([UsageSnapshot(provider: .deepSeek,
        buckets: [.init(id: "balance", label: "Balance", used: 10, limit: 100, remaining: 90, resetAt: nil, unit: .percent)],
        fetchedAt: .now, source: "test", state: .live, message: nil).for(work)])
    let app = MeterCLIApplication(service: UsageService(providers: [:]), settings: settings,
                                  secrets: secrets, cache: cache)

    let typo = await app.run(.init(command: .clearKey(Account(.deepSeek, name: "wrok")), json: false, strict: false))
    #expect(typo.exitCode == 64)
    #expect(secrets.secret(for: work) == "sk")

    let removed = await app.run(.init(command: .clearKey(work), json: false, strict: false))
    #expect(removed.exitCode == 0)
    #expect(secrets.secret(for: work) == nil)
    #expect(cache.read()[work] == nil)
    // Added again later, it is on, like any new account.
    #expect(settings.enabled(work))
}

@Test func lateCacheWritesCannotRestoreChangedCredentialsOrOlderObservations() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterCLI-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = UsageCache(fileURL: directory.appending(path: "usage-cache.json"))
    let account = Account(.deepSeek)
    let baseline = Date.now.addingTimeInterval(-30)
    func snapshot(_ percent: Double, fetchedAt: Date, state: SnapshotState) -> UsageSnapshot {
        UsageSnapshot(provider: .deepSeek,
            buckets: [.init(id: "week", label: "Weekly", used: percent, limit: 100,
                            remaining: 100 - percent, resetAt: nil, unit: .percent)],
            fetchedAt: fetchedAt, source: "test", state: state, message: state == .stale ? "offline" : nil)
    }
    try cache.save([snapshot(70, fetchedAt: baseline.addingTimeInterval(20), state: .live)],
                   attemptedAt: baseline.addingTimeInterval(21))
    try cache.save([snapshot(20, fetchedAt: baseline, state: .stale)],
                   attemptedAt: baseline.addingTimeInterval(22), startedAt: baseline)
    #expect(cache.read()[account]?.buckets.first?.percentageUsed == 70)
    try cache.invalidate(account, at: baseline.addingTimeInterval(25))
    try cache.save([snapshot(20, fetchedAt: baseline.addingTimeInterval(27), state: .live)],
                   attemptedAt: baseline.addingTimeInterval(28), startedAt: baseline.addingTimeInterval(24))
    #expect(cache.read()[account] == nil)
    try cache.save([snapshot(5, fetchedAt: baseline.addingTimeInterval(29), state: .live)],
                   attemptedAt: baseline.addingTimeInterval(30), startedAt: baseline.addingTimeInterval(26))
    #expect(cache.read()[account]?.buckets.first?.percentageUsed == 5)
}

@Test func providersPadsNamesByCharacter() throws {
    let suite = "MeterCLITests.pad.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let accounts = [Account(.codex), Account(.deepSeek, name: "café")]
    let lines = CLITextFormatter.providers(settings: MeterSettings(defaults: defaults), accounts: accounts).split(separator: "\n")
    #expect(lines[1] == "enabled   deepseek#café DeepSeek API · café")
    #expect(lines[0] == "enabled   codex         Codex")
}
