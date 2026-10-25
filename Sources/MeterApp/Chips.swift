import MeterCore
import SwiftUI

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
