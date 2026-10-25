import CommonCrypto
import Foundation
import SQLite3

/// A Chromium-based browser: where it keeps its profiles, and the keychain item holding the
/// key its cookies are encrypted with.
public struct ChromiumBrowser: Sendable, Equatable {
    public let name: String
    /// Under `~/Library/Application Support`.
    public let dataDirectory: String
    public let safeStorageService: String
    public let safeStorageAccount: String

    public static let known: [ChromiumBrowser] = [
        .init(name: "Chrome", dataDirectory: "Google/Chrome", safeStorageService: "Chrome Safe Storage", safeStorageAccount: "Chrome"),
        .init(name: "Aside", dataDirectory: "Aside", safeStorageService: "Aside Safe Storage", safeStorageAccount: "Aside"),
        .init(name: "Dia", dataDirectory: "Dia/User Data", safeStorageService: "Dia Safe Storage", safeStorageAccount: "Dia"),
        .init(name: "Arc", dataDirectory: "Arc/User Data", safeStorageService: "Arc Safe Storage", safeStorageAccount: "Arc"),
        .init(name: "Brave", dataDirectory: "BraveSoftware/Brave-Browser", safeStorageService: "Brave Safe Storage", safeStorageAccount: "Brave"),
        .init(name: "Edge", dataDirectory: "Microsoft Edge", safeStorageService: "Microsoft Edge Safe Storage", safeStorageAccount: "Microsoft Edge"),
        .init(name: "Chromium", dataDirectory: "Chromium", safeStorageService: "Chromium Safe Storage", safeStorageAccount: "Chromium"),
    ]
}

/// Reads one cookie out of the browsers on this Mac, so a site's session can be reused
/// without anyone copying it out of developer tools.
///
/// Every profile of every browser is searched by name and expiry alone - neither is secret -
/// and only the newest match is decrypted, so only that browser's keychain item is read.
public enum ChromiumCookies {
    public struct Found: Sendable, Equatable {
        public let value: String
        public let expires: Date?
        public let browser: String
    }

    public static func cookie(
        named name: String,
        host: String,
        browsers: [ChromiumBrowser] = ChromiumBrowser.known,
        applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support"),
        key: (ChromiumBrowser) throws -> String = { try Keychain.genericPassword(service: $0.safeStorageService, account: $0.safeStorageAccount) }
    ) throws -> Found? {
        guard let best = newest(named: name, host: host, browsers: browsers, applicationSupport: applicationSupport) else { return nil }
        if !best.row.plain.isEmpty {
            return Found(value: best.row.plain, expires: best.row.expires, browser: best.browser.name)
        }
        let value = try decrypt(best.row.encrypted, password: key(best.browser), databaseVersion: best.row.databaseVersion)
        return Found(value: value, expires: best.row.expires, browser: best.browser.name)
    }

    /// The browser with an unexpired cookie of this name, found without decrypting it.
    public static func browser(
        holding name: String, host: String, browsers: [ChromiumBrowser] = ChromiumBrowser.known,
        applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    ) -> String? {
        newest(named: name, host: host, browsers: browsers, applicationSupport: applicationSupport)?.browser.name
    }

    private static func newest(
        named name: String, host: String, browsers: [ChromiumBrowser], applicationSupport: URL
    ) -> (row: Row, browser: ChromiumBrowser)? {
        var best: (row: Row, browser: ChromiumBrowser)?
        for browser in browsers {
            for database in cookieDatabases(of: browser, in: applicationSupport) {
                for row in rows(in: database, name: name, host: host) where row.expires.map({ $0 > .now }) ?? true {
                    if best == nil || (row.expires ?? .distantFuture) > (best!.row.expires ?? .distantFuture) {
                        best = (row, browser)
                    }
                }
            }
        }
        return best
    }

    struct Row {
        let plain: String
        let encrypted: Data
        let expires: Date?
        let databaseVersion: Int
    }

    static func cookieDatabases(of browser: ChromiumBrowser, in applicationSupport: URL) -> [URL] {
        let root = applicationSupport.appending(path: browser.dataDirectory)
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        return profiles.flatMap { profile in
            ["Cookies", "Network/Cookies"].map { root.appending(path: "\(profile)/\($0)") }
        }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func rows(in database: URL, name: String, host: String) -> [Row] {
        var connection: OpaquePointer?
        // Immutable: the browser holds the file open and may be writing it; Meter never does.
        let uri = "file:\(database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path)?immutable=1"
        guard sqlite3_open_v2(uri, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            return []
        }
        defer { sqlite3_close(connection) }

        var version = 0
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(connection, "SELECT value FROM meta WHERE key = 'version'", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            version = Int(String(cString: text)) ?? 0
        }
        sqlite3_finalize(statement)

        let sql = "SELECT value, encrypted_value, expires_utc FROM cookies WHERE name = ? AND host_key = ?"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, transient)
        sqlite3_bind_text(statement, 2, host, -1, transient)

        var found: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let plain = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let bytes = sqlite3_column_blob(statement, 1)
            let count = Int(sqlite3_column_bytes(statement, 1))
            let encrypted = bytes.map { Data(bytes: $0, count: count) } ?? Data()
            // Microseconds since 1601; zero is a session cookie.
            let raw = sqlite3_column_int64(statement, 2)
            let expires = raw == 0 ? nil : Date(timeIntervalSince1970: Double(raw) / 1_000_000 - 11_644_473_600)
            found.append(Row(plain: plain, encrypted: encrypted, expires: expires, databaseVersion: version))
        }
        return found
    }

    public enum DecryptionError: LocalizedError, Equatable {
        case unsupportedFormat
        case failed

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "the browser stores this cookie in a format Meter cannot read"
            case .failed: "the browser's cookie could not be decrypted"
            }
        }
    }

    /// Chromium on macOS: "v10", then AES-128-CBC under a key derived from the keychain
    /// password with PBKDF2 (salt "saltysalt", 1003 rounds) and an IV of sixteen spaces.
    /// From database version 24 the plaintext starts with a 32-byte hash of the host.
    static func decrypt(_ encrypted: Data, password: String, databaseVersion: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else { throw DecryptionError.unsupportedFormat }
        let ciphertext = encrypted.dropFirst(3)

        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derived = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count
        )
        guard derived == kCCSuccess else { throw DecryptionError.failed }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = ciphertext.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, input.baseAddress, ciphertext.count, &output, output.count, &written)
        }
        guard status == kCCSuccess else { throw DecryptionError.failed }
        var plain = Array(output.prefix(written))
        if databaseVersion >= 24, plain.count >= 32 { plain.removeFirst(32) }
        guard let value = String(bytes: plain, encoding: .utf8) else { throw DecryptionError.failed }
        return value
    }

    /// For tests: the inverse of `decrypt`.
    static func encrypt(_ value: String, password: String, databaseVersion: Int, hostHash: [UInt8] = Array(repeating: 7, count: 32)) -> Data {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        let plain = (databaseVersion >= 24 ? hostHash : []) + Array(value.utf8)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var written = 0
        _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, plain, plain.count, &output, output.count, &written)
        return Data("v10".utf8) + Data(output.prefix(written))
    }
}
