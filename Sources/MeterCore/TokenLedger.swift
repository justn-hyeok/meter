import Foundation

/// The coding tool whose local logs a token record was read from.
///
/// Quotas say how much of a plan is left; these records say what spent it. They come from
/// logs each tool already keeps on this Mac, so they work without any key and never leave it.
public enum UsageTool: String, Codable, Sendable, CaseIterable, Comparable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Token counts for one response, normalised so every tool means the same thing by each field.
///
/// The tools disagree, and every source must convert to these rules:
/// - `input` is fresh input only. Cache reads and writes are never inside it. (Codex reports
///   `input_tokens` with `cached_input_tokens` included, so a Codex source subtracts them.)
/// - `output` includes reasoning. (Claude Code and Codex already count thinking inside
///   output; OpenCode reports `reasoning` beside `output`, so an OpenCode source adds it.)
/// - `reasoning` is the part of `output` that was reasoning, for display only. Never add it
///   to a total.
/// - `total` is `input + cacheRead + cacheWrite + output`, and nothing else.
public struct TokenCounts: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var reasoning: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public static let zero = TokenCounts()

    public var total: Int { input + cacheRead + cacheWrite + output }

    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}

/// One model response as a tool logged it.
public struct TokenRecord: Codable, Sendable, Equatable, Identifiable {
    /// Unique within its tool and stable across reads, so the same response read twice
    /// counts once. Sources build it from the log's own ids, never from a line number that
    /// shifts when the file grows.
    public let id: String
    public let tool: UsageTool
    /// Who served the model, as the tool names it: "anthropic", "openai", "opencode-go",
    /// "openrouter". Lowercased.
    public let provider: String
    public let model: String
    public let timestamp: Date
    public let sessionID: String?
    /// The working directory the tool was run in, when the log records one.
    public let project: String?
    public let tokens: TokenCounts
    /// Only when the tool itself recorded a price. Meter does not estimate one.
    public let costUSD: Double?

    public init(
        id: String, tool: UsageTool, provider: String, model: String, timestamp: Date,
        sessionID: String? = nil, project: String? = nil, tokens: TokenCounts, costUSD: Double? = nil
    ) {
        self.id = id
        self.tool = tool
        self.provider = provider.lowercased()
        self.model = model
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.project = project
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

/// A tool's local logs, read into records.
public protocol TokenLogSource: Sendable {
    var tool: UsageTool { get }
    /// Records at or after `since`, or all of them when it is nil, in any order.
    ///
    /// A tool that is not installed has no logs: return an empty array rather than throw.
    /// Throw only when logs exist and cannot be read, so the caller can say which tool failed.
    /// A single malformed line or row is skipped, not thrown: one bad line must not hide a
    /// month of good ones.
    func records(since: Date?) throws -> [TokenRecord]
}

/// What one source produced in one read.
public struct TokenSourceReport: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case ok, failed }

    public let tool: UsageTool
    public let state: State
    public let recordCount: Int
    public let message: String?

    public init(tool: UsageTool, state: State, recordCount: Int, message: String?) {
        self.tool = tool
        self.state = state
        self.recordCount = recordCount
        self.message = message
    }
}

/// How token totals are grouped.
public enum TokenGrouping: String, Codable, Sendable, CaseIterable {
    case model
    case provider
    case tool
    /// Provider and model together: the same model bought from two places is two rows.
    case providerModel = "provider-model"
}

/// Tokens summed over one group.
public struct TokenSummary: Codable, Sendable, Equatable {
    /// "model", "provider", "tool" or "provider/model", by grouping.
    public let key: String
    public let tool: UsageTool?
    public let provider: String?
    public let model: String?
    public let tokens: TokenCounts
    /// The sum of the costs the tools recorded; nil when none of the records had one.
    public let costUSD: Double?
    public let responses: Int
    public let lastUsed: Date
}

/// The model a tool used most recently.
public struct RecentModel: Codable, Sendable, Equatable {
    public let tool: UsageTool
    public let provider: String
    public let model: String
    public let lastUsed: Date
}

