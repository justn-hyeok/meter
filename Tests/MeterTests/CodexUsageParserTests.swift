import Foundation
import Testing
@testable import MeterCore

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

@Test func parsesAdditionalCodexModelWindows() throws {
    // limit_window_seconds is what names each window. Assuming primary meant five hours
    // showed Codex's weekly limit as a five-hour one on the wham/usage path.
    let data = #"{"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":2000000000},"secondary_window":null},"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox","rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_at":2000000100},"secondary_window":{"used_percent":21,"limit_window_seconds":604800,"reset_at":2000000200}}}]}"#.data(using: .utf8)!
    let snapshot = try CodexUsageParser.parse(data)
    #expect(snapshot.buckets.count == 3)
    #expect(snapshot.buckets.map(\.label) == ["5-hour", "GPT-5.3-Codex-Spark 5-hour", "GPT-5.3-Codex-Spark Weekly"])
    // Keyed by metered_feature, the same id the app-server path emits for that limit.
    #expect(snapshot.buckets.map(\.id) == ["codex-primary", "codex_bengalfox-primary", "codex_bengalfox-secondary"])
    #expect(snapshot.buckets[2].fractionUsed == 0.21)
}

@Test func parsesCodexAppServerLimitsByID() throws {
    let data = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":19,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":19,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":null},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":2000000100},"secondary":{"usedPercent":21,"windowDurationMins":10080,"resetsAt":2000000200}}}}}"#.data(using: .utf8)!
    let snapshot = try CodexAppServerUsageParser.parse(data)
    #expect(snapshot.source == "Codex app-server")
    #expect(snapshot.buckets.count == 3)
    #expect(snapshot.buckets[0].label == "Weekly")
    #expect(snapshot.buckets[1].label == "GPT-5.3-Codex-Spark 5-hour")
    #expect(snapshot.buckets[2].label == "GPT-5.3-Codex-Spark Weekly")
    #expect(snapshot.buckets[2].fractionUsed == 0.21)
}
