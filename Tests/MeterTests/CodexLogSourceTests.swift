import Foundation
import Testing
@testable import MeterCore

@Test func codexSourceReadsTheFixtureSessionsIntoTheExpectedRecords() throws {
    let records = try CodexLogSource(sessionsDirectory: try TokenLogFixtures.codexSessions).records(since: nil)
    let expected = TokenLogFixtures.codexRecords.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
    #expect(records.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) } == expected)
}

@Test func codexRecordsFollowTheTokenCountsRules() throws {
    let records = try CodexLogSource(sessionsDirectory: try TokenLogFixtures.codexSessions).records(since: nil)
    for record in records {
        #expect(record.tool == .codex)
        #expect(record.provider == record.provider.lowercased())
        #expect(record.costUSD == nil)
        #expect(record.tokens.reasoning <= record.tokens.output)
        #expect(record.tokens.input >= 0)
        #expect(record.tokens.total == record.tokens.input + record.tokens.cacheRead
            + record.tokens.cacheWrite + record.tokens.output)
    }

    // Codex puts cached input inside `input_tokens`; the source reports it separately.
    let first = try #require(records.first { $0.id == "resp_1" })
    #expect(first.tokens == TokenCounts(input: 600, output: 50, cacheRead: 400, reasoning: 10))
}

@Test func codexCountsTokenCountEventsOnlyWhenTheFileHasNoRecordLines() throws {
    let records = try CodexLogSource(sessionsDirectory: try TokenLogFixtures.codexSessions).records(since: nil)
    // Two records and two duplicate token_count events in the first file, two events in
    // the second. The duplicate events must not add more.
    #expect(records.count == 4)
    #expect(records.map(\.id).sorted() == [
        "0bbbbbbb-0000-7000-8000-00000000000b:2026-10-20T13:00:09.000Z",
        "0bbbbbbb-0000-7000-8000-00000000000b:2026-10-20T13:01:09.000Z",
        "resp_1",
        "resp_2",
    ])
    #expect(!records.contains { $0.id.contains("12:00:10.001Z") })
}

@Test func codexIgnoresCompressedArchiveLogs() throws {
    // The `.zst` archive lives in `archived_sessions`, beside `sessions`; reading the
    // directory above it must still find only the two JSONL files.
    let root = try TokenLogFixtures.codexSessions.deletingLastPathComponent()
    #expect(try CodexLogSource(sessionsDirectory: root).records(since: nil).count
        == TokenLogFixtures.codexRecords.count)

    // A readable log under any other extension is still not a session file.
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "meter-codex-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let session = try TokenLogFixtures.codexSessions.appending(
        path: "2026/10/20/rollout-2026-10-20T12-00-00-0aaaaaaa-0000-7000-8000-00000000000a.jsonl"
    )
    try FileManager.default.copyItem(at: session, to: directory.appending(path: "archived.jsonl.zst"))
    try FileManager.default.copyItem(at: session, to: directory.appending(path: "renamed.txt"))
    #expect(try CodexLogSource(sessionsDirectory: directory).records(since: nil).isEmpty)

    try FileManager.default.copyItem(at: session, to: directory.appending(path: "kept.jsonl"))
    #expect(try CodexLogSource(sessionsDirectory: directory).records(since: nil).count == 2)
}

@Test func codexSinceKeepsOnlyRecordsInsideTheWindow() throws {
    let since = TokenLogFixtures.date("2026-10-20T12:05:09.000Z")
    let records = try CodexLogSource(sessionsDirectory: try TokenLogFixtures.codexSessions).records(since: since)
    #expect(records.allSatisfy { $0.timestamp >= since })
    #expect(records.map(\.id).sorted() == [
        "0bbbbbbb-0000-7000-8000-00000000000b:2026-10-20T13:00:09.000Z",
        "0bbbbbbb-0000-7000-8000-00000000000b:2026-10-20T13:01:09.000Z",
        "resp_2",
    ])
}

@Test func codexSkipsFilesLastModifiedBeforeTheWindow() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "meter-codex-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.copyItem(at: try TokenLogFixtures.codexSessions, to: directory)

    #expect(try CodexLogSource(sessionsDirectory: directory).records(since: nil).count == 4)

    let old = TokenLogFixtures.date("2026-10-01T00:00:00.000Z")
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
    for case let file as URL in files {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
    }

    // The records inside the files are newer than the window, but the files themselves
    // were last written before it, so there is nothing new to read.
    let since = TokenLogFixtures.date("2026-10-20T00:00:00.000Z")
    #expect(try CodexLogSource(sessionsDirectory: directory).records(since: since).isEmpty)
}

@Test func codexReturnsNothingWhenTheSessionsDirectoryIsMissing() throws {
    let missing = FileManager.default.temporaryDirectory
        .appending(path: "meter-codex-missing-\(UUID().uuidString)")
    #expect(try CodexLogSource(sessionsDirectory: missing).records(since: nil).isEmpty)
}

@Test func codexHomeChoosesTheSessionsDirectory() {
    let home = URL(filePath: "/Users/example")
    #expect(CodexLogSource.sessionsDirectory(
        environment: ["CODEX_HOME": "/tmp/codex-home"], home: home
    ).path == "/tmp/codex-home/sessions")
    #expect(CodexLogSource.sessionsDirectory(environment: [:], home: home).path
        == "/Users/example/.codex/sessions")
    #expect(CodexLogSource.sessionsDirectory(environment: ["CODEX_HOME": ""], home: home).path
        == "/Users/example/.codex/sessions")
    #expect(CodexLogSource.default.tool == .codex)
}
