import Foundation

public struct UsageService: Sendable {
    private let providers: [ProviderID: any UsageProvider]

    public init() {
        self.providers = [
            .codex: CodexUsageProvider(),
            .claude: ClaudeUsageProvider(),
            .deepSeek: DeepSeekUsageProvider(),
            .cursor: CursorUsageProvider(),
            .commandCode: CommandCodeUsageProvider(),
            .openCodeGo: OpenCodeGoUsageProvider(),
        ]
    }

    init(providers: [ProviderID: any UsageProvider]) {
        self.providers = providers
    }

    public func fetch(_ selectedProviders: [ProviderID]) async -> [UsageSnapshot] {
        let selected = Set(selectedProviders)
        let snapshots = await withTaskGroup(of: UsageSnapshot.self, returning: [ProviderID: UsageSnapshot].self) { group in
            for provider in selectedProviders {
                guard let adapter = providers[provider] else { continue }
                group.addTask { await adapter.fetch() }
            }

            var result: [ProviderID: UsageSnapshot] = [:]
            for await snapshot in group {
                result[snapshot.provider] = snapshot
            }
            return result
        }

        // In the order asked for, so a caller that arranged the providers keeps that order.
        var seen = Set<ProviderID>()
        return selectedProviders
            .filter { selected.contains($0) && seen.insert($0).inserted }
            .compactMap { snapshots[$0] }
    }

    public func fetch(_ provider: ProviderID) async -> UsageSnapshot {
        guard let adapter = providers[provider] else {
            return .unavailable(provider, "Unknown provider")
        }
        return await adapter.fetch()
    }
}
