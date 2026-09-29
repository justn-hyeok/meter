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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Once per render rather than once per row: every row compares against it.
        let tightest = store.tightestLimit
        VStack(spacing: 0) {
            HStack {
                Text("Meter").font(.headline)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await store.refreshAll(interactive: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
            }
            .padding(14)

            Divider()
            VStack(spacing: 8) {
                ForEach(store.order) { account in
                    ProviderCard(account: account, store: store, tightest: tightest, drag: drag, animation: reorderAnimation)
                        // The carried card leaves an empty place behind: the card itself is what
                        // moves under the pointer, and a faded copy made it look like two.
                        .opacity(drag.account == account ? 0 : 1)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CardDrag.space)) } action: {
                            drag.frames[account] = $0
                        }
                        .accessibilityAction(named: "Move up") { moveByKeyboard(account, by: -1) }
                        .accessibilityAction(named: "Move down") { moveByKeyboard(account, by: 1) }
                }
            }
            .padding(12)
            MeterLegend().padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            SettingsRows(store: store)
            Divider()
            HStack {
                Text(store.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not updated")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
            }
            .font(.caption)
            .padding(12)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .topLeading) { liftedCard }
        .coordinateSpace(.named(CardDrag.space))
        // Opening the menu is the moment a keychain dialog is welcome; the five-minute
        // refresh never raises one.
        .background(MenuOpenObserver { Task { await store.menuOpened() } })
    }

}

extension MeterMenu {
    /// The card being carried, drawn at full size under the pointer with a shadow to show
    /// it is off the list. It moves only up and down, the one direction the list reorders.
    @ViewBuilder private var liftedCard: some View {
        if let account = drag.account, let frame = drag.liftedFrame {
            ProviderCard(account: account, store: store, tightest: store.tightestLimit, drag: drag, animation: nil, lifted: true)
                .frame(width: frame.width, height: frame.height)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var reorderAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }

    private func moveByKeyboard(_ account: Account, by step: Int) {
        let order = store.order
        guard let index = order.firstIndex(of: account), order.indices.contains(index + step) else { return }
        withAnimation(reorderAnimation) { store.move(account, to: order[index + step]) }
    }
}

private struct SettingsRows: View {
    @Bindable var store: UsageStore
    @State private var loginItemFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            }
            if let loginItemFailure {
                Text(loginItemFailure).foregroundStyle(.red)
            }
        }
        // Checkboxes here too: the provider rows stopped using blue switches so the bars
        // could own blue, and leaving these as switches made them the brightest thing left.
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(.callout)
        // Pinned to the leading edge like the legend and the footer; left to itself the
        // stack sized to its content and sat centred in the panel.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

private struct ProviderCard: View {
    let account: Account
    @Bindable var store: UsageStore
    let tightest: BucketKey?
    let drag: CardDrag
    let animation: Animation?
    /// The copy drawn under the pointer during a drag: no drag surface of its own.
    var lifted = false

