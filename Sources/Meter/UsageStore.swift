import AppKit
import Foundation

@MainActor
@Observable
final class UsageStore {
    private(set) var snapshots: [ProviderID: UsageSnapshot] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var enabledProviders: Set<ProviderID>
    var refreshInterval: TimeInterval = 300
    private var refreshTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let refreshOnEnable: Bool

    private let providers: [ProviderID: any UsageProvider] = [
        .codex: CodexUsageProvider(),
        .deepSeek: DeepSeekUsageProvider(),
        .cursor: CursorUsageProvider(),
        .commandCode: CommandCodeUsageProvider(),
    ]

    init(defaults: UserDefaults = .standard, refreshOnEnable: Bool = true) {
        self.defaults = defaults
        self.refreshOnEnable = refreshOnEnable
        self.enabledProviders = Set(ProviderID.allCases.filter { provider in
            let key = "enabled.\(provider.rawValue)"
            if defaults.object(forKey: key) != nil { return defaults.bool(forKey: key) }
            return Self.defaultEnabled(provider)
        })
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
        defaults.set(enabled, forKey: "enabled.\(provider.rawValue)")
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
        await withTaskGroup(of: UsageSnapshot.self) { group in
            for provider in ProviderID.allCases where enabled(provider) {
                if let adapter = providers[provider] { group.addTask { await adapter.fetch() } }
            }
            for await snapshot in group { merge(snapshot) }
        }
    }

    func refresh(_ provider: ProviderID) async {
        guard let adapter = providers[provider] else { return }
        merge(await adapter.fetch())
    }

    var highestUsage: Double? {
        snapshots.values.flatMap(\.buckets).compactMap(\.fractionUsed).max()
    }

    private static func defaultEnabled(_ provider: ProviderID) -> Bool {
        provider == .codex || provider == .deepSeek
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
