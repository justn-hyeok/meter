import Foundation
import MeterCore

/// `meter mcp`: a Model Context Protocol server over stdio, so an agent can ask how much of
/// a plan is left and what spent it.
struct MCPServer {
    let app: MeterCLIApplication

    static let latestProtocolVersion = "2025-06-18"
    private static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Serves until stdin closes, then returns the process exit code.
    func serve() async -> Int32 {
        while let line = readLine(strippingNewline: true) {
            guard let response = await handle(line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
        return 0
    }

    /// Answers one newline-delimited JSON-RPC message. Returns nil for a notification, which
    /// must never get a reply.
    func handle(_ line: String) async -> String? {
        let message: Any
        do {
            message = try JSONSerialization.jsonObject(with: Data(line.utf8))
        } catch {
            return Self.errorResponse(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let request = message as? [String: Any] else {
            return Self.errorResponse(id: NSNull(), code: -32600, message: "Invalid Request: expected a JSON object")
        }
        // A notification is a message with no id key at all; an explicit null id is a request.
        let isNotification = request["id"] == nil
        let id = request["id"] ?? NSNull()
        guard let method = request["method"] as? String else {
            return isNotification ? nil : Self.errorResponse(id: id, code: -32600, message: "Invalid Request: method must be a string")
        }
        if isNotification { return nil }

        switch method {
        case "initialize":
            return Self.resultResponse(id: id, result: initializeResult(params: request["params"]))
        case "ping":
            return Self.resultResponse(id: id, result: [:])
        case "tools/list":
            return Self.resultResponse(id: id, result: ["tools": Self.tools])
        case "tools/call":
            switch await callTool(params: request["params"]) {
            case .result(let result):
                return Self.resultResponse(id: id, result: result)
            case .invalid(let reason):
                return Self.errorResponse(id: id, code: -32602, message: reason)
            case .failed(let explanation):
                // The tool ran and could not produce an answer: a normal result, marked.
                return Self.resultResponse(id: id, result: [
                    "content": [["type": "text", "text": explanation]],
                    "isError": true,
                ])
            }
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Protocol

    private func initializeResult(params: Any?) -> [String: Any] {
        let requested = (params as? [String: Any])?["protocolVersion"] as? String
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.latestProtocolVersion
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "meter", "version": MeterCLIApplication.version],
            "instructions": Self.instructions,
        ]
    }

    private static let instructions = """
    Meter reports how much of each AI plan is left and what the coding tools on this Mac spent. \
    Quotas come from Meter.app's last refresh and may be stale; token usage comes from the logs \
    Claude Code, Codex and OpenCode already keep locally. Nothing leaves this Mac and this server \
    makes no network request.
    """

    private static func resultResponse(id: Any, result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func errorResponse(id: Any, code: Int, message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]])
    }

    private static func encode(_ message: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Tools

    private static var tools: [[String: Any]] {
        [
            [
                "name": "get_quotas",
                "description": "Plan limits and what is left for each AI provider account, taken from the last refresh by Meter.app. Returns one entry per account with every usage window's used, limit, remaining, percent used and reset time. Figures come from Meter.app's cache and can be stale; this server never queries a provider or prompts for a credential.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "providers": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Provider names to include, such as [\"claude\", \"codex\"]. Use \"all\" for every provider, or omit for the providers enabled in Meter. Accepted names: codex, claude, cursor, deepseek, command-code, opencode-go, openrouter.",
                        ],
                    ],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "get_token_usage",
                "description": "Tokens the coding tools on this Mac recorded in their local logs (Claude Code, Codex, OpenCode) over a window. Returns one row per group with input, cache-read, cache-write, output, reasoning and total token counts, the response count, last-used time and any cost the tool itself recorded. Units are tokens; total is input + cacheRead + cacheWrite + output, and reasoning is already inside output. Read from local logs; nothing leaves the Mac.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "since": [
                            "type": "string",
                            "description": "How far back to count: 30m, 24h, 7d or all. Defaults to 7d.",
                            "default": "7d",
                        ] as [String: Any],
                        "by": [
                            "type": "string",
                            "enum": TokenGrouping.allCases.map(\.rawValue),
                            "description": "How to group the rows. provider-model (the default) keeps the same model bought from two places apart.",
                            "default": "provider-model",
                        ] as [String: Any],
                    ],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "get_current_models",
                "description": "The model each coding tool used most recently, and every model that tool used in the window with response counts. Use since to set the window. Read from the coding tools' local logs on this Mac; nothing leaves the Mac.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "since": [
                            "type": "string",
                            "description": "How far back to count: 30m, 24h, 7d or all. Defaults to 7d.",
                            "default": "7d",
                        ] as [String: Any],
                    ],
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    private enum ToolOutcome {
        case result([String: Any])
        case invalid(String)
        case failed(String)
    }

