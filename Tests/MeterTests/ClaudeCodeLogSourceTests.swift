import Foundation
import Testing
@testable import MeterCore

private let sessionLog = "-Users-me-dev-alpha/11111111-1111-4111-8111-111111111111.jsonl"
private let subagentLog = "-Users-me-dev-alpha/11111111-1111-4111-8111-111111111111/subagents/agent-abc.jsonl"

private func temporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "meter-claude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Copies one fixture log to `destination`, creating the directories it needs.
private func copyFixtureLog(_ relativePath: String, to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: try TokenLogFixtures.claudeProjects.appending(path: relativePath), to: destination)
}

private func sortedByTimestamp(_ records: [TokenRecord]) -> [TokenRecord] {
    records.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
}

@Test func readsTheFixtureLogsIntoTheExpectedRecords() throws {
    let source = ClaudeCodeLogSource(projectsDirectories: [try TokenLogFixtures.claudeProjects])
    #expect(source.tool == .claudeCode)
    // The repeated content block, the `<synthetic>` message and the malformed line are gone,
    // and the subagent log beneath the session file was read.
    #expect(sortedByTimestamp(try source.records(since: nil)) == TokenLogFixtures.claudeRecords)
}

@Test func everyRecordFollowsTheTokenCountsRules() throws {
    let source = ClaudeCodeLogSource(projectsDirectories: [try TokenLogFixtures.claudeProjects])
    let records = try source.records(since: nil)

    for record in records {
        #expect(record.tokens.reasoning <= record.tokens.output, "reasoning is part of output: \(record.id)")
        #expect(record.tokens.total == record.tokens.input + record.tokens.cacheRead + record.tokens.cacheWrite + record.tokens.output)
        #expect(record.tool == .claudeCode)
        #expect(record.provider == "anthropic")
        #expect(record.costUSD == nil)
    }
    // Claude Code already counts thinking inside `output`, so it is reported, not added.
    let first = try #require(records.first { $0.id == "msg_A1:req_A1" })
    #expect(first.tokens == TokenCounts(input: 10, output: 50, cacheRead: 2000, cacheWrite: 1000, reasoning: 20))
}

@Test func sinceDropsEarlierRecords() throws {
    let source = ClaudeCodeLogSource(projectsDirectories: [try TokenLogFixtures.claudeProjects])
    let since = TokenLogFixtures.date("2026-10-20T11:00:00.000Z")
    #expect(try source.records(since: since).map(\.id).sorted() == ["msg_A2:req_A2", "msg_S1:req_S1"])
}

@Test func aFileUntouchedSinceTheWindowIsSkippedWithoutBeingRead() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The copy holds two responses inside the window. Only its modification date, older than
    // the window, keeps them out, so an empty result proves the file was never parsed.
    let file = directory.appending(path: "session.jsonl")
    try copyFixtureLog(sessionLog, to: file)
    try FileManager.default.setAttributes(
        [.modificationDate: TokenLogFixtures.date("2020-01-01T00:00:00.000Z")],
        ofItemAtPath: file.path
    )

    let source = ClaudeCodeLogSource(projectsDirectories: [directory])
    #expect(try source.records(since: TokenLogFixtures.date("2026-10-19T00:00:00.000Z")).isEmpty)
    // Without a window every file is read, so the same copy is not empty.
    #expect(try source.records(since: nil).map(\.id) == ["msg_A1:req_A1", "msg_A2:req_A2"])
}

@Test func aMissingProjectsDirectoryYieldsNoRecords() throws {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "meter-claude-missing-\(UUID().uuidString)")
    let source = ClaudeCodeLogSource(projectsDirectories: [missing])
    #expect(try source.records(since: nil).isEmpty)
}

@Test func claudeConfigDirNamesEveryConfigDirectoryToRead() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "one")
    let second = root.appending(path: "two")
    try copyFixtureLog(sessionLog, to: first.appending(path: "projects").appending(path: sessionLog))
    try copyFixtureLog(subagentLog, to: second.appending(path: "projects").appending(path: subagentLog))

    // The two installs together hold the logs, and the third entry does not exist.
    let environment = ["CLAUDE_CONFIG_DIR": "\(first.path), \(second.path), \(root.appending(path: "missing").path)"]
    let source = ClaudeCodeLogSource(environment: environment, homeDirectory: root.appending(path: "home"))
    #expect(sortedByTimestamp(try source.records(since: nil)) == TokenLogFixtures.claudeRecords)
}

@Test func claudeConfigDirThatNamesNoExistingDirectoryDoesNotFallBack() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home")
    try copyFixtureLog(sessionLog, to: home.appending(path: ".claude/projects").appending(path: sessionLog))

    // The home location holds logs, but a set variable is the whole answer: what it names is
    // missing, so there is nothing to read.
    let source = ClaudeCodeLogSource(
        environment: ["CLAUDE_CONFIG_DIR": root.appending(path: "missing").path],
        homeDirectory: home
    )
    #expect(try source.records(since: nil).isEmpty)
}

@Test func theDefaultDirectoriesAreTheTwoHomeLocations() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try copyFixtureLog(sessionLog, to: root.appending(path: ".claude/projects").appending(path: sessionLog))
    try copyFixtureLog(subagentLog, to: root.appending(path: ".config/claude/projects").appending(path: subagentLog))

    let source = ClaudeCodeLogSource(environment: [:], homeDirectory: root)
    #expect(sortedByTimestamp(try source.records(since: nil)) == TokenLogFixtures.claudeRecords)
}
