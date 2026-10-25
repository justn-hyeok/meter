import Foundation

/// A provider the user added themselves: an OpenAI-compatible API at a base URL they typed.
///
/// Meter cannot know what such an API reports, so it recognises the few whose balance routes
/// it does know from the host and otherwise asks only whether the key works. Each one is a
/// named account, `custom#<name>`: the key lives in the key file beside it and the base URL
/// in settings, both written by `UsageStore.addCustomProvider`.
struct CustomUsageProvider: UsageProvider {
    /// The network, injectable so a test can answer with a status instead of reaching out.
    typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let id = ProviderID.custom
    private let store: SecretStore
    private let account: Account
    private let baseURL: URL?
    private let send: Send?

    init(
        store: SecretStore = .default,
        account: Account,
        settings: MeterSettings = MeterSettings(),
        send: Send? = nil
    ) {
        self.store = store
        self.account = account
        self.baseURL = account.name
            .flatMap { settings.customProviders[$0] }
            .flatMap { URL(string: $0.baseURL) }
        self.send = send
    }

    init(store: SecretStore = .default, account: Account, baseURL: URL, send: Send? = nil) {
        self.store = store
        self.account = account
        self.baseURL = baseURL
        self.send = send
    }

    func fetch() async -> UsageSnapshot {
        do {
            return try await collected().for(account)
        } catch {
            return .unavailable(id, "\(account.title) unavailable", error: error).for(account)
        }
    }

    private func collected() async throws -> UsageSnapshot {
        // Only reachable if the settings entry was removed underneath an account that is
        // still in the key file; saying so beats a tile that never explains itself.
        guard let baseURL, let host = baseURL.host() else { throw CustomProviderError.noBaseURL(account) }
        let credential = CustomProviderCredential(store: store, account: account)
        let kind = CustomProviderKind.detect(baseURL: baseURL.absoluteString)
        switch kind {
        case .moonshot:
            let data = try await get(baseURL.appending(path: "users/me/balance"), credential, signInAt: host)
            return try CustomUsageParser.moonshot(data)
        case .siliconFlow:
            let data = try await get(baseURL.appending(path: "user/info"), credential, signInAt: host)
            return try CustomUsageParser.siliconFlow(data)
        case .deepSeek:
            // The same route the built-in provider reads, so a second DeepSeek key is read
            // exactly like the first.
            let data = try await get(URL(string: "https://api.deepseek.com/user/balance")!, credential, signInAt: host)
            return try DeepSeekUsageParser.parse(data)
        case .openRouter:
            let data = try await get(URL(string: "https://openrouter.ai/api/v1/key")!, credential, signInAt: host)
            return try OpenRouterUsageParser.parse(data)
        case .generic:
            let data = try await get(baseURL.appending(path: "models"), credential, signInAt: host)
            return try CustomUsageParser.models(data)
        }
    }

    /// One read of the API. The live route is `AuthenticatedRequest`, which maps a refused
    /// credential to `CredentialError`; an injected `send` answers with a status instead, so
    /// the same mapping happens here and both routes fail the same way.
    private func get(_ url: URL, _ credential: any CredentialSource, signInAt: String) async throws -> Data {
        guard let send else {
            return try await AuthenticatedRequest.json(url.absoluteString, credential: credential, signInAt: signInAt)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200..<300: return data
        case 300..<400, 401, 403:
            credential.invalidate()
            throw CredentialError.signInRequired(signInAt)
        default: throw ProviderHTTPError.unexpectedStatus(response.statusCode)
        }
    }
}

/// The key `addCustomProvider` filed under `custom#<name>`, presented as a bearer token.
struct CustomProviderCredential: CredentialSource {
    let store: SecretStore
    let account: Account

    var sourceDescription: String { "custom provider API key" }

    func authHeaders() throws -> [String: String] {
        guard let key = store.secret(for: account) else { throw CredentialError.noStoredKey(account) }
        return ["Authorization": "Bearer \(key)"]
    }
}

enum CustomProviderError: LocalizedError, Equatable {
    case noBaseURL(Account)

    var errorDescription: String? {
        switch self {
        case .noBaseURL(let account):
            "no base URL is saved for \(account.title); add it again in Settings › Providers"
        }
    }
}

/// The APIs Meter knows how to read without being told. Everything else is checked by
/// listing its models, which is the one thing an OpenAI-compatible API must answer.
public enum CustomProviderKind: Sendable, Equatable {
    case moonshot
    case siliconFlow
    case deepSeek
    case openRouter
    case generic

    /// The host decides: a user's base URL names the service even when its path differs.
    public static func detect(baseURL: String) -> Self {
        let host = URL(string: baseURL)?.host()?.lowercased() ?? ""
        if host.contains("moonshot") { return .moonshot }
        if host.contains("siliconflow") { return .siliconFlow }
        if host.contains("deepseek") { return .deepSeek }
        if host.contains("openrouter") { return .openRouter }
        return .generic
    }

    /// What the settings form says under the base URL field.
    public var hint: String {
        switch self {
        case .moonshot: "✓ Recognised: Moonshot balance API. The tile will show your balance."
        case .siliconFlow: "✓ Recognised: SiliconFlow balance API. The tile will show your balance."
        case .deepSeek: "✓ Recognised: DeepSeek balance API. The tile will show your balance."
        case .openRouter: "✓ Recognised: OpenRouter key API. The tile will show the key's usage."
        case .generic: "Unknown API: the tile will show whether the key works."
        }
    }
}

enum CustomUsageParser {
    static func moonshot(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["data"] as? [String: Any],
              let balance = numericValue(info["available_balance"]) else {
            throw URLError(.cannotParseResponse)
        }
        // The API does not state a currency, so the figure is reported as credits rather
        // than guessed into dollars.
        return balanceSnapshot(balance, source: "Moonshot balance API", now: now)
    }

    static func siliconFlow(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["data"] as? [String: Any],
              let balance = numericValue(info["totalBalance"]) ?? numericValue(info["balance"]) else {
            throw URLError(.cannotParseResponse)
        }
        return balanceSnapshot(balance, source: "SiliconFlow user info", now: now)
    }

    /// The key listing models is the proof it works, and the count is all there is to say.
    static func models(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [Any] else {
            throw URLError(.cannotParseResponse)
        }
        return .init(
            provider: .custom,
            buckets: [.init(id: "key", label: "Key works", used: nil, limit: nil, remaining: nil, resetAt: nil, unit: .unknown)],
            fetchedAt: now,
            source: "Custom models API",
            state: .live,
            message: "\(models.count) models"
        )
    }

    private static func balanceSnapshot(_ balance: Double, source: String, now: Date) -> UsageSnapshot {
        .init(
            provider: .custom,
            buckets: [.init(id: "balance", label: "Balance", used: nil, limit: nil, remaining: balance, resetAt: nil, unit: .credits)],
            fetchedAt: now,
            source: source,
            state: .live,
            message: nil
        )
    }
}
