import Foundation

public struct UsageService: Sendable {
    private let makeProvider: @Sendable (Account) -> (any UsageProvider)?

    /// Keys are read from `secrets`, the same store the caller lists accounts from.
    public init(secrets: SecretStore = .default) {
        self.makeProvider = { UsageService.provider(for: $0, secrets: secrets) }
    }

    init(makeProvider: @escaping @Sendable (Account) -> (any UsageProvider)?) {
        self.makeProvider = makeProvider
    }

    /// Default accounts only, for tests that stand in one provider per provider ID.
    init(providers: [ProviderID: any UsageProvider]) {
        self.init(makeProvider: { $0.name == nil ? providers[$0.provider] : nil })
    }

    /// One place decides how every account is read. A named account differs only in its
    /// credential, which each credential type works out from the account it is given.
    static func provider(for account: Account, secrets: SecretStore) -> (any UsageProvider)? {
        switch account.provider {
        case .codex: account.name == nil ? CodexUsageProvider() : nil
        case .claude: account.name == nil ? ClaudeUsageProvider(credential: ClaudeSubscriptionCredential(store: secrets)) : nil
        case .cursor: account.name == nil ? CursorUsageProvider() : nil
        case .deepSeek: DeepSeekUsageProvider(store: secrets, account: account)
        case .commandCode: CommandCodeUsageProvider(credential: CommandCodeAPIKeyCredential(store: secrets, account: account))
        case .openCodeGo: OpenCodeGoUsageProvider(credential: OpenCodeGoCredential(store: secrets, account: account))
        case .openRouter: OpenRouterUsageProvider(store: secrets, account: account)
        case .hive: account.name == nil ? HiveUsageProvider(store: secrets) : nil
        // Filled in by their own providers; until then they say so rather than vanish.
        case .openCodeZen: PendingProvider(id: .openCodeZen)
        case .githubCopilot: account.name == nil ? PendingProvider(id: .githubCopilot) : nil
        case .custom: account.name == nil ? nil : PendingProvider(id: .custom)
        }
    }

    public func fetch(_ accounts: [Account]) async -> [UsageSnapshot] {
        let snapshots = await withTaskGroup(of: UsageSnapshot.self, returning: [Account: UsageSnapshot].self) { group in
            for account in Set(accounts) {
                guard let provider = makeProvider(account) else { continue }
                group.addTask { await provider.fetch().for(account) }
            }

            var result: [Account: UsageSnapshot] = [:]
            for await snapshot in group {
                result[snapshot.accountID] = snapshot
            }
            return result
        }

        // In the order asked for, so a caller that arranged the accounts keeps that order.
        var seen = Set<Account>()
        return accounts
            .filter { seen.insert($0).inserted }
            .compactMap { snapshots[$0] }
    }

    public func fetch(_ account: Account) async -> UsageSnapshot {
        guard let provider = makeProvider(account) else {
            return UsageSnapshot.unavailable(account.provider, "Unknown account").for(account)
        }
        return await provider.fetch().for(account)
    }
}

/// A provider whose collector is not written yet.
struct PendingProvider: UsageProvider {
    let id: ProviderID
    func fetch() async -> UsageSnapshot { .unavailable(id, "\(id.title) is not supported yet") }
}
