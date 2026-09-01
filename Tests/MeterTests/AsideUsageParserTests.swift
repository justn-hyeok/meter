import Foundation
import Testing
@testable import Meter

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
    #expect(snapshot.buckets[1].fractionUsed == 0)
    #expect(snapshot.buckets[2].fractionUsed! > 0.21)
    #expect(snapshot.buckets[2].resetAt != nil)
}
