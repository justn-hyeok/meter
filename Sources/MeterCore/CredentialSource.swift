import Foundation

/// Supplies the header fields that authenticate one provider's request.
///
/// Splitting this out of the providers is what lets a new provider be an endpoint plus
/// a parser: the awkward part, getting hold of a live session, is shared.
public protocol CredentialSource: Sendable {
    /// Where the credential comes from, for `meter doctor`.
    var sourceDescription: String { get }
    func authHeaders() throws -> [String: String]
}

public enum CredentialError: LocalizedError, Equatable {
    case signInRequired(String)

    public var errorDescription: String? {
        switch self {
        case .signInRequired(let host): "sign in again at \(host)"
        }
    }
}

/// Cursor's desktop app keeps its WorkOS session in the login keychain and refreshes the
/// token itself, so reading the item gives Meter one that stays current. No browser has
/// to be installed or running.
public struct CursorSessionCredential: CredentialSource {
    public static let keychainService = "cursor-access-token"

    private let readToken: @Sendable () throws -> String

    public init() {
        self.init(readToken: { try Keychain.genericPassword(service: Self.keychainService) })
    }

    init(readToken: @escaping @Sendable () throws -> String) {
        self.readToken = readToken
    }

    public var sourceDescription: String { "keychain \(Self.keychainService)" }

    public func authHeaders() throws -> [String: String] {
        let token = try readToken()
        let subject = try JWT.subject(token)
        // The dashboard expects "<user id>::<jwt>" with the separator already encoded.
        return ["Cookie": "WorkosCursorSessionToken=\(subject)%3A%3A\(token)"]
    }
}

/// Claude Code stores the subscription OAuth token in the login keychain and refreshes
/// it, so Meter reads that item and calls the account usage endpoint with it.
public struct ClaudeSubscriptionCredential: CredentialSource {
    public static let keychainService = "Claude Code-credentials"

    private let readCredentials: @Sendable () throws -> String

    public init() {
        self.init(readCredentials: { try Keychain.genericPassword(service: Self.keychainService) })
    }

    init(readCredentials: @escaping @Sendable () throws -> String) {
        self.readCredentials = readCredentials
    }

    public var sourceDescription: String { "keychain \(Self.keychainService)" }

    public func authHeaders() throws -> [String: String] {
        let payload = try readCredentials()
        guard let root = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            throw CredentialError.signInRequired("claude.ai")
        }
        return [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
        ]
    }
}

/// A browser session, read straight from a Chromium profile's cookie store.
public struct BrowserSessionCredential: CredentialSource {
    public let host: String
    private let browsers: [ChromiumBrowser]

    public init(host: String, browsers: [ChromiumBrowser] = ChromiumBrowser.supported) {
        self.host = host
        self.browsers = browsers
    }

    public var sourceDescription: String { "browser cookies for \(host)" }

    public func authHeaders() throws -> [String: String] {
        guard let jar = ChromiumCookieJar.first(hosting: host, in: browsers) else {
            throw CookieJarError.noCookies(host)
        }
        return ["Cookie": try jar.cookieHeader(host: host)]
    }
}
