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
public enum Keychain {
    public static func genericPassword(service: String) throws -> String {
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

    /// Whether the item exists, without reading its secret.
    ///
    /// Asking only for attributes does not touch the item's access control, so this
    /// never shows a permission prompt. `meter doctor` relies on that.
    public static func exists(service: String) -> Bool {
        var item: CFTypeRef?
        return SecItemCopyMatching(query(service: service, returnData: false), &item) == errSecSuccess
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
