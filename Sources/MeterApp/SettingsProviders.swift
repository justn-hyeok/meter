import MeterCore
import SwiftUI

/// Providers on and off, keys, named accounts. (W2)
struct ProvidersSettingsTab: View {
    @Bindable var store: UsageStore

    var body: some View {
        Form {
            Text("Providers")
        }
        .formStyle(.grouped)
    }
}

/// Windows whose warnings are muted, to switch back on. (W2)
struct WarningsSettingsTab: View {
    @Bindable var store: UsageStore

    var body: some View {
        Form {
            Text("Warnings")
        }
        .formStyle(.grouped)
    }
}
