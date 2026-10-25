import Foundation

/// Codex's rollout logs: one JSONL file per session, nested by date under
/// `~/.codex/sessions`.
///
/// Codex compresses finished sessions to `.jsonl.zst` - in place under `sessions`, and in
/// `~/.codex/archived_sessions` for archived ones - and on a busy Mac that is nearly all of
/// its history. They are read through the `zstd` tool when it is installed (macOS does not
/// ship it); without it only the uncompressed, recent sessions count.
public struct CodexLogSource: TokenLogSource {
    public let tool = UsageTool.codex
    /// The `sessions` directory this source reads.
    public let sessionsDirectory: URL
    /// Where archived sessions are, or nil to leave them out.
    public let archivedDirectory: URL?
    let zstd: URL?
    /// Where what was read from each compressed session is kept. A compressed session is
    /// finished and never changes, and opening hundreds of them is most of a month's read.
    let cacheDirectory: URL?

    public init(sessionsDirectory: URL, archivedDirectory: URL? = nil, zstd: URL? = CodexLogSource.installedZstd,
                cacheDirectory: URL? = nil) {
        self.sessionsDirectory = sessionsDirectory
        self.archivedDirectory = archivedDirectory
        self.zstd = zstd
        self.cacheDirectory = cacheDirectory
    }

    public static var `default`: CodexLogSource {
        let sessions = sessionsDirectory(environment: ProcessInfo.processInfo.environment)
        return CodexLogSource(
            sessionsDirectory: sessions,
            archivedDirectory: sessions.deletingLastPathComponent().appending(path: "archived_sessions"),
            cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(path: "com.justn.meter/codex-sessions")
        )
    }

    /// Homebrew's two prefixes and MacPorts'. macOS does not ship `zstd`.
    public static let installedZstd: URL? = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/opt/local/bin/zstd"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }

    /// `$CODEX_HOME/sessions` when Codex was told to keep its state elsewhere.
    static func sessionsDirectory(
        environment: [String: String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(filePath: codexHome).appending(path: "sessions")
        }
        return home.appending(path: ".codex/sessions")
    }

    /// A tool that is not installed has no `sessions` directory, which is not a failure.
    public func records(since: Date?) throws -> [TokenRecord] {
        var records: [TokenRecord] = []
        var compressed: [URL] = []
        for directory in [sessionsDirectory] + [archivedDirectory].compactMap({ $0 }) {
            for file in files(in: directory, since: since) {
                if file.pathExtension == "jsonl" {
                    // One unreadable session must not hide the rest.
                    guard let data = try? Data(contentsOf: file) else { continue }
                    records += read(data, file: file, since: since)
                } else if file.pathExtension == "zst", file.deletingPathExtension().pathExtension == "jsonl" {
                    compressed.append(file)
                }
            }
        }
        records += readCompressed(compressed).filter { record in since.map { record.timestamp >= $0 } ?? true }
        return records
    }

    /// Every record in each compressed session, from the cache where it is current and
    /// otherwise through `zstd`, several at a time.
    private func readCompressed(_ files: [URL]) -> [TokenRecord] {
        guard zstd != nil, !files.isEmpty else { return [] }
        let results = LockedArray<[TokenRecord]>(count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let file = files[index]
            let stamp = Self.stamp(file)
            if let cached = cachedRecords(file, stamp: stamp) {
                results.set(index, cached)
            } else if let data = decompress(file) {
                let found = read(data, file: file.deletingPathExtension(), since: nil)
                results.set(index, found)
                cache(found, for: file, stamp: stamp)
            }
        }
        return results.values.flatMap { $0 }
    }

    private struct CachedSession: Codable {
        let stamp: String
        let records: [TokenRecord]
    }

