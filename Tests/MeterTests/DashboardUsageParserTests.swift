import Foundation
import Testing
@testable import MeterCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

@Test func parsesCursorSpendingPoolsAndTotalSpend() throws {
    let snapshot = try CursorUsageParser.parse(fixture("cursor-current-period-usage"))
    #expect(snapshot.buckets.count == 3)
    #expect(snapshot.buckets[0].used == 38.00888888888888)
    #expect(snapshot.buckets[1].fractionUsed == 1)
    #expect(snapshot.buckets[2].used == 0.4)
    #expect(snapshot.buckets[0].resetAt != nil)
}

@Test func parsesCommandCodeMonthlyAndRollingLimits() throws {
    let snapshot = try CommandCodeUsageParser.parse(fixture("command-code-usage"))
    #expect(snapshot.buckets.count == 3)
    #expect(snapshot.buckets[0].limit == 70)
    #expect(snapshot.buckets[0].remaining == 62.4638321627)
    #expect(snapshot.buckets[0].percentageUsed! > 10.7)
    #expect(snapshot.buckets[1].fractionUsed == 0)
    #expect(snapshot.buckets[2].fractionUsed! > 0.21)
    #expect(snapshot.buckets[2].percentageUsed! > 21.5)
    #expect(snapshot.buckets[2].resetAt != nil)
}

@Test func readsCursorSpendAfterTheDashboardMovedTheField() throws {
    // Today's response keeps the amount in planUsage and leaves spendLimitUsage without
    // it, which used to make the on-demand bucket vanish without any test failing.
    let snapshot = try CursorUsageParser.parse(try fixture("cursor-current-period-usage-moved-spend"))
    let spend = try #require(snapshot.buckets.first { $0.id == "spend" })
    #expect(spend.used == 136.08)
    #expect(spend.unit == .usd)
    // billingCycleEnd arrives as a string of milliseconds.
    #expect(spend.resetAt == Date(timeIntervalSince1970: 1_791_372_368))
    #expect(snapshot.buckets.map(\.id) == ["cursor-models", "other-models", "spend"])
    // No limit on purpose: planUsage.limit is the included allowance while totalSpend
    // also counts bonus usage, so the ratio would read several hundred percent.
    #expect(spend.limit == nil)
}

@Test func parsesClaudeWindowsFromTheSelfDescribingLimitsArray() throws {
    let snapshot = try ClaudeUsageParser.parse(try fixture("claude-oauth-usage"))

    // The codenamed top-level windows next to `limits` are deliberately ignored: they
    // come and go with plan changes, while `limits` carries its own labels.
    #expect(snapshot.buckets.map(\.id) == ["session", "weekly_all", "weekly_scoped-fable", "monthly_scoped", "spend"])
    #expect(snapshot.buckets.map(\.label) == ["Session", "Weekly", "Weekly (Fable)", "Monthly Scoped", "Extra usage"])
    #expect(snapshot.provider == .claude)
    #expect(snapshot.state == .live)
}

@Test func readsClaudePercentagesAndBothResetTimestampFormats() throws {
    let snapshot = try ClaudeUsageParser.parse(try fixture("claude-oauth-usage"))
    let byID = Dictionary(uniqueKeysWithValues: snapshot.buckets.map { ($0.id, $0) })

    let session = try #require(byID["session"])
    #expect(session.used == 20)
    #expect(session.remaining == 80)
    #expect(session.unit == .percent)
    // Fractional seconds present. ISO8601DateFormatter keeps milliseconds, so compare
    // with a tolerance rather than against the microseconds the API sends.
    let sessionReset = try #require(session.resetAt)
    #expect(abs(sessionReset.timeIntervalSince1970 - 1_790_581_800.955018) < 0.001)

    // Fractional seconds absent.
    #expect(byID["weekly_scoped-fable"]?.resetAt == Date(timeIntervalSince1970: 1_790_712_000))
    #expect(byID["monthly_scoped"]?.resetAt == nil)
}

@Test func readsClaudeExtraSpendInMajorUnits() throws {
    let snapshot = try ClaudeUsageParser.parse(try fixture("claude-oauth-usage"))
    let spend = try #require(snapshot.buckets.first { $0.id == "spend" })
    #expect(spend.used == 13.50)
    #expect(spend.limit == 50.00)
    #expect(spend.unit == .usd)
}

@Test func skipsClaudeSpendWhenTheAccountHasItTurnedOff() throws {
    let payload = Data("""
    {
      "limits": [{ "kind": "session", "percent": 5, "resets_at": null, "scope": null }],
      "spend": { "used": { "amount_minor": 900, "exponent": 2 }, "enabled": false }
    }
    """.utf8)
    let snapshot = try ClaudeUsageParser.parse(payload)
    #expect(snapshot.buckets.map(\.id) == ["session"])
}

@Test func rejectsAClaudeResponseWithNoUsableWindows() {
    #expect(throws: (any Error).self) {
        try ClaudeUsageParser.parse(Data(#"{"limits":[],"seven_day":null}"#.utf8))
    }
}
