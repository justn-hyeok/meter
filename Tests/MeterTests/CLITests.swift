import Foundation
import Testing
@testable import MeterCLI
@testable import MeterCore

@Test func parsesDefaultAndProviderStatusCommands() throws {
    #expect(try CLIArgumentParser.parse([]) == .init(command: .status(nil), json: false, strict: false))
    #expect(
        try CLIArgumentParser.parse(["codex", "command-code", "--json", "--strict"])
            == .init(command: .status([.codex, .commandCode]), json: true, strict: true)
    )
    #expect(try CLIArgumentParser.parse(["status", "all"]).command == .status(ProviderID.allCases))
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
    #expect(output.contains(#""schemaVersion" : 1"#))
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
    let result = await app.run(.init(command: .status([.codex, .cursor]), json: false, strict: true))

    #expect(result.exitCode == 1)
    #expect(result.standardOutput.contains("Codex"))
    #expect(result.standardOutput.contains("sign in"))
}

private struct StubProvider: UsageProvider {
    let snapshot: UsageSnapshot
    var id: ProviderID { snapshot.provider }
    func fetch() async -> UsageSnapshot { snapshot }
}
