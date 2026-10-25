import Foundation

/// Hive's credit balance, read the way its portal reads it.
///
/// Hive has no API for the balance: its portal asks its own backend, which answers only to
/// the portal's sign-in cookie, not to an API key. So Meter uses that cookie:
///
/// - It keeps the last one that worked, and takes the replacement the backend sends with
///   each answer. The session slides forward with use, so a Meter checking every five
///   minutes keeps it alive.
/// - When the kept one is refused, it reads a fresh one from whichever browser on this Mac
///   is signed in to the portal. Signing in there again is the whole fix.
struct HiveUsageProvider: UsageProvider {
    let id = ProviderID.hive
    static let cookieName = "hive-portal-production"
    static let apiHost = "portal-customer-api.thehive.ai"
    static let signInHint = "portal.thehive.ai in your browser"

    private let store: SecretStore
    private let browserCookie: @Sendable () throws -> String?
    private let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(
        store: SecretStore = .default,
        browserCookie: @escaping @Sendable () throws -> String? = {
            try ChromiumCookies.cookie(named: HiveUsageProvider.cookieName, host: HiveUsageProvider.apiHost)?.value
        },
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = HiveUsageProvider.liveSend
    ) {
        self.store = store
        self.browserCookie = browserCookie
        self.send = send
    }

    static let notConnected = "Sign in at portal.thehive.ai in Chrome, Arc, Dia, Brave, Edge or Aside. Meter picks the session up from there."
    static let sessionEnded = "The portal session ended. Sign in again at portal.thehive.ai in your browser."

    func fetch() async -> UsageSnapshot {
        do {
            return try await fetchBalance()
        } catch let error as ChromiumCookies.KeyUnavailable {
            return .unavailable(id, error.localizedDescription)
        } catch CredentialError.signInRequired {
            // Someone who has never had a session is setting it up; someone who had one
            // has lost it. They need different words, and only the second is an alert.
            return store.secret(for: .hive) == nil
                ? .unavailable(id, Self.notConnected, issue: .notConnected)
                : .unavailable(id, Self.sessionEnded, issue: .signInRequired)
        } catch {
            return .unavailable(id, "Hive unavailable", error: error)
        }
    }

    private func fetchBalance() async throws -> UsageSnapshot {
        if let kept = store.secret(for: .hive) {
            do { return try await balance(cookie: kept) }
            catch CredentialError.signInRequired {}
        }
        guard let fresh = try browserCookie(), fresh != store.secret(for: .hive) else {
            throw CredentialError.signInRequired(Self.signInHint)
        }
        return try await balance(cookie: fresh)
    }

    /// Keeps whichever cookie the last answer left in force: the one sent, or its renewal.
    private func balance(cookie: String) async throws -> UsageSnapshot {
        var cookie = cookie
        let profile = try await get("api/profile", cookie: &cookie)
        guard let organization = Self.organizationID(in: profile) else {
            throw URLError(.cannotParseResponse)
        }
        let balance = try await get("api/organization/\(organization)/balance", cookie: &cookie)
        let snapshot = try HiveBalanceParser.parse(balance)
        if cookie != store.secret(for: .hive) { try? store.setSecret(cookie, for: .hive) }
        return snapshot
    }

    /// One request, taking up any replacement cookie the answer carries.
    private func get(_ path: String, cookie: inout String) async throws -> Any {
        var request = URLRequest(url: URL(string: "https://\(Self.apiHost)/\(path)")!)
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("\(Self.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("https://portal.thehive.ai", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200..<300: break
        case 300..<400, 401, 403: throw CredentialError.signInRequired(Self.signInHint)
        default: throw ProviderHTTPError.unexpectedStatus(response.statusCode)
        }
        if let renewed = Self.renewedCookie(in: response) { cookie = renewed }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func renewedCookie(in response: HTTPURLResponse) -> String? {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { fields, pair in
            if let key = pair.key as? String, let value = pair.value as? String { fields[key] = value }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: response.url ?? URL(string: "https://\(apiHost)")!)
            .first { $0.name == cookieName && !$0.value.isEmpty }?
            .value
    }

    /// The portal opens on the user's default organization; failing that, the first one
    /// the profile lists.
    static func organizationID(in json: Any) -> String? {
        if let value = firstValue(forKey: "default_organization_id", in: json) { return value }
        for key in ["organization_id", "organizationId"] {
            if let value = firstValue(forKey: key, in: json) { return value }
        }
        return nil
    }

    private static func firstValue(forKey key: String, in json: Any) -> String? {
        if let object = json as? [String: Any] {
            if let value = object[key], let text = scalar(value) { return text }
            for value in object.values { if let found = firstValue(forKey: key, in: value) { return found } }
        } else if let array = json as? [Any] {
            for value in array { if let found = firstValue(forKey: key, in: value) { return found } }
        }
        return nil
    }

    private static func scalar(_ value: Any) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }

    @Sendable static func liveSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request, delegate: SameHostRedirectsOnly())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum HiveBalanceParser {
    /// `billing_info.balance`, in dollars, as the portal's navigation bar shows it.
    static func parse(_ json: Any, now: Date = .now) throws -> UsageSnapshot {
        let root = (json as? [String: Any]).map { ($0["data"] as? [String: Any]) ?? $0 }
        let info = root?["billing_info"] as? [String: Any] ?? root
        guard let balance = numericValue(info?["balance"]) ?? numericValue(info?["effective_balance"]) else {
            throw URLError(.cannotParseResponse)
        }
        return .init(
            provider: .hive,
            buckets: [.init(id: "balance", label: "Credits (USD)", used: nil, limit: nil, remaining: balance, resetAt: nil, unit: .usd)],
            fetchedAt: now, source: "Hive portal", state: .live, message: nil
        )
    }
}
