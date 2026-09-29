import Foundation
import Testing
@testable import MeterCore

private func percentSnapshot(_ provider: ProviderID, used: Double) -> UsageSnapshot {
    .init(
        provider: provider,
        buckets: [.init(id: "window", label: "Window", used: used, limit: 100, remaining: 100 - used, resetAt: nil, unit: .percent)],
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: "test",
        state: .live,
        message: nil
    )
}

private struct StubProvider: UsageProvider {
    let id: ProviderID
    let snapshot: UsageSnapshot
    func fetch() async -> UsageSnapshot { snapshot }
}

/// Hands out queued snapshots so a provider can succeed once and then fail.
private actor SnapshotQueue {
    private var remaining: [UsageSnapshot]
    init(_ snapshots: [UsageSnapshot]) { self.remaining = snapshots }
    func next() -> UsageSnapshot {
        remaining.count > 1 ? remaining.removeFirst() : remaining[0]
    }
}

private struct QueuedProvider: UsageProvider {
    let id: ProviderID
    let queue: SnapshotQueue
    func fetch() async -> UsageSnapshot { await queue.next() }
}

private func isolatedSettings() throws -> (MeterSettings, () -> Void) {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    return (MeterSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suiteName) })
}

@MainActor
@Test func gaugeStopsCountingAProviderTheUserSwitchedOff() async throws {
    let (settings, cleanup) = try isolatedSettings()
    defer { cleanup() }
    settings.setEnabled(true, for: .cursor)

    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [
            .codex: StubProvider(id: .codex, snapshot: percentSnapshot(.codex, used: 10)),
            .cursor: StubProvider(id: .cursor, snapshot: percentSnapshot(.cursor, used: 90)),
        ]),
        refreshOnEnable: false,
        secrets: .forTests
    )

    await store.refreshAll()
    #expect(store.highestUsage == 0.9)

    store.setEnabled(false, for: .cursor)
    // The gauge used to keep showing 90% for a provider whose card had disappeared.
    #expect(store.highestUsage == 0.1)
    #expect(store.snapshots[.cursor] == nil)
}

@MainActor
@Test func aRefreshThatProducedNothingDoesNotClaimAnUpdate() async throws {
    let (settings, cleanup) = try isolatedSettings()
    defer { cleanup() }

    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [
            .codex: StubProvider(id: .codex, snapshot: .unavailable(.codex, "no session")),
        ]),
        refreshOnEnable: false,
        secrets: .forTests
    )

    await store.refreshAll()
    // Previously the timestamp was set unconditionally, so a total failure still read
    // as "Updated 13:49" in the menu.
    #expect(store.lastRefresh == nil)
    #expect(store.snapshots[.codex]?.state == .unavailable)
    #expect(store.highestUsage == nil)
}

@MainActor
@Test func recordsTheUpdateTimeWhenAtLeastOneProviderSucceeds() async throws {
    let (settings, cleanup) = try isolatedSettings()
    defer { cleanup() }
    settings.setEnabled(true, for: .cursor)

    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [
            .codex: StubProvider(id: .codex, snapshot: .unavailable(.codex, "no session")),
            .cursor: StubProvider(id: .cursor, snapshot: percentSnapshot(.cursor, used: 42)),
        ]),
        refreshOnEnable: false,
        secrets: .forTests
    )

    await store.refreshAll()
    #expect(store.lastRefresh != nil)
    #expect(store.highestUsage == 0.42)
}

@MainActor
@Test func keepsTheLastGoodSnapshotAndMarksItStale() async throws {
    let (settings, cleanup) = try isolatedSettings()
    defer { cleanup() }

    let queue = SnapshotQueue([
        percentSnapshot(.codex, used: 55),
        .unavailable(.codex, "app-server timed out"),
    ])
    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [.codex: QueuedProvider(id: .codex, queue: queue)]),
        refreshOnEnable: false,
        secrets: .forTests
    )

    await store.refreshAll()
    let firstRefresh = store.lastRefresh
    #expect(store.snapshots[.codex]?.state == .live)

    await store.refreshAll()
    let snapshot = try #require(store.snapshots[.codex])
    #expect(snapshot.state == .stale)
    #expect(snapshot.buckets.first?.used == 55)
    #expect(snapshot.message == "app-server timed out")
    // The gauge keeps the last known figure rather than dropping to nothing.
    #expect(store.highestUsage == 0.55)
    // A stale refresh is not a fresh update.
    #expect(store.lastRefresh == firstRefresh)
}

@MainActor
@Test func doesNotRefreshAProviderThatIsDisabled() async throws {
    let (settings, cleanup) = try isolatedSettings()
    defer { cleanup() }

    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [
            .cursor: StubProvider(id: .cursor, snapshot: percentSnapshot(.cursor, used: 99)),
        ]),
        refreshOnEnable: false,
        secrets: .forTests
    )

    #expect(!store.enabled(.cursor))
    await store.refresh(.cursor)
    #expect(store.snapshots[.cursor] == nil)
    #expect(store.highestUsage == nil)
}
