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
