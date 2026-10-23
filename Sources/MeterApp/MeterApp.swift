import AppKit
import SwiftUI
import MeterCore

@main
struct MeterApp: App {
    @State private var store = UsageStore()
    @State private var hotKey: GlobalHotKey?

    var body: some Scene {
        MenuBarExtra {
            MeterMenu(store: store)
        } label: {
            // Back to the one form that actually paints. MenuBarExtra reserves space for an
            // arbitrary label view without drawing it, and Text(Image(systemName:)) drew the
            // number but not the symbol - the menu bar was left showing a bare "100%" next to
            // the battery's own, which reads as no Meter at all.
            Label("Meter", systemImage: icon)
                .task {
                    if hotKey == nil { hotKey = .openMenu { MenuBarToggle.toggle() } }
                    store.start()
                }
        }
        .menuBarExtraStyle(.window)
    }

    private var icon: String {
        if store.isAllUnavailable { return "exclamationmark.triangle" }
        guard let usage = store.highestUsage else { return "gauge.with.dots.needle.0percent" }
        if usage >= 0.95 { return "gauge.with.dots.needle.100percent" }
        if usage >= TightestLimit.threshold { return "gauge.with.dots.needle.67percent" }
        return "gauge.with.dots.needle.33percent"
    }
}

private struct MeterMenu: View {
    @Bindable var store: UsageStore
    @State private var drag = CardDrag()
    @State private var cardsHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            MenuHeader(store: store)
            // Every tile is one fixed size, so the menu's height follows only from how many
            // providers are on: it no longer grows and shrinks as they answer or fail, and it
            // has no empty band of window below the last tile. It scrolls only when the tiles
            // outgrow the screen.
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    TileGrid(store: store, drag: drag, animation: reorderAnimation, moveByKeyboard: moveByKeyboard)
                    HiddenProviders(store: store)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(cardsHeight, maxCardsHeight))
            Divider()
            MenuFooter()
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .topLeading) { liftedTile }
        .coordinateSpace(.named(CardDrag.space))
        // Opening the menu is the moment a keychain dialog is welcome; the five-minute
        // refresh never raises one.
        .background(MenuOpenObserver { Task { await store.menuOpened() } })
    }
}

extension MeterMenu {
    /// What is left of the screen once the header and footer are placed.
    private var maxCardsHeight: CGFloat {
        max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 160)
    }

    /// The tile being carried, drawn at full size under the pointer with a shadow to show
    /// it is off the grid.
    @ViewBuilder private var liftedTile: some View {
        if let account = drag.account, let frame = drag.liftedFrame {
            ProviderTile(account: account, store: store, drag: drag, animation: nil, lifted: true)
                .frame(width: frame.width, height: frame.height)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: MeterStyle.tileRadius))
                .overlay(RoundedRectangle(cornerRadius: MeterStyle.tileRadius).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var reorderAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }

    /// Steps past switched-off providers, which have no tile, so every move is one you see.
    private func moveByKeyboard(_ account: Account, by step: Int) {
        let visible = store.order.filter(store.enabled)
        guard let index = visible.firstIndex(of: account), visible.indices.contains(index + step) else { return }
        withAnimation(reorderAnimation) { store.move(account, to: visible[index + step]) }
    }
}

private struct MenuHeader: View {
    @Bindable var store: UsageStore

