import Foundation
import Testing
@testable import MeterCLI
@testable import MeterCore

private let fixedNow = TokenLogFixtures.date("2026-10-21T12:00:00.000Z")

private func lines(_ output: String) -> [String] {
    output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

private func json(_ output: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
}

// MARK: - meter tokens

@Test func tokensTextSumsTheFixtureByProviderAndModel() throws {
    let result = TokensCommand.tokens(ledger: .fixture, window: "7d", grouping: .providerModel, json: false, now: fixedNow)
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)

    let output = lines(result.standardOutput)
    #expect(output.first == "Tokens · last 7 days")
    #expect(output[1].contains("Cost"))

    // The largest group is printed first and carries its response count and total.
    #expect(output[2].hasPrefix("anthropic/claude-sonnet-5-5"))
    #expect(output[2].contains("3.10k"))
    #expect(output.contains { $0.hasPrefix("openrouter/o-legacy") && $0.contains("2") })
    // One tool recorded a price, so only that row shows one; the rest say they have none.
    #expect(output.contains { $0.hasPrefix("opencode-go/deepseek-v4.1-flash") && $0.hasSuffix("$0.0012") })
    #expect(output.contains { $0.hasPrefix("openai/gpt-6.1-sol") && $0.hasSuffix("—") })

    // 9 responses, 11,262 tokens across the eight groups.
    let total = try #require(output.first { $0.hasPrefix("Total") })
    #expect(total.contains("11.3k"))
    #expect(total.hasSuffix("$0.0012"))
    #expect(output.count == 1 + 1 + 8 + 1)
}

@Test func tokensTextNamesTheWindowThatWasAskedFor() {
    #expect(lines(TokensCommand.tokens(ledger: .fixture, window: "24h", grouping: .provider, json: false, now: fixedNow).standardOutput).first
        == "Tokens · last 24 hours")
    #expect(lines(TokensCommand.tokens(ledger: .fixture, window: "30m", grouping: .provider, json: false, now: fixedNow).standardOutput).first
        == "Tokens · last 30 minutes")
    #expect(lines(TokensCommand.tokens(ledger: .fixture, window: "all", grouping: .provider, json: false, now: fixedNow).standardOutput).first
        == "Tokens · all time")
}

@Test func tokensOneDayWindowDropsTheOlderDay() throws {
    let result = TokensCommand.tokens(ledger: .fixture, window: "24h", grouping: .providerModel, json: true, now: fixedNow)
    #expect(result.exitCode == 0)
    let object = try json(result.standardOutput)
    let rows = try #require(object["rows"] as? [[String: Any]])
    // The two Claude responses from the previous morning fall outside the window.
    #expect(rows.count == 6)
    #expect(rows.contains { ($0["name"] as? String) == "anthropic/claude-opus-5-5" } == false)
    let totals = try #require(object["totals"] as? [String: Any])
    #expect(totals["total"] as? Int == 11_262 - 3_060 - 3_105)
}

@Test func tokensJSONCarriesRowsTotalsAndSources() throws {
    let result = TokensCommand.tokens(ledger: .fixture, window: "7d", grouping: .providerModel, json: true, now: fixedNow)
    #expect(result.exitCode == 0)

    let object = try json(result.standardOutput)
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["window"] as? String == "7d")
    #expect(object["grouping"] as? String == "provider-model")
    #expect(object["since"] as? String == "2026-10-14T12:00:00Z")
    #expect(object["generatedAt"] as? String == "2026-10-21T12:00:00Z")

    let rows = try #require(object["rows"] as? [[String: Any]])
    #expect(rows.count == 8)
    #expect(rows.first?["name"] as? String == "anthropic/claude-sonnet-5-5")
    #expect(rows.first?["responses"] as? Int == 1)
    #expect(rows.first?["total"] as? Int == 3_105)
    #expect(rows.first?["provider"] as? String == "anthropic")
    #expect(rows.first?["model"] as? String == "claude-sonnet-5-5")
    // Only a tool grouping sets `tool`.
    #expect(rows.first?["tool"] == nil)

    let legacy = try #require(rows.first { ($0["name"] as? String) == "openrouter/o-legacy" })
    #expect(legacy["responses"] as? Int == 2)
    #expect(legacy["total"] as? Int == 540)

    let totals = try #require(object["totals"] as? [String: Any])
    #expect(totals["responses"] as? Int == 9)
    #expect(totals["input"] as? Int == 1_822)
    #expect(totals["cacheRead"] as? Int == 7_500)
    #expect(totals["cacheWrite"] as? Int == 1_500)
    #expect(totals["output"] as? Int == 440)
    #expect(totals["total"] as? Int == 11_262)
    #expect(totals["costUSD"] as? Double == 0.0012)

    let sources = try #require(object["sources"] as? [[String: Any]])
    #expect(sources.map { $0["tool"] as? String } == ["claude-code", "codex", "opencode"])
    #expect(sources.map { $0["state"] as? String } == ["ok", "ok", "ok"])
    #expect(sources.map { $0["recordCount"] as? Int } == [3, 4, 2])
}

