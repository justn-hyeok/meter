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
    #expect(credential.sourceDescription == "Cursor app or keychain cursor-access-token")
}

@Test func surfacesKeychainFailuresThroughTheCredential() {
    let credential = CursorSessionCredential(readToken: { () throws -> String in
        throw KeychainError.notFound("cursor-access-token")
    })
    #expect(throws: KeychainError.notFound("cursor-access-token")) { try credential.authHeaders() }
}


@Test func cursorSkipsAnExpiredTokenForACurrentOne() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expired = try unsignedJWT(["sub": "user_old", "exp": 1_799_999_000])
    let current = try unsignedJWT(["sub": "user_new", "exp": 1_800_003_600])
    let credential = CursorSessionCredential(readTokens: [{ expired }, { current }], now: { now })
    #expect(try credential.authHeaders()["Cookie"]?.hasPrefix("WorkosCursorSessionToken=user_new") == true)
}

/// An expired session is a sign-in problem, said before any request is sent: the dashboard
/// answers one with a redirect that used to surface as "HTTP 307".
@Test func cursorWithOnlyExpiredTokensAsksForSignIn() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expired = try unsignedJWT(["sub": "user_old", "exp": 1_800_000_030])
    let credential = CursorSessionCredential(readTokens: [
        { throw KeychainError.notFound("Cursor app session") },
        { expired },
    ], now: { now })
    #expect(throws: CredentialError.signInRequired(CursorSessionCredential.signInHint)) {
        try credential.authHeaders()
    }
}

@Test func readsTheCursorAppSessionFromItsSettingsDatabase() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterCursor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appending(path: "state.vscdb")
    let token = try unsignedJWT(["sub": "user_app"])

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path,
        "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)');"]
    try process.run()
    process.waitUntilExit()

    #expect(try CursorAppSession.accessToken(databaseURL: database) == token)
    #expect(throws: KeychainError.notFound("Cursor app session")) {
        try CursorAppSession.accessToken(databaseURL: directory.appending(path: "missing.vscdb"))
    }
}
