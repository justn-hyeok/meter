import Foundation

public enum JWTError: LocalizedError, Equatable {
    case malformed
    case missingClaim(String)

    public var errorDescription: String? {
        switch self {
        case .malformed: "token is not a well-formed JWT"
        case .missingClaim(let name): "token is missing the '\(name)' claim"
        }
    }
}

/// Reads claims out of a JWT payload.
///
/// Meter never verifies signatures. The tokens come from the local keychain and are
/// replayed to the service that issued them, which does the verifying.
public enum JWT {
    public static func claims(_ token: String) throws -> [String: Any] {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let data = base64URLDecoded(String(segments[1])),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JWTError.malformed
        }
        return claims
    }

    public static func subject(_ token: String) throws -> String {
        guard let subject = try claims(token)["sub"] as? String, !subject.isEmpty else {
            throw JWTError.missingClaim("sub")
        }
        return subject
    }

    public static func expiry(_ token: String) -> Date? {
        guard let expiry = (try? claims(token))?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: expiry.doubleValue)
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder != 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }
}
