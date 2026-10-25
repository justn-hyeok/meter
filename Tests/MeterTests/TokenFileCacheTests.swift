import Foundation
import Testing
@testable import MeterCore

/// A parser that turns each line into one record named after it, counting how many lines
/// it was handed, so a test can see what was read again.
private final class LineParser: @unchecked Sendable {
    var linesRead = 0

    func parse(_ data: Data) -> [TokenRecord] {
        let lines = data.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
        linesRead += lines.count
        return lines.map {
            TokenRecord(id: $0, tool: .claudeCode, provider: "anthropic", model: "m",
                        timestamp: Date(timeIntervalSince1970: 0), tokens: .zero)
        }
    }
}

private func scratch() throws -> (file: URL, cache: TokenFileCache, cleanup: () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterFileCache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory.appending(path: "session.jsonl"), TokenFileCache(directory: directory.appending(path: "cache")),
            { try? FileManager.default.removeItem(at: directory) })
}

private func append(_ text: String, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

@Test func aGrownLogIsReadFromWhereTheLastReadEnded() throws {
    let (file, cache, cleanup) = try scratch()
    defer { cleanup() }
    let parser = LineParser()
    try "a\nb\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(cache.records(in: file, parse: parser.parse).map(\.id) == ["a", "b"])

    // Unchanged: nothing is read.
    #expect(cache.records(in: file, parse: parser.parse).map(\.id) == ["a", "b"])
    #expect(parser.linesRead == 2)

    // Grown, with a line still being written: only the new whole line is read.
    try append("c\nd-unfinish", to: file)
    #expect(cache.records(in: file, parse: parser.parse).map(\.id) == ["a", "b", "c"])
    #expect(parser.linesRead == 3)

    try append("ed\n", to: file)
    #expect(cache.records(in: file, parse: parser.parse).map(\.id) == ["a", "b", "c", "d-unfinished"])
    #expect(parser.linesRead == 4)
}

@Test func aRewrittenLogIsReadAgainFromTheStart() throws {
    let (file, cache, cleanup) = try scratch()
    defer { cleanup() }
    let parser = LineParser()
    try "a\nb\n".write(to: file, atomically: true, encoding: .utf8)
    _ = cache.records(in: file, parse: parser.parse)

    // Shorter, and with different first bytes: both mean the file is not the one read.
    try "x\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(cache.records(in: file, parse: parser.parse).map(\.id) == ["x"])
    try "y\nz\nw\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(cache.records(in: file, parse: parser.parse).map(\.id) == ["y", "z", "w"])
}

@Test func theCachedClaudeCodeSourceMatchesAFreshRead() throws {
    let projects = try TokenLogFixtures.claudeProjects
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterClaudeCache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fresh = try ClaudeCodeLogSource(projectsDirectories: [projects]).records(since: nil)
    let cached = ClaudeCodeLogSource(projectsDirectories: [projects], cache: TokenFileCache(directory: directory))
    #expect(try cached.records(since: nil) == fresh)
    #expect(try cached.records(since: nil) == fresh)
}
