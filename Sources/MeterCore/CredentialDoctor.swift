import Foundation

public struct CredentialStatus: Sendable, Equatable, Codable {
    public enum Availability: String, Sendable, Codable {
        case ready, missing
    }

    public let provider: ProviderID
    public let source: String
    public let availability: Availability
    public let detail: String

    public init(provider: ProviderID, source: String, availability: Availability, detail: String) {
        self.provider = provider
        self.source = source
        self.availability = availability
        self.detail = detail
    }
}

/// Reports where each provider's credential comes from and whether it is there.
///
/// Makes no network request and unlocks no secret: keychain items are probed by
/// attribute and cookie stores by name, both of which skip the permission prompt. That
/// keeps `meter doctor` safe to run at any time, including when a provider is broken.
public enum CredentialDoctor {
    public static func diagnose(_ providers: [ProviderID] = ProviderID.allCases) -> [CredentialStatus] {
        providers.map(status(for:))
    }

    private static func status(for provider: ProviderID) -> CredentialStatus {
        switch provider {
        case .codex: codex()
        case .claude: claude()
        case .cursor: cursor()
        case .deepSeek: deepSeek()
        case .commandCode: commandCode()
        }
    }

    private static func codex() -> CredentialStatus {
        let auth = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
        let present = FileManager.default.fileExists(atPath: auth.path)
        return .init(
            provider: .codex,
            source: "file ~/.codex/auth.json",
            availability: present ? .ready : .missing,
            detail: present ? "present" : "run 'codex login'"
        )
    }

    private static func claude() -> CredentialStatus {
        let service = ClaudeSubscriptionCredential.keychainService
        let present = Keychain.exists(service: service)
        return .init(
            provider: .claude,
            source: "keychain \(service)",
            availability: present ? .ready : .missing,
            detail: present ? "present; first read asks for keychain permission" : "run 'claude' and sign in"
        )
    }

    private static func cursor() -> CredentialStatus {
        let service = CursorSessionCredential.keychainService
        let present = Keychain.exists(service: service)
        return .init(
            provider: .cursor,
            source: "keychain \(service)",
            availability: present ? .ready : .missing,
            detail: present ? "present; first read asks for keychain permission" : "sign in to the Cursor app"
        )
    }

    private static func deepSeek() -> CredentialStatus {
        let present = !(ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? "").isEmpty
        return .init(
            provider: .deepSeek,
            source: "environment DEEPSEEK_API_KEY",
            availability: present ? .ready : .missing,
            detail: present ? "set" : "not set in this process"
        )
    }

    private static func commandCode() -> CredentialStatus {
        let host = CommandCodeUsageProvider.host
        let source = "browser cookies for \(host)"
        let installed = ChromiumBrowser.supported.filter(\.isInstalled)
        guard !installed.isEmpty else {
            return .init(
                provider: .commandCode,
                source: source,
                availability: .missing,
                detail: "no supported browser is installed"
            )
        }

        var inventory: [String] = []
        for browser in installed {
            let names = ChromiumCookieJar(browser: browser).cookieNames(host: host) ?? []
            let session = names.filter(ChromiumCookieJar.isSessionLike)
            if !session.isEmpty {
                return .init(
                    provider: .commandCode,
                    source: source,
                    availability: .ready,
                    detail: "\(browser.name) holds \(session.count) session cookie(s)"
                )
            }
            inventory.append("\(browser.name) \(names.count) cookie(s), none session-like")
        }
        return .init(
            provider: .commandCode,
            source: source,
            availability: .missing,
            detail: "sign in at \(host) — " + inventory.joined(separator: "; ")
        )
    }
}
