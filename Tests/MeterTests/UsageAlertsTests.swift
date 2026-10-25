import Foundation
import Testing
@testable import MeterCore
@testable import MeterCLI

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(_ provider: ProviderID, _ used: Double, resetAt: Date? = now.addingTimeInterval(7_200),
                      state: SnapshotState = .live, issue: SnapshotIssue? = nil) -> UsageSnapshot {
    UsageSnapshot(provider: provider,
                  buckets: [.init(id: "week", label: "Weekly", used: used, limit: 100,
                                  remaining: 100 - used, resetAt: resetAt, unit: .percent)],
                  fetchedAt: now, source: "test", state: state, message: nil, issue: issue)
}

@Test func aLimitAlertsOncePerLevelAndPeriod() {
    var sent: Set<String> = []
    var result = UsageAlerts.evaluate([snapshot(.claude, 50)], sent: sent, now: now)
    #expect(result.alerts.isEmpty)

    result = UsageAlerts.evaluate([snapshot(.claude, 82)], sent: result.sent, now: now)
    #expect(result.alerts.map(\.title) == ["Claude: Weekly running low"])
    sent = result.sent

    // The same level on the next refresh is not news.
    result = UsageAlerts.evaluate([snapshot(.claude, 84)], sent: sent, now: now)
    #expect(result.alerts.isEmpty)

    result = UsageAlerts.evaluate([snapshot(.claude, 96)], sent: result.sent, now: now)
    #expect(result.alerts.map(\.title) == ["Claude: Weekly almost used up"])

    // Dropping back to 90% does not repeat the 80% alert.
    result = UsageAlerts.evaluate([snapshot(.claude, 90)], sent: result.sent, now: now)
    #expect(result.alerts.isEmpty)

    // A new period is news again.
    result = UsageAlerts.evaluate([snapshot(.claude, 85, resetAt: now.addingTimeInterval(7 * 86_400))], sent: result.sent, now: now)
    #expect(result.alerts.count == 1)
}

@Test func aWindowFoundPastBothLevelsAlertsOnce() {
    let result = UsageAlerts.evaluate([snapshot(.codex, 97)], sent: [], now: now)
    #expect(result.alerts.count == 1)
    #expect(result.alerts.first?.body.hasPrefix("97% used") == true)
}

@Test func staleFiguresNeitherAlertNorForget() {
    let first = UsageAlerts.evaluate([snapshot(.claude, 85)], sent: [], now: now)
    let stale = UsageAlerts.evaluate([snapshot(.claude, 85, state: .stale)], sent: first.sent, now: now)
    #expect(stale.alerts.isEmpty)
    #expect(stale.sent == first.sent)
    let back = UsageAlerts.evaluate([snapshot(.claude, 85)], sent: stale.sent, now: now)
    #expect(back.alerts.isEmpty)
}

@Test func aResetThatDriftsBySecondsIsTheSamePeriod() {
    let first = UsageAlerts.evaluate([snapshot(.claude, 85, resetAt: now.addingTimeInterval(7_200))], sent: [], now: now)
    let again = UsageAlerts.evaluate([snapshot(.claude, 85, resetAt: now.addingTimeInterval(7_230))], sent: first.sent, now: now)
    #expect(again.alerts.isEmpty)
}

@Test func signInAlertsOnTheChangeAndAgainAfterRecovery() {
    let broken = snapshot(.cursor, 10, state: .stale, issue: .signInRequired)
    var result = UsageAlerts.evaluate([broken], sent: [], now: now)
    #expect(result.alerts.map(\.title) == ["Cursor: sign in again"])
    #expect(result.alerts.first?.body.contains("cursor-agent login") == true)

    result = UsageAlerts.evaluate([broken], sent: result.sent, now: now)
    #expect(result.alerts.isEmpty)

    result = UsageAlerts.evaluate([snapshot(.cursor, 10)], sent: result.sent, now: now)
    result = UsageAlerts.evaluate([broken], sent: result.sent, now: now)
    #expect(result.alerts.count == 1)
}

@Test func anEndingSessionWarnsOnce() {
    let ending = snapshot(.cursor, 10, issue: .expiresSoon(now.addingTimeInterval(5 * 3_600)))
    let first = UsageAlerts.evaluate([ending], sent: [], now: now)
    #expect(first.alerts.first?.title.hasPrefix("Cursor: sign-in ends") == true)
    #expect(UsageAlerts.evaluate([ending], sent: first.sent, now: now).alerts.isEmpty)
}

@Test func aRefusedCredentialIsMarkedAsASignInProblem() {
    let refused = UsageSnapshot.unavailable(.claude, "Claude unavailable", error: CredentialError.signInRequired("claude.ai"))
    #expect(refused.issue == .signInRequired)
    #expect(refused.message == "Claude unavailable: sign in again at claude.ai")
    let offline = UsageSnapshot.unavailable(.claude, "Claude unavailable", error: URLError(.notConnectedToInternet))
    #expect(offline.issue == nil)
}

@Test func theIssueSurvivesTheCacheAndOldJSONStillDecodes() throws {
    let snapshot = snapshot(.cursor, 10, issue: .expiresSoon(now))
    let data = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(UsageSnapshot.self, from: data).issue == .expiresSoon(now))

    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["issue"] = nil
    let old = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(UsageSnapshot.self, from: old).issue == nil)
}

@Test func aMutedWindowNeitherAlertsNorCountsAsTightest() {
    let full = snapshot(.cursor, 100)
    let key = BucketKey(provider: .cursor, bucketID: "week")
    #expect(UsageAlerts.evaluate([full], sent: [], muted: [key], now: now).alerts.isEmpty)
    #expect(TightestLimit.find(in: [full], muted: [key]) == nil)
    #expect(TightestLimit.find(in: [full]) == key)
}

@MainActor
@Test func mutingIsSavedAndLeavesTheGauge() throws {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = MeterSettings(defaults: defaults)
    let store = UsageStore(settings: settings, service: UsageService(providers: [:]), refreshOnEnable: false, secrets: .forTests)
    store.replaceSnapshotForTesting(snapshot(.cursor, 100))
    store.replaceSnapshotForTesting(snapshot(.claude, 30))
    #expect(store.highestUsage == 1)

    let key = BucketKey(account: Account(.cursor, name: nil), bucketID: "week")
    store.setMuted(true, key)
    #expect(store.highestUsage == 0.3)
    #expect(MeterSettings(defaults: defaults).mutedWindows == [key])
    #expect(BucketKey(rawValue: key.rawValue) == key)
    #expect(BucketKey(rawValue: "deepseek#work|balance") == BucketKey(account: Account(.deepSeek, name: "work"), bucketID: "balance"))
}

@Test func shortLeadsWithAWindowStillWarnedAbout() {
    let cursor = UsageSnapshot(provider: .cursor, buckets: [
        .init(id: "cursor-models", label: "Cursor Models", used: 5, limit: 100, remaining: 95, resetAt: nil, unit: .percent),
        .init(id: "other-models", label: "Other Models", used: 100, limit: 100, remaining: 0, resetAt: nil, unit: .percent),
    ], fetchedAt: now, source: "test", state: .live, message: nil)
    #expect(CLITextFormatter.short([cursor]) == "Cursor 100%")
    #expect(CLITextFormatter.short([cursor], muted: [BucketKey(provider: .cursor, bucketID: "other-models")]) == "Cursor 5%")
}
