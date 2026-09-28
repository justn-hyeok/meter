import Foundation
import Testing
@testable import MeterCore

private func unsignedJWT(_ claims: [String: Any]) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: claims)
    let encoded = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

@Test func readsSubjectAndExpiryFromJWTPayload() throws {
    let token = try unsignedJWT(["sub": "user_01ABC", "exp": 1_800_000_000])
    #expect(try JWT.subject(token) == "user_01ABC")
    #expect(JWT.expiry(token) == Date(timeIntervalSince1970: 1_800_000_000))
}

@Test func rejectsMalformedTokensAndMissingClaims() throws {
    #expect(throws: JWTError.malformed) { try JWT.claims("not-a-jwt") }
    let withoutSubject = try unsignedJWT(["exp": 1_800_000_000])
    #expect(throws: JWTError.missingClaim("sub")) { try JWT.subject(withoutSubject) }
    #expect(JWT.expiry("not-a-jwt") == nil)
}

@Test func buildsCursorSessionCookieFromTheKeychainToken() throws {
    let token = try unsignedJWT(["sub": "user_01ABC"])
    let credential = CursorSessionCredential(readToken: { token })
    // Cursor expects "<user id>::<jwt>" with the separator already percent-encoded.
    #expect(try credential.authHeaders() == ["Cookie": "WorkosCursorSessionToken=user_01ABC%3A%3A\(token)"])
    #expect(credential.sourceDescription == "keychain cursor-access-token")
}

@Test func surfacesKeychainFailuresThroughTheCredential() {
    let credential = CursorSessionCredential(readToken: { () throws -> String in
        throw KeychainError.notFound("cursor-access-token")
    })
    #expect(throws: KeychainError.notFound("cursor-access-token")) { try credential.authHeaders() }
}

