import AppKit
import MeterCore
import SwiftUI

/// The compact tiles' numbers, kept in one place so the grid's cell and the drawings inside
/// it cannot drift apart.
enum CompactStyle {
    /// One cell of the standard grid. A 2×1 tile is two cells wide and one tall (176 × 80),
    /// a 1×2 one cell wide and two tall (84 × 168).
    static let cellWidth: CGFloat = 84
    static let cellHeight: CGFloat = 80
    static let gap: CGFloat = 8
    /// Half the full tile's 12 pt: a 2×1 tile has only 64 pt to draw in.
    static let padding: CGFloat = 8

    static func width(for size: TileSize) -> CGFloat {
        CGFloat(size.columns) * cellWidth + CGFloat(size.columns - 1) * gap
    }

    static func height(for size: TileSize) -> CGFloat {
        CGFloat(size.rows) * cellHeight + CGFloat(size.rows - 1) * gap
    }
}

extension TileSize {
    /// The sizes an account is offered. A figure measured only in money has no dial, and a
    /// 1×2 tile is a dial above a figure, so money keeps to the two wide sizes.
    static func offered(for snapshot: UsageSnapshot?) -> [TileSize] {
        let moneyOnly = snapshot.map { !$0.buckets.isEmpty && $0.buckets.allSatisfy { $0.fractionUsed == nil } } ?? false
        return moneyOnly ? [.full, .short] : TileSize.allCases
    }
}

/// Opens the settings window from inside a tile. The menu supplies it: the window needs the
/// alert and hot-key objects, which only the menu holds. Previews and the gallery leave it
/// out, and a tile then draws its hint as plain text.
private struct OpenMeterSettingsKey: EnvironmentKey {
    static let defaultValue: (@Sendable @MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var openMeterSettings: (@Sendable @MainActor () -> Void)? {
        get { self[OpenMeterSettingsKey.self] }
        set { self[OpenMeterSettingsKey.self] = newValue }
    }
}

/// What a compact tile says when it has more to explain than to draw: one line, with the
/// whole message on hover.
struct CompactNotice: Equatable {
    enum Kind: Equatable {
        case signIn
        case connect
        case ends
        case message
        case waiting
        case needsKey
        case stale
    }

    let kind: Kind
    let text: String
    /// The tooltip: the instruction, the provider's message and, for old figures, their age.
    let detail: String

    /// Orange only for the one thing that is the reader's to fix.
    var isWarning: Bool { kind == .signIn }
    var isNeedsKey: Bool { kind == .needsKey }

    /// In the order that matters: a key that was never stored is the whole story, then a
    /// credential problem, then why there is no figure to show, then how old it is.
    static func find(_ snapshot: UsageSnapshot?, account: Account, needsKey: Bool) -> CompactNotice? {
        let provider = account.provider
        if needsKey {
            return CompactNotice(kind: .needsKey, text: "Add key…",
                                 detail: snapshot?.message ?? "Paste an API key in Settings.")
        }
        guard let snapshot else {
            return CompactNotice(kind: .waiting, text: "Waiting…",
                                 detail: "Meter has not heard from \(provider.title) yet.")
        }
        if let issue = snapshot.issue {
            let detail = IssueRow.detail(provider: provider, issue: issue, snapshot: snapshot)
            switch issue {
            case .signInRequired:
                return CompactNotice(kind: .signIn, text: "⚠ Sign in again", detail: detail)
            case .notConnected:
                return CompactNotice(kind: .connect, text: "Connect", detail: detail)
            case .expiresSoon(let date):
                // `.numeric` already reads "in 5 hr.", so the line says "Ends in 5 hr.".
                let relative = date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
                return CompactNotice(kind: .ends, text: "Ends \(relative)", detail: detail)
            }
        }
        if snapshot.state == .unavailable {
            let line = snapshot.message?.split(separator: "\n").first.map(String.init)
            return CompactNotice(kind: .message, text: line ?? "Unavailable",
                                 detail: snapshot.message ?? "Meter could not read this account.")
        }
        if snapshot.buckets.isEmpty {
            return CompactNotice(kind: .waiting, text: "Waiting…",
                                 detail: snapshot.message ?? "Meter has not heard from \(provider.title) yet.")
        }
        if snapshot.state == .stale {
            let relative = snapshot.fetchedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
            return CompactNotice(kind: .stale, text: "From \(relative)",
                                 detail: snapshot.message ?? "Showing the last figures that arrived.")
        }
        return nil
    }
}

/// The one line a compact tile has for a problem. Outside the drag surface, so "Add key…"
/// is a click the tile cannot mistake for the start of a drag.
struct CompactNoticeLine: View {
    let notice: CompactNotice
    var openSettings: (@Sendable @MainActor () -> Void)?