    var body: some View {
        if store.enabled(account) {
            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 5) {
                    header
                    if let snapshot = store.snapshots[account], !snapshot.buckets.isEmpty {
                        ForEach(snapshot.buckets) { bucket in
                            UsageRow(bucket: bucket, isTightest: tightest == BucketKey(account: account, bucketID: bucket.id))
                        }
                        .opacity(snapshot.state == .stale ? 0.55 : 1)
                    } else {
                        Text(store.snapshots[account]?.message ?? "Waiting for refresh…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .overlay { if !lifted { dragSurface } }
                // Outside the drag surface: a drag that starts on a text field or a button
                // took the click away from it whenever the pointer drifted a point.
                if store.needsKey(account) {
                    KeyField(provider: account.provider, store: store)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: Alignment(horizontal: .trailing, vertical: .providerTitle)) {
                checkbox.padding(.trailing, 12)
            }
        } else {
            // A provider that is switched off has nothing to show, so it does not get a card
            // to show it in - just the row you turn it back on from.
            header
                .overlay { if !lifted { dragSurface } }
                .overlay(alignment: Alignment(horizontal: .trailing, vertical: .providerTitle)) { checkbox }
                .padding(.horizontal, 12)
        }
    }

    private var staleMessage: String? {
        guard let snapshot = store.snapshots[account], snapshot.state == .stale else { return nil }
        return snapshot.message ?? "Showing the last figures that arrived."
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text(account.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(store.enabled(account) ? .primary : .secondary)
                .alignmentGuide(.providerTitle) { $0[VerticalAlignment.center] }
            if staleMessage != nil {
                // Figures that stopped updating looked exactly like fresh ones, which is the
                // same silence this app keeps finding in itself.
                // The explanation is the drag surface's tooltip, since that surface lies over
                // this icon.
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Covers the title and the rows, so the card can be picked up anywhere but its controls.
    private var dragSurface: some View {
        CardDragSource(
            account: account,
            help: staleMessage,
            onBegin: { y in drag.begin(account, atY: y, store: store) },
            onMove: { y in drag.moved(toY: y, store: store, animation: animation) },
            onEnd: { dropped in drag.finish(store: store, commit: dropped, animation: animation) }
        )
        .accessibilityHidden(true)
    }

    /// Laid over the card rather than inside the drag surface, so a click on it is always a
    /// click. A checkbox, not a switch: five saturated blue pills were the loudest thing on
    /// screen, and blue now means "what is left" on every bar. One hue, one meaning.
    private var checkbox: some View {
        Toggle("", isOn: Binding(get: { store.enabled(account) }, set: { store.setEnabled($0, for: account) }))
            .labelsHidden().toggleStyle(.checkbox).controlSize(.small)
            .alignmentGuide(.providerTitle) { $0[VerticalAlignment.center] }
    }
}

private extension VerticalAlignment {
    /// The middle of a card's title, which the checkbox laid over the card lines up with -
    /// padding put it two points high, since the title and the checkbox differ in height.
    enum ProviderTitle: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }
    static let providerTitle = VerticalAlignment(ProviderTitle.self)
}

/// One usage window on one line: label, bar, figure, reset.
///
/// The bar is inline rather than on a row of its own, which halves the menu without hiding
/// anything. Every bar starts at the same left edge and is the same width, so reading down
/// the column shows which limit is tightest without reading a single number - the
/// comparison a row of vertical columns would have given, except the labels survive.
private struct UsageRow: View {
    let bucket: UsageBucket
    /// The one window worth acting on, if any. Weight rather than colour: blue and orange
    /// are already carrying spent-versus-left, and a third meaning on the same hues would
    /// undo that.
    var isTightest = false

    var body: some View {
        HStack(spacing: 8) {
            Text(bucket.label)
                .foregroundStyle(isTightest ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 128, alignment: .leading)

            UsageBar(fraction: bucket.fractionUsed)

            Text(UsageFormat.value(bucket))
                .monospacedDigit()
                .fontWeight(isTightest ? .semibold : .regular)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 70, alignment: .trailing)

            Text(UsageFormat.reset(bucket) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .font(.callout)
        .help(UsageFormat.detail(bucket))
    }
}

/// Orange for what is spent, blue for what is left, filling from the left.
///
/// The pair is the validated categorical slots 1 and 2: CVD separation deltaE 26.8 (protan),
/// normal-vision deltaE 31.8, both clearing 3:1 against this surface.
private struct UsageBar: View {
    let fraction: Double?

    private let segmentGap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            if let fraction {
                let used = min(max(fraction, 0), 1)
                let needsGap = used > 0.001 && used < 0.999
                let drawable = width - (needsGap ? segmentGap : 0)
                HStack(spacing: 0) {
                    Rectangle().fill(MeterPalette.used).frame(width: drawable * used)
                    if needsGap { Color.clear.frame(width: segmentGap) }
                    Rectangle().fill(MeterPalette.remaining).frame(width: drawable * (1 - used))
                }
            } else {
                // Nothing to divide by, so a filled bar would be a lie.
                Rectangle().fill(MeterPalette.remaining.opacity(0.18))
            }
        }
        .frame(height: 7)
        .clipShape(.rect(cornerRadius: 3.5))
    }
}

private struct MeterLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            swatch(MeterPalette.used, "used")
            swatch(MeterPalette.remaining, "left")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

enum MeterPalette {
    /// Slots 1 and 2 of the validated categorical theme, each with its own step per
    /// appearance rather than one colour dimmed for dark mode.
    static let used = dynamic(light: NSColor(srgbRed: 0.92, green: 0.41, blue: 0.20, alpha: 1),
                              dark: NSColor(srgbRed: 0.85, green: 0.35, blue: 0.15, alpha: 1))
    static let remaining = dynamic(light: NSColor(srgbRed: 0.16, green: 0.47, blue: 0.84, alpha: 1),
                                   dark: NSColor(srgbRed: 0.22, green: 0.53, blue: 0.90, alpha: 1))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

