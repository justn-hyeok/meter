import AppKit
import MeterCore
import SwiftUI

/// Switched-off providers, as chips to switch them back on. They have nothing to show, so
/// they do not get a tile, and a row of checkboxes among the figures was the noisiest thing
/// in the old menu.
struct HiddenProviders: View {
    @Bindable var store: UsageStore

    var body: some View {
        // A removed account is gone from `order` with its key, so no chip can be left behind
        // for it; hiding only ever applies to accounts that are still here.
        let hidden = store.order.filter { !store.enabled($0) && !store.hiddenSuggestions.contains($0) }
        if !hidden.isEmpty {
            // One row that scrolls sideways: wrapped, four chips took two rows of the menu
            // and moved the footer down every time a provider was added.
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
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
                        .contextMenu {
                            Button("Show \(account.title)") { store.setEnabled(true, for: account) }
                            Button("Don't suggest again") { store.setSuggestionHidden(true, for: account) }
                        }
                    }
                }
                // The dashed outline is drawn on the capsule's edge, which the scroll view
                // would cut off without a point of room around it.
                .padding(.horizontal, 1)
                .padding(.top, 1)
                // Room for the scroll bar under the chips, so it never covers their outline.
                .padding(.bottom, 6)
                .background(SlimHorizontalScroller())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// SwiftUI has no setting for how thick a scroll bar is, and the system's is heavy under a row
/// of chips. This one is still the system's overlay scroller - it appears while scrolling and
/// fades - with only the knob drawn thinner.
private struct SlimHorizontalScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view) }
    }

    private func apply(to view: NSView) {
        guard let scrollView = view.enclosingScrollView, !(scrollView.horizontalScroller is SlimScroller) else { return }
        let scroller = SlimScroller()
        scroller.scrollerStyle = .overlay
        scrollView.horizontalScroller = scroller
    }
}

private final class SlimScroller: NSScroller {
    private static let thickness: CGFloat = 3

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// No track: an overlay scroller has none to show, and the default draws one on hover.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        let bottom = isFlipped ? bounds.maxY - Self.thickness - 1 : bounds.minY + 1
        let slim = NSRect(x: knob.minX, y: bottom, width: knob.width, height: Self.thickness)
        NSColor.labelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: slim, xRadius: Self.thickness / 2, yRadius: Self.thickness / 2).fill()
    }
}