@Test func tokensJSONWritesNullSinceForAllTime() throws {
    let object = try json(TokensCommand.tokens(ledger: .fixture, window: "all", grouping: .tool, json: true, now: fixedNow).standardOutput)
    #expect(object["since"] is NSNull)
    #expect(object["window"] as? String == "all")
    #expect(object["grouping"] as? String == "tool")
}

@Test func anEmptyLedgerSaysWhatWasChecked() throws {
    let ledger = TokenLedger(sources: [FixedTokenSource(tool: .claudeCode), FixedTokenSource(tool: .codex)])
    let result = TokensCommand.tokens(ledger: ledger, window: "7d", grouping: .providerModel, json: false, now: fixedNow)
    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("No token usage in the last 7 days."))
    #expect(result.standardOutput.contains("Checked Claude Code and Codex."))

    let object = try json(TokensCommand.tokens(ledger: ledger, window: "all", grouping: .providerModel, json: true, now: fixedNow).standardOutput)
    #expect((object["rows"] as? [Any])?.isEmpty == true)
    #expect((object["totals"] as? [String: Any])?["total"] as? Int == 0)
    #expect((object["sources"] as? [Any])?.count == 2)

    // No sources is empty, not a failure.
    let none = TokensCommand.tokens(ledger: TokenLedger(sources: []), window: "7d", grouping: .tool, json: false, now: fixedNow)
    #expect(none.exitCode == 0)
    #expect(none.standardOutput.contains("Checked no tools."))
}

@Test func oneFailedSourceIsNamedUnderTheTable() throws {
    let ledger = TokenLedger(sources: [
        FixedTokenSource(tool: .claudeCode, records: TokenLogFixtures.claudeRecords),
        FixedTokenSource(tool: .codex, failure: "unreadable"),
    ])
    let text = TokensCommand.tokens(ledger: ledger, window: "7d", grouping: .providerModel, json: false, now: fixedNow)
    #expect(text.exitCode == 0)
    #expect(text.standardOutput.contains("anthropic/claude-opus-5-5"))
    #expect(text.standardOutput.contains("Codex logs could not be read: unreadable"))

    let object = try json(TokensCommand.tokens(ledger: ledger, window: "7d", grouping: .providerModel, json: true, now: fixedNow).standardOutput)
    let sources = try #require(object["sources"] as? [[String: Any]])
    #expect(sources.map { $0["state"] as? String } == ["ok", "failed"])
    #expect(sources[1]["recordCount"] as? Int == 0)
    #expect(sources[1]["message"] as? String == "unreadable")
}

@Test func everySourceFailingExitsTwo() {
    let ledger = TokenLedger(sources: [
        FixedTokenSource(tool: .claudeCode, failure: "denied"),
        FixedTokenSource(tool: .codex, failure: "gone"),
    ])
    let tokens = TokensCommand.tokens(ledger: ledger, window: "7d", grouping: .providerModel, json: false, now: fixedNow)
    #expect(tokens.exitCode == 2)
    #expect(tokens.standardOutput.contains("No token usage in the last 7 days."))
    #expect(tokens.standardOutput.contains("Claude Code logs could not be read: denied"))
    #expect(tokens.standardOutput.contains("Codex logs could not be read: gone"))

    let models = TokensCommand.models(ledger: ledger, window: "7d", json: true, now: fixedNow)
    #expect(models.exitCode == 2)
    #expect(models.standardOutput.contains(#""state" : "failed""#))
}

@Test func countsUseThreeSignificantFigures() {
    #expect(TokensCommand.compactCount(0) == "0")
    #expect(TokensCommand.compactCount(950) == "950")
    #expect(TokensCommand.compactCount(999) == "999")
    #expect(TokensCommand.compactCount(1_000) == "1.00k")
    #expect(TokensCommand.compactCount(12_345) == "12.3k")
    #expect(TokensCommand.compactCount(1_234_567) == "1.23M")
    #expect(TokensCommand.compactCount(4_560_000) == "4.56M")
    // Rounded up into the next unit rather than printed as 1000k.
    #expect(TokensCommand.compactCount(999_999) == "1.00M")
}

// MARK: - meter models

