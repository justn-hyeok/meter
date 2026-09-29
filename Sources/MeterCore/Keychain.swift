import Foundation
import Security

public enum KeychainError: LocalizedError, Equatable {
    case notFound(String)
    case accessDenied(String)
    case unreadable(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notFound(let service):
            "keychain item '\(service)' not found"
        case .accessDenied(let service):
            "keychain access to '\(service)' was denied"
        case .unreadable(let service, let status):
            "keychain item '\(service)' could not be read (OSStatus \(status))"
        }
    }
}

/// Reads generic passwords that other applications own.
///
/// The first read of another app's item asks the user for permission. The grant is
/// recorded against Meter's designated requirement, so it survives rebuilds only when
/// Meter is signed with a certificate rather than ad-hoc. See `Scripts/sign.sh`.
/// Holds secrets for the life of the process.
///
/// Without this the menu bar re-read every enabled provider's keychain item on each
/// five-minute refresh. macOS asks for permission per read unless the user picked
/// "Always Allow", so two enabled providers meant two prompts every five minutes forever.
final class SecretCache: @unchecked Sendable {
    static let shared = SecretCache()

    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for service: String, load: () throws -> String) throws -> String {
        lock.lock()
        if let cached = values[service] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Loaded outside the lock: this can block on a permission prompt.
        let loaded = try load()
        lock.lock()
        values[service] = loaded
        lock.unlock()
        return loaded
    }

    func forget(_ service: String) {
        lock.lock()
        values[service] = nil
        lock.unlock()
    }
}

public enum Keychain {
    /// Whether a read may put a permission dialog on screen.
    ///
    /// Claude Code rewrites its keychain item every few hours when it refreshes the session,
    /// and the rewrite discards the permission macOS recorded for Meter. Nothing here can
    /// prevent that, so the five-minute refresh stops asking: a background read that would
    /// need a dialog fails as `blocked` and the provider keeps its last figures, and the
    /// dialog is raised only when the user opens the menu or presses Refresh - a moment they
    /// chose, rather than an interruption in the middle of something else.
    @TaskLocal public static var allowInteraction = false

    /// Drops the cached copy so the next read goes back to the keychain. Called when a
    /// service rejects the credential, which is how a rotated token is picked up.
    public static func forget(service: String) {
        SecretCache.shared.forget(service)
    }

    /// Reads the item for `service`, preferring the one filed under `account` when given.
    ///
    /// Other software can file a second item under the same service name, and without an
    /// account the keychain returns whichever it finds first. Claude Code 2.1.284 did this:
    /// a new item under account "unknown" holding only MCP sign-ins sat beside the real one
    /// under the login name, and Meter read the wrong one. An account that has no item falls
    /// back to any item for the service.
    public static func genericPassword(service: String, account: String? = nil) throws -> String {
        try SecretCache.shared.value(for: service) {
            if let account {
                do { return try readFromKeychain(service: service, account: account) } catch KeychainError.notFound {}
            }
            return try readFromKeychain(service: service, account: nil)
        }
    }

    private static func readFromKeychain(service: String, account: String?) throws -> String {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(service: service, account: account, returnData: true), &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else {
                throw KeychainError.unreadable(service, status)
            }
            return value
        case errSecItemNotFound:
            throw KeychainError.notFound(service)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied(service)
        default:
            throw KeychainError.unreadable(service, status)
        }
    }

    public enum Presence: Equatable, Sendable {
        case present
        case missing
        /// The item is there but this process may not be able to read it - a locked
        /// keychain, or a grant that a rebuild revoked.
        case blocked
        case unknown(OSStatus)
    }

    /// Looks for the item without reading its secret.
    ///
    /// Asking only for attributes does not touch the item's access control, so this never
    /// shows a permission prompt, which is what makes it safe for `meter doctor`. The
    /// tradeoff is that a denied ACL still answers `present`; only a locked or
    /// non-interactive keychain is distinguishable here.
    public static func probe(service: String) -> Presence {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(service: service, account: nil, returnData: false), &item)
        switch status {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return .blocked
        default: return .unknown(status)
        }
    }

    private static func query(service: String, account: String?, returnData: Bool) -> CFDictionary {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        query[(returnData ? kSecReturnData : kSecReturnAttributes) as String] = true
        if returnData, !allowInteraction {
            // Fail instead of drawing a dialog the user did not ask for.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query as CFDictionary
    }
}
