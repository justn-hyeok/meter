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

@Test func readsOpenRouterKeyLimitBudgetAndMonthlySpendInDollars() throws {
    let now = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03, UTC.
    let snapshot = try OpenRouterUsageParser.parse(try fixture("openrouter-key"), now: now)
    #expect(snapshot.provider == .openRouter)
    #expect(snapshot.buckets.map(\.id) == ["key-limit", "budget", "monthly-spend"])
    #expect(snapshot.buckets.map(\.label) == ["Key limit", "Weekly budget", "Spend this month"])
    // Money stays money: no bucket here may drive the menu bar needle.
    #expect(snapshot.buckets.allSatisfy { $0.unit == .usd && $0.percentageUsed == nil })

    let keyLimit = snapshot.buckets[0]
    #expect(keyLimit.used == 25.5)
    #expect(keyLimit.limit == 100)
    #expect(keyLimit.remaining == 74.5)
    // From the key's own entry among the budgets, not computed from "monthly".
    #expect(keyLimit.resetAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))

    let budget = snapshot.buckets[1]
    #expect(budget.used == 32.5)
    #expect(budget.limit == 50)
    #expect(budget.remaining == 17.5)
    #expect(budget.resetAt == ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z"))

    let monthly = snapshot.buckets[2]
    #expect(monthly.used == 25.5)
    #expect(monthly.limit == nil)
    #expect(monthly.resetAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
}

@Test func anUnlimitedOpenRouterKeyShowsOnlyItsMonthlySpend() throws {
    // A key with no cap and nothing budgeted: `limit`, `limit_remaining` and
    // `effective_budget` are null, as the schema allows.
    let json = #"{"data":{"label":"sk-or-v1-abc","limit":null,"limit_remaining":null,"limit_reset":null,"budgets":[],"effective_budget":null,"usage":3.2,"usage_daily":0,"usage_weekly":1.1,"usage_monthly":2.75,"is_free_tier":true}}"#
    let snapshot = try OpenRouterUsageParser.parse(Data(json.utf8))
    #expect(snapshot.buckets.map(\.id) == ["monthly-spend"])
    #expect(snapshot.buckets.first?.used == 2.75)
}

@Test func anOpenRouterBudgetThatIsTheKeysOwnLimitIsNotShownTwice() throws {
    let json = #"{"data":{"limit":10,"limit_remaining":4,"usage_monthly":6,"budgets":[{"scope":"key_limit","limit_usd":10,"spend_usd":6,"remaining_usd":4,"reset_interval":null,"resets_at":null}],"effective_budget":{"scope":"key_limit","limit_usd":10,"spend_usd":6,"remaining_usd":4,"reset_interval":null,"resets_at":null}}}"#
    let snapshot = try OpenRouterUsageParser.parse(Data(json.utf8))
    #expect(snapshot.buckets.map(\.id) == ["key-limit", "monthly-spend"])
    // A lifetime limit never resets.
    #expect(snapshot.buckets[0].resetAt == nil)
}

@Test func anOpenRouterReplyWithoutDataIsAParseFailure() {
    #expect(throws: (any Error).self) { try OpenRouterUsageParser.parse(Data(#"{"error":{"code":401}}"#.utf8)) }
}
