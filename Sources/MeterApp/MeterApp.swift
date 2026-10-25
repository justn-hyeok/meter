import AppKit
import SwiftUI
import MeterCore

@main
struct MeterApp: App {
    @State private var store = UsageStore()
    @State private var tokens = TokenStore()
    @State private var alerts = AlertCenter()
    @State private var hotKeys = HotKeyController(action: { MenuBarToggle.toggle() })
    @State private var isHotKeyReady = false

    var body: some Scene {
        MenuBarExtra {
            MeterMenu(store: store, tokens: tokens, alerts: alerts, hotKeys: hotKeys)
        } label: {
            // MenuBarExtra reserves space for an arbitrary label view without drawing it,
            // but it does paint an image: the gauge is drawn into one.
            Image(nsImage: MenuBarIcon.image(usage: store.highestUsage, unavailable: store.isAllUnavailable))
                .task {
                    // The label can be drawn more than once; the registered hot key must not
                    // be torn down and rebuilt each time.
                    if !isHotKeyReady {
                        isHotKeyReady = true
                        hotKeys.apply(hotKeys.setting)
                    }
                    store.onUpdate = { [store, alerts] in alerts.check(Array(store.snapshots.values), muted: store.muted) }
                    store.start()
                    // Development flags, run once the app has finished launching: `--settings`
                    // opens the settings window, `--gallery` a window of every tile state in
                    // light and dark.
                    if CommandLine.arguments.contains("--settings") {
                        SettingsWindow.show(store: store, alerts: alerts, hotKeys: hotKeys)
                    }
                    if CommandLine.arguments.contains("--gallery") { StateGallery.show() }
                }
        }
        .menuBarExtraStyle(.window)
    }
}

/// The two things the menu answers: how much of each plan is left, and what spent it.
enum MenuTab: String, CaseIterable, Identifiable {
    case limits = "Limits"
    case tokens = "Tokens"
    var id: String { rawValue }
}

