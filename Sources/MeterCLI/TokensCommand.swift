import Foundation
import MeterCore

/// `meter tokens` and `meter models`: what the coding tools on this Mac spent, read from
/// their own logs.
enum TokensCommand {
    static func tokens(ledger: TokenLedger, window: String, grouping: TokenGrouping, json: Bool, now: Date = .now) -> CLIResult {
        guard let range = TokenWindowRange(window, now: now) else {
            return invalidWindow(window)
        }
        let report = ledger.read(since: range.since)
        let rows = report.summaries(by: grouping)
        let exitCode = exitCode(for: report)
        guard json else {
            return .init(standardOutput: text(report: report, rows: rows, range: range), standardError: "", exitCode: exitCode)
        }
        do {
            let envelope = TokensEnvelope(report: report, rows: rows, range: range, grouping: grouping, now: now)
            return .init(standardOutput: try encode(envelope), standardError: "", exitCode: exitCode)
        } catch {
            return .init(standardOutput: "", standardError: "Could not encode output: \(error.localizedDescription)", exitCode: 2)
        }
    }

    static func models(ledger: TokenLedger, window: String, json: Bool, now: Date = .now) -> CLIResult {
        guard let range = TokenWindowRange(window, now: now) else {
            return invalidWindow(window)
        }
        let report = ledger.read(since: range.since)
        let exitCode = exitCode(for: report)
        guard json else {
            return .init(standardOutput: modelsText(report: report, range: range, now: now), standardError: "", exitCode: exitCode)
        }
        do {
            let envelope = ModelsEnvelope(models: recentEntries(report), report: report, range: range, now: now)
            return .init(standardOutput: try encode(envelope), standardError: "", exitCode: exitCode)
        } catch {
            return .init(standardOutput: "", standardError: "Could not encode output: \(error.localizedDescription)", exitCode: 2)
        }
    }

    // MARK: - Text

    private static func text(report: TokenLedgerReport, rows: [TokenSummary], range: TokenWindowRange) -> String {
        var lines = ["Tokens · \(range.label)"]
        if rows.isEmpty {
            lines.append(emptyMessage(range))
            lines.append(checkedTools(report.sources))
        } else {
            lines += table(rows: rows, report: report)
        }
        lines += failures(report.sources)
        return lines.joined(separator: "\n")
    }

    private static func modelsText(report: TokenLedgerReport, range: TokenWindowRange, now: Date) -> String {
        var lines = ["Models · \(range.label)"]
        let recent = orderedRecentModels(report)
        if recent.isEmpty {
            lines.append(emptyMessage(range))
            lines.append(checkedTools(report.sources))
        } else {
            let toolWidth = recent.map(\.tool.title.count).max() ?? 0
            let modelWidth = recent.map(modelLabel).map(\.count).max() ?? 0
            for entry in recent {
                lines.append(
                    leftAligned(entry.tool.title, to: toolWidth)
                        + "  " + leftAligned(modelLabel(entry), to: modelWidth)
                        + "  " + age(entry.lastUsed, now: now) + " ago"
                )
                let others = otherModels(of: entry, in: report.records)
                guard !others.isEmpty else { continue }
                // The provider is named only where it differs from the one used last.
                let labels = others.map { $0.provider == entry.provider ? $0.model : "\($0.provider) / \($0.model)" }
                let nameWidth = labels.map(\.count).max() ?? 0
                for (label, other) in zip(labels, others) {
                    lines.append("  " + leftAligned(label, to: nameWidth) + "  " + responses(other.responses))
                }
            }
        }
        lines += failures(report.sources)
        return lines.joined(separator: "\n")
    }

