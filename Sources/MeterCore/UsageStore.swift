import Foundation
import Observation

/// Menu bar state: which providers are on, their latest snapshots, and the value that
/// drives the gauge.
///
/// Invariant: `snapshots` only ever holds providers that are currently enabled. The
/// gauge reads every snapshot it can see, so a snapshot left behind by a provider the
/// user switched off would keep driving it.
@MainActor
@Observable
public final class UsageStore {
    public private(set) var snapshots: [ProviderID: UsageSnapshot] = [:]
    public private(set) var isRefreshing = false
    /// When usable data last arrived, not when a refresh was last attempted.
    public private(set) var lastRefresh: Date?
    public private(set) var enabledProviders: Set<ProviderID>
    /// Stored rather than read through to settings so the menu toggle observes changes.
    public private(set) var alertsEnabled: Bool
    /// Cached so the menu does not read the key file from inside a SwiftUI body.
    public private(set) var storedKeyProviders: Set<ProviderID>
    /// Cached so the menu does not probe the machine from inside a SwiftUI body.
    public private(set) var credentialStatus: [ProviderID: CredentialStatus] = [:]
    public var refreshInterval: TimeInterval = 300

    /// Set by the app to post notifications; MeterCore stays free of UserNotifications.
    public var onAlerts: (@MainActor ([UsageAlert]) -> Void)?

    private var alertTracker = UsageAlertTracker()
    /// Identifies the most recently started fetch per provider, so a slow batch cannot
    /// land on top of a newer single refresh that has already answered.
    private var latestFetch: [ProviderID: Int] = [:]
    private var fetchCounter = 0
    private var refreshTask: Task<Void, Never>?
    private let settings: MeterSettings
    private let refreshOnEnable: Bool
    private let service: UsageService
    private let secrets: SecretStore

    public convenience init(
        defaults: UserDefaults = UserDefaults(suiteName: MeterSettings.suiteName) ?? .standard,
        refreshOnEnable: Bool = true
    ) {
        self.init(
            settings: MeterSettings(defaults: defaults),
            service: UsageService(),
            refreshOnEnable: refreshOnEnable
        )
    }

    init(
        settings: MeterSettings,
        service: UsageService,
        refreshOnEnable: Bool = true,
        secrets: SecretStore = .default
    ) {
        self.settings = settings
        self.service = service
        self.secrets = secrets
        self.refreshOnEnable = refreshOnEnable
        settings.migrateIfNeeded()
        self.enabledProviders = Set(settings.enabledProviders())
        self.alertsEnabled = settings.alertsEnabled
        self.storedKeyProviders = Self.providersWithStoredKeys(secrets)
        self.credentialStatus = Dictionary(uniqueKeysWithValues: CredentialDoctor.diagnose().map { ($0.provider, $0) })
    }

    public func enabled(_ provider: ProviderID) -> Bool {
        enabledProviders.contains(provider)
    }

    public func setEnabled(_ enabled: Bool, for provider: ProviderID) {
        let wasEnabled = enabledProviders.contains(provider)
        guard enabled != wasEnabled else { return }
        if enabled {
            enabledProviders.insert(provider)
        } else {
            enabledProviders.remove(provider)
            // Drop the data with the toggle, so the gauge stops counting it.
            snapshots[provider] = nil
        }
        settings.setEnabled(enabled, for: provider)
        if enabled && refreshOnEnable { Task { await refresh(provider) } }
    }

