import Foundation
import SQLite3

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
    /// A named account whose key is gone. Signing in again would fix the default account,
    /// not this one.
    case noStoredKey(Account)

    public var errorDescription: String? {
        switch self {
        case .signInRequired(let host): "sign in again at \(host)"
        case .noStoredKey(let account):
            "no key stored; run 'meter set-key \(account.provider.rawValue) --name \(account.name ?? "")'"
        }
    }

    static func missingKey(for account: Account, signInAt host: String) -> Self {
        account.name == nil ? .signInRequired(host) : .noStoredKey(account)
    }
}

/// Cursor's WorkOS session token, from wherever a signed-in Cursor keeps a current one.
///
/// The desktop app stores it in its own settings database; `cursor-agent` stores it in the
/// login keychain. Either may be signed out or stale - a CLI not run since its token
/// expired leaves an expired token behind - so each is tried in turn and an expired token
/// is never sent: the dashboard answers one with a redirect to its sign-in page.
public struct CursorSessionCredential: CredentialSource {
    public static let keychainService = "cursor-access-token"
    static let signInHint = "cursor.com (or run 'cursor-agent login')"

    private let readTokens: [@Sendable () throws -> String]
    private let now: @Sendable () -> Date

    public init() {
        // The app's database first: reading it never raises a keychain prompt.
        self.init(readTokens: [
            { try CursorAppSession.accessToken() },
            { try Keychain.genericPassword(service: Self.keychainService) },
        ])
    }

    init(readToken: @escaping @Sendable () throws -> String) {
        self.init(readTokens: [readToken])
    }

    init(readTokens: [@Sendable () throws -> String], now: @escaping @Sendable () -> Date = { .now }) {
        self.readTokens = readTokens
        self.now = now
    }

    public var sourceDescription: String { "Cursor app or keychain \(Self.keychainService)" }

    public func invalidate() { Keychain.forget(service: Self.keychainService) }

    public func authHeaders() throws -> [String: String] {
        let token = try currentToken()
        let subject = try JWT.subject(token)
        // The dashboard expects "<user id>::<jwt>" with the separator already encoded.
        return ["Cookie": "WorkosCursorSessionToken=\(subject)%3A%3A\(token)"]
    }

    private func currentToken() throws -> String {
        var firstError: (any Error)?
        var foundExpired = false
        for read in readTokens {
            do {
                let token = try read()
                // A minute of margin: the request takes time, and a token that expires on
                // the way is as good as expired.
                if let expiry = JWT.expiry(token), expiry <= now().addingTimeInterval(60) {
                    foundExpired = true
                    continue
                }
                return token
            } catch {
                firstError = firstError ?? error
            }
        }
        if foundExpired { throw CredentialError.signInRequired(Self.signInHint) }
        throw firstError ?? KeychainError.notFound(Self.keychainService)
    }
}

/// The session the Cursor desktop app keeps in its VS Code-style settings database.
enum CursorAppSession {
    static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    static func accessToken(databaseURL: URL = databaseURL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw KeychainError.notFound("Cursor app session")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &statement, nil) == SQLITE_OK else {
            throw KeychainError.notFound("Cursor app session")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw KeychainError.notFound("Cursor app session")
        }
        let token = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw KeychainError.notFound("Cursor app session") }
        return token
    }
}

/// Claude Code stores the subscription OAuth token in the login keychain and refreshes
/// it, so Meter reads that item and calls the account usage endpoint with it.
public struct ClaudeSubscriptionCredential: CredentialSource {
    public static let keychainService = "Claude Code-credentials"

    private let store: SecretStore
    private let readCredentials: @Sendable () throws -> String

    public init(store: SecretStore = .default) {
        self.init(store: store, readCredentials: {
            // Claude Code files its sign-in under the login name.
            try Keychain.genericPassword(service: Self.keychainService, account: NSUserName())
        })
    }

    init(store: SecretStore = .default, readCredentials: @escaping @Sendable () throws -> String) {
        self.store = store
        self.readCredentials = readCredentials
    }

