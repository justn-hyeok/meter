import Foundation
import Testing
@testable import MeterCore

/// Synthetic logs in each tool's real format, under `Tests/MeterTests/TokenLogs`. Every
/// value in them is invented; nothing was copied from a real log.
///
/// The expected records below are the contract each source is tested against.
enum TokenLogFixtures {
    static var root: URL {
        get throws { try #require(Bundle.module.url(forResource: "TokenLogs", withExtension: nil)) }
    }

    /// Claude Code's `projects` directory: one session file with a subagent log beneath it.
    static var claudeProjects: URL { get throws { try root.appending(path: "claude/projects") } }

    /// Codex's `sessions` directory. `archived_sessions` beside it holds a `.zst` file that
    /// no source may try to read as JSON.
    static var codexSessions: URL { get throws { try root.appending(path: "codex/sessions") } }

    /// A copy of the OpenCode database in a fresh directory, with its `-wal` and `-shm`.
    /// The rows live only in the `-wal` file, as they do while OpenCode is running, so a
    /// reader that ignores the WAL finds none.
    static func openCodeDatabase() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "meter-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            try FileManager.default.copyItem(
                at: try root.appending(path: "opencode/opencode.db\(suffix)"),
                to: directory.appending(path: "opencode.db\(suffix)")
            )
        }
        return directory.appending(path: "opencode.db")
    }

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)!
    }

    /// Message `msg_A1` appears twice (two content blocks) and counts once; the
    /// `<synthetic>` message and the malformed line are skipped; the subagent log is read.
    static let claudeRecords: [TokenRecord] = [
        .init(id: "msg_A1:req_A1", tool: .claudeCode, provider: "anthropic", model: "claude-opus-5-5",
              timestamp: date("2026-10-20T10:00:05.000Z"), sessionID: "11111111-1111-4111-8111-111111111111",
              project: "/Users/me/dev/alpha",
              tokens: .init(input: 10, output: 50, cacheRead: 2000, cacheWrite: 1000, reasoning: 20)),
        .init(id: "msg_A2:req_A2", tool: .claudeCode, provider: "anthropic", model: "claude-sonnet-5-5",
              timestamp: date("2026-10-20T11:30:00.000Z"), sessionID: "11111111-1111-4111-8111-111111111111",
              project: "/Users/me/dev/alpha",
              tokens: .init(input: 5, output: 100, cacheRead: 3000)),
        .init(id: "msg_S1:req_S1", tool: .claudeCode, provider: "anthropic", model: "claude-haiku-5-5",
              timestamp: date("2026-10-21T09:00:00.000Z"), sessionID: "11111111-1111-4111-8111-111111111111",
              project: "/Users/me/dev/alpha",
              tokens: .init(input: 7, output: 30)),
    ]

    /// The first file has `token_usage_record` lines, so its `token_count` events are
    /// ignored (they repeat the same figures). The second, older file has only
    /// `token_count` events, one with `info: null`. `input` excludes cached input.
    static let codexRecords: [TokenRecord] = [
        .init(id: "resp_1", tool: .codex, provider: "openai", model: "gpt-6.1-sol",
              timestamp: date("2026-10-20T12:00:10.000Z"), sessionID: "0aaaaaaa-0000-7000-8000-00000000000a",
              project: "/Users/me/dev/beta",
              tokens: .init(input: 600, output: 50, cacheRead: 400, reasoning: 10)),
        .init(id: "resp_2", tool: .codex, provider: "openai", model: "gpt-6-luna",
              timestamp: date("2026-10-20T12:05:09.000Z"), sessionID: "0aaaaaaa-0000-7000-8000-00000000000a",
              project: "/Users/me/dev/beta",
              tokens: .init(input: 500, output: 20)),
        .init(id: "0bbbbbbb-0000-7000-8000-00000000000b:2026-10-20T13:00:09.000Z", tool: .codex, provider: "openrouter", model: "o-legacy",
              timestamp: date("2026-10-20T13:00:09.000Z"), sessionID: "0bbbbbbb-0000-7000-8000-00000000000b",
              project: "/Users/me/dev/gamma",
              tokens: .init(input: 200, output: 30, cacheRead: 100, reasoning: 5)),
        .init(id: "0bbbbbbb-0000-7000-8000-00000000000b:2026-10-20T13:01:09.000Z", tool: .codex, provider: "openrouter", model: "o-legacy",
              timestamp: date("2026-10-20T13:01:09.000Z"), sessionID: "0bbbbbbb-0000-7000-8000-00000000000b",
              project: "/Users/me/dev/gamma",
              tokens: .init(input: 200, output: 10)),
    ]

    /// Assistant messages only. `output` includes `reasoning`. A cost of 0 means OpenCode
    /// did not price the response, so it reads as nil. The all-zero message (started, never
    /// answered) and the row whose data is not JSON are skipped.
    static let openCodeRecords: [TokenRecord] = [
        .init(id: "msg_o1", tool: .openCode, provider: "opencode-go", model: "deepseek-v4.1-flash",
              timestamp: date("2026-10-21T08:00:02.000Z"), sessionID: "ses_1", project: "/Users/me/dev/delta",
              tokens: .init(input: 100, output: 50, cacheRead: 500, reasoning: 10), costUSD: 0.0012),
        .init(id: "msg_o2", tool: .openCode, provider: "openai", model: "gpt-5.5",
              timestamp: date("2026-10-21T09:00:00.000Z"), sessionID: "ses_1", project: "/Users/me/dev/delta",
              tokens: .init(input: 200, output: 100, cacheRead: 1500, cacheWrite: 500, reasoning: 20)),
    ]

    static var allRecords: [TokenRecord] { claudeRecords + codexRecords + openCodeRecords }
}

/// Hands back fixed records, for testing what is built on the ledger without any logs.
struct FixedTokenSource: TokenLogSource {
    let tool: UsageTool
    var records: [TokenRecord] = []
    var failure: String?

    func records(since: Date?) throws -> [TokenRecord] {
        if let failure { throw NSError(domain: "FixedTokenSource", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
        return records
    }
}

extension TokenLedger {
    /// A ledger over the expected fixture records, one source per tool.
    static var fixture: TokenLedger {
        TokenLedger(sources: UsageTool.allCases.map { tool in
            FixedTokenSource(tool: tool, records: TokenLogFixtures.allRecords.filter { $0.tool == tool })
        })
    }
}
