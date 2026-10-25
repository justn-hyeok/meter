import Foundation
import Testing
@testable import MeterCore

@Test func everyExpectedFixtureRecordFollowsTheNormalisationRules() {
    // `reasoning` is part of `output`, never beside it, and the total is the four parts.
    for record in TokenLogFixtures.allRecords {
        #expect(record.tokens.reasoning <= record.tokens.output, "\(record.id)")
        #expect(record.tokens.total == record.tokens.input + record.tokens.cacheRead + record.tokens.cacheWrite + record.tokens.output)
    }
    // OpenCode wrote its own totals; the normalised ones must agree with them.
    #expect(TokenLogFixtures.openCodeRecords.map(\.tokens.total) == [650, 2300])
}

@Test func ledgerGroupsByProviderAndModelWithTheLargestFirst() {
    let report = TokenLedger.fixture.read(since: nil)
    #expect(report.records.count == 9)
    #expect(report.sources.allSatisfy { $0.state == .ok })

    let byProvider = report.summaries(by: .provider)
    // anthropic 3060 + 3105 + 37, openai 1050 + 520 + 2300, opencode-go 650, openrouter 330 + 210.
    #expect(byProvider.map(\.key) == ["anthropic", "openai", "opencode-go", "openrouter"])
    #expect(byProvider.map(\.tokens.total) == [6202, 3870, 650, 540])
    #expect(byProvider.first { $0.key == "openai" }?.responses == 3)

    // The same company's models bought through two tools stay one provider row, while
    // provider-model keeps a model bought from two places apart.
    let pairs = report.summaries(by: .providerModel)
    #expect(pairs.contains { $0.key == "opencode-go/deepseek-v4.1-flash" && $0.costUSD == 0.0012 })
    #expect(pairs.first { $0.key == "openai/gpt-5.5" }?.costUSD == nil)
}

@Test func ledgerKeepsOtherToolsWhenOneFailsAndCountsADuplicateOnce() {
    let record = TokenLogFixtures.claudeRecords[0]
    let ledger = TokenLedger(sources: [
        FixedTokenSource(tool: .claudeCode, records: [record, record]),
        FixedTokenSource(tool: .codex, failure: "unreadable"),
    ])
    let report = ledger.read(since: nil)
    #expect(report.records == [record])
    #expect(report.sources.map(\.state) == [.ok, .failed])
    #expect(report.sources[1].message == "unreadable")
}

@Test func ledgerDropsRecordsBeforeTheWindowAndNamesTheLastModelPerTool() {
    let since = TokenLogFixtures.date("2026-10-20T12:01:00.000Z")
    let report = TokenLedger.fixture.read(since: since)
    #expect(report.records.allSatisfy { $0.timestamp >= since })
    // Claude Code and OpenCode answered in the same second: the tool order breaks the tie.
    #expect(report.recentModels.map(\.model) == ["claude-haiku-5-5", "gpt-5.5", "o-legacy"])
}

@Test func tokenWindowsParseAndRejectNonsense() {
    let now = TokenLogFixtures.date("2026-10-24T00:00:00.000Z")
    #expect(TokenWindow.since("7d", now: now) == .some(now.addingTimeInterval(-7 * 86_400)))
    #expect(TokenWindow.since("all", now: now) == .some(nil))
    #expect(TokenWindow.since("0d", now: now) == nil)
    #expect(TokenWindow.since("200000000000000d", now: now) == nil)
    #expect(TokenWindow.since("7w", now: now) == nil)
}
