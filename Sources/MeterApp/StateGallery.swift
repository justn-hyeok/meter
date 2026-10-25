import AppKit
import MeterCore
import SwiftUI

/// Every tile state, in light and dark, in one window: `MeterApp --gallery`. (W3)
///
/// The tiles are the menu's own views over a preview store, so a change to the tile design
/// can be seen in both appearances at once instead of being reasoned about from the code.
@MainActor
enum StateGallery {
    /// Kept because a window freed on close leaves nothing to bring back, and the preview
    /// store it hosts has no other owner.
    private static var window: NSWindow?

    static func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let data = GalleryData.make()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meter State Gallery"
        window.identifier = NSUserInterfaceItemIdentifier("MeterStateGallery")
        // Narrower than this and the second column would be cut off rather than scrolled to.
        window.contentMinSize = NSSize(width: 880, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = GalleryDelegate.shared
        let hosting = NSHostingView(rootView: StateGalleryView(store: data.store, entries: data.entries))
        // The window sets the size; left to itself the host adopts the SwiftUI content's ideal
        // size, and a scroll view has none worth growing a window to.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.center()

        // Meter is an accessory app (LSUIElement): without this the window opens behind
        // whatever is in front and cannot be focused.
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Self.window = window
    }

    fileprivate static func closed(_ closing: NSWindow) {
        guard window === closing else { return }
        window = nil
        // The Dock icon and the menu bar belong to the gallery while it is up, not after it.
        _ = NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
private final class GalleryDelegate: NSObject, NSWindowDelegate {
    static let shared = GalleryDelegate()

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        StateGallery.closed(window)
    }
}

// MARK: - Data

private struct GalleryEntry: Identifiable {
    /// The state the tile is meant to show, printed under it.
    let state: String
    let account: Account
    var id: String { account.rawValue }
}

/// The states are built here rather than read from the machine: a gallery that answered
/// differently on every launch would not be one. Every tile gets an account of its own, and
/// every account but Hive's and the key-field one is named: the key field shows only for a
/// default account with no usable credential, so on a machine that has one a default account
/// would draw a field where a live tile belongs. Hive never takes a stored key, so it cannot.
@MainActor
private enum GalleryData {
    struct Data {
        let store: UsageStore
        let entries: [GalleryEntry]
    }

