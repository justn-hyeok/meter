import Foundation

public struct CredentialStatus: Sendable, Equatable, Codable {
    public enum Availability: String, Sendable, Codable {
        case ready
        case missing
        /// The credential exists but Meter may not be able to use it: a locked keychain, a
        /// grant a rebuild revoked, or a key that only this shell can see.
        case blocked
    }

    public let provider: ProviderID
    /// A named account's name; absent for the default account, whose JSON is unchanged.
    public let account: String?
    public let source: String
    public let availability: Availability
    public let detail: String

    public init(provider: ProviderID, account: String? = nil, source: String, availability: Availability, detail: String) {
        self.provider = provider
        self.account = account
        self.source = source
        self.availability = availability
        self.detail = detail
    }

    public var isUsable: Bool { availability == .ready }
    public var accountID: Account { Account(provider, name: account) }
}

/// Everything the doctor reads about the machine, in one place so every branch can be
/// exercised. The previous version reached straight for the real keychain and home
/// directory, which left its test unable to fail.
///
/// Constructed inside the module; callers outside it use `.live`.
public struct DiagnosticEnvironment: Sendable {
    public var environment: [String: String]
    public var secrets: SecretStore
    public var keychain: @Sendable (String) -> Keychain.Presence
    public var fileExists: @Sendable (URL) -> Bool
    public var codexExecutable: @Sendable () -> URL?
    /// Whether OpenCode's auth file holds an OpenCode Go key. Its existence alone says
    /// nothing: the file lists every provider OpenCode is connected to.
    public var openCodeGoKey: @Sendable () -> Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secrets: SecretStore = .default,
        keychain: @escaping @Sendable (String) -> Keychain.Presence = { Keychain.probe(service: $0) },
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        codexExecutable: @escaping @Sendable () -> URL? = DiagnosticEnvironment.liveCodexExecutable,
        openCodeGoKey: @escaping @Sendable () -> Bool = { OpenCodeGoCredential().cliKey() != nil }
    ) {
        self.environment = environment
        self.secrets = secrets
        self.keychain = keychain
        self.fileExists = fileExists
        self.codexExecutable = codexExecutable
        self.openCodeGoKey = openCodeGoKey
    }

    static var codexAuthFile: URL { CodexUsageProvider.authFile }

    static let liveCodexExecutable: @Sendable () -> URL? = { CodexAppServerBridge.locateExecutable() }

    public static let live = DiagnosticEnvironment()
}

/// Reports where each provider's credential comes from and whether it is there.
///
/// Makes no network request and unlocks no secret: keychain items are probed by attribute
/// and files by existence, both of which skip the permission prompt. That keeps
/// `meter doctor` safe to run at any time, including when a provider is broken.
public enum CredentialDoctor {
    public static func diagnose(
        _ providers: [ProviderID] = ProviderID.allCases,
        in machine: DiagnosticEnvironment = .live
    ) -> [CredentialStatus] {
        providers.map { status(for: $0, in: machine) }
    }

    /// A named account is nothing but its stored key, so there is one thing to check.
    public static func diagnose(_ account: Account, in machine: DiagnosticEnvironment = .live) -> CredentialStatus {
        guard account.name != nil else { return status(for: account.provider, in: machine) }
        let present = machine.secrets.secret(for: account) != nil
        return .init(
            provider: account.provider,
            account: account.name,
            source: "stored key",
            availability: present ? .ready : .missing,
            detail: present ? "stored key present" : "run 'meter set-key \(account.provider.rawValue) --name \(account.name ?? "")'"
        )
    }

