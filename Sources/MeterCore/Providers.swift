import Foundation

/// One numeric reader for every parser here. There were five copies and they had begun to
/// drift apart.
private func numericValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

/// Names a rate-limit window from its length. Both Codex paths use this, because naming
/// the same window differently depending on which one answered is how a weekly limit came
/// to be shown as a five-hour one.
func codexWindowLabel(minutes: Double?) -> String {
    guard let minutes else { return "Limit" }
    switch Int(minutes) {
    case 300: return "5-hour"
    case 10_080: return "Weekly"
    default:
        if minutes.truncatingRemainder(dividingBy: 1_440) == 0 { return "\(Int(minutes / 1_440))-day" }
        if minutes.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(minutes / 60))-hour" }
        return "\(Int(minutes))-minute"
    }
}

enum ProviderHTTPError: LocalizedError, Equatable {
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        // A 404 is how a private route announces it has moved; collapsing it into a generic
        // failure hid exactly the signal worth acting on.
        case .unexpectedStatus(let code): "provider returned HTTP \(code)"
        }
    }
}

/// Credentials belong to the host that issued them, which is what the README promises.
/// URLSession would otherwise replay the Authorization and Cookie headers to wherever a
/// 3xx points.
private final class SameHostRedirectsOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let origin = task.originalRequest?.url?.host, request.url?.host == origin else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct CodexAuth: Decodable {
    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
    let tokens: Tokens
}

struct CodexUsageProvider: UsageProvider {
    static var authFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
    }

    let id = ProviderID.codex

    func fetch() async -> UsageSnapshot {
        if let snapshot = try? await CodexAppServerBridge().fetch() {
            return snapshot
        }
        return await fetchFromBackend()
    }

    private func fetchFromBackend() async -> UsageSnapshot {
        do {
            let auth = try JSONDecoder().decode(CodexAuth.self, from: Data(contentsOf: CodexUsageProvider.authFile))
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.timeoutInterval = 15
            request.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = auth.tokens.accountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return try CodexUsageParser.parse(data)
        } catch {
            return .unavailable(id, "Codex usage unavailable: \(error.localizedDescription)")
        }
    }
}

enum CodexAppServerError: LocalizedError {
    case executableNotFound
    case timedOut
    case failed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "Codex app or CLI not found"
        case .timedOut: "Codex app-server timed out"
        case .failed: "Codex app-server failed"
        case .invalidResponse: "Codex app-server returned an invalid response"
        }
    }
}

struct CodexAppServerBridge: Sendable {
    func fetch() async throws -> UsageSnapshot {
        let executable = try executableURL()
        return try await Task.detached {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["app-server", "--stdio"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()

            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            defer {
                timeout.cancel()
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
            }

            var buffer = Data()
            func response(id: Int) throws -> Data {
                while true {
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              (envelope["id"] as? NSNumber)?.intValue == id else { continue }
                        if envelope["error"] != nil { throw CodexAppServerError.failed }
                        return line
                    }

                    // Read even after the process exits so its final response cannot be lost.
                    let chunk = output.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { throw CodexAppServerError.invalidResponse }
                    buffer.append(chunk)
                }
            }

            func send(_ message: String) throws {
                try input.fileHandleForWriting.write(contentsOf: Data((message + "\n").utf8))
            }

            try send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"Meter","version":"1"},"capabilities":{"experimentalApi":true}}}"#)
            _ = try response(id: 1)
            try send(#"{"id":2,"method":"account/rateLimits/read","params":null}"#)
            let line = try response(id: 2)
            return try CodexAppServerUsageParser.parse(line)
        }.value
    }

    func executableURL() throws -> URL {
        guard let url = Self.locateExecutable() else { throw CodexAppServerError.executableNotFound }
        return url
    }

    /// Shared with `meter doctor` so it checks the path a fetch actually takes.
    static func locateExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_CLI_PATH"],
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appending(path: ".local/bin/codex").path,
            home.appending(path: ".local/share/mise/shims/codex").path,
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}

