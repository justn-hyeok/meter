import CommonCrypto
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

/// Mirrors Chromium's cookie encryption so the jar can be tested without a browser.
private func chromiumEncrypted(_ plaintext: Data, key: Data) -> Data {
    let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    var output = Data(count: plaintext.count + kCCBlockSizeAES128)
    var moved = 0
    _ = output.withUnsafeMutableBytes { outputBytes in
        key.withUnsafeBytes { keyBytes in
            plaintext.withUnsafeBytes { inputBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, key.count,
                    iv,
                    inputBytes.baseAddress, plaintext.count,
                    outputBytes.baseAddress, outputBytes.count,
                    &moved
                )
            }
        }
    }
    return Data("v10".utf8) + output.prefix(moved)
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

@Test func derivesTheChromiumCookieKeyWithFixedParameters() throws {
    let key = try ChromiumCookieJar.derivedKey(password: "safe-storage-password")
    #expect(key.count == 16)
    // Same password must always give the same key, or cached grants would break.
    #expect(key == (try ChromiumCookieJar.derivedKey(password: "safe-storage-password")))
    #expect(key != (try ChromiumCookieJar.derivedKey(password: "other-password")))
}

@Test func decryptsChromiumCookieValues() throws {
    let key = try ChromiumCookieJar.derivedKey(password: "safe-storage-password")
    let encrypted = chromiumEncrypted(Data("user_01ABC::token.value".utf8), key: key)
    #expect(try ChromiumCookieJar.decrypt(encrypted, key: key) == "user_01ABC::token.value")
}

@Test func stripsTheDomainHashNewerChromiumPrepends() throws {
    let key = try ChromiumCookieJar.derivedKey(password: "safe-storage-password")
    var plaintext = Data(repeating: 0x00, count: 32) // stands in for SHA-256 of the domain
    plaintext.append(Data("session-value".utf8))
    let encrypted = chromiumEncrypted(plaintext, key: key)
    #expect(try ChromiumCookieJar.decrypt(encrypted, key: key) == "session-value")
}

@Test func rejectsCookieFormatsItCannotDecrypt() throws {
    let key = try ChromiumCookieJar.derivedKey(password: "safe-storage-password")
    #expect(throws: CookieJarError.undecryptable("unsupported cookie format")) {
        try ChromiumCookieJar.decrypt(Data("v20ciphertext".utf8), key: key)
    }
}

@Test func tellsSessionCookiesApartFromAnalyticsCookies() {
    #expect(ChromiumCookieJar.isSessionLike("WorkosCursorSessionToken"))
    #expect(ChromiumCookieJar.isSessionLike("sessionKey"))
    #expect(ChromiumCookieJar.isSessionLike("__Host-console_session"))
    // The names actually found for commandcode.ai, none of which prove a login.
    for analytics in ["_ga", "_ga_K247DYR4NS", "_fbp", "_rdt_uuid", "_twpid", "_twsid", "__stripe_mid"] {
        #expect(!ChromiumCookieJar.isSessionLike(analytics))
    }
}

@Test func reportsACredentialStatusForEveryProvider() {
    let statuses = CredentialDoctor.diagnose()
    #expect(statuses.map(\.provider) == ProviderID.allCases)
    #expect(statuses.allSatisfy { !$0.source.isEmpty && !$0.detail.isEmpty })
}