    var body: some View {
        Group {
            if notice.isNeedsKey, let openSettings {
                Button { openSettings() } label: { Text(notice.text) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Opens Settings to paste an API key")
            } else if notice.isWarning {
                Text(notice.text)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            } else {
                Text(notice.text)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .truncationMode(.tail)
        // The 1×2 tile is 68 pt wide inside its padding; "Sign in again" needs the last
        // point of that width more than it needs to stay at ten.
        .minimumScaleFactor(0.8)
        .help(notice.detail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The 2×1 and 1×2 tiles' figures. The same rules as `TileContent`, with room for one dial
/// and one window: a muted window never colours the tile, and the headline is the fullest
/// window still warned about.
struct CompactTileContent: View {
    let account: Account
    @Bindable var store: UsageStore
    let size: TileSize
    /// False when the problem line below has taken the caption's place.
    var showsCaption = true

    private var snapshot: UsageSnapshot? { store.snapshots[account] }
    private var muted: Set<String> {
        Set(store.muted.filter { $0.account == account }.map(\.bucketID))
    }
    /// Fullest first, as `TileContent` draws the arcs; a compact tile has room for the first.
    private var windows: [UsageBucket] {
        (snapshot?.buckets ?? []).filter { $0.fractionUsed != nil }
            .sorted { $0.fractionUsed! > $1.fractionUsed! }
    }
    private var headline: UsageBucket? {
        windows.first { !muted.contains($0.id) } ?? windows.first ?? snapshot?.buckets.first
    }
    private var isMuted: Bool { headline.map { muted.contains($0.id) } ?? false }
    private var alarm: Double? { isMuted ? nil : headline?.fractionUsed }
    private var hasDial: Bool { headline?.fractionUsed != nil }

    var body: some View {
        Group {
            if size == .narrow { narrow } else { short }
        }
    }

    private var short: some View {
        HStack(alignment: .top, spacing: 8) {
            if let headline, hasDial {
                dial(headline, size: 40)
                    .opacity(dimmed ? 0.55 : 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                name(fontSize: 12, truncation: .tail)
                if let headline {
                    VStack(alignment: .leading, spacing: 1) {
                        // Money has no dial and no reset, so its one line of two is the
                        // figure itself, set larger and bold.
                        figure(headline, size: 20, weight: hasDial ? .semibold : .bold)
                        if showsCaption, hasDial { caption(headline, lines: 1) }
                    }
                    .opacity(dimmed ? 0.55 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var narrow: some View {
        VStack(spacing: 3) {
            name(fontSize: 11, truncation: .middle)
            if let headline {
                VStack(spacing: 3) {
                    if hasDial { dial(headline, size: 54) }
                    // A money figure does not get the dial's 19 pt: it already carries the
                    // currency and the word "left".
                    figure(headline, size: hasDial ? 19 : 15, weight: .semibold)
                    if showsCaption { caption(headline, lines: 2) }
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .opacity(dimmed ? 0.55 : 1)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func name(fontSize: CGFloat, truncation: Text.TruncationMode) -> some View {
        Text(account.title)
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .truncationMode(truncation)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func figure(_ bucket: UsageBucket, size: CGFloat, weight: Font.Weight) -> some View {
        Text(UsageFormat.value(bucket))
            .font(.system(size: size, weight: weight, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Severity(alarm).color ?? .primary)
            .strikethrough(isMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func caption(_ bucket: UsageBucket, lines: Int) -> some View {
        Text(captionText(bucket))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(lines)
            .truncationMode(.tail)
            .help(UsageFormat.detail(bucket))
    }

    private func captionText(_ bucket: UsageBucket) -> String {
        guard let reset = UsageFormat.reset(bucket) else { return bucket.label }
        return "\(bucket.label) · \(reset)"
    }

    private func dial(_ bucket: UsageBucket, size: CGFloat) -> some View {
        ArcGauge(
            fractions: [bucket.fractionUsed ?? 0],
            alarms: [isMuted ? nil : bucket.fractionUsed],
            dimmed: [isMuted]
        )
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The same fade `TileContent` gets for figures that stopped updating, or an account
    /// that has not been used at all.
    private var dimmed: Bool {
        guard let snapshot, !snapshot.buckets.isEmpty else { return false }
        return snapshot.state == .stale
            || snapshot.buckets.allSatisfy { $0.fractionUsed == 0 && $0.resetAt == nil }
    }
}
