import Foundation

/// Supplies the header fields that authenticate one provider's request.
///
/// Splitting this out of the providers is what lets a new provider be an endpoint plus
/// a parser: the awkward part, getting hold of a live session, is shared.
public protocol CredentialSource: Sendable {
    /// Where the credential comes from, for `meter doctor`.
    var sourceDescription: String { get }
    func authHeaders() throws -> [String: String]
    /// Called after the service rejects the credential, so a cached copy is not reused and
    /// a rotated token is picked up on the next attempt.
    func invalidate()
}

extension CredentialSource {
    public func invalidate() {}
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

    public func invalidate() { Keychain.forget(service: Self.keychainService) }

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

    public func invalidate() { Keychain.forget(service: Self.keychainService) }

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

/// Command Code's own CLI authenticates with an API key, and the routes it uses accept
/// that key, so Meter presents the same credential to the same API rather than borrowing
/// a browser session meant for the dashboard.
public struct CommandCodeAPIKeyCredential: CredentialSource {
    public static let environmentKey = "COMMAND_CODE_API_KEY"

    private let store: SecretStore
    private let environment: [String: String]
    private let cliAuthFile: URL

    public init(
        store: SecretStore = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cliAuthFile: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".commandcode/auth.json")
    ) {
        self.store = store
        self.environment = environment
        self.cliAuthFile = cliAuthFile
    }

    public var sourceDescription: String { "Command Code API key" }

    /// Explicit beats discovered: an environment variable, then a key the user handed to
    /// Meter, then whatever the Command Code CLI already logged in with.
    public func apiKey() -> String? {
        if let key = environment[Self.environmentKey], !key.isEmpty { return key }
        if let key = store.secret(for: .commandCode) { return key }
        guard let data = try? Data(contentsOf: cliAuthFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = root["apiKey"] as? String,
              !key.isEmpty else {
            return nil
        }
        return key
    }

    public func authHeaders() throws -> [String: String] {
        guard let key = apiKey() else { throw CredentialError.signInRequired("commandcode.ai") }
        return ["Authorization": "Bearer \(key)"]
    }
}