    private static func status(for provider: ProviderID, in machine: DiagnosticEnvironment) -> CredentialStatus {
        switch provider {
        case .codex: codex(machine)
        case .claude: claude(machine)
        case .cursor: keychainBacked(.cursor, CursorSessionCredential.keychainService, missing: "sign in to the Cursor app", machine)
        case .deepSeek: apiKeyBacked(.deepSeek, DeepSeekUsageProvider.environmentKey, stored: true, cliFile: nil, machine)
        case .commandCode: apiKeyBacked(
            .commandCode,
            CommandCodeAPIKeyCredential.environmentKey,
            stored: true,
            cliFile: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".commandcode/auth.json"),
            machine
        )
        case .openCodeGo: openCodeGo(machine)
        }
    }

    /// Mirrors `CodexUsageProvider.fetch`, which tries the app-server first and only then
    /// falls back to the auth file. Checking one of the two reported the wrong answer in
    /// both directions.
    private static func codex(_ machine: DiagnosticEnvironment) -> CredentialStatus {
        let executable = machine.codexExecutable()
        let hasAuthFile = machine.fileExists(DiagnosticEnvironment.codexAuthFile)
        switch (executable, hasAuthFile) {
        case (let executable?, true):
            return .init(provider: .codex, source: "Codex app-server or auth file", availability: .ready,
                         detail: "\(executable.lastPathComponent) found, ~/.codex/auth.json present")
        case (let executable?, false):
            return .init(provider: .codex, source: "Codex app-server", availability: .ready,
                         detail: "\(executable.lastPathComponent) found; no ~/.codex/auth.json to fall back on")
        case (nil, true):
            return .init(provider: .codex, source: "~/.codex/auth.json", availability: .ready,
                         detail: "auth file present; no Codex executable for the app-server path")
        case (nil, false):
            return .init(provider: .codex, source: "Codex app-server or auth file", availability: .missing,
                         detail: "run 'codex login'")
        }
    }

    /// Prefers a token stored in Meter, because the keychain path re-prompts every time
    /// Claude Code refreshes its session - roughly three times a day.
    private static func claude(_ machine: DiagnosticEnvironment) -> CredentialStatus {
        if machine.secrets.hasSecret(for: .claude) {
            return .init(provider: .claude, source: "stored Claude token", availability: .ready,
                         detail: "stored token in use; the keychain is not read")
        }
        let keychain = keychainBacked(
            .claude,
            ClaudeSubscriptionCredential.keychainService,
            missing: "run 'claude' and sign in",
            machine
        )
        guard keychain.availability == .ready else { return keychain }
        return .init(
            provider: .claude,
            source: keychain.source,
            availability: .ready,
            detail: "present; macOS re-asks each time Claude Code rotates the session"
        )
    }

    private static func keychainBacked(
        _ provider: ProviderID,
        _ service: String,
        missing: String,
        _ machine: DiagnosticEnvironment
    ) -> CredentialStatus {
        let source = "keychain \(service)"
        switch machine.keychain(service) {
        case .present:
            return .init(provider: provider, source: source, availability: .ready,
                         detail: "present; access is confirmed on first read")
        case .missing:
            return .init(provider: provider, source: source, availability: .missing, detail: missing)
        case .blocked:
            return .init(provider: provider, source: source, availability: .blocked,
                         detail: "the login keychain is locked or access was refused")
        case .unknown(let status):
            return .init(provider: provider, source: source, availability: .blocked,
                         detail: "keychain returned OSStatus \(status)")
        }
    }

    private static func openCodeGo(_ machine: DiagnosticEnvironment) -> CredentialStatus {
        let source = "API key (env, stored, or OpenCode)"
        if machine.openCodeGoKey() && !machine.secrets.hasSecret(for: .openCodeGo) {
            return .init(provider: .openCodeGo, source: source, availability: .ready,
                         detail: "from OpenCode's auth.json (connected with /connect)")
        }
        let status = apiKeyBacked(.openCodeGo, OpenCodeGoCredential.environmentKey, stored: true, cliFile: nil, machine)
        return .init(provider: .openCodeGo, source: source, availability: status.availability,
                     detail: status.availability == .missing
                        ? "connect OpenCode Go in OpenCode (/connect), or run 'meter set-key opencode-go'"
                        : status.detail)
    }

    private static func apiKeyBacked(
        _ provider: ProviderID,
        _ variable: String,
        stored: Bool,
        cliFile: URL?,
        _ machine: DiagnosticEnvironment
    ) -> CredentialStatus {
        let source = cliFile == nil ? "API key (env or stored)" : "API key (env, stored, or CLI)"
        if stored, machine.secrets.hasSecret(for: provider) {
            return .init(provider: provider, source: source, availability: .ready, detail: "stored key present")
        }
        if let cliFile, machine.fileExists(cliFile) {
            return .init(provider: provider, source: source, availability: .ready,
                         detail: "from \(cliFile.lastPathComponent) written by its CLI")
        }
        // An environment variable is real for this shell and invisible to the app Finder
        // launches, which is the whole reason stored keys exist. Reporting it as ready made
        // `doctor --strict` pass while the menu bar showed nothing.
        if !(machine.environment[variable] ?? "").isEmpty {
            return .init(provider: provider, source: source, availability: .blocked,
                         detail: "\(variable) is set in this shell only; the app will not see it - run 'meter set-key \(provider.rawValue)'")
        }
        return .init(provider: provider, source: source, availability: .missing,
                     detail: "run 'meter set-key \(provider.rawValue)'")
    }
}