    private enum ParameterError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let reason): reason
            }
        }
    }

    private func callTool(params: Any?) async -> ToolOutcome {
        guard let params = params as? [String: Any], let name = params["name"] as? String else {
            return .invalid("tools/call needs a tool name")
        }
        let arguments: [String: Any]
        if let raw = params["arguments"] {
            guard let object = raw as? [String: Any] else {
                return .invalid("arguments must be a JSON object")
            }
            arguments = object
        } else {
            arguments = [:]
        }

        switch name {
        case "get_quotas": return await quotas(arguments)
        case "get_token_usage": return tokenUsage(arguments)
        case "get_current_models": return currentModels(arguments)
        default: return .invalid("Unknown tool: \(name)")
        }
    }

    /// The window argument shared by the two log tools. `since` is nil for "all".
    private func windowArguments(_ arguments: [String: Any]) throws -> (window: String, since: Date?) {
        let window: String
        switch arguments["since"] {
        case nil:
            window = "7d"
        case let value as String:
            window = value.lowercased()
        default:
            throw ParameterError.invalid("since must be a string such as 30m, 24h, 7d or all")
        }
        guard let since = TokenWindow.since(window) else {
            throw ParameterError.invalid("Invalid since '\(window)': use a positive duration in m, h or d, or all")
        }
        return (window, since)
    }

    /// Quotas are read exactly as `meter status --json` reads them: from `app`'s cache. No
    /// refresh happens here, because a headless process must not trigger a keychain prompt.
    private func quotas(_ arguments: [String: Any]) async -> ToolOutcome {
        let providers: [String]
        switch arguments["providers"] {
        case nil:
            providers = []
        case let values as [Any]:
            guard values.allSatisfy({ $0 is String }) else {
                return .invalid("providers must be an array of provider names")
            }
            providers = values.compactMap { $0 as? String }
        default:
            return .invalid("providers must be an array of provider names")
        }

        let options: CLIOptions
        do {
            // The CLI's own parser decides what a provider name means, including `all` and
            // `provider#account`, so the two entry points cannot drift apart.
            options = try CLIArgumentParser.parse(["status"] + providers)
        } catch {
            return .invalid(error.localizedDescription)
        }

        let result = await app.run(.init(command: options.command, json: true, strict: false))
        if result.exitCode == 64 {
            return .invalid(result.standardError.isEmpty ? "Unknown provider" : result.standardError)
        }
        guard !result.standardOutput.isEmpty else {
            return .failed(result.standardError.isEmpty ? "Meter returned no usage data." : result.standardError)
        }

        let envelope: StatusEnvelope
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            envelope = try decoder.decode(StatusEnvelope.self, from: Data(result.standardOutput.utf8))
        } catch {
            return .failed("Could not read Meter's cached usage: \(error.localizedDescription)")
        }

        let accounts = envelope.snapshots.map(QuotaAccount.init)
        guard accounts.contains(where: { !$0.windows.isEmpty }) else {
            return .failed(
                "No usage is cached for the selected providers. Open Meter.app or run 'meter --refresh' so Meter.app can refresh; this server never queries a provider itself."
            )
        }
        return encode(QuotasReport(generatedAt: envelope.generatedAt, accounts: accounts))
    }

    private func tokenUsage(_ arguments: [String: Any]) -> ToolOutcome {
        let window: String
        let since: Date?
        do {
            (window, since) = try windowArguments(arguments)
        } catch {
            return .invalid(error.localizedDescription)
        }

        let grouping: TokenGrouping
        switch arguments["by"] {
        case nil:
            grouping = .providerModel
        case let value as String:
            guard let parsed = TokenGrouping(rawValue: value.lowercased()) else {
                return .invalid("Invalid by '\(value)': use \(TokenGrouping.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            grouping = parsed
        default:
            return .invalid("by must be one of \(TokenGrouping.allCases.map(\.rawValue).joined(separator: ", "))")
        }

        let report = app.ledger.read(since: since)
        if !report.sources.isEmpty, report.sources.allSatisfy({ $0.state == .failed }) {
            return .failed(failureMessage(report.sources))
        }
        return encode(TokenUsageReport(
            window: window,
            since: since,
            grouping: grouping,
            rows: report.summaries(by: grouping).map(TokenUsageRow.init),
            totals: TokenTotals(report: report),
            sources: report.sources
        ))
    }

    private func currentModels(_ arguments: [String: Any]) -> ToolOutcome {
        let window: String
        let since: Date?
        do {
            (window, since) = try windowArguments(arguments)
        } catch {
            return .invalid(error.localizedDescription)
        }

        let report = app.ledger.read(since: since)
        if !report.sources.isEmpty, report.sources.allSatisfy({ $0.state == .failed }) {
            return .failed(failureMessage(report.sources))
        }

        // `recentModels` leaves a tie between two tools in no particular order; sorting here
        // keeps two calls against the same logs identical.
        let models = report.recentModels
            .sorted { lhs, rhs in
                if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed > rhs.lastUsed }
                return lhs.tool < rhs.tool
            }
            .map { recent in
                ToolModels(
                    tool: recent.tool,
                    title: recent.tool.title,
                    provider: recent.provider,
                    model: recent.model,
                    lastUsed: recent.lastUsed,
                    usedModels: usedModels(of: recent.tool, in: report.records)
                )
            }

        return encode(ModelUsageReport(
            window: window,
            since: since,
            models: models,
            totals: TokenTotals(report: report),
            sources: report.sources
        ))
    }

    /// Every model a tool used in the window, largest first. Grouped by provider and model,
    /// because the same model bought from two places is two entries.
    private func usedModels(of tool: UsageTool, in records: [TokenRecord]) -> [ModelCount] {
        var groups: [String: (provider: String, model: String, responses: Int, total: Int)] = [:]
        for record in records where record.tool == tool {
            let key = "\(record.provider)/\(record.model)"
            var group = groups[key] ?? (record.provider, record.model, 0, 0)
            group.responses += 1
            group.total += record.tokens.total
            groups[key] = group
        }
        return groups.values
            .map { ModelCount(provider: $0.provider, model: $0.model, responses: $0.responses, total: $0.total) }
            .sorted { lhs, rhs in
                if lhs.responses != rhs.responses { return lhs.responses > rhs.responses }
                if lhs.model != rhs.model { return lhs.model < rhs.model }
                return lhs.provider < rhs.provider
            }
    }

    private func failureMessage(_ sources: [TokenSourceReport]) -> String {
        "Every coding tool's logs could not be read: "
            + sources.map { "\($0.tool.title): \($0.message ?? "unknown error")" }.joined(separator: "; ")
    }

    /// Encodes a report once, so the text block and `structuredContent` are the same object.
    ///
    /// The text is written by the same serializer that writes the response, because
    /// JSONEncoder and JSONSerialization print some doubles differently; going through one
    /// serializer keeps the two blocks identical rather than merely close.
    private func encode(_ value: some Encodable) -> ToolOutcome {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = try? JSONSerialization.data(
                    withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                return .failed("The result could not be encoded.")
            }
            return .result([
                "content": [["type": "text", "text": String(decoding: text, as: UTF8.self)]],
                "structuredContent": object,
            ])
        } catch {
            return .failed("The result could not be encoded: \(error.localizedDescription)")
        }
    }
}

