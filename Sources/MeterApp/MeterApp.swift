import SwiftUI
import MeterCore

@main
struct MeterApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MeterMenu(store: store)
        } label: {
            Label("Meter", systemImage: icon)
                .task {
                    store.onAlerts = { Notifier.post($0) }
                    Notifier.requestAuthorization()
                    store.start()
                }
        }
        .menuBarExtraStyle(.window)
    }

    private var icon: String {
        if store.isAllUnavailable { return "exclamationmark.triangle" }
        guard let usage = store.highestUsage else { return "gauge.with.dots.needle.0percent" }
        if usage >= 0.95 { return "gauge.with.dots.needle.100percent" }
        if usage >= 0.8 { return "gauge.with.dots.needle.67percent" }
        return "gauge.with.dots.needle.33percent"
    }
}

private struct MeterMenu: View {
    @Bindable var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Meter").font(.headline)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await store.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
            }
            .padding(14)

            Divider()
            VStack(spacing: 10) {
                ForEach(ProviderID.allCases) { provider in
                    ProviderCard(provider: provider, store: store)
                }
            }
            .padding(12)
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
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
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
            Toggle("Notify at 80% and 95%", isOn: Binding(
                get: { store.alertsEnabled },
                set: { store.setAlertsEnabled($0) }
            ))
            if let loginItemFailure {
                Text(loginItemFailure).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
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
    let provider: ProviderID
    @Bindable var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.title).font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { store.enabled(provider) }, set: { store.setEnabled($0, for: provider) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if store.enabled(provider) {
                if let snapshot = store.snapshots[provider], !snapshot.buckets.isEmpty {
                    ForEach(snapshot.buckets) { bucket in UsageRow(bucket: bucket) }
                } else {
                    Text(store.snapshots[provider]?.message ?? "Waiting for refresh…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if provider.acceptsStoredKey {
                    KeyField(provider: provider, store: store)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct UsageRow: View {
    let bucket: UsageBucket
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(bucket.label).font(.caption)
                Spacer()
                Text(value).font(.caption.monospacedDigit())
            }
            if let fraction = bucket.fractionUsed { ProgressView(value: fraction) }
        }
    }

    private var value: String {
        if let percentage = bucket.percentageUsed { return String(format: "%.0f%%", percentage) }
        if let remaining = bucket.remaining { return "\(String(format: "%.2f", remaining)) \(bucket.unit.rawValue)" }
        if let used = bucket.used { return "\(String(format: "%.2f", used)) \(bucket.unit.rawValue) used" }
        return "—"
    }
}