enum CodexAppServerUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = envelope["result"] as? [String: Any] else {
            throw CodexAppServerError.invalidResponse
        }
        let byID = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        let limits: [(String, [String: Any])]
        if byID.isEmpty, let defaultLimit = result["rateLimits"] as? [String: Any] {
            limits = [(defaultLimit["limitId"] as? String ?? "codex", defaultLimit)]
        } else {
            limits = byID.sorted { $0.key < $1.key }
        }

        var buckets: [UsageBucket] = []
        for (limitID, limit) in limits {
            let name = limit["limitName"] as? String
            appendWindow(limit["primary"] as? [String: Any], id: "\(limitID)-primary", name: name, to: &buckets)
            appendWindow(limit["secondary"] as? [String: Any], id: "\(limitID)-secondary", name: name, to: &buckets)
        }
        guard !buckets.isEmpty else { throw CodexAppServerError.invalidResponse }
        return .init(provider: .codex, buckets: buckets, fetchedAt: now, source: "Codex app-server", state: .live, message: nil)
    }

    private static func appendWindow(_ window: [String: Any]?, id: String, name: String?, to output: inout [UsageBucket]) {
        guard let window, let used = numericValue(window["usedPercent"]) else { return }
        let minutes = numericValue(window["windowDurationMins"])
        let windowName = codexWindowLabel(minutes: minutes)
        let label = name.map { "\($0) \(windowName)" } ?? windowName
        let reset = numericValue(window["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
        output.append(.init(id: id, label: label, used: used, limit: 100, remaining: max(0, 100 - used), resetAt: reset, unit: .percent))
    }


}

enum CodexUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw URLError(.cannotParseResponse) }
        var buckets: [UsageBucket] = []
        appendWindow(root["rate_limit"] as? [String: Any], prefix: "codex", to: &buckets)
        appendWindow(root["code_review_rate_limit"] as? [String: Any], prefix: "code_review", labelPrefix: "Code review", to: &buckets)
        for (index, additional) in (root["additional_rate_limits"] as? [[String: Any]] ?? []).enumerated() {
            let name = additional["limit_name"] as? String ?? "Additional limit"
            let feature = additional["metered_feature"] as? String ?? String(index)
            appendWindow(additional["rate_limit"] as? [String: Any], prefix: feature, labelPrefix: name, to: &buckets)
        }
        if let credits = root["credits"] as? [String: Any] {
            let balance = numericValue(credits["balance"])
            buckets.append(.init(id: "credits", label: "Credits", used: nil, limit: nil, remaining: balance, resetAt: nil, unit: .credits))
        }
        guard !buckets.isEmpty else { throw URLError(.cannotParseResponse) }
        return .init(provider: .codex, buckets: buckets, fetchedAt: now, source: "Codex wham/usage", state: .live, message: nil)
    }

    private static func appendWindow(_ value: [String: Any]?, prefix: String, labelPrefix: String? = nil, to output: inout [UsageBucket]) {
        guard let value else { return }
        for key in ["primary_window", "secondary_window"] {
            guard let window = value[key] as? [String: Any] else { continue }
            let used = numericValue(window["used_percent"])
            let reset = numericValue(window["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            // The response reports the window length; the old code assumed primary meant
            // five hours, which mislabelled every weekly limit it fell back to.
            let minutes = numericValue(window["limit_window_seconds"]).map { $0 / 60 }
            let windowLabel = codexWindowLabel(minutes: minutes)
            let label = labelPrefix.map { "\($0) \(windowLabel)" } ?? windowLabel
            // Same id the app-server path produces, so the alert tracker and any --json
            // consumer see one stable key whichever path answered.
            let suffix = key == "primary_window" ? "primary" : "secondary"
            output.append(.init(
                id: "\(prefix)-\(suffix)",
                label: label,
                used: used,
                limit: 100,
                remaining: used.map { max(0, 100 - $0) },
                resetAt: reset,
                unit: .percent
            ))
        }
    }
}

struct DeepSeekUsageProvider: UsageProvider {
    static let environmentKey = "DEEPSEEK_API_KEY"

    let id = ProviderID.deepSeek
    private let store: SecretStore
    private let environment: [String: String]
    private let account: Account

    init(
        store: SecretStore = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        account: Account = Account(.deepSeek)
    ) {
        self.store = store
        self.environment = environment
        self.account = account
    }

    /// The environment variable wins so existing shell setups keep working; the stored key
    /// is what lets the app find one when launched from Finder, which inherits no shell.
    /// A named account has only its stored key.
    func apiKey() -> String? {
        if account.name == nil, let key = environment[Self.environmentKey], !key.isEmpty { return key }
        return store.secret(for: account)
    }

    func fetch() async -> UsageSnapshot {
        guard let key = apiKey() else {
            return .unavailable(id, "No API key. Run 'meter set-key deepseek' or paste one in the Meter menu.")
        }
        do {
            var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
            request.timeoutInterval = 15
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            return try DeepSeekUsageParser.parse(data)
        } catch {
            return .unavailable(id, "DeepSeek unavailable: \(error.localizedDescription)")
        }
    }
}

enum DeepSeekUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let infos = root?["balance_infos"] as? [[String: Any]] ?? []
        let buckets = infos.compactMap { info -> UsageBucket? in
            guard let currency = info["currency"] as? String,
                  let balance = Double(info["total_balance"] as? String ?? "") else { return nil }
            return .init(id: currency, label: "Balance (\(currency))", used: nil, limit: nil, remaining: balance, resetAt: nil, unit: currency == "USD" ? .usd : .credits)
        }
        guard !buckets.isEmpty else { throw URLError(.cannotParseResponse) }
        return .init(provider: .deepSeek, buckets: buckets, fetchedAt: now, source: "DeepSeek Balance API", state: .live, message: nil)
    }
}