@Test func modelsTextNamesTheLastModelAndTheOthers() throws {
    let result = TokensCommand.models(ledger: .fixture, window: "7d", json: false, now: fixedNow)
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)

    let output = lines(result.standardOutput)
    #expect(output.first == "Models · last 7 days")
    // Claude Code and OpenCode tie on the most recent response; the tool order breaks it.
    #expect(output[1].hasPrefix("Claude Code") && output[1].hasSuffix("3h ago"))
    #expect(output[1].contains("anthropic / claude-haiku-5-5"))
    #expect(output.contains { $0.hasPrefix("OpenCode") && $0.contains("openai / gpt-5.5") && $0.hasSuffix("3h ago") })
    #expect(output.contains { $0.hasPrefix("Codex") && $0.contains("openrouter / o-legacy") && $0.hasSuffix("22h ago") })

    let bodies = output.map { $0.trimmingCharacters(in: .whitespaces) }
    #expect(bodies.contains { $0.hasPrefix("claude-opus-5-5") && $0.hasSuffix("1 response") })
    #expect(bodies.contains { $0.hasPrefix("claude-sonnet-5-5") && $0.hasSuffix("1 response") })
    // OpenCode last used OpenAI; a model from another provider says which.
    #expect(bodies.contains { $0.hasPrefix("opencode-go / deepseek-v4.1-flash") && $0.hasSuffix("1 response") })
}

@Test func modelsListOtherModelsLargestFirst() throws {
    let base = fixedNow.addingTimeInterval(-3_600)
    func record(_ id: String, _ model: String, _ offset: TimeInterval) -> TokenRecord {
        .init(id: id, tool: .codex, provider: "openai", model: model,
              timestamp: base.addingTimeInterval(offset), tokens: .init(input: 1))
    }
    let ledger = TokenLedger(sources: [FixedTokenSource(tool: .codex, records: [
        record("r1", "recent", 300),
        record("r2", "alpha", 200),
        record("r3", "alpha", 100),
        record("r4", "beta", 150),
        record("r5", "beta", 50),
        record("r6", "beta", 25),
    ])])

    let output = lines(TokensCommand.models(ledger: ledger, window: "7d", json: false, now: fixedNow).standardOutput)
    #expect(output[1].hasPrefix("Codex") && output[1].contains("openai / recent") && output[1].hasSuffix("55m ago"))
    let bodies = output.map { $0.trimmingCharacters(in: .whitespaces) }
    #expect(bodies.contains { $0.hasPrefix("alpha") && $0.hasSuffix("2 responses") })
    #expect(bodies.contains { $0.hasPrefix("beta") && $0.hasSuffix("3 responses") })
    let beta = try #require(bodies.firstIndex { $0.hasPrefix("beta") })
    let alpha = try #require(bodies.firstIndex { $0.hasPrefix("alpha") })
    #expect(beta < alpha)
}

@Test func modelsJSONCarriesTheRecentModelAndItsOthers() throws {
    let result = TokensCommand.models(ledger: .fixture, window: "7d", json: true, now: fixedNow)
    #expect(result.exitCode == 0)

    let object = try json(result.standardOutput)
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["window"] as? String == "7d")
    #expect(object["since"] as? String == "2026-10-14T12:00:00Z")

    let models = try #require(object["models"] as? [[String: Any]])
    #expect(models.count == 3)
    #expect(models.map { $0["tool"] as? String } == ["claude-code", "opencode", "codex"])

    let claude = try #require(models.first)
    #expect(claude["provider"] as? String == "anthropic")
    #expect(claude["model"] as? String == "claude-haiku-5-5")
    #expect(claude["lastUsed"] as? String == "2026-10-21T09:00:00Z")
    let others = try #require(claude["otherModels"] as? [[String: Any]])
    #expect(others.compactMap { $0["model"] as? String } == ["claude-opus-5-5", "claude-sonnet-5-5"])
    #expect(others.compactMap { $0["responses"] as? Int } == [1, 1])

    let totals = try #require(object["totals"] as? [String: Any])
    #expect(totals["responses"] as? Int == 9)
    #expect(totals["total"] as? Int == 11_262)
}

@Test func modelsOnAnEmptyLedgerSaysWhatWasChecked() {
    let ledger = TokenLedger(sources: [FixedTokenSource(tool: .openCode)])
    let result = TokensCommand.models(ledger: ledger, window: "all", json: false, now: fixedNow)
    #expect(result.exitCode == 0)
    #expect(lines(result.standardOutput).first == "Models · all time")
    #expect(result.standardOutput.contains("No token usage yet."))
    #expect(result.standardOutput.contains("Checked OpenCode."))
}

@Test func aBadWindowIsRejectedBeforeReadingTheLogs() {
    let result = TokensCommand.tokens(ledger: .fixture, window: "7w", grouping: .providerModel, json: false, now: fixedNow)
    #expect(result.exitCode == 64)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains("Invalid --since '7w'"))
}
