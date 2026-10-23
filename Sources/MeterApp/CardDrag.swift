import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MeterCore

/// One drag of a provider card, from pickup to drop or abandonment.
@MainActor @Observable
final class CardDrag {
    /// Meter's own type, offered only inside this app: as plain text the card name was
    /// typed into a focused key field when dragged over it, and landed in Terminal or on
    /// the Desktop when dragged out of the menu.
    static let type = UTType(exportedAs: "com.justn.meter.provider-card")
    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)

    private(set) var account: Account?
    @ObservationIgnored private var orderBefore: [Account] = []
    /// Where each card sits in the menu, for deciding which cards the pointer has passed.
    @ObservationIgnored var frames: [Account: CGRect] = [:]
    /// The coordinate space the frames are measured in: the whole menu.
    nonisolated static let space = "menu"

    /// Where the lifted card is drawn: under the pointer, held at the point it was grabbed.
    private(set) var liftedFrame: CGRect?
    @ObservationIgnored private var grabOffset: CGSize = .zero
    /// When the last move landed. Tiles of two widths reflow when one moves, which can slide
    /// a different tile under a pointer that has not moved, and without a pause the two
    /// would trade places back and forth for as long as it stayed there.
    @ObservationIgnored private var lastMove: Date = .distantPast

    func begin(_ account: Account, at point: CGPoint, store: UsageStore) {
        guard let card = frames[account] else { return }
        self.account = account
        store.isReordering = true
        orderBefore = store.order
        grabOffset = CGSize(width: point.x - card.minX, height: point.y - card.minY)
        liftedFrame = card
        lastMove = .distantPast
    }

    /// Moves the carried tile into the place of the tile under the pointer. Past the last
    /// tile it goes to the end and above the first to the start, so a quick flick that
    /// overshoots the grid still lands where it was aimed.
    func moved(to point: CGPoint, store: UsageStore, animation: Animation?) {
        guard let carried = account else { return }
        if let lifted = liftedFrame {
            liftedFrame = CGRect(origin: CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height), size: lifted.size)
        }
        guard Date.now.timeIntervalSince(lastMove) > 0.25 else { return }
        let others = store.order.filter { $0 != carried && store.enabled($0) && frames[$0] != nil }
        guard !others.isEmpty else { return }
        var target = others.first { frames[$0]!.contains(point) }
        if target == nil, let from = store.order.firstIndex(of: carried) {
            // Only towards the end the pointer went past: a tile already last, held below the
            // grid, would otherwise trade places with the one before it and back again.
            func index(_ account: Account) -> Int { store.order.firstIndex(of: account) ?? from }
            if let last = others.last, point.y > frames[last]!.maxY, index(last) > from { target = last }
            else if let first = others.first, point.y < frames[first]!.minY, index(first) < from { target = first }
        }
        if let target {
            lastMove = .now
            withAnimation(animation) { store.move(carried, to: target, persist: false) }
        }
    }

    /// A drop saves the order on screen; anything else - Esc, or a release outside the
    /// menu - puts back the order from before the drag.
    func finish(store: UsageStore, commit: Bool, animation: Animation?) {
        guard account != nil else { return }
        store.isReordering = false
        if commit {
            store.saveOrder()
        } else {
            withAnimation(animation) { store.restoreOrder(orderBefore) }
        }
        account = nil
        liftedFrame = nil
    }
}

/// Runs a card drag from AppKit, start to finish.
///
/// SwiftUI's `onDrag` does not say when a drag ends, so the end had to be guessed from the
/// mouse button, which reads as released during a three-finger trackpad drag or with drag
/// lock, and the drag was cancelled under the user's fingers. This view follows the pointer
/// itself and decides at the end whether the card was put down in the menu or the drag was
/// called off.
///
/// The system is handed an invisible drag image; the menu draws the lifted card itself.
/// macOS drew a card-sized drag image at about half size, a card that shrank as it was
/// picked up, and nothing in the drag API sets that scale.
struct CardDragSource: NSViewRepresentable {
    let account: Account
    /// Shown on hover. The drag surface covers the card, so it carries the card's tooltip.
    let help: String?
    /// The pointer in the menu's coordinates when the drag starts.
    let onBegin: (_ point: CGPoint) -> Void
    /// The pointer in the menu's coordinates, as the drag moves.
    let onMove: (_ point: CGPoint) -> Void
    /// Whether the card was put down in the menu, as opposed to Esc or a release outside.
    let onEnd: (_ dropped: Bool) -> Void

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.account = account
        view.toolTip = help
        view.onBegin = onBegin
        view.onMove = onMove
        view.onEnd = onEnd
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var account: Account?
    var onBegin: (CGPoint) -> Void = { _ in }
    var onMove: (CGPoint) -> Void = { _ in }
    var onEnd: (Bool) -> Void = { _ in }
    private var mouseDown: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { mouseDown = event }
    override func mouseUp(with event: NSEvent) { mouseDown = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDown, let account else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        // A few points of slack, so a click with a trembling hand stays a click.
        guard hypot(now.x - start.x, now.y - start.y) >= 4 else { return }
        mouseDown = nil

        let item = NSPasteboardItem()
        item.setString(account.rawValue, forType: CardDrag.pasteboardType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let point = convert(now, from: nil)
        dragItem.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 1, height: 1), contents: NSImage(size: NSSize(width: 1, height: 1)))

        onBegin(menuPoint(forWindowPoint: start) ?? .zero)
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let window, let point = menuPoint(forWindowPoint: window.convertPoint(fromScreen: screenPoint)) else { return }
        onMove(point)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Esc ends the drag while the key is still down; a release ends it with the key up.
        let escaped = CGEventSource.keyState(.combinedSessionState, key: 53)
        let insideMenu = window?.frame.contains(screenPoint) == true
        onEnd(insideMenu && !escaped)
    }

    /// The menu's root view is where the card frames are measured from.
    private func menuPoint(forWindowPoint point: NSPoint) -> CGPoint? {
        guard let root = window?.contentView else { return nil }
        return root.convert(point, from: nil)
    }
}

/// Calls `onOpen` each time the menu's window comes on screen.
///
/// `.task` on the menu's content runs when SwiftUI creates the view, and a window-style menu
/// bar extra may keep that view between openings, so it is not a reliable "the menu opened".
/// The window going from hidden to visible is. Becoming key would not do: the window becomes
/// key again when a keychain dialog closes, which would retry the read and raise the dialog
/// again straight after the user dismissed it.
struct MenuOpenObserver: NSViewRepresentable {
    let onOpen: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.onOpen = onOpen }

    final class ObserverView: NSView {
        var onOpen: () -> Void = {}
        private var observation: NSObjectProtocol?
        private var wasVisible = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the window, which happens before the view goes away, ends the observation.
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            guard let window else { return }
            observation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            }
            visibilityChanged()
        }

        private func visibilityChanged() {
            let visible = window?.occlusionState.contains(.visible) == true
            defer { wasVisible = visible }
            if visible && !wasVisible { onOpen() }
        }
    }
}

