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
    /// Drops the cached copy so the next read goes back to the keychain. Called when a
    /// service rejects the credential, which is how a rotated token is picked up.
    public static func forget(service: String) {
        SecretCache.shared.forget(service)
    }

    public static func genericPassword(service: String) throws -> String {
        try SecretCache.shared.value(for: service) { try readFromKeychain(service: service) }
    }

    private static func readFromKeychain(service: String) throws -> String {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(service: service, returnData: true), &item)
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
        let status = SecItemCopyMatching(query(service: service, returnData: false), &item)
        switch status {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return .blocked
        default: return .unknown(status)
        }
    }

    private static func query(service: String, returnData: Bool) -> CFDictionary {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[(returnData ? kSecReturnData : kSecReturnAttributes) as String] = true
        return query as CFDictionary
    }
}
