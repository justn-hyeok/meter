@testable import MeterCore

/// Lets tests keep writing `store.snapshots[.codex]` for a provider's default account.
extension Dictionary where Key == Account {
    subscript(_ provider: ProviderID) -> Value? {
        self[Account(provider)]
    }
}

import Foundation

extension SecretStore {
    /// A key file of its own, so a store under test never sees the named accounts on the
    /// machine running the tests.
    static var forTests: SecretStore {
        SecretStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MeterTests-\(UUID().uuidString)/credentials.json"))
    }
}

@MainActor
extension UsageStore {
    /// The order as providers, for tests where every account is a default one.
    var providerOrder: [ProviderID] { order.map(\.provider) }

    func restoreOrder(_ providers: [ProviderID]) {
        restoreOrder(providers.map { Account($0) })
    }
}

extension UsageService {
    func fetch(_ providers: [ProviderID]) async -> [UsageSnapshot] {
        await fetch(providers.map { Account($0) })
    }
}