    /// Size and modification time: a file rewritten in place gets a new one.
    private static func stamp(_ file: URL) -> String {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? -1)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)"
    }

    private func cacheFile(for file: URL) -> URL? {
        cacheDirectory?.appending(path: file.lastPathComponent + ".json")
    }

    private func cachedRecords(_ file: URL, stamp: String) -> [TokenRecord]? {
        guard let url = cacheFile(for: file), let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedSession.self, from: data),
              cached.stamp == stamp else { return nil }
        return cached.records
    }

    private func cache(_ records: [TokenRecord], for file: URL, stamp: String) {
        guard let url = cacheFile(for: file),
              let data = try? JSONEncoder().encode(CachedSession(stamp: stamp, records: records)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func files(in directory: URL, since: Date?) -> [URL] {
        // The enumerator does not descend into a directory reached through a symbolic link.
        let directory = directory.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let files = FileManager.default.enumerator(
                  at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
              ) else { return [] }
        return files.compactMap { $0 as? URL }.filter { file in
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { return false }
            // A file last written before the window holds nothing inside it.
            if let since, let modified = values?.contentModificationDate, modified < since { return false }
            return true
        }
    }

    private func decompress(_ file: URL) -> Data? {
        guard let zstd else { return nil }
        let process = Process()
        process.executableURL = zstd
        process.arguments = ["-dcq", file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// Session files get large and mostly hold conversation. Only lines with one of the
    /// keys this source reads are decoded.
    private static let markers = [
        Data("token_usage_record".utf8),
        Data("token_count".utf8),
        Data("turn_context".utf8),
        Data("session_meta".utf8),
    ]

    private func read(_ data: Data, file: URL, since: Date?) -> [TokenRecord] {
        let decoder = JSONDecoder()
        let timestamps = Timestamps()
        var context = SessionContext()
        var found: [TokenRecord] = []
        // Newer Codex writes each response twice: a token_usage_record, then a token_count
        // event for the same response. A count event is a copy while a record before it is
        // still unmatched, and a response of its own otherwise - which is how a session
        // begun by an older Codex and resumed by a newer one keeps its early turns.
        var unmatchedRecords = 0
        // A count event whose running total did not move reports no new response.
        var lastTotal: Int?

        for line in data.split(separator: UInt8(ascii: "\n"))
        where Self.markers.contains(where: { line.range(of: $0) != nil }) {
            guard let entry = try? decoder.decode(LogEntry.self, from: line) else { continue }
            switch entry.type {
            case "session_meta":
                context.read(entry.payload)
            case "turn_context":
                context.model = entry.payload?.model ?? context.model
            case "token_usage_record":
                // A record that cannot be read leaves its count event to stand in for it.
                guard let payload = entry.payload, let usage = payload.usage,
                      let timestamp = timestamps.date(entry.timestamp) else { continue }
                unmatchedRecords += 1
                found.append(record(
                    id: payload.responseID ?? "\(context.id(fallback: file)):\(entry.timestamp)",
                    timestamp: timestamp, context: context, usage: usage
                ))
            case "event_msg":
                guard entry.payload?.type == "token_count" else { continue }
                let total = entry.payload?.info?.totalTokenUsage?.totalTokens
                let repeated = total != nil && total == lastTotal
                if let total { lastTotal = total }
                if unmatchedRecords > 0 {
                    unmatchedRecords -= 1
                    continue
                }
                guard !repeated,
                      let usage = entry.payload?.info?.lastTokenUsage,
                      let timestamp = timestamps.date(entry.timestamp) else { continue }
                found.append(record(
                    // A token_count event carries no response id, so the line's own
                    // timestamp stands in; it is stable because Codex appends.
                    id: "\(context.id(fallback: file)):\(entry.timestamp)",
                    timestamp: timestamp, context: context, usage: usage
                ))
            default:
                continue
            }
        }

        guard let since else { return found }
        return found.filter { $0.timestamp >= since }
    }

    private func record(
        id: String, timestamp: Date, context: SessionContext, usage: Usage
    ) -> TokenRecord {
        TokenRecord(
            id: id,
            tool: .codex,
            provider: context.provider,
            model: context.model,
            timestamp: timestamp,
            sessionID: context.sessionID,
            project: context.project,
            tokens: usage.counts
        )
    }
}

/// What the lines before a response said about it.
private struct SessionContext {
    var sessionID: String?
    var project: String?
    var provider = "openai"
    var model = "unknown"

    mutating func read(_ payload: LogEntry.Payload?) {
        guard let payload else { return }
        sessionID = payload.id ?? sessionID
        project = payload.cwd ?? project
        if let provider = payload.modelProvider, !provider.isEmpty {
            self.provider = provider.lowercased()
        }
    }

    /// Older logs sometimes lack a session id; the file name is still stable across reads.
    func id(fallback file: URL) -> String {
        sessionID ?? file.deletingPathExtension().lastPathComponent
    }
}

/// Codex timestamps are ISO 8601 with fractional seconds; a plain form is the fallback.
private struct Timestamps {
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func date(_ value: String) -> Date? {
        fractional.date(from: value) ?? plain.date(from: value)
    }
}

private struct LogEntry: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload?

    struct Payload: Decodable {
        let id: String?
        let cwd: String?
        let model: String?
        let type: String?
        let modelProvider: String?
        let responseID: String?
        let usage: Usage?
        let info: Info?

        enum CodingKeys: String, CodingKey {
            case id, cwd, model, type, usage, info
            case modelProvider = "model_provider"
            case responseID = "response_id"
        }
    }
}

private struct Info: Decodable {
    let lastTokenUsage: Usage?
    let totalTokenUsage: Usage?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
        case totalTokenUsage = "total_token_usage"
    }
}

private struct Usage: Decodable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }

    /// Codex counts cached input inside `input_tokens`, and `output_tokens` already
    /// includes reasoning.
    var counts: TokenCounts {
        let cached = cachedInputTokens ?? 0
        return TokenCounts(
            input: max((inputTokens ?? 0) - cached, 0),
            output: outputTokens ?? 0,
            cacheRead: cached,
            cacheWrite: cacheWriteInputTokens ?? 0,
            reasoning: reasoningOutputTokens ?? 0
        )
    }
}

/// Results written by index from several threads at once.
private final class LockedArray<Element>: @unchecked Sendable {
    private var storage: [Element?]
    private let lock = NSLock()

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: Element) { lock.withLock { storage[index] = value } }

    var values: [Element] { lock.withLock { storage.compactMap { $0 } } }
}
