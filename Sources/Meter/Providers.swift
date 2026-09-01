import Foundation

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
    let id = ProviderID.codex

    func fetch() async -> UsageSnapshot {
        do {
            let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
            let auth = try JSONDecoder().decode(CodexAuth.self, from: Data(contentsOf: url))
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

enum CodexUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw URLError(.cannotParseResponse) }
        var buckets: [UsageBucket] = []
        appendWindow(root["rate_limit"] as? [String: Any], prefix: "rate", to: &buckets)
        appendWindow(root["code_review_rate_limit"] as? [String: Any], prefix: "review", to: &buckets)
        if let credits = root["credits"] as? [String: Any] {
            let balance = number(credits["balance"])
            buckets.append(.init(id: "credits", label: "Credits", used: nil, limit: nil, remaining: balance, resetAt: nil, unit: .credits))
        }
        guard !buckets.isEmpty else { throw URLError(.cannotParseResponse) }
        return .init(provider: .codex, buckets: buckets, fetchedAt: now, source: "Codex wham/usage", state: .live, message: nil)
    }

    private static func appendWindow(_ value: [String: Any]?, prefix: String, to output: inout [UsageBucket]) {
        guard let value else { return }
        for (key, label) in [("primary_window", "5-hour"), ("secondary_window", "Weekly")] {
            guard let window = value[key] as? [String: Any] else { continue }
            let used = number(window["used_percent"])
            let reset = number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            output.append(.init(id: "\(prefix)-\(key)", label: label, used: used, limit: 100, remaining: used.map { 100 - $0 }, resetAt: reset, unit: .percent))
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

struct DeepSeekUsageProvider: UsageProvider {
    let id = ProviderID.deepSeek

    func fetch() async -> UsageSnapshot {
        guard let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty else {
            return .unavailable(id, "Set DEEPSEEK_API_KEY")
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

enum AsideBridgeError: LocalizedError {
    case executableNotFound
    case timedOut
    case failed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "Aside CLI not found"
        case .timedOut: "Aside collector timed out"
        case .failed(let message): "Aside collector failed: \(message)"
        case .invalidResponse: "Aside returned an invalid response"
        }
    }
}

struct AsideBridge: Sendable {
    private static let marker = "METER_JSON:"

    func fetchJSON(script: String) async throws -> Data {
        let executable = try executableURL()
        return try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["repl", script]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(20)
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()

            let text = String(decoding: data, as: UTF8.self)
            if process.terminationStatus != 0, Date() >= deadline { throw AsideBridgeError.timedOut }
            guard process.terminationStatus == 0 else {
                throw AsideBridgeError.failed(Self.sanitizedFailure(text))
            }
            guard let markerRange = text.range(of: Self.marker, options: .backwards) else {
                throw AsideBridgeError.invalidResponse
            }
            let payload = text[markerRange.upperBound...].prefix { $0 != "\n" && $0 != "\r" }
            guard let envelopeData = String(payload).data(using: .utf8),
                  let envelope = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
                  let status = envelope["status"] as? Int else {
                throw AsideBridgeError.invalidResponse
            }
            if status == 401 || status == 403 {
                throw AsideBridgeError.failed("sign in to the provider in Aside Browser")
            }
            guard (200..<300).contains(status) else {
                throw AsideBridgeError.failed("provider returned HTTP \(status)")
            }
            guard let body = envelope["body"] else { throw AsideBridgeError.invalidResponse }
            return try JSONSerialization.data(withJSONObject: body)
        }.value
    }

    private func executableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["ASIDE_CLI_PATH"],
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/aside").path,
            "/opt/homebrew/bin/aside",
            "/usr/local/bin/aside",
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AsideBridgeError.executableNotFound
        }
        return URL(fileURLWithPath: path)
    }

    private static func sanitizedFailure(_ output: String) -> String {
        if output.localizedCaseInsensitiveContains("sign in") { return "sign in to Aside Browser" }
        if output.localizedCaseInsensitiveContains("fetch failed") { return "Aside Browser is unavailable" }
        return "open the provider page in Aside and verify the session"
    }
}

