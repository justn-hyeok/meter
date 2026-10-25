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
                .padding(1)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