// MARK: - Reports

/// The shape `meter status --json` writes, decoded back so the MCP tool can restate it.
private struct StatusEnvelope: Decodable {
    let generatedAt: Date
    let snapshots: [UsageSnapshot]
}

private struct QuotasReport: Encodable {
    let generatedAt: Date
    let source = "Meter.app's cached last refresh on this Mac; no network request was made"
    let accounts: [QuotaAccount]

    init(generatedAt: Date, accounts: [QuotaAccount]) {
        self.generatedAt = generatedAt
        self.accounts = accounts
    }
}

private struct QuotaAccount: Encodable {
    let provider: String
    let account: String?
    let title: String
    let state: String
    let source: String
    let observedAt: Date
    let windows: [QuotaWindow]
    let note: String?

    init(_ snapshot: UsageSnapshot) {
        self.provider = snapshot.provider.rawValue
        self.account = snapshot.account
        self.title = snapshot.accountID.title
        self.state = snapshot.state.rawValue
        self.source = snapshot.source
        self.observedAt = snapshot.fetchedAt
        self.windows = snapshot.buckets.map(QuotaWindow.init)
        self.note = snapshot.message
    }
}

private struct QuotaWindow: Encodable {
    let id: String
    let label: String
    let unit: String
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let percentUsed: Double?
    let resetsAt: Date?

