import Foundation
import SQLite3
import Testing
@testable import MeterCore

private func tempStore() -> (SecretStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterHive-\(UUID().uuidString)")
    return (SecretStore(fileURL: directory.appending(path: "credentials.json")), directory)
}

private func response(_ status: Int, setCookie: String? = nil) -> HTTPURLResponse {
    var headers: [String: String] = [:]
    if let setCookie { headers["Set-Cookie"] = setCookie }
    return HTTPURLResponse(url: URL(string: "https://portal-customer-api.thehive.ai/x")!, statusCode: status,
                           httpVersion: nil, headerFields: headers)!
}

/// Answers like the portal backend: only `good` or `renewed` is signed in, and each answer
/// hands back `renewed`, as a sliding session does.
private final class FakePortal: @unchecked Sendable {
    var cookiesSeen: [String] = []
    let lock = NSLock()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        lock.withLock { cookiesSeen.append(cookie) }
        guard cookie == "hive-portal-production=good" || cookie == "hive-portal-production=renewed" else {
            return (Data(#"{"status_code":401}"#.utf8), response(401))
        }
        let renew = "hive-portal-production=renewed; Path=/; HttpOnly; Secure"
        if request.url!.path.hasSuffix("/balance") {
            return (Data(#"{"billing_info": {"balance": "12.5"}}"#.utf8), response(200, setCookie: renew))
        }
        return (Data(#"{"data": {"user": {"default_organization_id": 42}}}"#.utf8), response(200, setCookie: renew))
    }
}

@Test func hiveReadsTheBalanceAndKeepsTheRenewedSession() async throws {
    let (store, directory) = tempStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let portal = FakePortal()
    let provider = HiveUsageProvider(store: store, browserCookie: { "good" }, send: portal.send)

    let snapshot = await provider.fetch()
    #expect(snapshot.state == .live)
    #expect(snapshot.buckets.first?.remaining == 12.5)
    #expect(snapshot.buckets.first?.unit == .usd)
    // The renewed cookie is what is kept, and what the second request already used.
    #expect(store.secret(for: .hive) == "renewed")
    #expect(portal.cookiesSeen == ["hive-portal-production=good", "hive-portal-production=renewed"])
}

@Test func hiveFallsBackToTheBrowserWhenTheKeptSessionIsRefused() async throws {
    let (store, directory) = tempStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try store.setSecret("expired", for: .hive)
    let provider = HiveUsageProvider(store: store, browserCookie: { "good" }, send: FakePortal().send)

    let snapshot = await provider.fetch()
    #expect(snapshot.state == .live)
    #expect(store.secret(for: .hive) == "renewed")
}

/// Someone who had a session and lost it is told to sign in again, and alerted.
@Test func hiveWithAnEndedSessionAsksForSignIn() async throws {
    let (store, directory) = tempStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try store.setSecret("expired", for: .hive)
    let provider = HiveUsageProvider(store: store, browserCookie: { "also-expired" }, send: FakePortal().send)
    let snapshot = await provider.fetch()
    #expect(snapshot.issue == .signInRequired)
    #expect(snapshot.message == HiveUsageProvider.sessionEnded)
}

/// Someone adding Hive for the first time is told how to connect it, and not alerted.
@Test func hiveNeverConnectedSaysHowToConnect() async throws {
    let (store, directory) = tempStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = await HiveUsageProvider(store: store, browserCookie: { nil }, send: FakePortal().send).fetch()
    #expect(snapshot.issue == .notConnected)
    #expect(snapshot.message == HiveUsageProvider.notConnected)
    #expect(UsageAlerts.evaluate([snapshot], sent: []).alerts.isEmpty)
}

/// The browser has a session but macOS has not let Meter read its cookies yet.
@Test func hiveSaysWhichKeychainItemToAllow() async throws {
    let (store, directory) = tempStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let locked = HiveUsageProvider(store: store, browserCookie: {
        throw ChromiumCookies.KeyUnavailable(browser: "Arc", service: "Arc Safe Storage")
    }, send: FakePortal().send)
    let snapshot = await locked.fetch()
    #expect(snapshot.issue == nil)
    #expect(snapshot.message?.contains("Always Allow") == true)
    #expect(snapshot.message?.contains("\"Arc Safe Storage\"") == true)
}

@Test func hiveFindsTheOrganizationWhereverTheProfileNestsIt() {
    #expect(HiveUsageProvider.organizationID(in: ["data": ["default_organization_id": 7]]) == "7")
    #expect(HiveUsageProvider.organizationID(in: ["organizations": [["organization_id": "9"]]]) == "9")
    #expect(HiveUsageProvider.organizationID(in: ["name": "x"]) == nil)
}

/// A cookie database laid out like Chromium's, with one encrypted row.
@Test func readsAnEncryptedCookieFromAChromiumProfile() throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "MeterChromium-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let profile = support.appending(path: "Test/Profile 2")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

    var database: OpaquePointer?
    #expect(sqlite3_open(profile.appending(path: "Cookies").path, &database) == SQLITE_OK)
    sqlite3_exec(database, "CREATE TABLE meta (key TEXT, value TEXT); INSERT INTO meta VALUES ('version', '24');"
        + "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER);", nil, nil, nil)
    var statement: OpaquePointer?
    sqlite3_prepare_v2(database, "INSERT INTO cookies VALUES ('api.example.com', 'session', '', ?, ?)", -1, &statement, nil)
    let encrypted = ChromiumCookies.encrypt("s3cret", password: "pw", databaseVersion: 24)
    _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(encrypted.count), nil) }
    let expires = Date.now.addingTimeInterval(86_400)
    sqlite3_bind_int64(statement, 2, Int64((expires.timeIntervalSince1970 + 11_644_473_600) * 1_000_000))
    sqlite3_step(statement)
    sqlite3_finalize(statement)
    sqlite3_close(database)

    let browser = ChromiumBrowser(name: "Test", dataDirectory: "Test", safeStorageService: "Test Safe Storage", safeStorageAccount: "Test")
    let found = try ChromiumCookies.cookie(named: "session", host: "api.example.com", browsers: [browser],
                                           applicationSupport: support, key: { _ in "pw" })
    #expect(found?.value == "s3cret")
    #expect(found?.browser == "Test")
    #expect(ChromiumCookies.browser(holding: "session", host: "api.example.com", browsers: [browser], applicationSupport: support) == "Test")
    #expect(try ChromiumCookies.cookie(named: "other", host: "api.example.com", browsers: [browser],
                                       applicationSupport: support, key: { _ in "pw" }) == nil)
}
