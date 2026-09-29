import AppKit
import SwiftUI
import MeterCore

@main
struct MeterApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MeterMenu(store: store)
        } label: {
            // Back to the one form that actually paints. MenuBarExtra reserves space for an
            // arbitrary label view without drawing it, and Text(Image(systemName:)) drew the
            // number but not the symbol - the menu bar was left showing a bare "100%" next to
            // the battery's own, which reads as no Meter at all.
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
                Button { Task { await store.refreshAll(interactive: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
            }
            .padding(14)

            Divider()
            VStack(spacing: 8) {
                ForEach(ProviderID.allCases) { provider in
                    ProviderCard(provider: provider, store: store)
                }
            }
            .padding(12)
            MeterLegend().padding(.horizontal, 12).padding(.bottom, 10)
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
        // Opening the menu is the moment a keychain dialog is welcome; the five-minute
        // refresh never raises one.
        .task { await store.menuOpened() }
    }
}

private struct SettingsRows: View {
    @Bindable var store: UsageStore
    @State private var notifier = Notifier.shared
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
            // Saying the toggle is on while macOS discards every notification would be a
            // lie of exactly the kind this app keeps finding in itself.
            if store.alertsEnabled, notifier.permission.blocksDelivery {
                HStack(spacing: 4) {
                    Text(notifier.permission == .denied
                         ? "macOS is blocking Meter's notifications."
                         : "macOS has not been asked yet.")
                    Button("Open Settings") { notifier.openSystemSettings() }
                        .buttonStyle(.link)
                }
                .foregroundStyle(.secondary)
            }
            if let loginItemFailure {
                Text(loginItemFailure).foregroundStyle(.red)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .task { notifier.refreshPermission() }
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
        if store.enabled(provider) {
            VStack(alignment: .leading, spacing: 5) {
                header
                if let snapshot = store.snapshots[provider], !snapshot.buckets.isEmpty {
                    ForEach(snapshot.buckets) { UsageRow(bucket: $0) }
                } else {
                    Text(store.snapshots[provider]?.message ?? "Waiting for refresh…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.needsKey(provider) {
                    KeyField(provider: provider, store: store)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        } else {
            // A provider that is switched off has nothing to show, so it does not get a card
            // to show it in - just the row you turn it back on from.
            header.padding(.horizontal, 12)
        }
    }

    private var header: some View {
        HStack {
            Text(provider.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(store.enabled(provider) ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: Binding(get: { store.enabled(provider) }, set: { store.setEnabled($0, for: provider) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}

/// One usage window on one line: label, bar, figure, reset.
///
/// The bar is inline rather than on a row of its own, which halves the menu without hiding
/// anything. Every bar starts at the same left edge and is the same width, so reading down
/// the column shows which limit is tightest without reading a single number - the
/// comparison a row of vertical columns would have given, except the labels survive.
private struct UsageRow: View {
    let bucket: UsageBucket

    var body: some View {
        HStack(spacing: 8) {
            Text(bucket.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 112, alignment: .leading)

            UsageBar(fraction: bucket.fractionUsed)

            Text(UsageFormat.value(bucket))
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)

            Text(UsageFormat.reset(bucket) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
        .font(.caption)
        .help(UsageFormat.detail(bucket))
    }
}

/// Orange for what is spent, blue for what is left, filling from the left.
///
/// The pair is the validated categorical slots 1 and 2: CVD separation deltaE 26.8 (protan),
/// normal-vision deltaE 31.8, both clearing 3:1 against this surface.
private struct UsageBar: View {
    let fraction: Double?

    private let segmentGap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            if let fraction {
                let used = min(max(fraction, 0), 1)
                let needsGap = used > 0.001 && used < 0.999
                let drawable = width - (needsGap ? segmentGap : 0)
                HStack(spacing: 0) {
                    Rectangle().fill(MeterPalette.used).frame(width: drawable * used)
                    if needsGap { Color.clear.frame(width: segmentGap) }
                    Rectangle().fill(MeterPalette.remaining).frame(width: drawable * (1 - used))
                }
            } else {
                // Nothing to divide by, so a filled bar would be a lie.
                Rectangle().fill(MeterPalette.remaining.opacity(0.18))
            }
        }
        .frame(height: 6)
        .clipShape(.rect(cornerRadius: 3))
    }
}

private struct MeterLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            swatch(MeterPalette.used, "used")
            swatch(MeterPalette.remaining, "left")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

enum MeterPalette {
    /// Slots 1 and 2 of the validated categorical theme, each with its own step per
    /// appearance rather than one colour dimmed for dark mode.
    static let used = dynamic(light: NSColor(srgbRed: 0.92, green: 0.41, blue: 0.20, alpha: 1),
                              dark: NSColor(srgbRed: 0.85, green: 0.35, blue: 0.15, alpha: 1))
    static let remaining = dynamic(light: NSColor(srgbRed: 0.16, green: 0.47, blue: 0.84, alpha: 1),
                                   dark: NSColor(srgbRed: 0.22, green: 0.53, blue: 0.90, alpha: 1))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

