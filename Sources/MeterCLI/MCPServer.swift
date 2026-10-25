import Foundation
import MeterCore

/// `meter mcp`: a Model Context Protocol server over stdio, so an agent can ask how much of
/// a plan is left and what spent it.
struct MCPServer {
    let app: MeterCLIApplication
    /// Shared by every call this server answers, so a burst of questions reads the logs once.
    private let memo = LedgerMemo()

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
    Start with get_limit_warnings to learn whether anything needs attention; use get_quotas for \
    every window, get_token_usage for spend and get_current_models for which model each tool \
    is on. Quotas come from Meter.app's last refresh and may be stale; token usage comes from \
    the logs Claude Code, Codex and OpenCode already keep locally. Nothing leaves this Mac and \
    this server makes no network request.
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

    private static let providerNames = ProviderID.allCases.map(\.rawValue).joined(separator: ", ")

    /// Every tool only reads: the cache Meter.app wrote, or the coding tools' own logs.
    private static func annotations(_ title: String) -> [String: Any] {
        ["title": title, "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
    }

    private static var windowProperty: [String: Any] { [
        "type": "string",
        "description": "How far back to count: 30m, 24h, 7d, 30d or all. Defaults to 7d.",
        "default": "7d",
    ] }

    private static var providersProperty: [String: Any] { [
        "type": "array",
        "items": ["type": "string"],
        "description": "Provider names to include, such as [\"claude\", \"codex\"]. Use \"all\" for every provider, or omit for the providers enabled in Meter. Accepted names: \(providerNames).",
    ] }

    private static var tokenCountsSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "responses": ["type": "integer"], "input": ["type": "integer"], "cacheRead": ["type": "integer"],
            "cacheWrite": ["type": "integer"], "output": ["type": "integer"], "reasoning": ["type": "integer"],
            "total": ["type": "integer"], "excludingCacheReads": ["type": "integer"], "costUSD": ["type": "number"],
        ],
        "required": ["responses", "input", "cacheRead", "cacheWrite", "output", "reasoning", "total", "excludingCacheReads"],
    ] }

    private static var sourcesSchema: [String: Any] { [
        "type": "array",
        "items": [
            "type": "object",
            "properties": [
                "tool": ["type": "string"], "state": ["type": "string", "enum": ["ok", "failed"]],
                "recordCount": ["type": "integer"], "message": ["type": "string"],
            ],
            "required": ["tool", "state", "recordCount"],
        ] as [String: Any],
    ] }

    private static var tools: [[String: Any]] {
        [
            [
                "name": "get_limit_warnings",
                "title": "Limit warnings",
                "description": "What needs attention right now: usage windows at or past 80% (\"warning\") or 95% (\"critical\"), and accounts whose sign-in stopped working, was never connected, or is about to end. Windows the user muted in Meter are left out. An empty result means nothing is close to a limit. Read from Meter.app's cached last refresh; no network request, no keychain prompt.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["providers": providersProperty],
                    "additionalProperties": false,
                ],
                "outputSchema": [
                    "type": "object",
                    "properties": [
                        "generatedAt": ["type": "string"],
                        "source": ["type": "string"],
                        "warnings": ["type": "array", "items": [
                            "type": "object",
                            "properties": [
                                "provider": ["type": "string"], "account": ["type": "string"], "title": ["type": "string"],
                                "window": ["type": "string"], "label": ["type": "string"], "percentUsed": ["type": "number"],
                                "level": ["type": "string", "enum": ["warning", "critical"]], "resetsAt": ["type": "string"],
                                "observedAt": ["type": "string"], "stale": ["type": "boolean"],
                            ],
                            "required": ["provider", "title", "window", "label", "percentUsed", "level", "observedAt", "stale"],
                        ] as [String: Any]] as [String: Any],
                        "signIn": ["type": "array", "items": [
                            "type": "object",
                            "properties": [
                                "provider": ["type": "string"], "account": ["type": "string"], "title": ["type": "string"],
                                "issue": ["type": "string", "enum": ["signInRequired", "notConnected", "expiresSoon"]],
                                "sessionEndsAt": ["type": "string"], "fix": ["type": "string"], "message": ["type": "string"],
                            ],
                            "required": ["provider", "title", "issue"],
                        ] as [String: Any]] as [String: Any],
                    ],
                    "required": ["generatedAt", "source", "warnings", "signIn"],
                ] as [String: Any],
                "annotations": annotations("Limit warnings"),
            ],
            [
                "name": "get_quotas",
                "title": "Plan quotas",
                "description": "Plan limits and what is left for each AI provider account, taken from the last refresh by Meter.app. Returns one entry per account with every usage window's used, limit, remaining, percent used, reset time and level (ok, warning at 80%, critical at 95%; a window the user muted is always ok and marked warningsMuted), plus any sign-in issue. Figures come from Meter.app's cache and can be stale; this server never queries a provider or prompts for a credential.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["providers": providersProperty],
                    "additionalProperties": false,
                ],
                "outputSchema": [
                    "type": "object",
                    "properties": [
                        "generatedAt": ["type": "string"],
                        "source": ["type": "string"],
                        "accounts": ["type": "array", "items": [
                            "type": "object",
                            "properties": [
                                "provider": ["type": "string"], "account": ["type": "string"], "title": ["type": "string"],
                                "state": ["type": "string", "enum": ["live", "stale", "unavailable"]], "source": ["type": "string"],
                                "observedAt": ["type": "string"], "note": ["type": "string"], "issue": ["type": "string"],
                                "sessionEndsAt": ["type": "string"],
                                "windows": ["type": "array", "items": [
                                    "type": "object",
                                    "properties": [
                                        "id": ["type": "string"], "label": ["type": "string"], "unit": ["type": "string"],
                                        "used": ["type": "number"], "limit": ["type": "number"], "remaining": ["type": "number"],
                                        "percentUsed": ["type": "number"], "resetsAt": ["type": "string"],
                                        "level": ["type": "string", "enum": ["ok", "warning", "critical"]],
                                        "warningsMuted": ["type": "boolean"],
                                    ],
                                    "required": ["id", "label", "unit", "level", "warningsMuted"],
                                ] as [String: Any]] as [String: Any],
                            ],
                            "required": ["provider", "title", "state", "source", "observedAt", "windows"],
                        ] as [String: Any]] as [String: Any],
                    ],
                    "required": ["generatedAt", "source", "accounts"],
                ] as [String: Any],
                "annotations": annotations("Plan quotas"),
            ],
            [
                "name": "get_token_usage",
                "title": "Token usage",
                "description": "Tokens the coding tools on this Mac recorded in their local logs (Claude Code, Codex, OpenCode) over a window, largest first. Each row has input, cache-read, cache-write, output, reasoning and total token counts, excludingCacheReads (the work actually sent and produced; cache reads are the context re-read every turn and usually dwarf the rest), the response count, last-used time and any cost the tool itself recorded. total is input + cacheRead + cacheWrite + output, and reasoning is already inside output. Rows past limit are counted in omittedRows; totals always cover every row.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "since": windowProperty,
                        "by": [
                            "type": "string",
                            "enum": TokenGrouping.allCases.map(\.rawValue),
                            "description": "How to group the rows. provider-model (the default) keeps the same model bought from two places apart.",
                            "default": "provider-model",
                        ] as [String: Any],
                        "tool": [
                            "type": "string",
                            "enum": UsageTool.allCases.map(\.rawValue),
                            "description": "Only this coding tool's logs. Omit for all of them.",
                        ] as [String: Any],
                        "limit": [
                            "type": "integer", "minimum": 1, "maximum": 200, "default": 20,
                            "description": "At most this many rows. Defaults to 20.",
                        ] as [String: Any],
                    ],
                    "additionalProperties": false,
                ],
                "outputSchema": [
                    "type": "object",
                    "properties": [
                        "window": ["type": "string"], "since": ["type": "string"], "grouping": ["type": "string"],
                        "tool": ["type": "string"],
                        "rows": ["type": "array", "items": [
                            "type": "object",
                            "properties": (tokenCountsSchema["properties"] as! [String: Any]).merging([
                                "name": ["type": "string"], "tool": ["type": "string"], "provider": ["type": "string"],
                                "model": ["type": "string"], "lastUsed": ["type": "string"],
                            ] as [String: Any]) { $1 },
                            "required": ["name", "responses", "total", "excludingCacheReads", "lastUsed"],
                        ] as [String: Any]] as [String: Any],
                        "omittedRows": ["type": "integer"],
                        "totals": tokenCountsSchema,
                        "sources": sourcesSchema,
                    ],
                    "required": ["window", "grouping", "rows", "omittedRows", "totals", "sources"],
                ] as [String: Any],
                "annotations": annotations("Token usage"),
            ],
            [
                "name": "get_current_models",
                "title": "Current models",
                "description": "The model each coding tool used most recently, and every model that tool used in the window with response counts and token totals. Read from the coding tools' local logs on this Mac; nothing leaves the Mac.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["since": windowProperty],
                    "additionalProperties": false,
                ],
                "outputSchema": [
                    "type": "object",
                    "properties": [
                        "window": ["type": "string"], "since": ["type": "string"],
                        "models": ["type": "array", "items": [
                            "type": "object",
                            "properties": [
                                "tool": ["type": "string"], "title": ["type": "string"], "provider": ["type": "string"],
                                "model": ["type": "string"], "lastUsed": ["type": "string"],
                                "usedModels": ["type": "array", "items": [
                                    "type": "object",
                                    "properties": [
                                        "provider": ["type": "string"], "model": ["type": "string"],
                                        "responses": ["type": "integer"], "total": ["type": "integer"],
                                    ],
                                    "required": ["provider", "model", "responses", "total"],
                                ] as [String: Any]] as [String: Any],
                            ],
                            "required": ["tool", "title", "provider", "model", "lastUsed", "usedModels"],
                        ] as [String: Any]] as [String: Any],
                        "totals": tokenCountsSchema,
                        "sources": sourcesSchema,
                    ],
                    "required": ["window", "models", "totals", "sources"],
                ] as [String: Any],
                "annotations": annotations("Current models"),
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
        case "get_limit_warnings": return await limitWarnings(arguments)
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
    private func cachedSnapshots(_ arguments: [String: Any]) async -> Result<(Date, [UsageSnapshot]), QuotaFailure> {
        let providers: [String]
        switch arguments["providers"] {
        case nil:
            providers = []
        case let values as [Any]:
            guard values.allSatisfy({ $0 is String }) else {
                return .failure(.invalid("providers must be an array of provider names"))
            }
            providers = values.compactMap { $0 as? String }
            // These go to the CLI's argv parser, where "-h" or "--json" is an option, not a
            // provider.
            if let flag = providers.first(where: { $0.hasPrefix("-") }) {
                return .failure(.invalid("Unknown provider '\(flag)'"))
            }
        default:
            return .failure(.invalid("providers must be an array of provider names"))
        }

        let options: CLIOptions
        do {
            // The CLI's own parser decides what a provider name means, including `all` and
            // `provider#account`, so the two entry points cannot drift apart.
            options = try CLIArgumentParser.parse(["status"] + providers)
        } catch {
            return .failure(.invalid(error.localizedDescription))
        }
        guard case .status = options.command else {
            return .failure(.invalid("providers must be an array of provider names"))
        }

        let result = await app.run(.init(command: options.command, json: true, strict: false))
        if result.exitCode == 64 {
            return .failure(.invalid(result.standardError.isEmpty ? "Unknown provider" : result.standardError))
        }
        guard !result.standardOutput.isEmpty else {
            return .failure(.failed(result.standardError.isEmpty ? "Meter returned no usage data." : result.standardError))
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(StatusEnvelope.self, from: Data(result.standardOutput.utf8))
            return .success((envelope.generatedAt, envelope.snapshots))
        } catch {
            return .failure(.failed("Could not read Meter's cached usage: \(error.localizedDescription)"))
        }
    }

    private enum QuotaFailure: Error {
        case invalid(String)
        case failed(String)

        var outcome: ToolOutcome {
            switch self {
            case .invalid(let reason): .invalid(reason)
            case .failed(let explanation): .failed(explanation)
            }
        }
    }

    private static let noCache = "No usage is cached for the selected providers. Open Meter.app or run 'meter --refresh' so Meter.app can refresh; this server never queries a provider itself."

    private func quotas(_ arguments: [String: Any]) async -> ToolOutcome {
        let generatedAt: Date
        let snapshots: [UsageSnapshot]
        switch await cachedSnapshots(arguments) {
        case .failure(let failure): return failure.outcome
        case .success(let loaded): (generatedAt, snapshots) = loaded
        }
        let muted = app.settings.mutedWindows
        let accounts = snapshots.map { QuotaAccount($0, muted: muted) }
        guard accounts.contains(where: { !$0.windows.isEmpty }) else { return .failed(Self.noCache) }
        return encode(QuotasReport(generatedAt: generatedAt, accounts: accounts))
    }

    /// Only what needs attention, so an agent can check in one short answer.
    private func limitWarnings(_ arguments: [String: Any]) async -> ToolOutcome {
        let generatedAt: Date
        let snapshots: [UsageSnapshot]
        switch await cachedSnapshots(arguments) {
        case .failure(let failure): return failure.outcome
        case .success(let loaded): (generatedAt, snapshots) = loaded
        }
        guard snapshots.contains(where: { !$0.buckets.isEmpty || $0.issue != nil }) else { return .failed(Self.noCache) }
        let muted = app.settings.mutedWindows
        var warnings: [LimitWarning] = []
        var signIn: [SignInNotice] = []
        for snapshot in snapshots {
            if let issue = snapshot.issue { signIn.append(SignInNotice(snapshot, issue: issue)) }
            for bucket in snapshot.buckets {
                guard !muted.contains(BucketKey(account: snapshot.accountID, bucketID: bucket.id)),
                      let level = QuotaLevel(bucket.fractionUsed), level != .ok else { continue }
                warnings.append(LimitWarning(snapshot, bucket, level: level))
            }
        }
        warnings.sort { ($0.percentUsed, $1.title) > ($1.percentUsed, $0.title) }
        return encode(LimitWarningsReport(generatedAt: generatedAt, warnings: warnings, signIn: signIn))
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

        var tool: UsageTool?
        switch arguments["tool"] {
        case nil: break
        case let value as String:
            guard let parsed = UsageTool(rawValue: value.lowercased()) else {
                return .invalid("Invalid tool '\(value)': use \(UsageTool.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            tool = parsed
        default:
            return .invalid("tool must be one of \(UsageTool.allCases.map(\.rawValue).joined(separator: ", "))")
        }

        let limit: Int
        switch arguments["limit"] {
        case nil: limit = 20
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID()
            && value.doubleValue == value.doubleValue.rounded() && (1...200).contains(value.intValue):
            limit = value.intValue
        default:
            return .invalid("limit must be a whole number from 1 to 200")
        }

        var report = memo.report(window: window, since: since, ledger: app.ledger)
        if let tool { report = report.only(tool) }
        if !report.sources.isEmpty, report.sources.allSatisfy({ $0.state == .failed }) {
            return .failed(failureMessage(report.sources))
        }
        let rows = report.summaries(by: grouping)
        return encode(TokenUsageReport(
            window: window,
            since: since,
            grouping: grouping,
            tool: tool,
            rows: rows.prefix(limit).map(TokenUsageRow.init),
            omittedRows: max(0, rows.count - limit),
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

        let report = memo.report(window: window, since: since, ledger: app.ledger)
        if !report.sources.isEmpty, report.sources.allSatisfy({ $0.state == .failed }) {
            return .failed(failureMessage(report.sources))
        }

        let models = report.recentModels
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

/// The menu's levels: orange from 80%, red from 95%.
private enum QuotaLevel: String, Encodable {
    case ok, warning, critical

    init?(_ fraction: Double?) {
        guard let fraction else { return nil }
        if fraction >= TightestLimit.critical { self = .critical }
        else if fraction >= TightestLimit.threshold { self = .warning }
        else { self = .ok }
    }
}

private extension SnapshotIssue {
    var name: String {
        switch self {
        case .signInRequired: "signInRequired"
        case .notConnected: "notConnected"
        case .expiresSoon: "expiresSoon"
        }
    }

    var endsAt: Date? {
        if case .expiresSoon(let date) = self { return date }
        return nil
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
    let issue: String?
    let sessionEndsAt: Date?

    init(_ snapshot: UsageSnapshot, muted: Set<BucketKey>) {
        self.provider = snapshot.provider.rawValue
        self.account = snapshot.account
        self.title = snapshot.accountID.title
        self.state = snapshot.state.rawValue
        self.source = snapshot.source
        self.observedAt = snapshot.fetchedAt
        self.windows = snapshot.buckets.map {
            QuotaWindow($0, muted: muted.contains(BucketKey(account: snapshot.accountID, bucketID: $0.id)))
        }
        self.note = snapshot.message
        self.issue = snapshot.issue?.name
        self.sessionEndsAt = snapshot.issue?.endsAt
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
    let level: QuotaLevel
    let warningsMuted: Bool

    init(_ bucket: UsageBucket, muted: Bool) {
        self.id = bucket.id
        self.label = bucket.label
        self.unit = bucket.unit.rawValue
        self.used = bucket.used
        self.limit = bucket.limit
        self.remaining = bucket.remaining
        self.percentUsed = bucket.percentageUsed
        self.resetsAt = bucket.resetAt
        self.level = muted ? .ok : (QuotaLevel(bucket.fractionUsed) ?? .ok)
        self.warningsMuted = muted
    }
}

private struct LimitWarningsReport: Encodable {
    let generatedAt: Date
    let source = "Meter.app's cached last refresh on this Mac; no network request was made"
    let warnings: [LimitWarning]
    let signIn: [SignInNotice]

    init(generatedAt: Date, warnings: [LimitWarning], signIn: [SignInNotice]) {
        self.generatedAt = generatedAt
        self.warnings = warnings
        self.signIn = signIn
    }
}

private struct LimitWarning: Encodable {
    let provider: String
    let account: String?
    let title: String
    let window: String
    let label: String
    let percentUsed: Double
    let level: QuotaLevel
    let resetsAt: Date?
    let observedAt: Date
    let stale: Bool

    init(_ snapshot: UsageSnapshot, _ bucket: UsageBucket, level: QuotaLevel) {
        self.provider = snapshot.provider.rawValue
        self.account = snapshot.account
        self.title = snapshot.accountID.title
        self.window = bucket.id
        self.label = bucket.label
        self.percentUsed = bucket.percentageUsed ?? 0
        self.level = level
        self.resetsAt = bucket.resetAt
        self.observedAt = snapshot.fetchedAt
        self.stale = snapshot.state != .live
    }
}

private struct SignInNotice: Encodable {
    let provider: String
    let account: String?
    let title: String
    let issue: String
    let sessionEndsAt: Date?
    let fix: String?
    let message: String?

    init(_ snapshot: UsageSnapshot, issue: SnapshotIssue) {
        self.provider = snapshot.provider.rawValue
        self.account = snapshot.account
        self.title = snapshot.accountID.title
        self.issue = issue.name
        self.sessionEndsAt = issue.endsAt
        self.fix = snapshot.provider.signInFix?.instruction
        self.message = snapshot.message
    }
}

private struct TokenUsageReport: Encodable {
    let window: String
    let since: Date?
    let grouping: TokenGrouping
    let tool: UsageTool?
    let rows: [TokenUsageRow]
    let omittedRows: Int
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
    let excludingCacheReads: Int
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
        self.excludingCacheReads = summary.tokens.excludingCacheReads
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
    let excludingCacheReads: Int
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
        self.excludingCacheReads = tokens.excludingCacheReads
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

/// The ledger reads of the last half minute, by window. An agent asking for usage and then
/// for models, or asking twice, reads the logs once; a minute later it reads them again.
final class LedgerMemo: @unchecked Sendable {
    static let lifetime: TimeInterval = 30
    private var reports: [String: (at: Date, report: TokenLedgerReport)] = [:]
    private let lock = NSLock()

    func report(window: String, since: Date?, ledger: TokenLedger, now: Date = .now) -> TokenLedgerReport {
        if let hit = lock.withLock({ reports[window] }), now.timeIntervalSince(hit.at) < Self.lifetime {
            return hit.report
        }
        let report = ledger.read(since: since)
        lock.withLock { reports[window] = (now, report) }
        return report
    }
}