/// Issues an authenticated JSON request using headers from a `CredentialSource`.
enum AuthenticatedRequest {
    static func json(
        _ url: String,
        method: String = "GET",
        body: Data? = nil,
        origin: String? = nil,
        referer: String? = nil,
        credential: any CredentialSource,
        signInAt: String,
        timeout: TimeInterval = 15
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        // Send only the credential's cookies; nothing from the shared cookie store.
        request.httpShouldHandleCookies = false
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        for (field, value) in try credential.authHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await URLSession.shared.data(for: request, delegate: SameHostRedirectsOnly())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:
            credential.invalidate()
            throw CredentialError.signInRequired(signInAt)
        default: throw ProviderHTTPError.unexpectedStatus(http.statusCode)
        }
    }
}

struct CursorUsageProvider: UsageProvider {
    let id = ProviderID.cursor
    private let credential: any CredentialSource

    init(credential: any CredentialSource = CursorSessionCredential()) {
        self.credential = credential
    }

    func fetch() async -> UsageSnapshot {
        do {
            let data = try await AuthenticatedRequest.json(
                "https://cursor.com/api/dashboard/get-current-period-usage",
                method: "POST",
                body: Data("{}".utf8),
                // Cursor refuses state-changing requests whose Origin does not match.
                origin: "https://cursor.com",
                referer: "https://cursor.com/dashboard/spending",
                credential: credential,
                signInAt: "cursor.com"
            )
            return try CursorUsageParser.parse(data)
        } catch {
            return .unavailable(id, "Cursor unavailable: \(error.localizedDescription)")
        }
    }
}

enum CursorUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["planUsage"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var buckets: [UsageBucket] = []
        appendPercent(usage["autoPercentUsed"], id: "cursor-models", label: "Cursor Models", to: &buckets)
        appendPercent(usage["apiPercentUsed"], id: "other-models", label: "Other Models", to: &buckets)
        // Cursor moved totalSpend from spendLimitUsage into planUsage; read both so the
        // bucket does not silently disappear when the dashboard shape changes again.
        let spendSources = [usage, root["spendLimitUsage"] as? [String: Any]].compactMap { $0 }
        if let cents = spendSources.lazy.compactMap({ numericValue($0["totalSpend"]) }).first {
            // Deliberately no limit: planUsage.limit is the plan's included allowance, while
            // totalSpend also counts the bonus usage Cursor grants on top, so dividing one by
            // the other reports several hundred percent and would peg the menu bar gauge.
            buckets.append(.init(id: "spend", label: "Total spend", used: cents / 100, limit: nil, remaining: nil, resetAt: nil, unit: .usd))
        }
        guard !buckets.isEmpty else { throw URLError(.cannotParseResponse) }
        let resetAt = milliseconds(root["billingCycleEnd"])
        buckets = buckets.map { bucket in
            .init(id: bucket.id, label: bucket.label, used: bucket.used, limit: bucket.limit, remaining: bucket.remaining, resetAt: resetAt, unit: bucket.unit)
        }
        return .init(provider: .cursor, buckets: buckets, fetchedAt: now, source: "Cursor dashboard", state: .live, message: nil)
    }

    private static func appendPercent(_ value: Any?, id: String, label: String, to output: inout [UsageBucket]) {
        guard let used = numericValue(value) else { return }
        output.append(.init(id: id, label: label, used: used, limit: 100, remaining: max(0, 100 - used), resetAt: nil, unit: .percent))
    }


    private static func milliseconds(_ value: Any?) -> Date? {
        numericValue(value).map { Date(timeIntervalSince1970: $0 / 1_000) }
    }
}

