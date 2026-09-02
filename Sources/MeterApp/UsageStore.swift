import AppKit
import Foundation
import MeterCore
import Observation

@MainActor
@Observable
final class UsageStore {
    private(set) var snapshots: [ProviderID: UsageSnapshot] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var enabledProviders: Set<ProviderID>
    var refreshInterval: TimeInterval = 300
    private var refreshTask: Task<Void, Never>?
    private let settings: MeterSettings
    private let refreshOnEnable: Bool
    private let service = UsageService()

    init(
        defaults: UserDefaults = UserDefaults(suiteName: MeterSettings.suiteName) ?? .standard,
        refreshOnEnable: Bool = true
    ) {
        let settings = MeterSettings(defaults: defaults)
        self.settings = settings
        self.refreshOnEnable = refreshOnEnable
        self.enabledProviders = Set(settings.enabledProviders())
    }

    func enabled(_ provider: ProviderID) -> Bool {
        enabledProviders.contains(provider)
    }

    func setEnabled(_ enabled: Bool, for provider: ProviderID) {
        let wasEnabled = enabledProviders.contains(provider)
        guard enabled != wasEnabled else { return }
        if enabled {
            enabledProviders.insert(provider)
        } else {
            enabledProviders.remove(provider)
        }
        settings.setEnabled(enabled, for: provider)
        if enabled && refreshOnEnable { Task { await refresh(provider) } }
    }

    func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshAll()
                try? await Task.sleep(for: .seconds(self.refreshInterval))
            }
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = .now }
        let selected = ProviderID.allCases.filter(enabled)
        for snapshot in await service.fetch(selected) { merge(snapshot) }
    }

    func refresh(_ provider: ProviderID) async {
        merge(await service.fetch(provider))
    }

    var highestUsage: Double? {
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
