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

// MARK: - Store races

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

@Test func aSecretIsReadOnceAndOnlyReReadAfterBeingRejected() throws {
    let cache = SecretCache()
    var loads = 0
    func load() throws -> String {
        loads += 1
        return "token"
    }

    // The menu bar refreshes every five minutes. Reading the keychain each time is what
    // made macOS ask for permission again and again for every enabled provider.
    #expect(try cache.value(for: "svc", load: load) == "token")
    #expect(try cache.value(for: "svc", load: load) == "token")
    #expect(try cache.value(for: "svc", load: load) == "token")
    #expect(loads == 1)

    // A rejected credential drops the copy so a rotated token is picked up.
    cache.forget("svc")
    #expect(try cache.value(for: "svc", load: load) == "token")
    #expect(loads == 2)

    // Other services are unaffected.
    cache.forget("other")
    #expect(try cache.value(for: "svc", load: load) == "token")
    #expect(loads == 2)
}

// MARK: - The two Codex paths must agree

@Test func bothCodexPathsNameAndKeyTheSameWindowIdentically() throws {
    // wham/usage carries limit_window_seconds, but the parser assumed primary == 5-hour.
    // Codex's primary window is now weekly, so whenever the app-server path was
    // unavailable the same 16% was shown as "5-hour" instead of "Weekly" - and under a
    // different bucket id, which re-keys the alert tracker and any --json consumer.
    let http = try CodexUsageParser.parse(Data(#"""
    {"rate_limit":{"primary_window":{"used_percent":16,"limit_window_seconds":604800,"reset_at":2000000000},"secondary_window":null},
     "additional_rate_limits":[{"limit_name":"gpt-reserve","metered_feature":"base_model_inference",
       "rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":2000000100},"secondary_window":null}}]}
    """#.utf8))

    let appServer = try CodexAppServerUsageParser.parse(Data(#"""
    {"id":2,"result":{"rateLimitsByLimitId":{
      "codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":null},
      "base_model_inference":{"limitId":"base_model_inference","limitName":"gpt-reserve","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":2000000100},"secondary":null}}}}
    """#.utf8))

    let httpWindows = http.buckets.filter { $0.unit == .percent }
    #expect(Set(httpWindows.map(\.label)) == Set(appServer.buckets.map(\.label)))
    #expect(Set(httpWindows.map(\.id)) == Set(appServer.buckets.map(\.id)))
    #expect(Set(httpWindows.map(\.label)) == ["Weekly", "gpt-reserve Weekly"])
}

@Test func anUnknownCodexWindowIsNotGuessedAtAFiveHourOne() throws {
    let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":40,"reset_at":2000000000},"secondary_window":null}}"#.utf8)
    let snapshot = try CodexUsageParser.parse(data)
    // With no duration reported, naming it is a guess, and the guess was wrong.
    #expect(snapshot.buckets[0].label == "Limit")
}

@MainActor
@Test func theKeyFieldAppearsOnlyWhereACredentialIsActuallyNeeded() async throws {
    let (settings, cleanup) = try isolatedSettingsForRegression()
    defer { cleanup() }

    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [:]),
        refreshOnEnable: false
    )

    // Providers whose credential Meter finds on the machine are never asked for a key,
    // whatever their state.
    for provider in ProviderID.allCases where !provider.acceptsStoredKey {
        #expect(!store.needsKey(provider))
    }

    // Command Code authenticates through its own CLI's login, so offering a key field on a
    // working provider was noise - the menu showed one under a card reading 92%.
    #expect(ProviderID.commandCode.acceptsStoredKey)
    if store.credentialStatus[.commandCode]?.isUsable == true {
        #expect(!store.needsKey(.commandCode))
    }
}

@Test func backgroundReadsAreNotAllowedToRaiseAKeychainDialog() async {
    // The default has to be non-interactive: the five-minute refresh runs whatever the user
    // happens to be doing, and Claude Code rotating its session makes macOS want a dialog
    // roughly three times a day.
    #expect(Keychain.allowInteraction == false)

    await Keychain.$allowInteraction.withValue(true) {
        #expect(Keychain.allowInteraction)
        // The value has to survive into the child tasks the provider fan-out creates.
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { Keychain.allowInteraction }
            for await inherited in group { #expect(inherited) }
        }
    }

    #expect(Keychain.allowInteraction == false)
}

@Test func resetTimesUseTheShortestFormThatIsStillActionable() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func bucket(_ offset: TimeInterval?) -> UsageBucket {
        .init(id: "w", label: "Weekly", used: 50, limit: 100, remaining: 50,
              resetAt: offset.map { now.addingTimeInterval($0) }, unit: .percent)
    }

    // A percentage on its own is not a decision: 92% with five days left is trouble, 92%
    // with two hours left is nothing. The menu dropped this while the CLI always had it.
    #expect(UsageFormat.reset(bucket(5 * 86_400 + 3 * 3_600), now: now) == "5d")
    #expect(UsageFormat.reset(bucket(13 * 3_600), now: now) == "13h")
    #expect(UsageFormat.reset(bucket(90), now: now) == "1m")
    #expect(UsageFormat.reset(bucket(-60), now: now) == "due")
    #expect(UsageFormat.reset(bucket(nil), now: now) == nil)
}

@Test func aWindowWithNoReportedResetIsNotLeftBlank() {
    // Command Code reports resetAt 0 for its rolling windows. A blank column beside
    // neighbours showing "4d" reads as a rendering fault rather than as missing data.
    let noReset = UsageBucket(id: "w", label: "Weekly", used: 0, limit: 35, remaining: 35, resetAt: nil, unit: .credits)
    #expect(UsageFormat.reset(noReset) == nil)
    #expect((UsageFormat.reset(noReset) ?? "—") == "—")
}

@MainActor
@Test func onlyAWindowWorthActingOnIsSingledOut() async throws {
    let (settings, cleanup) = try isolatedSettingsForRegression()
    defer { cleanup() }

    func store(_ used: Double...) -> UsageStore {
        let buckets = used.enumerated().map { index, value in
            UsageBucket(id: "w\(index)", label: "W\(index)", used: value, limit: 100,
                        remaining: 100 - value, resetAt: nil, unit: .percent)
        }
        let store = UsageStore(settings: settings, service: UsageService(providers: [:]), refreshOnEnable: false)
        store.replaceSnapshotForTesting(.init(provider: .codex, buckets: buckets,
                                              fetchedAt: .now, source: "test", state: .live, message: nil))
        return store
    }

    // Nothing near a limit means nothing to point at; bolding the least-fine row while
    // everything sits at 5% is noise, not emphasis.
    #expect(store(5, 40, 70).tightestLimit == nil)
    #expect(store(5, 40, 81).tightestLimit == BucketKey(provider: .codex, bucketID: "w2"))
    #expect(store(96, 40, 81).tightestLimit == BucketKey(provider: .codex, bucketID: "w0"))
}

@MainActor
@Test func staleFiguresAreDistinguishableFromFreshOnes() async throws {
    let (settings, cleanup) = try isolatedSettingsForRegression()
    defer { cleanup() }

    let gate = Gate()
    let store = UsageStore(
        settings: settings,
        service: UsageService(providers: [
            .codex: SequencedProvider(
                id: .codex, gate: gate, counter: CallCounter(),
                first: window(.codex, used: 60),
                later: .unavailable(.codex, "app-server timed out")
            ),
        ]),
        refreshOnEnable: false
    )
    await gate.open()

    await store.refreshAll()
    #expect(store.snapshots[.codex]?.state == .live)

    // The figures survive a failed refresh - that is the point - but the menu has to say
    // they stopped updating rather than presenting them as current.
    await store.refreshAll()
    let snapshot = try #require(store.snapshots[.codex])
    #expect(snapshot.state == .stale)
    #expect(snapshot.buckets.first?.used == 60)
    #expect(snapshot.message == "app-server timed out")
}

@Test func commandCodeDoesNotInventAMonthlyCapOnceTheBalanceIsGone() throws {
    // Both fields describe the same period while credits remain, so the pair gives the cap.
    let withBalance = try CommandCodeUsageParser.parse(Data(#"""
    {"credits":{"credits":{"monthlyCredits":5.27},"windowLimits":{}},"summary":{"totalMonthlyCredits":64.73}}
    """#.utf8))
    let coherent = try #require(withBalance.buckets.first { $0.id == "monthly" })
    #expect(coherent.limit == 70)
    #expect(coherent.percentageUsed.map { ($0 * 100).rounded() / 100 } == 92.47)

    // Once the balance is zero the billing period has rolled: spend restarts near nothing
    // while the balance stays at 0. Summing them produced a cap of 0.0086 credits and a
    // "100% used" beside a few thousandths actually spent - which also seized the menu bar
    // needle and the tightest-limit emphasis.
    let depleted = try CommandCodeUsageParser.parse(Data(#"""
    {"credits":{"credits":{"monthlyCredits":0},"windowLimits":{}},"summary":{"totalMonthlyCredits":0.008591345}}
    """#.utf8))
    let balance = try #require(depleted.buckets.first { $0.id == "monthly" })
    #expect(balance.limit == nil)
    #expect(balance.used == nil)
    #expect(balance.remaining == 0)
    #expect(balance.percentageUsed == nil)
    #expect(balance.fractionUsed == nil)
}

@Test func balancesDropDecimalsThatSayNothing() {
    func balance(_ value: Double) -> UsageBucket {
        .init(id: "b", label: "Monthly credits", used: nil, limit: nil, remaining: value, resetAt: nil, unit: .credits)
    }
    // "0.00 credits" was wide enough to wrap the row onto two lines, which broke the
    // alignment every other row depends on.
    #expect(UsageFormat.value(balance(0)) == "0 credits")
    #expect(UsageFormat.value(balance(8.6)) == "8.6 credits")
    #expect(UsageFormat.value(balance(64.725)) == "64.73 credits")
}

@MainActor
@Test func aDraggedCardTakesThePlaceOfTheOneItPasses() async throws {
    let (settings, cleanup) = try isolatedSettingsForRegression()
    defer { cleanup() }
    let store = UsageStore(settings: settings, service: UsageService(providers: [:]), refreshOnEnable: false)
    #expect(store.providerOrder == [.codex, .claude, .cursor, .deepSeek, .commandCode])

    // Down the list: lands after the card it passed.
    store.move(.codex, to: .cursor)
    #expect(store.providerOrder == [.claude, .cursor, .codex, .deepSeek, .commandCode])

    // Up the list: lands before it.
    store.move(.commandCode, to: .claude)
    #expect(store.providerOrder == [.commandCode, .claude, .cursor, .codex, .deepSeek])

    // Dropping on itself changes nothing.
    store.move(.cursor, to: .cursor)
    #expect(store.providerOrder == [.commandCode, .claude, .cursor, .codex, .deepSeek])

    // Saved, so a restart comes back the same way.
    #expect(settings.providerOrder == store.providerOrder)
}

@Test func theServiceAnswersInTheOrderItWasAsked() async {
    let service = UsageService(providers: [
        .codex: GatedProvider(id: .codex, gate: { let g = Gate(); Task { await g.open() }; return g }(), snapshot: window(.codex, used: 1)),
        .claude: GatedProvider(id: .claude, gate: { let g = Gate(); Task { await g.open() }; return g }(), snapshot: window(.claude, used: 1)),
        .cursor: GatedProvider(id: .cursor, gate: { let g = Gate(); Task { await g.open() }; return g }(), snapshot: window(.cursor, used: 1)),
    ])
    // It used to re-sort into declaration order, which would have undone the arrangement.
    let results = await service.fetch([.cursor, .codex, .claude])
    #expect(results.map(\.provider) == [.cursor, .codex, .claude])
}

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
@Test func anAbandonedDragLeavesTheSavedOrderAlone() async throws {
    let (settings, cleanup) = try isolatedSettingsForRegression()
    defer { cleanup() }
    let store = UsageStore(settings: settings, service: UsageService(providers: [:]), refreshOnEnable: false)
    let before = store.providerOrder

    // Passing over cards moves them on screen without writing anything.
    store.move(.codex, to: .deepSeek, persist: false)
    #expect(store.providerOrder == [.claude, .cursor, .deepSeek, .codex, .commandCode])
    #expect(settings.providerOrder == before)

    // Esc: the old order comes back.
    store.restoreOrder(before)
    #expect(store.providerOrder == before)

    // A drop saves what is on screen.
    store.move(.cursor, to: .codex, persist: false)
    store.saveOrder()
    #expect(settings.providerOrder == store.providerOrder)
    #expect(settings.providerOrder != before)
}