    var body: some View {
        HStack(spacing: 8) {
            // Relative, because the question is "how old is this", and a clock time made the
            // reader do the subtraction against the clock in the corner of the screen.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(updatedText(now: context.date))
            }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small) }
            Button { Task { await store.refreshAll(interactive: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh all")
            .accessibilityLabel("Refresh all")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func updatedText(now: Date) -> String {
        guard let last = store.lastRefresh else { return "Not updated yet" }
        if now.timeIntervalSince(last) < 60 { return "Updated just now" }
        return "Updated \(last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
    }
}

private struct MenuFooter: View {
    @State private var loginItemFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if LoginItem.isAvailable {
                    Toggle("Launch at login", isOn: Binding(
                        get: { LoginItem.isEnabled },
                        set: { newValue in
                            do {
                                try LoginItem.setEnabled(newValue)
                                loginItemFailure = nil
                            } catch {
                                loginItemFailure = error.localizedDescription
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
                Spacer()
                // The shortcut was in the README and nowhere on screen.
                Text("⌃⌥M").foregroundStyle(.tertiary).help("Opens and closes Meter from anywhere")
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
            }
            if let loginItemFailure {
                Text(loginItemFailure).foregroundStyle(.red)
            }
        }
        .controlSize(.small)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Grid

/// Enabled providers as tiles of one size, two to a row. An odd one out keeps its size
/// rather than stretching across the row.
private struct TileGrid: View {
    @Bindable var store: UsageStore
    let drag: CardDrag
    let animation: Animation?
    let moveByKeyboard: (Account, Int) -> Void

    var body: some View {
        let visible = store.order.filter(store.enabled)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(visible) { account in
                ProviderTile(account: account, store: store, drag: drag, animation: animation)
                    // The carried tile leaves an empty place behind: the tile itself is
                    // what moves under the pointer, and a faded copy made it look like two.
                    .opacity(drag.account == account ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CardDrag.space)) } action: {
                        drag.frames[account] = $0
                    }
                    .accessibilityAction(named: "Move up") { moveByKeyboard(account, -1) }
                    .accessibilityAction(named: "Move down") { moveByKeyboard(account, 1) }
            }
        }
    }
}

/// Switched-off providers, as chips to switch them back on. They have nothing to show, so
/// they do not get a tile, and a row of checkboxes among the figures was the noisiest thing
/// in the old menu.
private struct HiddenProviders: View {
    @Bindable var store: UsageStore

    var body: some View {
        let hidden = store.order.filter { !store.enabled($0) }
        if !hidden.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(hidden) { account in
                    Button { store.setEnabled(true, for: account) } label: {
                        Label(account.title, systemImage: "plus")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Show \(account.title)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Left-to-right, wrapping onto a new line when the next item would not fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let placed = place(subviews, width: width)
        return CGSize(width: placed.map(\.maxX).max() ?? 0, height: placed.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

// MARK: - Tile

private struct ProviderTile: View {
    let account: Account
    @Bindable var store: UsageStore
    let drag: CardDrag
    let animation: Animation?
    /// The copy drawn under the pointer during a drag: no drag surface of its own.
    var lifted = false

    private var snapshot: UsageSnapshot? { store.snapshots[account] }
    private var severity: Severity { Severity(snapshot?.buckets.compactMap(\.fractionUsed).max()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let snapshot, !snapshot.buckets.isEmpty {
                    TileContent(buckets: snapshot.buckets)
                        .opacity(snapshot.state == .stale || isIdle(snapshot) ? 0.55 : 1)
                    if snapshot.state == .stale { staleNote(snapshot) }
                } else {
                    Text(snapshot?.message ?? "Waiting for refresh…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(store.needsKey(account) ? 3 : 6)
                        .help(snapshot?.message ?? "")
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .overlay { if !lifted { dragSurface } }
            // Outside the drag surface: a drag that starts on a text field or a button
            // took the click away from it whenever the pointer drifted a point.
            if store.needsKey(account) {
                KeyField(provider: account.provider, store: store)
            }
        }
        .padding(12)
        .frame(height: MeterStyle.tileHeight)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: MeterStyle.tileRadius))
        .overlay {
            // A tile at its limit is outlined, so it is found before any figure is read.
            if let color = severity.color {
                RoundedRectangle(cornerRadius: MeterStyle.tileRadius).strokeBorder(color.opacity(0.7), lineWidth: 1)
            }
        }
        .contextMenu {
            Button("Refresh \(account.title)") { Task { await store.refresh(account, interactive: true) } }
            Button("Hide \(account.title)") { store.setEnabled(false, for: account) }
        }
    }

    /// Every window at zero with no reset scheduled: an account that has not been used,
    /// which should not look as present as one that is working.
    private func isIdle(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.buckets.allSatisfy { $0.fractionUsed == 0 && $0.resetAt == nil }
    }

    private var header: some View {
        Text(account.title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Figures that stopped updating used to differ from fresh ones by a faint icon whose
    /// explanation was only a tooltip. The age is now written on the tile.
    private func staleNote(_ snapshot: UsageSnapshot) -> some View {
        Label {
            Text("From \(snapshot.fetchedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
        } icon: {
            Image(systemName: "clock.badge.exclamationmark")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(snapshot.message ?? "Showing the last figures that arrived.")
    }

    /// Covers the title and the figures, so the tile can be picked up anywhere but its controls.
    private var dragSurface: some View {
        CardDragSource(
            account: account,
            help: snapshot?.state == .stale ? (snapshot?.message ?? "Showing the last figures that arrived.") : nil,
            onBegin: { point in drag.begin(account, at: point, store: store) },
            onMove: { point in drag.moved(to: point, store: store, animation: animation) },
            onEnd: { dropped in drag.finish(store: store, commit: dropped, animation: animation) }
        )
        .accessibilityHidden(true)
    }
}

/// The arcs and the headline figure, then every window on a line of its own.
private struct TileContent: View {
    let buckets: [UsageBucket]

    /// The windows the arcs draw: the fullest first, outermost, so the arc that matters is
    /// the longest one.
    private var arcs: [UsageBucket] {
        Array(buckets.filter { $0.fractionUsed != nil }
            .sorted { $0.fractionUsed! > $1.fractionUsed! }
            .prefix(MeterStyle.maxArcs))
    }

    /// The windows that get a line of their own: all of them when they fit, otherwise the
    /// fullest first, keeping one line for the count of the rest.
    private var listed: [UsageBucket] {
        guard buckets.count > MeterStyle.maxRows else { return buckets }
        let kept = Set(buckets.sorted { ($0.fractionUsed ?? -1) > ($1.fractionUsed ?? -1) }
            .prefix(MeterStyle.maxRows - 1).map(\.id))
        return buckets.filter { kept.contains($0.id) }
    }

    private var folded: [UsageBucket] {
        let shown = Set(listed.map(\.id))
        return buckets.filter { !shown.contains($0.id) }
    }

    /// The fullest window, or, for an account measured only in money, its first figure.
    private var headline: UsageBucket? { arcs.first ?? buckets.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if !arcs.isEmpty {
                    ArcGauge(fractions: arcs.map { $0.fractionUsed ?? 0 })
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                }
                if let headline {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UsageFormat.value(headline))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Severity(headline.fractionUsed).color ?? .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        // The reset is also on the window's own line below, so it is the
                        // part to give up when a narrow tile cannot fit both.
                        ViewThatFits(in: .horizontal) {
                            Text(caption(headline))
                            Text(headline.label).truncationMode(.tail)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            }
            // One figure is already the headline; listing it again under itself says nothing.
            if buckets.count > 1 {
                VStack(spacing: 3) {
                    ForEach(listed) { bucket in
                        WindowRow(bucket: bucket, arcIndex: arcs.firstIndex { $0.id == bucket.id })
                    }
                    if !folded.isEmpty {
                        Text("+\(folded.count) more")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 12)
                            .help(folded.map { "\($0.label): \(UsageFormat.value($0))" }.joined(separator: "\n"))
                    }
                }
            }
        }
    }

    private func caption(_ bucket: UsageBucket) -> String {
        guard let reset = UsageFormat.reset(bucket) else { return bucket.label }
        return "\(bucket.label) · \(reset)"
    }
}

/// One window: the dot that names its arc, label, figure, reset.
private struct WindowRow: View {
    let bucket: UsageBucket
    let arcIndex: Int?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(arcIndex.map { MeterStyle.arcColor($0, fraction: bucket.fractionUsed) } ?? .clear)
                .frame(width: 6, height: 6)
            Text(bucket.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(UsageFormat.value(bucket))
                .monospacedDigit()
                .fontWeight(.medium)
                .foregroundStyle(Severity(bucket.fractionUsed).color ?? .primary)
                .lineLimit(1)
            Text(UsageFormat.reset(bucket) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .font(.caption)
        .help(UsageFormat.detail(bucket))
        .accessibilityElement(children: .combine)
    }
}

/// Up to three concentric 270° arcs, open at the bottom like a dial, outermost first.
private struct ArcGauge: View {
    let fractions: [Double]

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                ForEach(Array(fractions.enumerated()), id: \.offset) { index, fraction in
                    let inset = CGFloat(index) * (MeterStyle.arcWidth + MeterStyle.arcGap)
                    let used = min(max(fraction, 0), 1)
                    ZStack {
                        arc(to: 1).stroke(MeterStyle.track, style: stroke)
                        // A sliver even at zero, so an empty window still shows where it starts.
                        arc(to: max(used, 0.015)).stroke(MeterStyle.arcColor(index, fraction: fraction), style: stroke)
                    }
                    .padding(inset + MeterStyle.arcWidth / 2)
                }
            }
            .frame(width: size, height: size)
        }
    }

    private var stroke: StrokeStyle { StrokeStyle(lineWidth: MeterStyle.arcWidth, lineCap: .round) }

    /// From the lower left, over the top, to the lower right.
    private func arc(to fraction: Double) -> some Shape {
        Circle()
            .trim(from: 0, to: MeterStyle.arcSweep * fraction)
            .rotation(.degrees(90 + (1 - MeterStyle.arcSweep) * 180))
    }
}

/// How close a window is to its limit, as the one thing colour is allowed to say.
private enum Severity {
    case calm, warning, critical

    init(_ fraction: Double?) {
        guard let fraction else { self = .calm; return }
        if fraction >= 0.95 { self = .critical }
        else if fraction >= TightestLimit.threshold { self = .warning }
        else { self = .calm }
    }

    var color: Color? {
        switch self {
        case .calm: nil
        case .warning: MeterStyle.warning
        case .critical: MeterStyle.critical
        }
    }
}

/// The tile design's tokens. Arcs are drawn in three steps of the label colour, so every
/// colour that is not grey means a limit is close: orange from 80%, red from 95%.
enum MeterStyle {
    static let tileRadius: CGFloat = 12
    /// Fits the title, the arcs and three windows. Every tile is this tall whatever it holds,
    /// so a tile picked up and put down elsewhere never reflows the grid around it.
    static let tileHeight: CGFloat = 168
    /// Windows listed under the arcs before the rest fold into a "+N more" line.
    static let maxRows = 3
    static let maxArcs = 3
    /// Of a full circle; 1 draws closed rings.
    static let arcSweep = 0.75
    static let arcWidth: CGFloat = 5
    static let arcGap: CGFloat = 2
    static let track = Color.primary.opacity(0.1)
    static let warning = Color(nsColor: .systemOrange)
    static let critical = Color(nsColor: .systemRed)
    private static let arcSteps: [Double] = [0.85, 0.55, 0.32]

    static func arcColor(_ index: Int, fraction: Double?) -> Color {
        Severity(fraction).color ?? Color.primary.opacity(arcSteps[min(index, arcSteps.count - 1)])
    }
}

private struct KeyField: View {
    let provider: ProviderID
    @Bindable var store: UsageStore
    @State private var key = ""
    @State private var failure: String?

    private var hasKey: Bool { store.hasStoredKey(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField(hasKey ? "Replace key" : "API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button("Save") {
                    do {
                        try store.storeKey(key, for: provider)
                        key = ""
                        failure = nil
                    } catch {
                        // Keep what was typed: the save is what failed, not the key.
                        failure = error.localizedDescription
                    }
                }
                .controlSize(.small)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .font(.caption)
    }
}
