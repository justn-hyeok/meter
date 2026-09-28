import CommonCrypto
import Foundation
import SQLite3

public enum CookieJarError: LocalizedError, Equatable {
    case browserNotInstalled(String)
    case databaseUnreadable(String)
    case undecryptable(String)
    case noCookies(String)

    public var errorDescription: String? {
        switch self {
        case .browserNotInstalled(let browser): "\(browser) is not installed"
        case .databaseUnreadable(let browser): "could not read \(browser)'s cookie store"
        case .undecryptable(let browser): "could not decrypt \(browser)'s cookies"
        case .noCookies(let host): "no browser has cookies for \(host)"
        }
    }
}

/// A Chromium profile whose cookie store Meter can read.
public struct ChromiumBrowser: Sendable, Equatable {
    public let name: String
    public let cookieDatabase: URL
    /// Keychain item holding the random password that protects the profile's cookies.
    public let safeStorageService: String

    public init(name: String, cookieDatabase: URL, safeStorageService: String) {
        self.name = name
        self.cookieDatabase = cookieDatabase
        self.safeStorageService = safeStorageService
    }

    private static func profile(_ relativePath: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(relativePath)/Cookies")
    }

    public static let aside = ChromiumBrowser(
        name: "Aside",
        cookieDatabase: profile("Aside/Default"),
        safeStorageService: "Aside Safe Storage"
    )
    public static let chrome = ChromiumBrowser(
        name: "Chrome",
        cookieDatabase: profile("Google/Chrome/Default"),
        safeStorageService: "Chrome Safe Storage"
    )
    public static let dia = ChromiumBrowser(
        name: "Dia",
        cookieDatabase: profile("Dia/Default"),
        safeStorageService: "Dia Safe Storage"
    )
    public static let brave = ChromiumBrowser(
        name: "Brave",
        cookieDatabase: profile("BraveSoftware/Brave-Browser/Default"),
        safeStorageService: "Brave Safe Storage"
    )
    public static let edge = ChromiumBrowser(
        name: "Edge",
        cookieDatabase: profile("Microsoft Edge/Default"),
        safeStorageService: "Microsoft Edge Safe Storage"
    )

    public static let supported: [ChromiumBrowser] = [.aside, .chrome, .dia, .brave, .edge]

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: cookieDatabase.path)
    }
}

/// Reads and decrypts cookies from a Chromium profile.
///
/// This replaces driving a browser for every refresh. Cookie names are stored in the
/// clear, so an inventory costs nothing; only reading values needs the Safe Storage key,
/// which means one keychain prompt rather than a running browser.
public struct ChromiumCookieJar: Sendable {
    public let browser: ChromiumBrowser

    public init(browser: ChromiumBrowser) {
        self.browser = browser
    }

    /// First installed browser that holds a plausible session for `host`.
    public static func first(
        hosting host: String,
        in browsers: [ChromiumBrowser] = ChromiumBrowser.supported
    ) -> ChromiumCookieJar? {
        let jars = browsers.filter(\.isInstalled).map(ChromiumCookieJar.init)
        return jars.first { ($0.cookieNames(host: host)?.contains(where: isSessionLike)) == true }
            ?? jars.first { ($0.cookieNames(host: host)?.isEmpty == false) }
    }

    /// Cookie names for `host`, read without decrypting anything.
    ///
    /// Returns nil when the store cannot be opened at all.
    public func cookieNames(host: String) -> [String]? {
        try? read(host: host).map(\.name)
    }

    public func cookies(host: String) throws -> [(name: String, value: String)] {
        let rows = try read(host: host)
        guard !rows.isEmpty else { throw CookieJarError.noCookies(host) }
        let key = try decryptionKey()
        let cookies = rows.compactMap { row -> (name: String, value: String)? in
            guard let value = try? Self.decrypt(row.encryptedValue, key: key) else { return nil }
            return (row.name, value)
        }
        guard !cookies.isEmpty else { throw CookieJarError.undecryptable(browser.name) }
        return cookies
    }

    public func cookieHeader(host: String) throws -> String {
        try cookies(host: host).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Cookie names that only ever carry analytics, used to tell "logged in" from
    /// "merely visited" in diagnostics. Never used to decide whether a request is sent.
    private static let analyticsPrefixes = [
        "_ga", "_gid", "_gcl", "_fbp", "_fbc", "_rdt", "_tw", "_scid", "_uetsid", "_uetvid",
        "_hj", "_ca_", "__stripe", "ajs_", "amp_", "mp_", "intercom-", "optimizely",
        "cf_", "FPGCLAW", "_clck", "_clsk", "_pk_",
    ]

    static func isSessionLike(_ name: String) -> Bool {
        !analyticsPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: - Storage

    private struct Row {
        let name: String
        let encryptedValue: Data
    }

    private func read(host: String) throws -> [Row] {
        guard browser.isInstalled else { throw CookieJarError.browserNotInstalled(browser.name) }

        var database: OpaquePointer?
        // immutable=1 reads the file even while the browser holds its own lock.
        let uri = "file:\(browser.cookieDatabase.path)?immutable=1"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw CookieJarError.databaseUnreadable(browser.name)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let sql = "SELECT name, encrypted_value FROM cookies WHERE host_key = ?1 OR host_key = '.' || ?1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CookieJarError.databaseUnreadable(browser.name)
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, host, -1, transient)

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 1))
            guard length > 0, let blob = sqlite3_column_blob(statement, 1) else { continue }
            rows.append(Row(name: String(cString: name), encryptedValue: Data(bytes: blob, count: length)))
        }
        return rows
    }

    // MARK: - Crypto

    private func decryptionKey() throws -> Data {
        let password = try Keychain.genericPassword(service: browser.safeStorageService)
        return try Self.derivedKey(password: password)
    }

    /// Chromium on macOS derives its cookie key with these fixed parameters.
    static func derivedKey(password: String, rounds: UInt32 = 1003, length: Int = 16) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: length)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            rounds,
            &derived, length
        )
        guard status == kCCSuccess else { throw CookieJarError.undecryptable("key derivation") }
        return Data(derived)
    }

    static func decrypt(_ encrypted: Data, key: Data) throws -> String {
        guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8) else {
            throw CookieJarError.undecryptable("unsupported cookie format")
        }
        let plaintext = try aes128CBCDecrypt(encrypted.dropFirst(3), key: key)
        guard let value = String(data: stripDomainHash(plaintext), encoding: .utf8) else {
            throw CookieJarError.undecryptable("cookie value is not UTF-8")
        }
        return value
    }

    /// The IV is sixteen spaces, fixed by Chromium.
    private static func aes128CBCDecrypt(_ ciphertext: Data, key: Data) throws -> Data {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            key.withUnsafeBytes { keyBytes in
                Data(ciphertext).withUnsafeBytes { inputBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        iv,
                        inputBytes.baseAddress, ciphertext.count,
                        outputBytes.baseAddress, outputBytes.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CookieJarError.undecryptable("AES-128-CBC") }
        return output.prefix(moved)
    }

    /// Chromium 100 and later prefix the plaintext with a 32-byte SHA-256 of the cookie's
    /// domain. Cookie values are printable ASCII, so a control byte in the first block
    /// means the hash is there.
    private static func stripDomainHash(_ plaintext: Data) -> Data {
        guard plaintext.count > 32 else { return plaintext }
        let head = plaintext.prefix(32)
        return head.contains(where: { $0 < 0x20 || $0 > 0x7E }) ? plaintext.dropFirst(32) : plaintext
    }
}
