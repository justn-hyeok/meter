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

@Test func codexSkipsCompressedArchivesWithoutZstd() throws {
    // The `.zst` archive lives in `archived_sessions`, beside `sessions`; with no `zstd` to
    // open it, reading the directory above must still find only the two JSONL files.
    let root = try TokenLogFixtures.codexSessions.deletingLastPathComponent()
    #expect(try CodexLogSource(sessionsDirectory: root, zstd: nil).records(since: nil).count
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
    #expect(try CodexLogSource(sessionsDirectory: directory, zstd: nil).records(since: nil).isEmpty)

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

private func codexLine(_ timestamp: String, _ type: String, _ payload: String) -> String {
    #"{"timestamp": "\#(timestamp)", "type": "\#(type)", "payload": \#(payload)}"#
}

private func usage(_ input: Int, _ output: Int, total: Int) -> String {
    #"{"input_tokens": \#(input), "cached_input_tokens": 0, "cache_write_input_tokens": 0, "output_tokens": \#(output), "reasoning_output_tokens": 0, "total_tokens": \#(total)}"#
}

private func countEvent(_ timestamp: String, last: String, total: String) -> String {
    codexLine(timestamp, "event_msg", #"{"type": "token_count", "info": {"total_token_usage": \#(total), "last_token_usage": \#(last)}}"#)
}

private func writeSession(_ lines: [String]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "meter-codex-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let header = codexLine("2026-10-20T10:00:00.000Z", "session_meta", #"{"id": "s1", "model_provider": "openai"}"#)
    let context = codexLine("2026-10-20T10:00:01.000Z", "turn_context", #"{"model": "gpt-test"}"#)
    try ([header, context] + lines).joined(separator: "\n").write(to: directory.appending(path: "rollout.jsonl"), atomically: true, encoding: .utf8)
    return directory
}

/// A session begun by an older Codex (count events only) and resumed by a newer one (a
/// record, then its count event) keeps its early turns and counts the later ones once.
@Test func codexKeepsTheEarlyTurnsOfAResumedSession() throws {
    let directory = try writeSession([
        countEvent("2026-10-20T10:01:00.000Z", last: usage(100, 10, total: 110), total: usage(100, 10, total: 110)),
        codexLine("2026-10-20T10:02:00.000Z", "token_usage_record", #"{"response_id": "r2", "usage": \#(usage(200, 20, total: 220))}"#),
        countEvent("2026-10-20T10:02:00.500Z", last: usage(200, 20, total: 220), total: usage(300, 30, total: 330)),
    ])
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = try CodexLogSource(sessionsDirectory: directory, zstd: nil).records(since: nil)
    #expect(records.map(\.tokens.total).sorted() == [110, 220])
}

/// Codex can write the same count event again; the running total did not move, so it is
/// not another response.
@Test func codexCountsARepeatedCountEventOnce() throws {
    let first = usage(100, 10, total: 110)
    let directory = try writeSession([
        countEvent("2026-10-20T10:01:00.000Z", last: first, total: first),
        countEvent("2026-10-20T10:01:05.000Z", last: first, total: first),
    ])
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try CodexLogSource(sessionsDirectory: directory, zstd: nil).records(since: nil).count == 1)
}

@Test(.enabled(if: CodexLogSource.installedZstd != nil))
func codexReadsArchivedSessionsThroughZstd() throws {
    let directory = try writeSession([
        countEvent("2026-10-20T10:01:00.000Z", last: usage(100, 10, total: 110), total: usage(100, 10, total: 110)),
    ])
    defer { try? FileManager.default.removeItem(at: directory) }
    let archived = directory.appending(path: "archived_sessions")
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    let zstd = Process()
    zstd.executableURL = CodexLogSource.installedZstd
    zstd.arguments = ["-q", "--rm", directory.appending(path: "rollout.jsonl").path,
                      "-o", archived.appending(path: "rollout.jsonl.zst").path]
    try zstd.run()
    zstd.waitUntilExit()

    let empty = directory.appending(path: "sessions")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let records = try CodexLogSource(sessionsDirectory: empty, archivedDirectory: archived).records(since: nil)
    #expect(records.map(\.tokens.total) == [110])
}

/// A compressed session is finished, so what was read from it is kept and the next read
/// does not open it again - here with a `zstd` that can no longer open anything.
@Test(.enabled(if: CodexLogSource.installedZstd != nil))
func codexKeepsWhatItReadFromCompressedSessions() throws {
    let directory = try writeSession([
        countEvent("2026-10-20T10:01:00.000Z", last: usage(100, 10, total: 110), total: usage(100, 10, total: 110)),
    ])
    defer { try? FileManager.default.removeItem(at: directory) }
    let zstd = Process()
    zstd.executableURL = CodexLogSource.installedZstd
    zstd.arguments = ["-q", "--rm", directory.appending(path: "rollout.jsonl").path]
    try zstd.run()
    zstd.waitUntilExit()

    let cache = directory.appending(path: "cache")
    let first = try CodexLogSource(sessionsDirectory: directory, cacheDirectory: cache).records(since: nil)
    #expect(first.map(\.tokens.total) == [110])
    let again = try CodexLogSource(sessionsDirectory: directory, zstd: URL(fileURLWithPath: "/usr/bin/false"),
                                   cacheDirectory: cache).records(since: nil)
    #expect(again == first)
}
