import Foundation

/// Reads the token counts Claude Code records in its own session logs.
///
/// Claude Code writes one JSONL file per session below `<config>/projects` and keeps a
/// session's subagent conversations in a `subagents` directory beside it, so the files are
/// found by walking the tree rather than by guessing a depth. The logs stay on this Mac and
/// need no key, which is what makes them a usable record of spend.
public struct ClaudeCodeLogSource: TokenLogSource {
    public let tool = UsageTool.claudeCode

    private let projectsDirectories: [URL]

    public init(projectsDirectories: [URL]) {
        self.projectsDirectories = projectsDirectories
    }

    /// Takes the environment and home directory separately so a test can point both at a
    /// temporary tree instead of this Mac's real logs.
    init(environment: [String: String], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.projectsDirectories = Self.projectsDirectories(environment: environment, homeDirectory: homeDirectory)
    }

    /// The projects directories of every Claude Code install this Mac has: the ones
    /// `CLAUDE_CONFIG_DIR` names, or the two default locations when it is unset.
    public static var `default`: ClaudeCodeLogSource {
        ClaudeCodeLogSource(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// `CLAUDE_CONFIG_DIR` holds config directories, not projects directories, and may list
    /// several installs separated by commas. A directory that does not exist is kept: it
    /// reads as no logs, and Claude Code may create it after Meter starts.
    private static func projectsDirectories(environment: [String: String], homeDirectory: URL) -> [URL] {
        let configured = (environment["CLAUDE_CONFIG_DIR"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let configDirectories = configured.isEmpty
            ? [homeDirectory.appending(path: ".claude"), homeDirectory.appending(path: ".config/claude")]
            : configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        return configDirectories.map { $0.appending(path: "projects") }
    }

    /// A file whose modification date is earlier than `since` cannot hold a later response,
    /// because a response is written when it happens. Skipping those files is what keeps a
    /// window over a week of logs from touching everything on disk.
    ///
    /// A file that cannot be read is skipped rather than thrown, so one unreadable file does
    /// not hide the rest; a directory that is not there simply has no logs.
    public func records(since: Date?) throws -> [TokenRecord] {
        let cutoff = since ?? .distantPast
        let decoder = JSONDecoder()
        // One response is written as several lines, one per content block. If their usage
        // differs, the line with the most output is the one written last.
        var index: [String: Int] = [:]
        var records: [TokenRecord] = []
        for directory in projectsDirectories {
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                errorHandler: { _, _ in true }
            )
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension == "jsonl" else { continue }
                if let since,
                   let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modified < since {
                    continue
                }
                guard let data = try? Data(contentsOf: file) else { continue }
                for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                    guard line.range(of: Self.usageKey) != nil,
                          let entry = try? decoder.decode(LogLine.self, from: line),
                          let record = entry.record(),
                          record.timestamp >= cutoff else { continue }
                    if let earlier = index[record.id] {
                        if record.tokens.output > records[earlier].tokens.output { records[earlier] = record }
                    } else {
                        index[record.id] = records.count
                        records.append(record)
                    }
                }
            }
        }
        return records
    }

    /// Checked before decoding, which is most of the cost: a session log is mostly prompts,
    /// tool results and file snapshots, and none of them mention usage.
    private static let usageKey = Data("\"usage\"".utf8)

    private struct LogLine: Decodable {
        let type: String?
        let timestamp: String?
        let sessionId: String?
        let cwd: String?
        let requestId: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let outputTokens: Int?
            let outputTokensDetails: OutputDetails?

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case outputTokens = "output_tokens"
                case outputTokensDetails = "output_tokens_details"
            }

            struct OutputDetails: Decodable {
                let thinkingTokens: Int?

                private enum CodingKeys: String, CodingKey { case thinkingTokens = "thinking_tokens" }
            }
        }

        /// Only assistant messages with usage are responses; `<synthetic>` is a local stand-in
        /// Claude Code writes without calling a model, and a message with no id has nothing
        /// stable to count it by.
        func record() -> TokenRecord? {
            guard type == "assistant",
                  let message,
                  let usage = message.usage,
                  let model = message.model, model != "<synthetic>",
                  let id = message.id,
                  let timestamp = Self.date(timestamp) else { return nil }
            return TokenRecord(
                id: requestId.map { "\(id):\($0)" } ?? id,
                tool: .claudeCode,
                provider: "anthropic",
                model: model,
                timestamp: timestamp,
                sessionID: sessionId,
                project: cwd,
                tokens: TokenCounts(
                    input: usage.inputTokens ?? 0,
                    output: usage.outputTokens ?? 0,
                    cacheRead: usage.cacheReadInputTokens ?? 0,
                    cacheWrite: usage.cacheCreationInputTokens ?? 0,
                    reasoning: usage.outputTokensDetails?.thinkingTokens ?? 0
                )
            )
        }

        private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        private static let wholeSeconds = Date.ISO8601FormatStyle()

        private static func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            return (try? fractionalSeconds.parse(text)) ?? (try? wholeSeconds.parse(text))
        }
    }
}
