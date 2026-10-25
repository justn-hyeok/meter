import MeterCore
import SwiftUI

/// The 2×1 and 1×2 tiles' content. (0.6.4 W2)
struct CompactTileContent: View {
    let account: Account
    @Bindable var store: UsageStore
    let size: TileSize

    var body: some View {
        Text(account.title)
    }
}
