import MeterCore
import SwiftUI

/// Refresh interval, launch at login, alerts and the global shortcut. (W1)
struct GeneralSettingsTab: View {
    @Bindable var store: UsageStore
    let alerts: AlertCenter

    var body: some View {
        Form {
            Text("General settings")
        }
        .formStyle(.grouped)
    }
}
