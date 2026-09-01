import Foundation
import Testing
@testable import Meter

@Test func parsesCodexWindowsAndCredits() throws {
    let data = #"{"rate_limit":{"primary_window":{"used_percent":12,"reset_at":2000000000},"secondary_window":{"used_percent":34,"reset_at":2000000100}},"credits":{"balance":"9.50"}}"#.data(using: .utf8)!
    let snapshot = try CodexUsageParser.parse(data)
    #expect(snapshot.buckets.count == 3)
    #expect(snapshot.buckets[0].fractionUsed == 0.12)
    #expect(snapshot.buckets[2].remaining == 9.5)
}

@Test func parsesDeepSeekBalancesWithoutInventingUsageFraction() throws {
    let data = #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.34"}]}"#.data(using: .utf8)!
    let snapshot = try DeepSeekUsageParser.parse(data)
    #expect(snapshot.buckets.count == 1)
    #expect(snapshot.buckets[0].remaining == 12.34)
    #expect(snapshot.buckets[0].fractionUsed == nil)
}
