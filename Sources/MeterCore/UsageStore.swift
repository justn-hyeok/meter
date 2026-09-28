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
    public var refreshInterval: TimeInterval = 300

    private var refreshTask: Task<Void, Never>?
    private let settings: MeterSettings
    private let refreshOnEnable: Bool
    private let service: UsageService

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

    init(settings: MeterSettings, service: UsageService, refreshOnEnable: Bool = true) {
        self.settings = settings
        self.service = service
        self.refreshOnEnable = refreshOnEnable
        self.enabledProviders = Set(settings.enabledProviders())
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

    public func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let results = await service.fetch(ProviderID.allCases.filter(enabled))
        for snapshot in results { merge(snapshot) }

        // A refresh that produced nothing usable must not advertise itself as the last
        // update; the menu would otherwise show a fresh time above stale figures.
        if results.contains(where: { $0.state == .live }) { lastRefresh = .now }
    }

    public func refresh(_ provider: ProviderID) async {
        guard enabled(provider) else { return }
        merge(await service.fetch(provider))
    }

    public var highestUsage: Double? {
        snapshots.values.flatMap(\.buckets).compactMap(\.fractionUsed).max()
    }

    private func merge(_ incoming: UsageSnapshot) {
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