/// OpenCode has no documented usage API for Go. This is the route its own console reads,
/// which answers to the plan's API key; it may change without notice.
struct OpenCodeGoUsageProvider: UsageProvider {
    let id = ProviderID.openCodeGo
    private let credential: any CredentialSource

    init(credential: any CredentialSource = OpenCodeGoCredential()) {
        self.credential = credential
    }

    func fetch() async -> UsageSnapshot {
        do {
            let data = try await AuthenticatedRequest.json(
                "https://opencode.ai/zen/go/v1/usage", credential: credential, signInAt: "opencode.ai"
            )
            return try OpenCodeGoUsageParser.parse(data)
        } catch {
            return .unavailable(id, "OpenCode Go unavailable: \(error.localizedDescription)")
        }
    }
}

enum OpenCodeGoUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let windows = [("rolling", "five-hour", "5-hour"), ("weekly", "weekly", "Weekly"), ("monthly", "monthly", "Monthly")]
        let buckets: [UsageBucket] = windows.compactMap { key, id, label in
            guard let window = usage[key] as? [String: Any], let percent = numericValue(window["percent"]) else { return nil }
            let resetAt = (window["resetsAt"] as? String).flatMap(Self.date)
            return .init(id: id, label: label, used: percent, limit: 100, remaining: max(0, 100 - percent), resetAt: resetAt, unit: .percent)
        }
        guard !buckets.isEmpty else { throw URLError(.cannotParseResponse) }
        return .init(provider: .openCodeGo, buckets: buckets, fetchedAt: now, source: "OpenCode Go usage", state: .live, message: nil)
    }

    /// With and without fractional seconds: the weekly reset came back as "…T00:00:00.000Z".
    private static func date(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct CommandCodeUsageProvider: UsageProvider {
    let id = ProviderID.commandCode
    private let credential: any CredentialSource

    init(credential: any CredentialSource = CommandCodeAPIKeyCredential()) {
        self.credential = credential
    }

    func fetch() async -> UsageSnapshot {
        do {
            // The same routes Command Code's own CLI calls, with the same API key.
            // Two independent reads; sequential awaits doubled the worst case to 30s.
            async let credits = request("https://api.commandcode.ai/alpha/billing/credits")
            async let summary = request("https://api.commandcode.ai/alpha/usage/summary")
            let combined = try JSONSerialization.data(withJSONObject: [
                "credits": try JSONSerialization.jsonObject(with: try await credits),
                "summary": try JSONSerialization.jsonObject(with: try await summary),
            ])
            return try CommandCodeUsageParser.parse(combined)
        } catch {
            return .unavailable(id, "Command Code unavailable: \(error.localizedDescription)")
        }
    }

    private func request(_ url: String) async throws -> Data {
        try await AuthenticatedRequest.json(url, credential: credential, signInAt: "commandcode.ai")
    }
}

enum CommandCodeUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let creditsRoot = root["credits"] as? [String: Any],
              let credits = creditsRoot["credits"] as? [String: Any],
              let windows = creditsRoot["windowLimits"] as? [String: Any],
              let summary = root["summary"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var buckets: [UsageBucket] = []
        if let remaining = numericValue(credits["monthlyCredits"]), let used = numericValue(summary["totalMonthlyCredits"]) {
            // The allowance is not reported, only the balance and what this billing period has
            // spent, so the cap has to be inferred from the pair - and that only holds while
            // both describe the same period. Once the balance reaches zero the period has
            // rolled: spend resets to near nothing while the balance stays at 0, and the sum
            // collapses to a cap of a hundredth of a credit that reads as 100% used against a
            // few thousandths actually spent. A balance with no cap is the honest answer there.
            let cap = remaining > 0 ? used + remaining : nil
            buckets.append(.init(
                id: "monthly",
                label: "Monthly credits",
                used: cap == nil ? nil : used,
                limit: cap,
                remaining: remaining,
                resetAt: nil,
                unit: .credits
            ))
        }
        appendWindow(windows["fiveHour"] as? [String: Any], id: "five-hour", label: "5-hour", to: &buckets)
        appendWindow(windows["weekly"] as? [String: Any], id: "weekly", label: "Weekly", to: &buckets)
        guard !buckets.isEmpty else { throw URLError(.cannotParseResponse) }
        return .init(provider: .commandCode, buckets: buckets, fetchedAt: now, source: "Command Code API", state: .live, message: nil)
    }

    private static func appendWindow(_ value: [String: Any]?, id: String, label: String, to output: inout [UsageBucket]) {
        guard let value, let used = numericValue(value["used"]), let cap = numericValue(value["cap"]) else { return }
        let resetMilliseconds = numericValue(value["resetAt"]).flatMap { $0 > 0 ? $0 : nil }
        output.append(.init(id: id, label: label, used: used, limit: cap, remaining: max(0, cap - used), resetAt: resetMilliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }, unit: .credits))
    }

}