    private static func table(rows: [TokenSummary], report: TokenLedgerReport) -> [String] {
        let totals = TokenTotals(report: report)
        let showCost = rows.contains { $0.costUSD != nil }
        var headers = ["Name", "Responses", "Input", "Cache read", "Cache write", "Output", "Total"]
        if showCost { headers.append("Cost") }

        var cells = rows.map { row -> [String] in
            var line = [
                row.key,
                String(row.responses),
                compactCount(row.tokens.input),
                compactCount(row.tokens.cacheRead),
                compactCount(row.tokens.cacheWrite),
                compactCount(row.tokens.output),
                compactCount(row.tokens.total),
            ]
            if showCost { line.append(cost(row.costUSD)) }
            return line
        }
        var totalLine = [
            "Total",
            String(totals.responses),
            compactCount(totals.input),
            compactCount(totals.cacheRead),
            compactCount(totals.cacheWrite),
            compactCount(totals.output),
            compactCount(totals.total),
        ]
        if showCost { totalLine.append(cost(totals.costUSD)) }
        cells.append(totalLine)

        var widths = headers.map(\.count)
        for row in cells {
            for (index, value) in row.enumerated() {
                widths[index] = max(widths[index], value.count)
            }
        }
        return ([headers] + cells).map { row in
            row.enumerated().map { index, value in
                index == 0 ? leftAligned(value, to: widths[index]) : rightAligned(value, to: widths[index])
            }.joined(separator: "  ")
        }
    }

    private static func emptyMessage(_ range: TokenWindowRange) -> String {
        range.raw == "all" ? "No token usage yet." : "No token usage in the \(range.label)."
    }

    private static func checkedTools(_ sources: [TokenSourceReport]) -> String {
        let titles = sources.map(\.tool.title)
        guard !titles.isEmpty else { return "Checked no tools." }
        return "Checked \(listing(titles))."
    }

    private static func listing(_ values: [String]) -> String {
        switch values.count {
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default: return values.dropLast().joined(separator: ", ") + " and " + values[values.count - 1]
        }
    }

    private static func failures(_ sources: [TokenSourceReport]) -> [String] {
        sources.compactMap { report in
            guard report.state == .failed else { return nil }
            return "\(report.tool.title) logs could not be read: \(report.message ?? "unknown error")"
        }
    }

    private static func orderedRecentModels(_ report: TokenLedgerReport) -> [RecentModel] {
        // `recentModels` leaves a tie between two tools in no particular order; the CLI has
        // to pick one so two runs print the same report.
        report.recentModels.sorted { lhs, rhs in
            if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed > rhs.lastUsed }
            return lhs.tool < rhs.tool
        }
    }

    private static func modelLabel(_ model: RecentModel) -> String {
        "\(model.provider) / \(model.model)"
    }

    private static func recentEntries(_ report: TokenLedgerReport) -> [RecentModelEntry] {
        orderedRecentModels(report).map { entry in
            RecentModelEntry(
                tool: entry.tool,
                provider: entry.provider,
                model: entry.model,
                lastUsed: entry.lastUsed,
                otherModels: otherModels(of: entry, in: report.records)
                    .map { ModelCount(provider: $0.provider, model: $0.model, responses: $0.responses) }
            )
        }
    }

    /// Models a tool used in the window other than the one it used last, largest first.
    ///
    /// The ledger groups by model across every tool, which would credit a model's uses in
    /// one tool to another, so the counts are taken from this tool's own records. The same
    /// model bought from another provider is another entry, as it is in `meter tokens`.
    private static func otherModels(of last: RecentModel, in records: [TokenRecord]) -> [(provider: String, model: String, responses: Int)] {
        struct Key: Hashable { let provider: String; let model: String }
        var counts: [Key: Int] = [:]
        for record in records where record.tool == last.tool
            && (record.provider, record.model) != (last.provider, last.model) {
            counts[Key(provider: record.provider, model: record.model), default: 0] += 1
        }
        return counts
            .map { (provider: $0.key.provider, model: $0.key.model, responses: $0.value) }
            .sorted { lhs, rhs in
                lhs.responses != rhs.responses ? lhs.responses > rhs.responses
                    : (lhs.model, lhs.provider) < (rhs.model, rhs.provider)
            }
    }

    private static func responses(_ count: Int) -> String {
        count == 1 ? "1 response" : "\(count) responses"
    }

    private static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    private static func leftAligned(_ value: String, to width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    private static func rightAligned(_ value: String, to width: Int) -> String {
        value.count >= width ? value : String(repeating: " ", count: width - value.count) + value
    }

    // MARK: - Numbers

    /// Three significant figures and a unit: `950`, `12.3k`, `4.56M`. Counts small enough
    /// to read at a glance stay exact, which is the case for most windows.
    static func compactCount(_ value: Int) -> String {
        TokenFormat.compact(value, fixedWidth: true)
    }

    /// A price as the tool recorded it, at the precision such prices are written in.
    private static func cost(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "$0.00" }
        if value >= 1 { return String(format: "$%.2f", value) }
        if value >= 0.01 { return String(format: "$%.3f", value) }
        return String(format: "$%.4f", value)
    }

    // MARK: - Exit status

    private static func exitCode(for report: TokenLedgerReport) -> Int32 {
        // A ledger with no sources read nothing rather than failed, so it is not an error.
        !report.sources.isEmpty && report.sources.allSatisfy { $0.state == .failed } ? 2 : 0
    }

    private static func invalidWindow(_ value: String) -> CLIResult {
        .init(
            standardOutput: "",
            standardError: "Invalid --since '\(value)': use a positive duration in m, h or d, or 'all'",
            exitCode: 64
        )
    }

    // MARK: - JSON

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// The window as it was typed, the start it resolves to, and the phrase the heading uses.
private struct TokenWindowRange {
    let raw: String
    let since: Date?
    let label: String

