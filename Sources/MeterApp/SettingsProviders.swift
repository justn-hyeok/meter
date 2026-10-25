import AppKit
import MeterCore
import SwiftUI

/// Providers on and off, keys, named accounts. (W2)
struct ProvidersSettingsTab: View {
    @Bindable var store: UsageStore

    var body: some View {
        Form {
            ForEach(ProviderID.allCases) { provider in
                Section {
                    ProviderHeader(provider: provider, status: store.credentialStatus[provider])
                    Toggle("Show in menu", isOn: Binding(
                        get: { store.enabled(Account(provider)) },
                        set: { store.setEnabled($0, for: Account(provider)) }
                    ))
                    if provider.acceptsStoredKey {
                        StoredKeyControls(provider: provider, store: store)
                    }
                    if provider.acceptsNamedAccounts {
                        NamedAccountControls(provider: provider, store: store)
                    }
                    if let fix = provider.signInFix {
                        SignInLine(fix: fix)
                    }
                }
            }
        }
        .formStyle(.grouped)
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

    private var windows: [MutedWindow] {
        MutedWindow.all(store.muted, in: store.snapshots)
    }

    var body: some View {
        Form {
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