private struct MeterMenu: View {
    @Bindable var store: UsageStore
    @Bindable var tokens: TokenStore
    let alerts: AlertCenter
    let hotKeys: HotKeyController
    @State private var tab = MenuTab.limits
    @State private var drag = CardDrag()
    @State private var cardsHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            MenuHeader(store: store, tokens: tokens, tab: $tab)
            // Every tile is one fixed size, so the menu's height follows only from how many
            // providers are on: it no longer grows and shrinks as they answer or fail, and it
            // has no empty band of window below the last tile. It scrolls only when the tiles
            // outgrow the screen.
            // The token view takes the height the tiles set, so switching tabs never resizes
            // the menu under the pointer; it scrolls inside that height instead.
            ZStack(alignment: .top) {
                // Removed, not hidden, on the Tokens tab: a hidden key field still took Tab
                // focus and hidden tiles still showed tooltips. The height it last measured
                // stays in `cardsHeight`, so switching tabs does not resize the menu.
                if tab == .limits {
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
                }

                if tab == .tokens {
                    ScrollView(.vertical) { TokensView(tokens: tokens) }
                        .scrollBounceBehavior(.basedOnSize)
                        .task { await tokens.load() }
                }
            }
            .frame(height: min(cardsHeight, maxCardsHeight))
            Divider()
            MenuFooter(store: store, alerts: alerts, hotKeys: hotKeys)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .topLeading) { liftedTile }
        .coordinateSpace(.named(CardDrag.space))
        // Opening the menu is the moment a keychain dialog is welcome; the five-minute
        // refresh never raises one.
        .background(MenuOpenObserver {
            Task { await store.menuOpened() }
            Task { await alerts.refreshAuthorization() }
            if tab == .tokens { Task { await tokens.load() } }
        })
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
    @Bindable var tokens: TokenStore
    @Binding var tab: MenuTab

    var body: some View {
        HStack(spacing: 8) {
            Picker("View", selection: $tab) {
                ForEach(MenuTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Spacer()
            // Relative, because the question is "how old is this", and a clock time made the
            // reader do the subtraction against the clock in the corner of the screen.
            if tab == .limits {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(updatedText(now: context.date))
                }
            }
            if store.isRefreshing || tokens.isLoading { ProgressView().controlSize(.small) }
            IconButton(systemImage: "arrow.clockwise", accessibilityLabel: "Refresh all") {
                Task { await store.refreshAll(interactive: true) }
                if tab == .tokens { Task { await tokens.load(force: true) } }
            }
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
    let store: UsageStore
    @Bindable var alerts: AlertCenter
    let hotKeys: HotKeyController
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
                if AppBundle.isBundled {
                    Toggle("Alerts", isOn: $alerts.isEnabled)
                        .toggleStyle(.checkbox)
                        .help("Notify at the percents set in Settings, once each, or when a sign-in stops working")
                }
                Spacer()
                SettingsButton(store: store, alerts: alerts, hotKeys: hotKeys)
                // The shortcut was in the README and nowhere on screen, and it changes now.
                if let display = hotKeys.display {
                    Text(display).foregroundStyle(.tertiary).help("Opens and closes Meter from anywhere")
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
            }
            if let loginItemFailure {
                Text(loginItemFailure).foregroundStyle(.red)
            }
            if alerts.isEnabled, alerts.isDenied {
                Button("Notifications are off for Meter in System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .buttonStyle(.link)
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
struct TileGrid: View {
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
                    // A tile scrolled out of the lazy grid, or on a tab not shown, has no
                    // place on screen; a frame left behind would catch the pointer.
                    .onDisappear { drag.frames[account] = nil }
                    .accessibilityAction(named: "Move up") { moveByKeyboard(account, -1) }
                    .accessibilityAction(named: "Move down") { moveByKeyboard(account, 1) }
            }
        }
    }
}

/// A problem the user can fix, with the fix one click away: copying the sign-in command,
/// or opening the page. Outside the drag surface, so a click is never taken for a drag.
struct IssueRow: View {
    let provider: ProviderID
    let issue: SnapshotIssue
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .foregroundStyle(issue == .signInRequired ? Color(nsColor: .systemOrange) : .secondary)
                .help(detail)
            Spacer(minLength: 0)
            if let command = provider.signInFix?.command {
                IconButton(
                    systemImage: "doc.on.doc",
                    help: "Copy '\(command)'",
                    accessibilityLabel: "Copy the sign-in command"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
            if let url = provider.signInFix?.url {
                IconButton(
                    systemImage: "safari",
                    help: "Open \(url.host() ?? url.absoluteString)",
                    accessibilityLabel: "Open the sign-in page"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var icon: String {
        switch issue {
        case .signInRequired: "person.crop.circle.badge.exclamationmark"
        case .notConnected: "link"
        case .expiresSoon: "clock.badge.exclamationmark"
        }
    }

    private var title: String {
        switch issue {
        case .signInRequired: "Sign in again"
        case .notConnected: "Connect"
        // Short enough to sit beside two buttons in half the menu's width; the tooltip
        // says the rest.
        case .expiresSoon(let date): "Ends \(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))"
        }
    }

    private var detail: String {
        var lines = [provider.signInFix?.instruction ?? snapshot.message ?? ""]
        if case .expiresSoon(let date) = issue {
            lines.insert("Sign-in ends \(date.formatted(date: .abbreviated, time: .shortened))", at: 0)
        }
        if snapshot.state == .stale {
            lines.append("Showing figures from \(snapshot.fetchedAt.formatted(.relative(presentation: .named)))")
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Switched-off providers, as chips to switch them back on. They have nothing to show, so
/// they do not get a tile, and a row of checkboxes among the figures was the noisiest thing
/// in the old menu.
struct HiddenProviders: View {
    @Bindable var store: UsageStore

    var body: some View {
        let hidden = store.order.filter { !store.enabled($0) }
        if !hidden.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(hidden) { account in
                    Button { store.setEnabled(true, for: account) } label: {
                        Label(account.title, systemImage: "plus")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
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
struct FlowLayout: Layout {
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

struct ProviderTile: View {
    let account: Account
    @Bindable var store: UsageStore
    let drag: CardDrag
    let animation: Animation?
    /// The copy drawn under the pointer during a drag: no drag surface of its own.
    var lifted = false

    private var snapshot: UsageSnapshot? { store.snapshots[account] }
    private var muted: Set<String> {
        Set(store.muted.filter { $0.account == account }.map(\.bucketID))
    }
    private var severity: Severity {
        Severity(snapshot?.buckets.filter { !muted.contains($0.id) }.compactMap(\.fractionUsed).max())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let snapshot, !snapshot.buckets.isEmpty {
                    // A live tile with an issue row below has one row less to spare.
                    TileContent(buckets: snapshot.buckets, muted: muted,
                                maxRows: needsExtraRow(snapshot) ? MeterStyle.maxRows - 1 : MeterStyle.maxRows)
                        .opacity(snapshot.isVisiblyStale() || isIdle(snapshot) ? 0.55 : 1)
                    if snapshot.isVisiblyStale(), snapshot.issue == nil { staleNote(snapshot) }
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
            } else if let snapshot, let issue = snapshot.issue {
                IssueRow(provider: account.provider, issue: issue, snapshot: snapshot)
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
            // A window that sits full by design, such as a plan's bonus models, would be red
            // and alerting for good. Unchecking it keeps the figure and drops the warning.
            let windows = snapshot?.buckets.filter { $0.alertFraction != nil } ?? []
            if !windows.isEmpty {
                Section("Warn when nearly used") {
                    ForEach(windows) { bucket in
                        let key = BucketKey(account: account, bucketID: bucket.id)
                        Toggle(bucket.label, isOn: Binding(
                            get: { !store.isMuted(key) },
                            set: { store.setMuted(!$0, key) }
                        ))
                    }
                }
            }
        }
    }

    /// Every window at zero with no reset scheduled: an account that has not been used,
    /// which should not look as present as one that is working.
    private func isIdle(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.buckets.allSatisfy { $0.fractionUsed == 0 && $0.resetAt == nil }
    }

    /// A sign-in row or an age line takes a window's place, so three windows plus that
    /// extra line cannot overflow the fixed tile.
    private func needsExtraRow(_ snapshot: UsageSnapshot) -> Bool {
        (snapshot.issue != nil && snapshot.state == .live) || (snapshot.isVisiblyStale() && snapshot.issue == nil)
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
            Image(systemName: "clock")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(snapshot.message ?? "Showing the last figures that arrived.")
    }

    /// Covers the title and the figures, so the tile can be picked up anywhere but its controls.
    private var dragSurface: some View {
        CardDragSource(
            account: account,
            help: snapshot?.isVisiblyStale() == true ? (snapshot?.message ?? "Showing the last figures that arrived.") : nil,
            onBegin: { point in drag.begin(account, at: point, store: store) },
            onMove: { point in drag.moved(to: point, store: store, animation: animation) },
            onEnd: { dropped in drag.finish(store: store, commit: dropped, animation: animation) }
        )
        .accessibilityHidden(true)
    }
}

/// The arcs and the headline figure, then every window on a line of its own.
struct TileContent: View {
    let buckets: [UsageBucket]
    /// Windows drawn without warning colours.
    var muted: Set<String> = []
    var maxRows = MeterStyle.maxRows

    /// The fraction that decides a window's colour: none for a muted one.
    private func alarm(_ bucket: UsageBucket) -> Double? {
        muted.contains(bucket.id) ? nil : bucket.fractionUsed
    }

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
        guard buckets.count > maxRows else { return buckets }
        let kept = Set(buckets.sorted { ($0.fractionUsed ?? -1) > ($1.fractionUsed ?? -1) }
            .prefix(maxRows - 1).map(\.id))
        return buckets.filter { kept.contains($0.id) }
    }

    private var folded: [UsageBucket] {
        let shown = Set(listed.map(\.id))
        return buckets.filter { !shown.contains($0.id) }
    }

    /// The fullest window still warned about, or, for an account measured only in money,
    /// its first figure. A muted window is not what the tile should lead with.
    private var headline: UsageBucket? {
        arcs.first { !muted.contains($0.id) } ?? arcs.first ?? buckets.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if !arcs.isEmpty {
                    ArcGauge(fractions: arcs.map { $0.fractionUsed ?? 0 }, alarms: arcs.map(alarm),
                             dimmed: arcs.map { muted.contains($0.id) })
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                }
                if let headline {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UsageFormat.value(headline))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Severity(alarm(headline)).color ?? .primary)
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
                        WindowRow(bucket: bucket, arcIndex: arcs.firstIndex { $0.id == bucket.id },
                                  isMuted: muted.contains(bucket.id))
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
struct WindowRow: View {
    let bucket: UsageBucket
    let arcIndex: Int?
    var isMuted = false

    private var alarm: Double? { isMuted ? nil : bucket.fractionUsed }

    var body: some View {
        HStack(spacing: 6) {
            // A muted window's mark takes the dot's place, so its label keeps its width.
            Group {
                if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .help("No warning for this window. Right-click the tile to turn it back on.")
                        .accessibilityLabel("warnings off")
                } else {
                    Circle().fill(arcIndex.map { MeterStyle.arcColor($0, fraction: alarm) } ?? .clear)
                }
            }
            .frame(width: 6, height: 6)
            Text(bucket.label)
                .strikethrough(isMuted)
                .foregroundStyle(isMuted ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(UsageFormat.value(bucket))
                .monospacedDigit()
                .fontWeight(.medium)
                .strikethrough(isMuted)
                .foregroundStyle(isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Severity(alarm).color ?? .primary))
                .lineLimit(1)
            Text(UsageFormat.reset(bucket) ?? "—")
                .monospacedDigit()
                .foregroundStyle(isMuted ? .quaternary : .tertiary)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .font(.caption)
        .help(UsageFormat.detail(bucket))
        .accessibilityElement(children: .combine)
    }
}

/// Up to three concentric 270° arcs, open at the bottom like a dial, outermost first.
struct ArcGauge: View {
    let fractions: [Double]
    /// Per arc, the fraction that decides its colour; nil keeps it neutral.
    var alarms: [Double?] = []
    /// Arcs of muted windows, drawn faint so a full one does not dominate the dial.
    var dimmed: [Bool] = []

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
                        arc(to: max(used, 0.015)).stroke(
                            dimmed.indices.contains(index) && dimmed[index]
                                ? Color.primary.opacity(0.22)
                                : MeterStyle.arcColor(index, fraction: alarms.indices.contains(index) ? alarms[index] : fraction),
                            style: stroke)
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
enum Severity {
    case calm, warning, critical

    init(_ fraction: Double?) {
        guard let fraction else { self = .calm; return }
        if fraction >= TightestLimit.critical { self = .critical }
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
/// An SF Symbol control whose clickable area is the frame, not the glyph.
struct IconButton: View {
    let systemImage: String
    var help: String?
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

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

struct KeyField: View {
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
                // The tile's height is fixed; a long system message must not spill out of it.
                Text(failure).foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(failure)
            }
        }
        .font(.caption)
    }
}