struct CursorUsageProvider: UsageProvider {
    let id = ProviderID.cursor
    private let bridge = AsideBridge()

    func fetch() async -> UsageSnapshot {
        do {
            let script = #"const p=await openTab('https://cursor.com/dashboard/spending'); const x=await p.evaluate(async()=>{const r=await fetch('/api/dashboard/get-current-period-usage',{method:'POST',headers:{'content-type':'application/json'},body:'{}'}); return {status:r.status,body:await r.json()}}); console.log('METER_JSON:'+JSON.stringify(x))"#
            return try CursorUsageParser.parse(await bridge.fetchJSON(script: script))
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
        if let spend = root["spendLimitUsage"] as? [String: Any], let cents = number(spend["totalSpend"]) {
            buckets.append(.init(id: "on-demand", label: "On-demand spend", used: cents / 100, limit: nil, remaining: nil, resetAt: nil, unit: .usd))
        }
        guard !buckets.isEmpty else { throw URLError(.cannotParseResponse) }
        let resetAt = milliseconds(root["billingCycleEnd"])
        buckets = buckets.map { bucket in
            .init(id: bucket.id, label: bucket.label, used: bucket.used, limit: bucket.limit, remaining: bucket.remaining, resetAt: resetAt, unit: bucket.unit)
        }
        return .init(provider: .cursor, buckets: buckets, fetchedAt: now, source: "Cursor Spending via Aside", state: .live, message: nil)
    }

    private static func appendPercent(_ value: Any?, id: String, label: String, to output: inout [UsageBucket]) {
        guard let used = number(value) else { return }
        output.append(.init(id: id, label: label, used: used, limit: 100, remaining: max(0, 100 - used), resetAt: nil, unit: .percent))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func milliseconds(_ value: Any?) -> Date? {
        number(value).map { Date(timeIntervalSince1970: $0 / 1_000) }
    }
}

struct CommandCodeUsageProvider: UsageProvider {
    let id = ProviderID.commandCode
    private let bridge = AsideBridge()

    func fetch() async -> UsageSnapshot {
        do {
            let script = #"const p=await openTab('https://commandcode.ai/studio'); const x=await p.evaluate(async()=>{const [c,s]=await Promise.all([fetch('https://api.commandcode.ai/internal/billing/credits',{credentials:'include'}),fetch('https://api.commandcode.ai/internal/usage/summary',{credentials:'include'})]); return {status:c.ok&&s.ok?200:500,body:{credits:await c.json(),summary:await s.json()}}}); console.log('METER_JSON:'+JSON.stringify(x))"#
            return try CommandCodeUsageParser.parse(await bridge.fetchJSON(script: script))
        } catch {
            return .unavailable(id, "Command Code unavailable: \(error.localizedDescription)")
        }
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
        if let remaining = number(credits["monthlyCredits"]), let used = number(summary["totalMonthlyCredits"]) {
            buckets.append(.init(id: "monthly", label: "Monthly credits", used: used, limit: used + remaining, remaining: remaining, resetAt: nil, unit: .credits))
        }
        appendWindow(windows["fiveHour"] as? [String: Any], id: "five-hour", label: "5-hour", to: &buckets)
        appendWindow(windows["weekly"] as? [String: Any], id: "weekly", label: "Weekly", to: &buckets)
        guard !buckets.isEmpty else { throw URLError(.cannotParseResponse) }
        return .init(provider: .commandCode, buckets: buckets, fetchedAt: now, source: "Command Code usage via Aside", state: .live, message: nil)
    }

    private static func appendWindow(_ value: [String: Any]?, id: String, label: String, to output: inout [UsageBucket]) {
        guard let value, let used = number(value["used"]), let cap = number(value["cap"]) else { return }
        let resetMilliseconds = number(value["resetAt"]).flatMap { $0 > 0 ? $0 : nil }
        output.append(.init(id: id, label: label, used: used, limit: cap, remaining: max(0, cap - used), resetAt: resetMilliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }, unit: .credits))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