    init?(_ value: String, now: Date) {
        let raw = value.lowercased()
        guard let since = TokenWindow.since(raw, now: now) else { return nil }
        self.raw = raw
        self.since = since
        self.label = Self.label(for: raw)
    }

    private static func label(for value: String) -> String {
        guard value != "all" else { return "all time" }
        guard let unit = value.last, let amount = Int(value.dropLast()) else { return value }
        switch unit {
        case "m": return "last \(amount) \(amount == 1 ? "minute" : "minutes")"
        case "h": return "last \(amount) \(amount == 1 ? "hour" : "hours")"
        case "d": return "last \(amount) \(amount == 1 ? "day" : "days")"
        default: return value
        }
    }
}

private struct TokensRow: Encodable {
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

private struct TokensEnvelope: Encodable {
    let schemaVersion = 1
    let generatedAt: Date
    let window: String
    let since: Date?
    let grouping: TokenGrouping
    let rows: [TokensRow]
    let totals: TokenTotals
    let sources: [TokenSourceReport]

    init(report: TokenLedgerReport, rows: [TokenSummary], range: TokenWindowRange, grouping: TokenGrouping, now: Date) {
        self.generatedAt = now
        self.window = range.raw
        self.since = range.since
        self.grouping = grouping
        self.rows = rows.map(TokensRow.init)
        self.totals = TokenTotals(report: report)
        self.sources = report.sources
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, window, since, grouping, rows, totals, sources
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(window, forKey: .window)
        // An all-time window has no start, and a reader should not have to tell a missing
        // key from an omitted one.
        if let since {
            try container.encode(since, forKey: .since)
        } else {
            try container.encodeNil(forKey: .since)
        }
        try container.encode(grouping, forKey: .grouping)
        try container.encode(rows, forKey: .rows)
        try container.encode(totals, forKey: .totals)
        try container.encode(sources, forKey: .sources)
    }
}

private struct ModelCount: Encodable {
    let provider: String
    let model: String
    let responses: Int
}

private struct RecentModelEntry: Encodable {
    let tool: UsageTool
    let provider: String
    let model: String
    let lastUsed: Date
    let otherModels: [ModelCount]
}

private struct ModelsEnvelope: Encodable {
    let schemaVersion = 1
    let generatedAt: Date
    let window: String
    let since: Date?
    let models: [RecentModelEntry]
    let totals: TokenTotals
    let sources: [TokenSourceReport]

    init(models: [RecentModelEntry], report: TokenLedgerReport, range: TokenWindowRange, now: Date) {
        self.generatedAt = now
        self.window = range.raw
        self.since = range.since
        self.models = models
        self.totals = TokenTotals(report: report)
        self.sources = report.sources
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, window, since, models, totals, sources
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(window, forKey: .window)
        if let since {
            try container.encode(since, forKey: .since)
        } else {
            try container.encodeNil(forKey: .since)
        }
        try container.encode(models, forKey: .models)
        try container.encode(totals, forKey: .totals)
        try container.encode(sources, forKey: .sources)
    }
}
