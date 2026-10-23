import CryptoKit
import Foundation
import Testing
@testable import MeterCore

@Test func openCodeSourceReadsEveryAssistantMessageFromTheWAL() throws {
    let database = try TokenLogFixtures.openCodeDatabase()
    let records = try OpenCodeLogSource(databaseURL: database).records(since: nil)
    #expect(records == TokenLogFixtures.openCodeRecords)
}

@Test func openCodeSourceNormalisesTokensTheSameWayAsTheContract() throws {
    let database = try TokenLogFixtures.openCodeDatabase()
    let records = try OpenCodeLogSource(databaseURL: database).records(since: nil)
    // OpenCode reports reasoning beside output, so output grows by it; the total is the
    // four normalised parts and still agrees with the total OpenCode wrote itself.
    #expect(records.map(\.tokens.total) == [650, 2300])
    for record in records {
        #expect(record.tokens.reasoning <= record.tokens.output)
        #expect(record.tokens.total == record.tokens.input + record.tokens.cacheRead + record.tokens.cacheWrite + record.tokens.output)
    }
    #expect(records.map(\.costUSD) == [0.0012, nil])
}

@Test func openCodeSourceFiltersByTimeCreated() throws {
    let database = try TokenLogFixtures.openCodeDatabase()
    let source = OpenCodeLogSource(databaseURL: database)
    let since = TokenLogFixtures.date("2026-10-21T08:30:00.000Z")
    #expect(try source.records(since: since).map(\.id) == ["msg_o2"])

    // The boundary is inclusive, as the protocol requires.
    let exact = TokenLogFixtures.date("2026-10-21T08:00:02.000Z")
    #expect(try source.records(since: exact).map(\.id) == ["msg_o1", "msg_o2"])
}

@Test func openCodeSourceWithoutADatabaseHasNoRecords() throws {
    let missing = FileManager.default.temporaryDirectory
        .appending(path: "meter-opencode-missing-\(UUID().uuidString)/opencode.db")
    #expect(try OpenCodeLogSource(databaseURL: missing).records(since: nil).isEmpty)
}

@Test func readingTheOpenCodeDatabaseChangesNothingOnDisk() throws {
    let database = try TokenLogFixtures.openCodeDatabase()
    let directory = database.deletingLastPathComponent()
    let hashBefore = SHA256.hash(data: try Data(contentsOf: database))
    let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path)

    _ = try OpenCodeLogSource(databaseURL: database).records(since: nil)

    #expect(SHA256.hash(data: try Data(contentsOf: database)) == hashBefore)
    // A checkpoint would move the WAL into the database file and change it; a read must not.
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == filesBefore.sorted())
}

@Test func openCodeDatabaseLocationFollowsXDGAndTheHomeFallback() {
    let home = URL(fileURLWithPath: "/Users/me")
    #expect(
        OpenCodeLogSource.defaultDatabaseURL(
            environment: ["XDG_DATA_HOME": "/tmp/xdg-data"], homeDirectory: home
        ) == URL(fileURLWithPath: "/tmp/xdg-data/opencode/opencode.db")
    )
    #expect(
        OpenCodeLogSource.defaultDatabaseURL(environment: [:], homeDirectory: home)
            == URL(fileURLWithPath: "/Users/me/.local/share/opencode/opencode.db")
    )
    // The XDG spec treats an empty variable as unset.
    #expect(
        OpenCodeLogSource.defaultDatabaseURL(environment: ["XDG_DATA_HOME": ""], homeDirectory: home)
            == URL(fileURLWithPath: "/Users/me/.local/share/opencode/opencode.db")
    )
}
