import AppKit
import MeterCore
import SwiftUI

/// Providers on and off, keys, named accounts. (W2)
struct ProvidersSettingsTab: View {
    @Bindable var store: UsageStore
    @Bindable var alerts: AlertCenter

    var body: some View {
        Form {
            // `custom` has no default account and no stored-key field of its own; it has the
            // section below instead.
            ForEach(ProviderID.allCases.filter { $0 != .custom }) { provider in
                Section {
                    ProviderHeader(provider: provider, status: store.credentialStatus[provider])
                    Toggle("Show in menu", isOn: Binding(
                        get: { store.enabled(Account(provider)) },
                        set: { store.setEnabled($0, for: Account(provider)) }
                    ))
                    TileSizePicker(account: Account(provider), store: store)
                    if alerts.isEnabled {
                        AccountPercentsField(account: Account(provider), alerts: alerts)
                    }
                    if provider.acceptsStoredKey {
                        StoredKeyControls(provider: provider, store: store)
                    }
                    if provider.acceptsNamedAccounts {
                        NamedAccountControls(provider: provider, store: store, alerts: alerts)
                    }
                    if let fix = provider.signInFix {
                        SignInLine(fix: fix)
                    }
                }
            }
            CustomProvidersSection(store: store)
            AddCustomProviderSection(store: store)
            NotSuggestedSection(store: store)
        }
        .formStyle(.grouped)
    }
}

/// The same choice as the tile's right-click Size menu, for someone who has not found it.
private struct TileSizePicker: View {
    let account: Account
    @Bindable var store: UsageStore

    /// What the tile may be, plus the size it already is: a size the account was set to
    /// before its figures changed would otherwise have no row to show as selected.
    private var sizes: [TileSize] {
        let offered = TileSize.offered(for: store.snapshots[account])
        let current = store.tileSize(account)
        return offered.contains(current) ? offered : offered + [current]
    }

    var body: some View {
        Picker("Tile size", selection: Binding(
            get: { store.tileSize(account) },
            set: { store.setTileSize($0, for: account) }
        )) {
            ForEach(sizes, id: \.self) { Text($0.title).tag($0) }
        }
    }
}

/// The provider's name, where its credential comes from and whether it is there: one glance
/// before the controls under it.
private struct ProviderHeader: View {
    let provider: ProviderID
    let status: CredentialStatus?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title)
                    .font(.headline)
                Text(status?.detail ?? "No credential reported yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var color: Color {
        switch status?.availability {
        case .ready: Color(nsColor: .systemGreen)
        case .missing: Color(nsColor: .systemOrange)
        case .blocked: Color(nsColor: .systemRed)
        case nil: .secondary
        @unknown default: .secondary
        }
    }
}

/// A key Meter keeps for the provider, typed here rather than through the CLI.
private struct StoredKeyControls: View {
    let provider: ProviderID
    @Bindable var store: UsageStore
    @State private var key = ""
    @State private var failure: String?
    @State private var isConfirmingRemoval = false

    private var hasKey: Bool { store.hasStoredKey(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField(hasKey ? "Replace key" : "API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { save() }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if hasKey {
                Button("Remove key") { isConfirmingRemoval = true }
            }
        }
        .confirmationDialog("Remove the stored key?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove key", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(provider.title) goes back to the credential this Mac already has, if any.")
        }
    }

