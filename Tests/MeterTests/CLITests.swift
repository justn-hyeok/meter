import Foundation
import Testing
@testable import MeterCLI
@testable import MeterCore

@Test func parsesDefaultAndProviderStatusCommands() throws {
    #expect(try CLIArgumentParser.parse([]) == .init(command: .status(.enabled), json: false, strict: false))
    #expect(
        try CLIArgumentParser.parse(["codex", "command-code", "--json", "--strict"])
            == .init(command: .status(.named([.codex, .commandCode])), json: true, strict: true)
    )
    #expect(try CLIArgumentParser.parse(["status", "all"]).command == .status(.all))
    // Every name typed out is a named list, not `all`: it prints in the order typed.
    let typed = ProviderID.allCases.map(\.rawValue)
    #expect(try CLIArgumentParser.parse(typed).command == .status(.named(ProviderID.allCases)))
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
    #expect(output.contains(#""schemaVersion" : 2"#))
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
    let app = MeterCLIApplication(service: service, settings: MeterSettings(defaults: defaults))
    let result = await app.run(.init(command: .status(.named([.codex, .cursor])), json: false, strict: true))

    #expect(result.exitCode == 1)
    #expect(result.standardOutput.contains("Codex"))
    #expect(result.standardOutput.contains("sign in"))
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
    #expect(try CLIArgumentParser.parse(["set-key", "deepseek"]).command == .setKey(.deepSeek))
    #expect(try CLIArgumentParser.parse(["clear-key", "deepseek"]).command == .clearKey(.deepSeek))

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
    #expect(try CLIArgumentParser.parse(["set-key", "claude"]).command == .setKey(.claude))
}

@Test func recognisesClaudeAsAProvider() throws {
    #expect(try CLIArgumentParser.parse(["claude"]).command == .status(.named([.claude])))
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
    #expect(CLITextFormatter.tightestWindow(in: [snapshot(81)]) == "claude/w")
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
    #expect(CLITextFormatter.tightestWindow(in: [snapshot(.claude), snapshot(.codex)]) == "claude/w")
}

@Test func providersListFollowsTheArrangedOrder() throws {
    let suite = "MeterCLITests.order.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = MeterSettings(defaults: defaults)
    settings.providerOrder = [.commandCode, .cursor, .codex, .claude, .deepSeek]

    let names = CLITextFormatter.providers(settings: settings)
        .split(separator: "\n")
        .map { $0.split(separator: " ", omittingEmptySubsequences: true)[1] }
    #expect(names == ["command-code", "cursor", "codex", "claude", "deepseek"])
}
