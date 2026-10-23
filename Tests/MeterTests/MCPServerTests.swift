import Foundation
import Testing
@testable import MeterCLI
@testable import MeterCore

private struct TestEnvironment {
    let app: MeterCLIApplication
    let cache: UsageCache
    private let directory: URL
    private let suiteName: String

    init(service: UsageService = UsageService(providers: [:]), ledger: TokenLedger = .fixture) throws {
        let suiteName = "MeterMCPTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appending(path: "MeterMCP-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = UsageCache(fileURL: directory.appending(path: "usage-cache.json"))

        self.suiteName = suiteName
        self.directory = directory
        self.cache = cache
        self.app = MeterCLIApplication(
            service: service,
            settings: MeterSettings(defaults: defaults),
            secrets: SecretStore(fileURL: directory.appending(path: "credentials.json")),
            cache: cache,
            ledger: ledger
        )
    }

    func cleanup() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct FixedProvider: UsageProvider {
    let snapshot: UsageSnapshot
    var id: ProviderID { snapshot.provider }
    func fetch() async -> UsageSnapshot { snapshot }
}

private func reply(_ server: MCPServer, _ request: String) async throws -> [String: Any] {
    let line = await server.handle(request)
    let text = try #require(line)
    let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try #require(value as? [String: Any])
}

private func toolCall(
    _ server: MCPServer, _ name: String, arguments: [String: Any] = [:], id: Any = 1
) async throws -> [String: Any] {
    let request: [String: Any] = [
        "jsonrpc": "2.0", "id": id, "method": "tools/call",
        "params": ["name": name, "arguments": arguments],
    ]
    let data = try JSONSerialization.data(withJSONObject: request)
    return try await reply(server, String(decoding: data, as: UTF8.self))
}

private func resultObject(_ response: [String: Any]) throws -> [String: Any] {
    try #require(response["result"] as? [String: Any])
}

private func structured(_ response: [String: Any]) throws -> [String: Any] {
    let result = try resultObject(response)
    return try #require(result["structuredContent"] as? [String: Any])
}

private func isError(_ response: [String: Any]) throws -> Bool {
    let result = try resultObject(response)
    return try #require(result["isError"] as? Bool)
}

private func text(of response: [String: Any]) throws -> String {
    let result = try resultObject(response)
    let content = try #require(result["content"] as? [[String: Any]])
    return try #require(content.first?["text"] as? String)
}

private func errorCode(_ response: [String: Any]) -> Int? {
    (response["error"] as? [String: Any])?["code"] as? Int
}

// MARK: - Handshake

@Test func initializeNegotiatesAKnownProtocolVersion() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    for requested in ["2025-06-18", "2025-03-26", "2024-11-05"] {
        let response = try await reply(server, #"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(requested)"}}
        """#)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == requested)

        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "meter")
        #expect(info["version"] as? String == MeterCLIApplication.version)

        let capabilities = try #require(result["capabilities"] as? [String: Any])
        let tools = try #require(capabilities["tools"] as? [String: Any])
        #expect(tools["listChanged"] as? Bool == false)
        #expect((result["instructions"] as? String)?.contains("Meter") == true)
    }

    // A version the server does not speak, and a request that names none, get the latest.
    for params in [#"{"protocolVersion":"2099-01-01"}"#, "{}"] {
        let response = try await reply(server, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":\#(params)}"#)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
    }
}

@Test func notificationsGetNoReply() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let initialized = await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    #expect(initialized == nil)
    let cancelled = await server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#)
    #expect(cancelled == nil)
    // Even a method the server does not know is silent when it arrives as a notification.
    let unknown = await server.handle(#"{"jsonrpc":"2.0","method":"resources/list"}"#)
    #expect(unknown == nil)
}

@Test func pingAnswersWithAnEmptyResultAndEchoesEitherIdKind() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let stringID = try await reply(server, #"{"jsonrpc":"2.0","id":"ping-1","method":"ping"}"#)
    #expect(stringID["id"] as? String == "ping-1")
    #expect((stringID["result"] as? [String: Any])?.isEmpty == true)

    let numericID = try await reply(server, #"{"jsonrpc":"2.0","id":42,"method":"ping"}"#)
    #expect(numericID["id"] as? Int == 42)
}

// MARK: - Tools listing

@Test func toolsListNamesEveryToolWithASchema() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let response = try await reply(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
    let result = try #require(response["result"] as? [String: Any])
    let tools = try #require(result["tools"] as? [[String: Any]])
    #expect(tools.map { $0["name"] as? String } == ["get_quotas", "get_token_usage", "get_current_models"])

    for tool in tools {
        #expect((tool["description"] as? String)?.isEmpty == false)
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["properties"] as? [String: Any] != nil)
    }

    let quotas = try #require(tools.first)
    #expect((quotas["description"] as? String)?.contains("last refresh") == true)
    let quotaSchema = try #require(quotas["inputSchema"] as? [String: Any])
    let quotaProperties = try #require(quotaSchema["properties"] as? [String: Any])
    let providers = try #require(quotaProperties["providers"] as? [String: Any])
    #expect(providers["type"] as? String == "array")

    let tokens = try #require(tools[safe: 1])
    let tokenProperties = try #require((tokens["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
    let by = try #require(tokenProperties["by"] as? [String: Any])
    #expect(by["enum"] as? [String] == ["model", "provider", "tool", "provider-model"])
    let since = try #require(tokenProperties["since"] as? [String: Any])
    #expect(since["default"] as? String == "7d")
}

// MARK: - get_token_usage

@Test func tokenUsageSumsTheFixtureLogs() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let response = try await toolCall(server, "get_token_usage", arguments: ["since": "all"])
    let object = try structured(response)
    #expect(object["window"] as? String == "all")
    #expect(object["grouping"] as? String == "provider-model")
    #expect(object["since"] == nil)

    let rows = try #require(object["rows"] as? [[String: Any]])
    #expect(rows.count == 8)
    #expect(rows.first?["name"] as? String == "anthropic/claude-sonnet-5-5")
    #expect(rows.first?["provider"] as? String == "anthropic")
    #expect(rows.first?["model"] as? String == "claude-sonnet-5-5")
    #expect(rows.first?["total"] as? Int == 3_105)
    #expect(rows.first?["tool"] == nil)

    let legacy = try #require(rows.first { ($0["name"] as? String) == "openrouter/o-legacy" })
    #expect(legacy["responses"] as? Int == 2)
    #expect(legacy["total"] as? Int == 540)

    let totals = try #require(object["totals"] as? [String: Any])
    #expect(totals["responses"] as? Int == 9)
    #expect(totals["input"] as? Int == 1_822)
    #expect(totals["cacheRead"] as? Int == 7_500)
    #expect(totals["cacheWrite"] as? Int == 1_500)
    #expect(totals["output"] as? Int == 440)
    #expect(totals["total"] as? Int == 11_262)
    #expect((totals["costUSD"] as? Double).map { abs($0 - 0.0012) < 1e-9 } == true)

    let sources = try #require(object["sources"] as? [[String: Any]])
    #expect(sources.map { $0["tool"] as? String } == ["claude-code", "codex", "opencode"])
    #expect(sources.map { $0["state"] as? String } == ["ok", "ok", "ok"])
    #expect(sources.map { $0["recordCount"] as? Int } == [3, 4, 2])

    // The text block is the same object as structuredContent, as an agent would read it.
    let textBlock = try text(of: response)
    let parsed = try JSONSerialization.jsonObject(with: Data(textBlock.utf8))
    let fromText = try #require(parsed as? [String: Any])
    #expect(NSDictionary(dictionary: fromText).isEqual(to: object))
}

@Test func tokenUsageGroupsByTool() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let response = try await toolCall(server, "get_token_usage", arguments: ["since": "all", "by": "tool"])
    let object = try structured(response)
    #expect(object["grouping"] as? String == "tool")
    let rows = try #require(object["rows"] as? [[String: Any]])
    // Largest first: Claude Code 6,202 tokens, OpenCode 2,950, Codex 2,110.
    #expect(rows.map { $0["name"] as? String } == ["claude-code", "opencode", "codex"])
    #expect(rows.map { $0["tool"] as? String } == ["claude-code", "opencode", "codex"])
    #expect(rows.first?["provider"] == nil)
    #expect(rows.first?["total"] as? Int == 6_202)
}

@Test func tokenUsageUsesSevenDaysByDefault() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let response = try await toolCall(server, "get_token_usage")
    let object = try structured(response)
    let result = try resultObject(response)
    #expect(object["window"] as? String == "7d")
    #expect((object["rows"] as? [[String: Any]]) != nil)
    #expect(result["isError"] == nil)
}

@Test func aToolThatRunsButFailsReturnsAnErrorResult() async throws {
    let environment = try TestEnvironment(ledger: TokenLedger(sources: [
        FixedTokenSource(tool: .codex, failure: "unreadable"),
    ]))
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let response = try await toolCall(server, "get_token_usage", arguments: ["since": "all"])
    let failed = try isError(response)
    let result = try resultObject(response)
    #expect(failed)
    #expect(result["structuredContent"] == nil)
    let explanation = try text(of: response)
    #expect(explanation.contains("Codex: unreadable"))

    let models = try await toolCall(server, "get_current_models", arguments: ["since": "all"])
    let modelsFailed = try isError(models)
    #expect(modelsFailed)
}

// MARK: - get_current_models

@Test func currentModelsListsTheLatestModelAndEverythingUsed() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let response = try await toolCall(server, "get_current_models", arguments: ["since": "all"])
    let object = try structured(response)
    #expect(object["window"] as? String == "all")
    let models = try #require(object["models"] as? [[String: Any]])
    // Claude Code and OpenCode tie on the most recent response; the tool order breaks it.
    #expect(models.map { $0["tool"] as? String } == ["claude-code", "opencode", "codex"])

    let claude = try #require(models.first)
    #expect(claude["provider"] as? String == "anthropic")
    #expect(claude["model"] as? String == "claude-haiku-5-5")
    #expect(claude["lastUsed"] as? String == "2026-10-21T09:00:00Z")
    let claudeModels = try #require(claude["usedModels"] as? [[String: Any]])
    #expect(claudeModels.compactMap { $0["model"] as? String } == ["claude-haiku-5-5", "claude-opus-5-5", "claude-sonnet-5-5"])
    #expect(claudeModels.compactMap { $0["responses"] as? Int } == [1, 1, 1])

    let codex = try #require(models.last)
    #expect(codex["model"] as? String == "o-legacy")
    let codexModels = try #require(codex["usedModels"] as? [[String: Any]])
    #expect(codexModels.compactMap { $0["model"] as? String } == ["o-legacy", "gpt-6-luna", "gpt-6.1-sol"])
    #expect(codexModels.compactMap { $0["responses"] as? Int } == [2, 1, 1])
}

// MARK: - get_quotas

@Test func quotasReadTheCachedObservationAndNeverRefresh() async throws {
    // A provider that would answer 99% if anything refreshed: the tool must not ask it.
    let service = UsageService(providers: [.claude: FixedProvider(snapshot: UsageSnapshot(
        provider: .claude,
        buckets: [.init(id: "week", label: "Weekly", used: 99, limit: 100, remaining: 1, resetAt: nil, unit: .percent)],
        fetchedAt: .now, source: "network", state: .live, message: nil
    ))])
    let environment = try TestEnvironment(service: service)
    defer { environment.cleanup() }
    let reset = Date.now.addingTimeInterval(3_600)
    try environment.cache.save([UsageSnapshot(
        provider: .claude,
        buckets: [.init(id: "hour", label: "5-hour", used: 35, limit: 100, remaining: 65, resetAt: reset, unit: .percent)],
        fetchedAt: .now, source: "test", state: .live, message: nil
    )])
    let server = MCPServer(app: environment.app)

    let response = try await toolCall(server, "get_quotas", arguments: ["providers": ["claude"]])
    let object = try structured(response)
    #expect((object["source"] as? String)?.contains("no network request") == true)
    let accounts = try #require(object["accounts"] as? [[String: Any]])
    #expect(accounts.count == 1)
    let claude = try #require(accounts.first)
    #expect(claude["provider"] as? String == "claude")
    #expect(claude["title"] as? String == "Claude")
    #expect(claude["account"] == nil)
    #expect(claude["state"] as? String == "live")
    let windows = try #require(claude["windows"] as? [[String: Any]])
    #expect(windows.count == 1)
    let window = try #require(windows.first)
    #expect(window["label"] as? String == "5-hour")
    #expect(window["unit"] as? String == "percent")
    #expect(window["used"] as? Double == 35)
    #expect(window["limit"] as? Double == 100)
    #expect(window["remaining"] as? Double == 65)
    #expect(window["percentUsed"] as? Double == 35)
    #expect(window["resetsAt"] is String)
    // The cache is authoritative even though the provider stub would say 99.
    #expect(window["used"] as? Double != 99)
}

@Test func quotasNameProvidersThatHaveNoCachedObservation() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    try environment.cache.save([UsageSnapshot(
        provider: .claude,
        buckets: [.init(id: "hour", label: "5-hour", used: 10, limit: 100, remaining: 90, resetAt: nil, unit: .percent)],
        fetchedAt: .now, source: "test", state: .live, message: nil
    )])
    let server = MCPServer(app: environment.app)

    let response = try await toolCall(server, "get_quotas", arguments: ["providers": ["claude", "codex"]])
    let object = try structured(response)
    let accounts = try #require(object["accounts"] as? [[String: Any]])
    #expect(accounts.count == 2)
    #expect(accounts.map { $0["provider"] as? String } == ["claude", "codex"])
    let codex = try #require(accounts.last)
    #expect(codex["state"] as? String == "unavailable")
    #expect((codex["windows"] as? [[String: Any]])?.isEmpty == true)
    #expect(codex["note"] as? String != nil)
}

@Test func quotasWithoutACacheFailWithAnExplanation() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let response = try await toolCall(server, "get_quotas", arguments: ["providers": ["claude"]])
    let failed = try isError(response)
    let result = try resultObject(response)
    #expect(failed)
    #expect(result["structuredContent"] == nil)
    let explanation = try text(of: response)
    #expect(explanation.contains("Meter.app"))
}

// MARK: - Errors

@Test func unknownToolsAndMethodsAreProtocolErrors() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let unknownTool = try await toolCall(server, "get_everything")
    #expect(errorCode(unknownTool) == -32602)
    #expect(unknownTool["result"] == nil)

    let unknownMethod = try await reply(server, #"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#)
    #expect(errorCode(unknownMethod) == -32601)
    #expect(unknownMethod["id"] as? Int == 9)
}

@Test func malformedJSONIsAParseErrorWithANullID() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let line = await server.handle("{not json")
    let text = try #require(line)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(object["id"] is NSNull)
    #expect(errorCode(object) == -32700)
}

@Test func badToolParametersAreInvalidParams() async throws {
    let environment = try TestEnvironment()
    defer { environment.cleanup() }
    let server = MCPServer(app: environment.app)

    let badSince = try await toolCall(server, "get_token_usage", arguments: ["since": "7w"])
    #expect(errorCode(badSince) == -32602)
    #expect(((badSince["error"] as? [String: Any])?["message"] as? String)?.contains("since") == true)

    let badGrouping = try await toolCall(server, "get_token_usage", arguments: ["by": "session"])
    #expect(errorCode(badGrouping) == -32602)

    let badProvider = try await toolCall(server, "get_quotas", arguments: ["providers": ["nope"]])
    #expect(errorCode(badProvider) == -32602)

    let noName = try await reply(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"arguments":{}}}"#)
    #expect(errorCode(noName) == -32602)

    let badArguments = try await reply(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_quotas","arguments":[]}}"#)
    #expect(errorCode(badArguments) == -32602)
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
