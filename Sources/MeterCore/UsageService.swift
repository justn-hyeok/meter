import Foundation

public struct UsageService: Sendable {
    private let providers: [ProviderID: any UsageProvider]
    private let makeNamed: @Sendable (Account) -> (any UsageProvider)?

    public init() {
        self.providers = [
            .codex: CodexUsageProvider(),
            .claude: ClaudeUsageProvider(),
            .deepSeek: DeepSeekUsageProvider(),
            .cursor: CursorUsageProvider(),
            .commandCode: CommandCodeUsageProvider(),
            .openCodeGo: OpenCodeGoUsageProvider(),
        ]
        self.makeNamed = UsageService.namedProvider
    }

    init(providers: [ProviderID: any UsageProvider], named: @escaping @Sendable (Account) -> (any UsageProvider)? = { _ in nil }) {
        self.providers = providers
        self.makeNamed = named
    }

    public func fetch(_ accounts: [Account]) async -> [UsageSnapshot] {
        let snapshots = await withTaskGroup(of: UsageSnapshot.self, returning: [Account: UsageSnapshot].self) { group in
            for account in Set(accounts) {
                guard let adapter = adapter(for: account) else { continue }
                group.addTask { await adapter.fetch().for(account) }
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

    public func fetch(_ providers: [ProviderID]) async -> [UsageSnapshot] {
        await fetch(providers.map { Account($0) })
    }

    public func fetch(_ account: Account) async -> UsageSnapshot {
        guard let adapter = adapter(for: account) else {
            return UsageSnapshot.unavailable(account.provider, "Unknown account").for(account)
        }
        return await adapter.fetch().for(account)
    }

    public func fetch(_ provider: ProviderID) async -> UsageSnapshot {
        await fetch(Account(provider))
    }

    private func adapter(for account: Account) -> (any UsageProvider)? {
        account.name == nil ? providers[account.provider] : makeNamed(account)
    }

    /// A named account's provider reads that account's stored key and nothing else: the
    /// environment variable and a CLI's own login belong to the default account.
    static func namedProvider(_ account: Account) -> (any UsageProvider)? {
        switch account.provider {
        case .deepSeek: DeepSeekUsageProvider(account: account)
        case .commandCode: CommandCodeUsageProvider(credential: StoredKeyCredential(account: account, signInAt: "commandcode.ai"))
        case .openCodeGo: OpenCodeGoUsageProvider(credential: StoredKeyCredential(account: account, signInAt: "opencode.ai"))
        case .codex, .claude, .cursor: nil
        }
    }
}
