import Foundation
import Testing
@testable import MeterCore

private func snapshot(_ provider: ProviderID, used: Double, resetAt: Date? = nil, state: SnapshotState = .live) -> UsageSnapshot {
    .init(
        provider: provider,
        buckets: [.init(id: "window", label: "Weekly", used: used, limit: 100, remaining: 100 - used, resetAt: resetAt, unit: .percent)],
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: "test",
        state: state,
        message: nil
    )
}

@Test func announcesAThresholdOnceRatherThanEveryRefresh() {
    var tracker = UsageAlertTracker()
    #expect(tracker.alerts(for: [snapshot(.codex, used: 79)]).isEmpty)

    let crossing = tracker.alerts(for: [snapshot(.codex, used: 81)])
    #expect(crossing.count == 1)
    #expect(crossing[0].threshold == 80)
    #expect(crossing[0].title == "Codex at 80%")
    #expect(crossing[0].body == "Weekly is 81% used.")

    // Five minutes later the window is still above 80 and must stay quiet.
    #expect(tracker.alerts(for: [snapshot(.codex, used: 84)]).isEmpty)
}

@Test func announcesTheHigherThresholdWhenUsageKeepsClimbing() {
    var tracker = UsageAlertTracker()
    #expect(tracker.alerts(for: [snapshot(.codex, used: 81)]).count == 1)

    let escalation = tracker.alerts(for: [snapshot(.codex, used: 96)])
    #expect(escalation.map(\.threshold) == [95])
    #expect(tracker.alerts(for: [snapshot(.codex, used: 99)]).isEmpty)
}

@Test func rearmsWhenTheWindowRolls() {
    var tracker = UsageAlertTracker()
    let firstWindow = Date(timeIntervalSince1970: 1_700_000_000)
    let nextWindow = Date(timeIntervalSince1970: 1_700_600_000)

    #expect(tracker.alerts(for: [snapshot(.claude, used: 90, resetAt: firstWindow)]).count == 1)
    #expect(tracker.alerts(for: [snapshot(.claude, used: 92, resetAt: firstWindow)]).isEmpty)
    // A new reset time means a new window, which deserves its own warning.
    #expect(tracker.alerts(for: [snapshot(.claude, used: 88, resetAt: nextWindow)]).count == 1)
}

@Test func rearmsWhenUsageFallsBackBelowWhatWasAnnounced() {
    var tracker = UsageAlertTracker()
    #expect(tracker.alerts(for: [snapshot(.cursor, used: 96)]).count == 1)
    #expect(tracker.alerts(for: [snapshot(.cursor, used: 40)]).isEmpty)
    #expect(tracker.alerts(for: [snapshot(.cursor, used: 97)]).map(\.threshold) == [95])
}

@Test func ignoresProvidersWithNoData() {
    var tracker = UsageAlertTracker()
    #expect(tracker.alerts(for: [.unavailable(.codex, "no session")]).isEmpty)
    // Stale data still reflects real usage, so it is allowed to warn.
    #expect(tracker.alerts(for: [snapshot(.codex, used: 99, state: .stale)]).count == 1)
}

@Test func reportsEachProviderSeparately() {
    var tracker = UsageAlertTracker()
    let alerts = tracker.alerts(for: [snapshot(.codex, used: 85), snapshot(.claude, used: 96)])
    #expect(alerts.map(\.provider) == [.codex, .claude])
    #expect(alerts.map(\.threshold) == [80, 95])
}
