import SwiftUI
import MeterCore

/// How far back the token view looks.
enum TokenRange: String, CaseIterable, Identifiable {
    case day = "24h"
    case week = "7d"
    case month = "30d"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: "24h"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    var phrase: String {
        switch self {
        case .day: "in the last 24 hours"
        case .week: "in the last 7 days"
        case .month: "in the last 30 days"
        }
    }
}

/// The coding tools' token logs, read off the main thread.
///
/// Reading is file work - a thousand session logs on a busy Mac - so it never runs inside a
/// view update, and a read finished for one range does not land on top of another.
@MainActor
@Observable
final class TokenStore {
    private(set) var report: TokenLedgerReport?
    private(set) var isLoading = false
    var range: TokenRange = .week {
        didSet { if range != oldValue { Task { await load() } } }
    }

    private let ledger: TokenLedger
    private var loaded: (range: TokenRange, at: Date)?
    private var generation = 0
    /// The range a read is running for, so opening the menu twice does not read twice.
    private var inFlight: TokenRange?

    init(ledger: TokenLedger = .default) {
        self.ledger = ledger
    }

    /// Reloads unless this range was read within the last minute, which is about how often
    /// anyone opening the menu could want it.
    func load(force: Bool = false) async {
        if !force, let loaded, loaded.range == range, Date.now.timeIntervalSince(loaded.at) < 60 {
            // A read for another range may still be running; it must not land on this one.
            generation += 1
            inFlight = nil
            isLoading = false
            return
        }
        if inFlight == range, !force { return }
        generation += 1
        let mine = generation
        let ledger = ledger
        let range = range
        let since = TokenWindow.since(range.rawValue) ?? nil
        isLoading = true
        inFlight = range
        let report = await Task.detached(priority: .utility) { ledger.read(since: since) }.value
        guard mine == generation else { return }
        inFlight = nil
        self.report = report
        loaded = (range, .now)
        isLoading = false
    }
}

/// What the coding tools on this Mac spent, and on which models.
struct TokensView: View {
    @Bindable var tokens: TokenStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Range", selection: $tokens.range) {
                    ForEach(TokenRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer()
                if let report = tokens.report, !report.records.isEmpty {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(TokenFormat.compact(report.total.excludingCacheReads)) tokens")
                            .font(.callout.weight(.semibold))
                        Text("+ \(TokenFormat.compact(report.total.cacheRead)) cache reads")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .monospacedDigit()
                    .help("Input, cache writes and output. Cache reads - the context re-read on every turn - are counted apart.")
                }
            }

            if let report = tokens.report {
                if report.records.isEmpty {
                    emptyState(report)
                } else {
                    NowUsing(models: report.recentModels)
                    ModelBreakdown(summaries: report.summaries(by: .providerModel))
                }
                failures(report)
            } else {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func emptyState(_ report: TokenLedgerReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No token usage \(tokens.range.phrase).")
                .font(.callout)
            Text("Checked \(report.sources.map(\.tool.title).joined(separator: ", ")).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func failures(_ report: TokenLedgerReport) -> some View {
        ForEach(report.sources.filter { $0.state == .failed }, id: \.tool) { source in
            Label("\(source.tool.title) logs could not be read", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(source.message ?? "")
        }
    }
}

/// The model each tool answered with last: the "which model am I on" question.
private struct NowUsing: View {
    let models: [RecentModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Last used")
            ForEach(models, id: \.tool) { model in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.tool.title)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.model).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Text(model.provider).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.ago(model.lastUsed, now: context.date))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
            }
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// Tokens per model and where it was bought, largest first, each against the largest.
private struct ModelBreakdown: View {
    let summaries: [TokenSummary]

    var body: some View {
        let summaries = summaries.sorted { $0.tokens.excludingCacheReads > $1.tokens.excludingCacheReads }
        let largest = max(summaries.first?.tokens.excludingCacheReads ?? 1, 1)
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("By model")
            ForEach(summaries, id: \.key) { summary in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary.model ?? summary.key)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(summary.provider ?? "")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let cost = summary.costUSD {
                            Text(String(format: "$%.2f", cost))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text(TokenFormat.compact(summary.tokens.excludingCacheReads))
                            .monospacedDigit()
                            .fontWeight(.medium)
                    }
                    .font(.callout)
                    GeometryReader { proxy in
                        Capsule().fill(MeterStyle.track)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.55))
                                    .frame(width: max(3, proxy.size.width * Double(summary.tokens.excludingCacheReads) / Double(largest)))
                            }
                    }
                    .frame(height: 4)
                }
                .help(Self.detail(summary))
                .accessibilityElement(children: .combine)
            }
        }
    }

    static func detail(_ summary: TokenSummary) -> String {
        let t = summary.tokens
        return [
            "\(summary.responses) responses",
            "input \(TokenFormat.compact(t.input))",
            "cache read \(TokenFormat.compact(t.cacheRead))",
            "cache write \(TokenFormat.compact(t.cacheWrite))",
            "output \(TokenFormat.compact(t.output))",
        ].joined(separator: " · ")
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
