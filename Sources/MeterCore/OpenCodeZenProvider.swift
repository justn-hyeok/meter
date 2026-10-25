import Foundation

/// Zen publishes no balance route, so the only thing a key can be asked is whether it
/// works: the models list is the one endpoint it always answers. A balance is read when a
/// response happens to carry one rather than being assumed to exist.
struct OpenCodeZenUsageProvider: UsageProvider {
    let id = ProviderID.openCodeZen
    private let credential: any CredentialSource

    init(credential: any CredentialSource = OpenCodeZenCredential()) {
        self.credential = credential
    }

    func fetch() async -> UsageSnapshot {
        do {
            let data = try await AuthenticatedRequest.json(
                "https://opencode.ai/zen/v1/models", credential: credential, signInAt: "opencode.ai"
            )
            return try OpenCodeZenUsageParser.parse(data)
        } catch {
            return .unavailable(id, "OpenCode Zen unavailable", error: error)
        }
    }
}

enum OpenCodeZenUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        // Whatever the route adds, the key bucket stays: a key that answered is the one fact
        // this provider can report, and a model count read from an unexpected shape must not
        // turn a working key into an error.
        var buckets: [UsageBucket] = [
            .init(id: "key", label: "Key works", used: nil, limit: nil, remaining: nil, resetAt: nil, unit: .unknown)
        ]
        if let balance = balance(root) {
            buckets.append(.init(id: "balance", label: "Balance (USD)", used: nil, limit: nil, remaining: balance, resetAt: nil, unit: .usd))
        }
        return .init(
            provider: .openCodeZen,
            buckets: buckets,
            fetchedAt: now,
            source: "OpenCode Zen API",
            state: .live,
            message: modelCount(root).map { "\($0) models" }
        )
    }

    /// `/zen/v1/models` is OpenAI-shaped (`{"data": [{"id": …}]}`), but the console has
    /// answered with a bare `models` array, so both are counted.
    private static func modelCount(_ root: [String: Any]) -> Int? {
        if let list = root["data"] as? [[String: Any]] { return list.count }
        if let list = root["data"] as? [String] { return list.count }
        if let list = root["models"] as? [[String: Any]] { return list.count }
        if let list = root["models"] as? [String] { return list.count }
        return nil
    }

    /// A balance, if one is ever sent: top level or nested, under any of the names an
    /// OpenAI-compatible gateway uses. `credits` is an object at some providers, so only a
    /// number is accepted and the rest is passed over.
    private static func balance(_ root: [String: Any]) -> Double? {
        let containers = [root, root["data"] as? [String: Any], root["usage"] as? [String: Any]].compactMap { $0 }
        for container in containers {
            for key in ["balance", "credits", "remaining"] {
                if let value = numericValue(container[key]) { return value }
            }
        }
        return nil
    }
}
