import Foundation

/// Codex's rollout logs: one JSONL file per session, nested by date under
/// `~/.codex/sessions`.
///
/// Codex archives old sessions as `.zst` files in `~/.codex/archived_sessions`. Those are
/// compressed and out of scope here, so this source never opens them; a `.jsonl.zst` file
/// is not a `.jsonl` file and is skipped.
public struct CodexLogSource: TokenLogSource {
    public let tool = UsageTool.codex
    /// The `sessions` directory this source reads.
    public let sessionsDirectory: URL

    public init(sessionsDirectory: URL) {
        self.sessionsDirectory = sessionsDirectory
    }

    public static var `default`: CodexLogSource {
        CodexLogSource(sessionsDirectory: sessionsDirectory(environment: ProcessInfo.processInfo.environment))
    }

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
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: sessionsDirectory.path, isDirectory: &isDirectory
        ), isDirectory.boolValue, let files = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else { return [] }

        var records: [TokenRecord] = []
        for case let file as URL in files where file.pathExtension == "jsonl" {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            // A file last written before the window holds nothing inside it.
            if let since, let modified = values?.contentModificationDate, modified < since { continue }
            records += read(file, since: since)
        }
        return records
    }

    /// Session files get large and mostly hold conversation. Only lines with one of the
    /// keys this source reads are decoded.
    private static let markers = [
        Data("token_usage_record".utf8),
        Data("token_count".utf8),
        Data("turn_context".utf8),
        Data("session_meta".utf8),
    ]

    private func read(_ file: URL, since: Date?) -> [TokenRecord] {
        // One unreadable session must not hide the rest.
        guard let data = try? Data(contentsOf: file) else { return [] }

        let decoder = JSONDecoder()
        let timestamps = Timestamps()
        var context = SessionContext()
        var current: [TokenRecord] = []
        var legacy: [TokenRecord] = []
        var hasTokenUsageRecords = false

        for line in data.split(separator: UInt8(ascii: "\n"))
        where Self.markers.contains(where: { line.range(of: $0) != nil }) {
            guard let entry = try? decoder.decode(LogEntry.self, from: line) else { continue }
            switch entry.type {
            case "session_meta":
                context.read(entry.payload)
            case "turn_context":
                context.model = entry.payload?.model ?? context.model
            case "token_usage_record":
                hasTokenUsageRecords = true
                guard let payload = entry.payload, let usage = payload.usage,
                      let timestamp = timestamps.date(entry.timestamp) else { continue }
                current.append(record(
                    id: payload.responseID ?? "\(context.id(fallback: file)):\(entry.timestamp)",
                    timestamp: timestamp, context: context, usage: usage
                ))
            case "event_msg":
                guard entry.payload?.type == "token_count",
                      let usage = entry.payload?.info?.lastTokenUsage,
                      let timestamp = timestamps.date(entry.timestamp) else { continue }
                legacy.append(record(
                    // A token_count event carries no response id, so the line's own
                    // timestamp stands in; it is stable because Codex appends.
                    id: "\(context.id(fallback: file)):\(entry.timestamp)",
                    timestamp: timestamp, context: context, usage: usage
                ))
            default:
                continue
            }
        }

        // Newer Codex writes every response twice: as a token_usage_record and again as a
        // token_count event. A file with records is read from the records alone, or the
        // same tokens would count twice.
        let found = hasTokenUsageRecords ? current : legacy
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

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
    }
}

private struct Usage: Decodable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
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