    static func make() -> Data {
        let now = Date.now

        let live = Account(.claude, name: "live")
        let warn = Account(.codex, name: "warn")
        let stale = Account(.openCodeGo, name: "stale")
        let timeout = Account(.commandCode, name: "timeout")
        // Deliberately absent from `snapshots`: an account that is on and has not answered yet.
        let waiting = Account(.openRouter, name: "waiting")
        let signIn = Account(.cursor, name: "signin")
        let hive = Account(.hive)
        let soon = Account(.cursor, name: "soon")
        let five = Account(.openCodeGo, name: "five")
        let balance = Account(.deepSeek, name: "balance")
        let noKey = Account(.openRouter)
        let muted = Account(.cursor, name: "muted")
        let work = Account(.deepSeek, name: "work")

        let snapshots: [UsageSnapshot] = [
            UsageSnapshot(
                provider: .claude,
                buckets: [
                    percent("five-hour", "5-hour", 20, resetsIn: 3, from: now),
                    percent("weekly", "Weekly", 45, resetsIn: 96, from: now),
                    percent("opus", "Opus", 60, resetsIn: 48, from: now),
                ],
                fetchedAt: now, source: "Claude account usage", state: .live, message: nil
            ).for(live),

            UsageSnapshot(
                provider: .codex,
                buckets: [
                    percent("codex-primary", "5-hour", 85, resetsIn: 2, from: now),
                    percent("codex-secondary", "Weekly", 97, resetsIn: 120, from: now),
                ],
                fetchedAt: now, source: "Codex app-server", state: .live, message: nil
            ).for(warn),

            // Stale, so the tile says when its figures are from rather than passing them off
            // as current.
            UsageSnapshot(
                provider: .openCodeGo,
                buckets: [
                    percent("five-hour", "5-hour", 30, resetsIn: 2, from: now),
                    percent("weekly", "Weekly", 70, resetsIn: 72, from: now),
                ],
                fetchedAt: now.addingTimeInterval(-3 * 3_600), source: "OpenCode Go API",
                state: .stale, message: "The request timed out."
            ).for(stale),

            UsageSnapshot.unavailable(.commandCode, "Command Code unavailable: The request timed out.").for(timeout),

            UsageSnapshot(
                provider: .cursor,
                buckets: [
                    percent("cursor-models", "Cursor Models", 12),
                    percent("other-models", "Other Models", 34),
                ],
                fetchedAt: now.addingTimeInterval(-3_600), source: "Cursor dashboard",
                state: .stale, message: "Cursor session expired.", issue: .signInRequired
            ).for(signIn),

            // Mirrors HiveUsageProvider.notConnected, which is internal to MeterCore.
            UsageSnapshot.unavailable(
                .hive,
                "Sign in at portal.thehive.ai in Chrome, Arc, Dia, Brave, Edge or Aside. Meter picks the session up from there.",
                issue: .notConnected
            ).for(hive),

            UsageSnapshot(
                provider: .cursor,
                buckets: [
                    percent("cursor-models", "Cursor Models", 30),
                    percent("other-models", "Other Models", 55),
                ],
                fetchedAt: now, source: "Cursor dashboard", state: .live, message: nil,
                issue: .expiresSoon(now.addingTimeInterval(5 * 3_600))
            ).for(soon),

            // Five windows, three rows: the two fullest stay and the rest fold into "+3 more".
            UsageSnapshot(
                provider: .openCodeGo,
                buckets: [
                    percent("five-hour", "5-hour", 10, resetsIn: 4, from: now),
                    percent("weekly", "Weekly", 25, resetsIn: 90, from: now),
                    percent("opus", "Opus", 40, resetsIn: 40, from: now),
                    percent("sonnet", "Sonnet", 55, resetsIn: 20, from: now),
                    percent("haiku", "Haiku", 70, resetsIn: 5, from: now),
                ],
                fetchedAt: now, source: "OpenCode Go API", state: .live, message: nil
            ).for(five),

            UsageSnapshot(
                provider: .deepSeek,
                buckets: [
                    UsageBucket(id: "USD", label: "Balance (USD)", used: nil, limit: nil,
                                remaining: 8.6, resetAt: nil, unit: .usd),
                ],
                fetchedAt: now, source: "DeepSeek Balance API", state: .live, message: nil
            ).for(balance),

            UsageSnapshot.unavailable(
                .openRouter,
                "No API key. Run 'meter set-key openrouter' or paste one in the Meter menu."
            ),

            UsageSnapshot(
                provider: .cursor,
                buckets: [
                    percent("cursor-models", "Cursor Models", 40),
                    percent("other-models", "Other Models", 100),
                ],
                fetchedAt: now, source: "Cursor dashboard", state: .live, message: nil
            ).for(muted),

            UsageSnapshot(
                provider: .deepSeek,
                buckets: [
                    UsageBucket(id: "USD", label: "Balance (USD)", used: nil, limit: nil,
                                remaining: 42, resetAt: nil, unit: .usd),
                ],
                fetchedAt: now, source: "DeepSeek Balance API", state: .live, message: nil
            ).for(work),
        ]

        let entries: [GalleryEntry] = [
            GalleryEntry(state: "1 · Live · 20 / 45 / 60%", account: live),
            GalleryEntry(state: "2 · Warning 85% · critical 97%", account: warn),
            GalleryEntry(state: "3 · Stale · from 3h ago", account: stale),
            GalleryEntry(state: "4 · Unavailable · timed out", account: timeout),
            GalleryEntry(state: "5 · Waiting · no figures yet", account: waiting),
            GalleryEntry(state: "6 · Sign in again", account: signIn),
            GalleryEntry(state: "7 · Hive not connected", account: hive),
            GalleryEntry(state: "8 · Expires soon", account: soon),
            GalleryEntry(state: "9 · More than three windows", account: five),
            GalleryEntry(state: "10 · Money only", account: balance),
            GalleryEntry(state: "11 · Key field", account: noKey),
            GalleryEntry(state: "12 · Muted window", account: muted),
            GalleryEntry(state: "13 · Named account", account: work),
        ]

        let store = UsageStore.preview(snapshots, namedAccounts: entries.map(\.account).filter { $0.name != nil })
        // Window-level rather than per snapshot: muting is what the menu's right-click menu
        // writes, and the tile should draw it the same way.
        store.setMuted(true, BucketKey(account: muted, bucketID: "other-models"))
        return Data(store: store, entries: entries)
    }

    private static func percent(_ id: String, _ label: String, _ used: Double, resetsIn hours: Double? = nil, from now: Date = .now) -> UsageBucket {
        UsageBucket(
            id: id,
            label: label,
            used: used,
            limit: 100,
            remaining: max(0, 100 - used),
            resetAt: hours.map { now.addingTimeInterval($0 * 3_600) },
            unit: .percent
        )
    }
}

// MARK: - View

private struct StateGalleryView: View {
    let store: UsageStore
    let entries: [GalleryEntry]
    @State private var drag = CardDrag()

    var body: some View {
        // The window's minimum width keeps both columns whole, so the gallery stacks up from
        // the top and only ever scrolls down.
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 20) {
                column(.light)
                column(.dark)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// One appearance, drawn at the menu's width so the tiles wrap and truncate exactly as
    /// they do there. `ProviderTile` is given a drag object with no frames, so the drag
    /// surface finds nothing to pick up and every tile stays put.
    private func column(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scheme == .light ? "Light" : "Dark")
                .font(.headline)
                .padding(.horizontal, 2)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        ProviderTile(account: entry.account, store: store, drag: drag, animation: nil)
                        Text(entry.state)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 380, alignment: .top)
        // An explicit fill rather than a window colour: an AppKit dynamic colour resolves
        // against the window's appearance, which is not the appearance forced here.
        .background(scheme == .light ? Color(white: 0.96) : Color(white: 0.12))
        .environment(\.colorScheme, scheme)
    }
}