    public var sourceDescription: String {
        store.hasSecret(for: .claude) ? "stored Claude token" : "keychain \(Self.keychainService)"
    }

    /// A stored token the service refuses is worse than no stored token at all, because it
    /// takes precedence and would leave Claude quietly broken. `claude setup-token` issues
    /// one the usage endpoint answers 403 to - its scope does not include the account read -
    /// so dropping a rejected token is what puts collection back on the keychain by itself.
    public func invalidate() {
        try? store.setSecret(nil, for: .claude)
        Keychain.forget(service: Self.keychainService)
    }

    /// A token stored in Meter is preferred because reading it never touches the keychain,
    /// which is what makes macOS ask for permission again every time Claude Code rotates its
    /// session. Note that `claude setup-token` is not a source for one: that token is scoped
    /// for inference and the account usage endpoint refuses it.
    public func token() throws -> String {
        if let stored = store.secret(for: .claude) { return stored }

        let payload = try readCredentials()
        guard let root = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            throw CredentialError.signInRequired("claude.ai")
        }
        return token
    }

    public func authHeaders() throws -> [String: String] {
        [
            "Authorization": "Bearer \(try token())",
            "anthropic-beta": "oauth-2025-04-20",
        ]
    }
}

/// OpenCode keeps the OpenCode Go key it was connected with in its own auth file, under
/// `opencode-go`, and the usage route the OpenCode console reads accepts that key.
public struct OpenCodeGoCredential: CredentialSource {
    public static let environmentKey = "OPENCODE_GO_API_KEY"
    public static let cliAuthFile = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".local/share/opencode/auth.json")

    private let store: SecretStore
    private let environment: [String: String]
    private let cliAuthFile: URL
    private let account: Account

    public init(
        store: SecretStore = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cliAuthFile: URL = OpenCodeGoCredential.cliAuthFile,
        account: Account = Account(.openCodeGo)
    ) {
        self.store = store
        self.environment = environment
        self.cliAuthFile = cliAuthFile
        self.account = account
    }

    public var sourceDescription: String { "OpenCode Go API key" }

    /// An environment variable, then a key handed to Meter, then OpenCode's own login. A
    /// named account has only its stored key: the others belong to the default account.
    public func apiKey() -> String? {
        guard account.name == nil else { return store.secret(for: account) }
        if let key = environment[Self.environmentKey], !key.isEmpty { return key }
        if let key = store.secret(for: account) { return key }
        return cliKey()
    }

    /// The key OpenCode stored when OpenCode Go was connected with `/connect`. The file holds
    /// every provider OpenCode is connected to, so only that one entry is read.
    public func cliKey() -> String? {
        guard let data = try? Data(contentsOf: cliAuthFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String,
              !key.isEmpty else {
            return nil
        }
        return key
    }

    public func authHeaders() throws -> [String: String] {
        guard let key = apiKey() else { throw CredentialError.missingKey(for: account, signInAt: "opencode.ai") }
        return ["Authorization": "Bearer \(key)"]
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
    private let account: Account

    public init(
        store: SecretStore = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cliAuthFile: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".commandcode/auth.json"),
        account: Account = Account(.commandCode)
    ) {
        self.store = store
        self.environment = environment
        self.cliAuthFile = cliAuthFile
        self.account = account
    }

    public var sourceDescription: String { "Command Code API key" }

    /// Explicit beats discovered: an environment variable, then a key the user handed to
    /// Meter, then whatever the Command Code CLI already logged in with. A named account has
    /// only its stored key: the others belong to the default account.
    public func apiKey() -> String? {
        guard account.name == nil else { return store.secret(for: account) }
        if let key = environment[Self.environmentKey], !key.isEmpty { return key }
        if let key = store.secret(for: account) { return key }
        guard let data = try? Data(contentsOf: cliAuthFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = root["apiKey"] as? String,
              !key.isEmpty else {
            return nil
        }
        return key
    }

    public func authHeaders() throws -> [String: String] {
        guard let key = apiKey() else { throw CredentialError.missingKey(for: account, signInAt: "commandcode.ai") }
        return ["Authorization": "Bearer \(key)"]
    }
}