/// Everything one read of the logs produced.
public struct TokenLedgerReport: Sendable {
    public let records: [TokenRecord]
    public let sources: [TokenSourceReport]
    public let since: Date?

    /// Largest total first; ties by name so the order is stable.
    public func summaries(by grouping: TokenGrouping) -> [TokenSummary] {
        var groups: [String: [TokenRecord]] = [:]
        for record in records { groups[Self.key(record, grouping), default: []].append(record) }
        return groups.map { key, records in
            let first = records[0]
            let costs = records.compactMap(\.costUSD)
            return TokenSummary(
                key: key,
                tool: grouping == .tool ? first.tool : nil,
                provider: grouping == .provider || grouping == .providerModel ? first.provider : nil,
                model: grouping == .model || grouping == .providerModel ? first.model : nil,
                tokens: records.reduce(.zero) { $0 + $1.tokens },
                costUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                responses: records.count,
                lastUsed: records.map(\.timestamp).max()!
            )
        }
        .sorted { ($0.tokens.total, $1.key) > ($1.tokens.total, $0.key) }
    }

    /// The last model each tool used, most recent first.
    public var recentModels: [RecentModel] {
        var latest: [UsageTool: TokenRecord] = [:]
        for record in records where record.timestamp > (latest[record.tool]?.timestamp ?? .distantPast) {
            latest[record.tool] = record
        }
        return latest.values
            .map { RecentModel(tool: $0.tool, provider: $0.provider, model: $0.model, lastUsed: $0.timestamp) }
            // Two tools can answer in the same second; the tool order settles it, so the list
            // does not reshuffle between two reads of the same logs.
            .sorted { ($0.lastUsed, $1.tool) > ($1.lastUsed, $0.tool) }
    }

    public var total: TokenCounts { records.reduce(.zero) { $0 + $1.tokens } }

    static func key(_ record: TokenRecord, _ grouping: TokenGrouping) -> String {
        switch grouping {
        case .model: record.model
        case .provider: record.provider
        case .tool: record.tool.rawValue
        case .providerModel: "\(record.provider)/\(record.model)"
        }
    }
}

/// Reads every source and merges what they found.
public struct TokenLedger: Sendable {
    public let sources: [any TokenLogSource]

    public init(sources: [any TokenLogSource]) {
        self.sources = sources
    }

    /// One source failing leaves the others' records in the report, with the failure
    /// recorded against that tool.
    public func read(since: Date?) -> TokenLedgerReport {
        var records: [TokenRecord] = []
        var reports: [TokenSourceReport] = []
        for source in sources {
            do {
                // A source may hand back the same response twice; it counts once.
                var seen = Set<String>()
                let found = try source.records(since: since).filter { record in
                    (since.map { record.timestamp >= $0 } ?? true) && seen.insert(record.id).inserted
                }
                records += found
                reports.append(.init(tool: source.tool, state: .ok, recordCount: found.count, message: nil))
            } catch {
                reports.append(.init(tool: source.tool, state: .failed, recordCount: 0, message: error.localizedDescription))
            }
        }
        records.sort { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        return TokenLedgerReport(records: records, sources: reports, since: since)
    }
}

extension TokenLedger {
    /// The ledger over this Mac's real logs.
    public static var `default`: TokenLedger {
        TokenLedger(sources: [ClaudeCodeLogSource.default, CodexLogSource.default, OpenCodeLogSource.default])
    }
}

/// A duration written the way the CLI and the MCP tools accept one: `30m`, `24h`, `7d`.
public enum TokenWindow {
    /// The start of the window ending at `now`, or nil for `all`.
    public static func since(_ value: String, now: Date = .now) -> Date?? {
        if value.lowercased() == "all" { return .some(nil) }
        guard let unit = value.last, let amount = Int(value.dropLast()), amount > 0 else { return nil }
        let multiplier: Int
        switch unit {
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        default: return nil
        }
        // A value typed by hand or sent by an MCP client must not overflow and trap.
        let (seconds, overflow) = amount.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { return nil }
        return .some(now.addingTimeInterval(-TimeInterval(seconds)))
    }
}