    public func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshAll()
                try? await Task.sleep(for: .seconds(self.refreshInterval))
            }
        }
    }

    /// `interactive` is true only when the user is looking: opening the menu or pressing
    /// Refresh. A background refresh never raises a keychain dialog.
    public func refreshAll(interactive: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let selected = ProviderID.allCases.filter(enabled)
        let tokens = Dictionary(uniqueKeysWithValues: selected.map { ($0, beginFetch($0)) })
        let results = await Keychain.$allowInteraction.withValue(interactive) {
            await service.fetch(selected)
        }
        for snapshot in results { merge(snapshot, token: tokens[snapshot.provider]) }

        // A refresh that produced nothing usable must not advertise itself as the last
        // update; the menu would otherwise show a fresh time above stale figures.
        if results.contains(where: { $0.state == .live }) { lastRefresh = .now }

        announceAlerts()
    }

    public func setAlertsEnabled(_ enabled: Bool) {
        guard enabled != alertsEnabled else { return }
        alertsEnabled = enabled
        settings.alertsEnabled = enabled
    }

    // MARK: - Provider keys

    public func hasStoredKey(for provider: ProviderID) -> Bool {
        storedKeyProviders.contains(provider)
    }

    /// Whether the menu should offer somewhere to type a key.
    ///
    /// Only for providers Meter is handed a credential for, and only while that provider
    /// is not working: Command Code is already authenticated by its own CLI's login, so
    /// asking for a key there was noise, and a key that turns out to be wrong brings the
    /// field back rather than stranding the user with no way to correct it.
    public func needsKey(_ provider: ProviderID) -> Bool {
        guard provider.acceptsStoredKey else { return false }
        if credentialStatus[provider]?.isUsable != true { return true }
        return snapshots[provider]?.state == .unavailable
    }

    /// Stores a key the user typed into the menu, then refreshes that provider.
    ///
    /// Throwing rather than swallowing: the directory can be unwritable, and a Save that
    /// silently did nothing while clearing the field left the user retyping forever.
    public func storeKey(_ value: String, for provider: ProviderID) throws {
        try secrets.setSecret(value, for: provider)
        storedKeyProviders = Self.providersWithStoredKeys(secrets)
        credentialStatus = Dictionary(uniqueKeysWithValues: CredentialDoctor.diagnose().map { ($0.provider, $0) })
        Task { await refresh(provider) }
    }

    private static func providersWithStoredKeys(_ secrets: SecretStore) -> Set<ProviderID> {
        Set(ProviderID.allCases.filter { $0.acceptsStoredKey && secrets.hasSecret(for: $0) })
    }

    public func refresh(_ provider: ProviderID, interactive: Bool = false) async {
        guard enabled(provider) else { return }
        let token = beginFetch(provider)
        let snapshot = await Keychain.$allowInteraction.withValue(interactive) {
            await service.fetch(provider)
        }
        merge(snapshot, token: token)
        announceAlerts()
    }

    /// Called when the menu opens. Retries anything the background refresh could not read
    /// without a dialog, which is where the keychain prompt now appears.
    public func menuOpened() async {
        let stale = ProviderID.allCases.filter { enabled($0) && snapshots[$0]?.state != .live }
        guard !stale.isEmpty else { return }
        for provider in stale {
            await refresh(provider, interactive: true)
        }
    }

    private func beginFetch(_ provider: ProviderID) -> Int {
        fetchCounter += 1
        latestFetch[provider] = fetchCounter
        return fetchCounter
    }

    /// The tracker is consulted only when alerts are on. Asking it while they are off
    /// would record the crossing as already announced, and turning them back on would
    /// then stay silent until the window rolled.
    private func announceAlerts() {
        guard alertsEnabled else { return }
        let alerts = alertTracker.alerts(for: ProviderID.allCases.compactMap { snapshots[$0] })
        if !alerts.isEmpty { onAlerts?(alerts) }
    }

    /// Every enabled provider answered and none produced data. `highestUsage` is nil for
    /// this and for "nothing enabled" alike, and the menu drew both as a zero-percent
    /// needle - a total credential failure looked like a healthy, idle account.
    public var isAllUnavailable: Bool {
        !enabledProviders.isEmpty && enabledProviders.allSatisfy { snapshots[$0]?.buckets.isEmpty ?? false }
    }

    public var highestUsage: Double? {
        snapshots.values.flatMap(\.buckets).compactMap(\.fractionUsed).max()
    }

    private func merge(_ incoming: UsageSnapshot, token: Int?) {
        // Both callers suspend for up to fifteen seconds. In that window the user can switch
        // the provider off, or a newer fetch can answer first; neither result belongs here.
        guard enabled(incoming.provider), let token, latestFetch[incoming.provider] == token else { return }

        if incoming.state == .unavailable,
           let previous = snapshots[incoming.provider],
           previous.state != .unavailable,
           !previous.buckets.isEmpty {
            snapshots[incoming.provider] = .init(
                provider: previous.provider,
                buckets: previous.buckets,
                fetchedAt: previous.fetchedAt,
                source: previous.source,
                state: .stale,
                message: incoming.message
            )
        } else {
            snapshots[incoming.provider] = incoming
        }
    }
}
