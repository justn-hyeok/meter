import Foundation
import Testing
@testable import MeterCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

@Test func parsesCursorSpendingPoolsAndOnDemandSpend() throws {
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
    let spend = try #require(snapshot.buckets.first { $0.id == "on-demand" })
    #expect(spend.used == 136.08)
    #expect(spend.unit == .usd)
    // billingCycleEnd arrives as a string of milliseconds.
    #expect(spend.resetAt == Date(timeIntervalSince1970: 1_791_372_368))
    #expect(snapshot.buckets.map(\.id) == ["cursor-models", "other-models", "on-demand"])
}
