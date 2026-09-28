import Foundation
import Testing
@testable import MeterCore

// Each test here fails against the code as reviewed, and names what it pins down.

private func loadFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

// MARK: - Money must never become a gauge percentage

@Test func moneyNeverDerivesAPercentage() {
    // Twice now a dollar figure was paired with a "limit" that was not a spending cap:
    // Cursor's plan allowance against bonus-inclusive spend, and Claude's extra-usage cap.
    // Both produced a percentage that drove the menu bar needle.
    let spend = UsageBucket(id: "spend", label: "Extra usage", used: 13.50, limit: 50, remaining: nil, resetAt: nil, unit: .usd)
    #expect(spend.percentageUsed == nil)
    #expect(spend.fractionUsed == nil)

    // Countable units keep deriving one.
    let credits = UsageBucket(id: "monthly", label: "Monthly", used: 25, limit: 50, remaining: 25, resetAt: nil, unit: .credits)
    #expect(credits.percentageUsed == 50)
}

@Test func claudeSpendDoesNotDriveTheGauge() throws {
    let snapshot = try ClaudeUsageParser.parse(try loadFixture("claude-oauth-usage"))
    let spend = try #require(snapshot.buckets.first { $0.id == "spend" })
    #expect(spend.used == 13.50)
    #expect(spend.percentageUsed == nil)
    // The real windows decide the needle, not the dollars.
    let highest = snapshot.buckets.compactMap { $0.fractionUsed }.max()
    #expect(highest == 0.44)
}

// MARK: - Alerts

private func window(_ provider: ProviderID, used: Double, resetAt: Date? = nil) -> UsageSnapshot {
    .init(
        provider: provider,
        buckets: [.init(id: "w", label: "Weekly", used: used, limit: 100, remaining: 100 - used, resetAt: resetAt, unit: .percent)],
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: "test",
        state: .live,
        message: nil
    )
}

@Test func doesNotAnnounceAThresholdWhileUsageIsFalling() {
    var tracker = UsageAlertTracker()
    #expect(tracker.alerts(for: [window(.codex, used: 96)]).map(\.threshold) == [95])

    // Rolling windows decay as old usage ages out. Dropping from the 95 band into the 80
    // band is not a crossing, and announcing it made an oscillating window notify forever.
    #expect(tracker.alerts(for: [window(.codex, used: 85)]).isEmpty)
    #expect(tracker.alerts(for: [window(.codex, used: 96)]).isEmpty)
    #expect(tracker.alerts(for: [window(.codex, used: 85)]).isEmpty)
    #expect(tracker.alerts(for: [window(.codex, used: 90)]).isEmpty)
}

@Test func announcesAgainOnlyAfterFallingUnderEveryThreshold() {
    var tracker = UsageAlertTracker()
    #expect(tracker.alerts(for: [window(.cursor, used: 96)]).map(\.threshold) == [95])
    #expect(tracker.alerts(for: [window(.cursor, used: 40)]).isEmpty)
    #expect(tracker.alerts(for: [window(.cursor, used: 82)]).map(\.threshold) == [80])
}

// MARK: - Store races and the alert gate

private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private(set) var entered = 0

    func wait() async {
        entered += 1
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private func waitForEntry(_ gate: Gate) async {
    while await gate.entered == 0 { await Task.yield() }
}

private actor CallCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private struct GatedProvider: UsageProvider {
    let id: ProviderID
    let gate: Gate
    let snapshot: UsageSnapshot
    func fetch() async -> UsageSnapshot {
        await gate.wait()
        return snapshot
    }
}

/// First call is held at the gate, later calls answer immediately.
private struct SequencedProvider: UsageProvider {
    let id: ProviderID
    let gate: Gate
    let counter: CallCounter
    let first: UsageSnapshot
    let later: UsageSnapshot
    func fetch() async -> UsageSnapshot {
        if await counter.next() == 1 {
            await gate.wait()
            return first
        }
        return later
    }
}

private final class AlertBox: @unchecked Sendable {
    var alerts: [UsageAlert] = []
}

private func isolatedSettingsForRegression() throws -> (MeterSettings, () -> Void) {
    let suiteName = "MeterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    return (MeterSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suiteName) })
}

@MainActor
@Test func aProviderSwitchedOffMidRefreshDoesNotComeBack() async throws {
    let (settings, cleanup) = try isolatedSettingsForRegression()
    defer { cleanup() }
    settings.setEnabled(true, for: .cursor)

    let gate = Gate()
    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [
            .cursor: GatedProvider(id: .cursor, gate: gate, snapshot: window(.cursor, used: 90)),
        ]),
        refreshOnEnable: false
    )

    let refresh = Task { await store.refreshAll() }
    await waitForEntry(gate)
    // The user switches Cursor off while its fetch is still in the air.
    store.setEnabled(false, for: .cursor)
    await gate.open()
    await refresh.value

    // The card is gone, so the needle must not still be driven by it.
    #expect(store.snapshots[.cursor] == nil)
    #expect(store.highestUsage == nil)
}