    init(_ bucket: UsageBucket) {
        self.id = bucket.id
        self.label = bucket.label
        self.unit = bucket.unit.rawValue
        self.used = bucket.used
        self.limit = bucket.limit
        self.remaining = bucket.remaining
        self.percentUsed = bucket.percentageUsed
        self.resetsAt = bucket.resetAt
    }
}

private struct TokenUsageReport: Encodable {
    let window: String
    let since: Date?
    let grouping: TokenGrouping
    let rows: [TokenUsageRow]
    let totals: TokenTotals
    let sources: [TokenSourceReport]
}

private struct TokenUsageRow: Encodable {
    let name: String
    let tool: UsageTool?
    let provider: String?
    let model: String?
    let responses: Int
    let input: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int
    let reasoning: Int
    let total: Int
    let costUSD: Double?
    let lastUsed: Date

    init(_ summary: TokenSummary) {
        self.name = summary.key
        self.tool = summary.tool
        self.provider = summary.provider
        self.model = summary.model
        self.responses = summary.responses
        self.input = summary.tokens.input
        self.cacheRead = summary.tokens.cacheRead
        self.cacheWrite = summary.tokens.cacheWrite
        self.output = summary.tokens.output
        self.reasoning = summary.tokens.reasoning
        self.total = summary.tokens.total
        self.costUSD = summary.costUSD
        self.lastUsed = summary.lastUsed
    }
}

private struct TokenTotals: Encodable {
    let responses: Int
    let input: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int
    let reasoning: Int
    let total: Int
    let costUSD: Double?

    init(report: TokenLedgerReport) {
        let tokens = report.total
        let costs = report.records.compactMap(\.costUSD)
        self.responses = report.records.count
        self.input = tokens.input
        self.cacheRead = tokens.cacheRead
        self.cacheWrite = tokens.cacheWrite
        self.output = tokens.output
        self.reasoning = tokens.reasoning
        self.total = tokens.total
        self.costUSD = costs.isEmpty ? nil : costs.reduce(0, +)
    }
}

private struct ModelUsageReport: Encodable {
    let window: String
    let since: Date?
    let models: [ToolModels]
    let totals: TokenTotals
    let sources: [TokenSourceReport]
}

private struct ToolModels: Encodable {
    let tool: UsageTool
    let title: String
    let provider: String
    let model: String
    let lastUsed: Date
    let usedModels: [ModelCount]
}

private struct ModelCount: Encodable {
    let provider: String
    let model: String
    let responses: Int
    let total: Int
}