    private func save() {
        do {
            try store.storeKey(key, for: provider)
            key = ""
            failure = nil
        } catch {
            // Keep what was typed: the save is what failed, not the key.
            failure = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try store.clearKey(for: provider)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The extra accounts a provider can hold, each switched on by itself, and the way to add
/// another.
private struct NamedAccountControls: View {
    let provider: ProviderID
    @Bindable var store: UsageStore
    @Bindable var alerts: AlertCenter
    @State private var name = ""
    @State private var key = ""
    @State private var failure: String?
    @State private var isAdding = false
    @State private var removal: Account?

    private var accounts: [Account] {
        store.accounts.filter { $0.provider == provider && $0.name != nil }
    }

    /// The default account counts towards the limit, so two named ones fill it.
    private var isFull: Bool {
        store.accounts.filter { $0.provider == provider }.count >= Account.limitPerProvider
    }

    private var canAdd: Bool {
        !isFull
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    var body: some View {
        Group {
            ForEach(accounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(account.title)
                            .lineLimit(1)
                        Spacer()
                        Button("Remove", role: .destructive) { removal = account }
                    }
                    Toggle("Show in menu", isOn: Binding(
                        get: { store.enabled(account) },
                        set: { store.setEnabled($0, for: account) }
                    ))
                    TileSizePicker(account: account, store: store)
                    if alerts.isEnabled {
                        AccountPercentsField(account: account, alerts: alerts)
                    }
                }
            }
            DisclosureGroup("Add account", isExpanded: $isAdding) {
                TextField("Name", text: $name)
                SecureField("API key", text: $key)
                HStack {
                    if isFull {
                        Text(AccountError.full(provider).localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Add") { add() }
                        .disabled(!canAdd)
                }
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog("Remove account?", isPresented: isRemoving, titleVisibility: .visible,
                            presenting: removal) { account in
            Button("Remove \(account.title)", role: .destructive) { remove(account) }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("The key for \(account.title) is deleted from this Mac.")
        }
    }

    private func add() {
        do {
            try store.addAccount(provider, name: name, key: key)
            name = ""
            key = ""
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove(_ account: Account) {
        do {
            try store.removeAccount(account)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Custom OpenAI-compatible providers that were added, each switched on by itself.
private struct CustomProvidersSection: View {
    @Bindable var store: UsageStore
    @State private var failure: String?
    @State private var removal: Account?

    private var accounts: [Account] {
        store.accounts.filter { $0.provider == .custom }
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    var body: some View {
        Section("Custom providers") {
            if accounts.isEmpty {
                Text("No custom providers yet. Add an OpenAI-compatible API below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.title)
                                .lineLimit(1)
                            if let saved = store.customProviders[account.name ?? ""]?.baseURL {
                                Text(saved)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Remove", role: .destructive) { removal = account }
                    }
                    Toggle("Show in menu", isOn: Binding(
                        get: { store.enabled(account) },
                        set: { store.setEnabled($0, for: account) }
                    ))
                    TileSizePicker(account: account, store: store)
                }
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Remove custom provider?", isPresented: isRemoving, titleVisibility: .visible,
                            presenting: removal) { account in
            Button("Remove \(account.title)", role: .destructive) { remove(account) }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("The key and base URL for \(account.title) are deleted from this Mac.")
        }
    }

    private func remove(_ account: Account) {
        do {
            try store.removeAccount(account)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The form that adds one. What such an API reports is not knowable, so the hint under the
/// address says which of the two things its tile will show.
private struct AddCustomProviderSection: View {
    @Bindable var store: UsageStore
    @State private var name = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var failure: String?

    private var address: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var kind: CustomProviderKind? {
        address.isEmpty ? nil : CustomProviderKind.detect(baseURL: address)
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !address.isEmpty
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section("Add a custom provider") {
            TextField("Name", text: $name)
            TextField("Base URL", text: $baseURL)
            if let kind {
                Text(kind.hint)
                    .font(.caption)
                    .foregroundStyle(kind == .generic
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(Color(nsColor: .systemGreen)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField("API key", text: $key)
            HStack {
                Spacer(minLength: 0)
                Button("Add") { add() }
                    .disabled(!canAdd)
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func add() {
        do {
            try store.addCustomProvider(name: name, baseURL: baseURL, key: key)
            name = ""
            baseURL = ""
            key = ""
            failure = nil
        } catch {
            // Keep what was typed: the save is what failed, not the address.
            failure = error.localizedDescription
        }
    }
}

/// Switched-off chips the user put away, to bring back. Empty means there is no section:
/// a heading with nothing under it would read as a missing feature. (W4)
private struct NotSuggestedSection: View {
    @Bindable var store: UsageStore

    private var accounts: [Account] {
        store.hiddenSuggestions
            .filter { store.accounts.contains($0) && !store.enabled($0) }
            .sorted { $0.title < $1.title }
    }

    var body: some View {
        if !accounts.isEmpty {
            Section("Not suggested in the menu") {
                ForEach(accounts) { account in
                    HStack(spacing: 8) {
                        Text(account.title)
                        Spacer(minLength: 0)
                        Button("Suggest again") { store.setSuggestionHidden(false, for: account) }
                    }
                }
            }
        }
    }
}

/// Where the session lives, for a provider Meter cannot fix with a key of its own.
private struct SignInLine: View {
    let fix: SignInFix

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("How to sign in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(fix.instruction)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let url = fix.url {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

/// Windows whose warnings are muted, to switch back on. (W2)
struct WarningsSettingsTab: View {
    @Bindable var store: UsageStore
    @Bindable var alerts: AlertCenter

    private var windows: [MutedWindow] {
        MutedWindow.all(store.muted, in: store.snapshots)
    }

    private var alertable: [AlertableWindow] {
        store.snapshots.values
            .flatMap { snapshot in
                snapshot.buckets.compactMap { bucket -> AlertableWindow? in
                    guard bucket.alertFraction != nil else { return nil }
                    return AlertableWindow(
                        key: BucketKey(account: snapshot.accountID, bucketID: bucket.id),
                        accountTitle: snapshot.accountID.title,
                        label: bucket.label
                    )
                }
            }
            .sorted { ($0.accountTitle, $0.label, $0.key.bucketID) < ($1.accountTitle, $1.label, $1.key.bucketID) }
    }

    var body: some View {
        Form {
            if alerts.isEnabled {
                Section("Percents") {
                    Text("Empty inherits the provider list, then General. Dollar windows with a cap use the same steps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if alertable.isEmpty {
                        Text("No windows with a limit yet. Refresh, then set percents here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(alertable) { window in
                            LabeledContent("\(window.accountTitle) · \(window.label)") {
                                AlertPercentsField(
                                    placeholder: alerts.inheritedPercents(for: window.key),
                                    current: alerts.percentsText(for: window.key)
                                ) { alerts.setPercentsText($0, for: window.key) }
                            }
                        }
                    }
                }
            }
            Section {
                Text("Muted windows keep their figure but lose colour, alerts and their place in the menu bar gauge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                if windows.isEmpty {
                    Text("No muted windows. Right-click a tile in the menu to mute one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(windows) { window in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.accountTitle)
                                Text(window.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Warn again") { store.setMuted(false, window.key) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlertableWindow: Identifiable {
    let key: BucketKey
    let accountTitle: String
    let label: String
    var id: BucketKey { key }
}

private struct AccountPercentsField: View {
    let account: Account
    @Bindable var alerts: AlertCenter

    var body: some View {
        LabeledContent("Percents") {
            AlertPercentsField(
                placeholder: alerts.inheritedPercents(for: account),
                current: alerts.percentsText(for: account)
            ) { alerts.setPercentsText($0, for: account) }
        }
    }
}