@MainActor
@Test func aLateBatchResultDoesNotOverwriteANewerSingleRefresh() async throws {
    let (settings, cleanup) = try isolatedSettingsForRegression()
    defer { cleanup() }

    let gate = Gate()
    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [
            .deepSeek: SequencedProvider(
                id: .deepSeek,
                gate: gate,
                counter: CallCounter(),
                first: .unavailable(.deepSeek, "No API key."),
                later: window(.deepSeek, used: 10)
            ),
        ]),
        refreshOnEnable: false
    )

    // The timer's batch is already in the air with the old, keyless credential.
    let batch = Task { await store.refreshAll() }
    await waitForEntry(gate)
    // The user pastes a key, which refreshes just that provider and succeeds.
    await store.refresh(.deepSeek)
    #expect(store.snapshots[.deepSeek]?.state == .live)

    await gate.open()
    await batch.value
    // The stale batch result must not demote the newer success to stale.
    #expect(store.snapshots[.deepSeek]?.state == .live)
}

@MainActor
@Test func aCrossingWhileNotificationsAreOffIsAnnouncedOnceTheyAreBackOn() async throws {
    let (settings, cleanup) = try isolatedSettingsForRegression()
    defer { cleanup() }
    settings.alertsEnabled = false

    let box = AlertBox()
    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [
            .codex: GatedProvider(id: .codex, gate: { let g = Gate(); Task { await g.open() }; return g }(), snapshot: window(.codex, used: 96)),
        ]),
        refreshOnEnable: false
    )
    store.onAlerts = { box.alerts.append(contentsOf: $0) }

    await store.refreshAll()
    #expect(box.alerts.isEmpty)

    // Turning notifications on must not find the crossing already marked as announced.
    store.setAlertsEnabled(true)
    await store.refreshAll()
    #expect(box.alerts.map(\.threshold) == [95])
}

// MARK: - Key file robustness

@Test func oneUnexpectedValueDoesNotHideOrDestroyTheOtherKeys() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MeterTests-\(UUID().uuidString)")
    let file = directory.appending(path: "credentials.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // A future version, a hand edit, or a partially written file can leave a value that is
    // not a string. Casting the whole document meant every key read as nil and the next
    // write replaced the file with just that one key.
    try Data(#"{"deepseek":"sk-KEEP-ME","command-code":{"legacy":true}}"#.utf8).write(to: file)
    let store = SecretStore(fileURL: file)

    #expect(store.secret(for: .deepSeek) == "sk-KEEP-ME")
    #expect(store.secret(for: .commandCode) == nil)

    try store.setSecret("cc-new", for: .commandCode)
    #expect(store.secret(for: .deepSeek) == "sk-KEEP-ME")
    #expect(store.secret(for: .commandCode) == "cc-new")

    // Anything it did not understand is left alone rather than dropped.
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect(raw?.count == 2)
}

@MainActor
@Test func totalFailureIsDistinguishableFromAHealthyIdleAccount() async throws {
    let (settings, cleanup) = try isolatedSettingsForRegression()
    defer { cleanup() }

    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [
            .codex: GatedProvider(id: .codex, gate: { let g = Gate(); Task { await g.open() }; return g }(),
                                  snapshot: .unavailable(.codex, "no session")),
        ]),
        refreshOnEnable: false
    )
    for provider in ProviderID.allCases where provider != .codex {
        store.setEnabled(false, for: provider)
    }

    // Before the first refresh nothing is known, which is not the same as everything failing.
    #expect(!store.isAllUnavailable)

    await store.refreshAll()
    #expect(store.highestUsage == nil)
    #expect(store.isAllUnavailable)
}
