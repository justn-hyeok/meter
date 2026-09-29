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
            // The number beside the needle is the whole point: most checks are "am I near a
            // limit", and answering that in the menu bar means never opening the menu.
            MenuBarLabel(icon: icon, headline: headline)
                .task {
                    store.onAlerts = { Notifier.post($0) }
                    Notifier.requestAuthorization()
                    store.start()
                }
        }
        .menuBarExtraStyle(.window)
    }

    /// The tightest limit, as a whole percent. Nil when nothing measurable is known, which
    /// is not the same as zero.
    private var headline: String? {
        guard !store.isAllUnavailable, let usage = store.highestUsage else { return nil }
        return String(format: "%.0f%%", usage * 100)
    }

    private var icon: String {
        if store.isAllUnavailable { return "exclamationmark.triangle" }
        guard let usage = store.highestUsage else { return "gauge.with.dots.needle.0percent" }
        if usage >= 0.95 { return "gauge.with.dots.needle.100percent" }
        if usage >= 0.8 { return "gauge.with.dots.needle.67percent" }
        return "gauge.with.dots.needle.33percent"
    }
}

private struct MenuBarLabel: View {
    let icon: String
    let headline: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            if let headline {
                Text(headline).font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
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
            VStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.title).font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { store.enabled(provider) }, set: { store.setEnabled($0, for: provider) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if store.enabled(provider) {
                if let snapshot = store.snapshots[provider], !snapshot.buckets.isEmpty {
                    let columns = snapshot.buckets.filter { $0.fractionUsed != nil }
                    let lines = snapshot.buckets.filter { $0.fractionUsed == nil }
                    if !columns.isEmpty {
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(columns) { UsageColumn(bucket: $0) }
                            Spacer(minLength: 0)
                        }
                    }
                    ForEach(lines) { UsageLine(bucket: $0) }
                } else {
                    Text(store.snapshots[provider]?.message ?? "Waiting for refresh…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.needsKey(provider) {
                    KeyField(provider: provider, store: store)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One usage window as a vertical column: orange for what is spent, blue for what is
/// left, growing from a baseline at the bottom.
///
/// Columns side by side make the comparison the list could not: the tallest orange is the
/// limit that will bite first, without reading a single number. The pair is the palette's
/// dark categorical slots 1 and 2, which clear CVD separation (ΔE 26.8 protan) and 3:1
/// contrast against this surface.
private struct UsageColumn: View {
    let bucket: UsageBucket

    private let height: CGFloat = 44
    private let width: CGFloat = 14
    /// A gap in the surface colour, not a stroke, is what separates the two segments.
    private let segmentGap: CGFloat = 2

    var body: some View {
        VStack(spacing: 4) {
            Text(UsageFormat.value(bucket))
                .font(.caption2.monospacedDigit())
            column
            Text(bucket.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 64)
        .help(UsageFormat.detail(bucket))
    }

    private var column: some View {
        VStack(spacing: 0) {
            if let fraction = bucket.fractionUsed {
                let used = min(max(fraction, 0), 1)
                let needsGap = used > 0.001 && used < 0.999
                let drawable = height - (needsGap ? segmentGap : 0)
                Rectangle().fill(MeterPalette.remaining)
                    .frame(height: drawable * (1 - used))
                if needsGap { Color.clear.frame(height: segmentGap) }
                Rectangle().fill(MeterPalette.used)
                    .frame(height: drawable * used)
            } else {
                // No limit to divide by, so the column would be a lie; keep the slot quiet.
                Rectangle().fill(MeterPalette.remaining.opacity(0.2))
                    .frame(height: height)
            }
        }
        .frame(width: width, height: height)
        // Rounded at the data end, square where it meets the baseline.
        .clipShape(.rect(topLeadingRadius: 4, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 4))
    }
}

/// A bucket with no limit to divide by - a balance, a running total - reads as a line.
private struct UsageLine: View {
    let bucket: UsageBucket

    var body: some View {
        HStack {
            Text(bucket.label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(UsageFormat.value(bucket)).font(.caption.monospacedDigit())
        }
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

enum UsageFormat {
    static func value(_ bucket: UsageBucket) -> String {
        if let percentage = bucket.percentageUsed { return String(format: "%.0f%%", percentage) }
        if bucket.unit == .usd {
            if let remaining = bucket.remaining { return String(format: "$%.2f left", remaining) }
            if let used = bucket.used, let limit = bucket.limit {
                return String(format: "$%.2f / $%.2f", used, limit)
            }
            if let used = bucket.used { return String(format: "$%.2f", used) }
        }
        if let remaining = bucket.remaining { return "\(String(format: "%.2f", remaining)) \(bucket.unit.rawValue)" }
        if let used = bucket.used { return "\(String(format: "%.2f", used)) \(bucket.unit.rawValue) used" }
        return "—"
    }

    /// The tooltip carries what the column cannot: the full label and when it resets.
    static func detail(_ bucket: UsageBucket) -> String {
        guard let resetAt = bucket.resetAt else { return bucket.label }
        return "\(bucket.label) · resets \(resetAt.formatted(.relative(presentation: .named)))"
    }
}