struct ClaudeUsageProvider: UsageProvider {
    let id = ProviderID.claude
    private let credential: any CredentialSource

    init(credential: any CredentialSource = ClaudeSubscriptionCredential()) {
        self.credential = credential
    }

    func fetch() async -> UsageSnapshot {
        do {
            let data = try await AuthenticatedRequest.json(
                "https://api.anthropic.com/api/oauth/usage",
                credential: credential,
                signInAt: "claude.ai"
            )
            return try ClaudeUsageParser.parse(data)
        } catch {
            return .unavailable(id, "Claude unavailable: \(error.localizedDescription)")
        }
    }
}

enum ClaudeUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        // Read the windows from `limits`. It is self-describing, unlike the codenamed
        // top-level keys next to it, which come and go as plans change.
        var buckets: [UsageBucket] = []
        for limit in root["limits"] as? [[String: Any]] ?? [] {
            guard let kind = limit["kind"] as? String, let percent = numericValue(limit["percent"]) else { continue }
            let scope = limit["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            // Two limits of the same kind can differ only by surface; without it they collide
            // into one SwiftUI id, one alert key and one notification.
            let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                ?? scope?["surface"] as? String
            buckets.append(.init(
                id: [kind, model, surface].compactMap { $0 }.joined(separator: "-").lowercased(),
                label: label(kind: kind, model: model),
                used: percent,
                limit: 100,
                remaining: max(0, 100 - percent),
                resetAt: date(limit["resets_at"]),
                unit: .percent
            ))
        }

        if let spend = root["spend"] as? [String: Any],
           spend["enabled"] as? Bool == true,
           let used = spend["used"] as? [String: Any],
           let minor = numericValue(used["amount_minor"]) {
            let exponent = numericValue(used["exponent"]) ?? 2
            buckets.append(.init(
                id: "spend",
                label: "Extra usage",
                used: minor / pow(10, exponent),
                limit: numericValue(spend["limit"]).map { $0 / pow(10, exponent) },
                remaining: nil,
                resetAt: nil,
                unit: .usd
            ))
        }

        guard !buckets.isEmpty else { throw URLError(.cannotParseResponse) }
        return .init(provider: .claude, buckets: buckets, fetchedAt: now, source: "Claude account usage", state: .live, message: nil)
    }

    private static func label(kind: String, model: String?) -> String {
        let base: String
        switch kind {
        case "session": base = "Session"
        case "weekly_all", "weekly_scoped": base = "Weekly"
        default: base = kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return model.map { "\(base) (\($0))" } ?? base
    }

    /// `resets_at` is RFC 3339, sometimes with fractional seconds and sometimes without.
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: text) ?? plain.date(from: text)
    }

}
