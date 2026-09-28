import Foundation

/// Stores per-provider API keys that Meter is given directly.
///
/// The file sits at `~/Library/Application Support/Meter/credentials.json` with `0600`,
/// alongside how `~/.codex/auth.json` and `~/.commandcode/auth.json` already keep the
/// same class of secret. A file rather than the keychain because the app and the `meter`
/// CLI are separately signed binaries with different designated requirements: a keychain
/// item written by one would prompt the other on every read. It is also strictly better
/// than the environment variable it replaces, which leaks into every child process.
public struct SecretStore: Sendable {
    public static let `default` = SecretStore()

    private let fileURL: URL

    public init(fileURL: URL = SecretStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Meter/credentials.json")
    }

    public func secret(for provider: ProviderID) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let value = root[provider.rawValue],
              !value.isEmpty else {
            return nil
        }
        return value
    }

    public func hasSecret(for provider: ProviderID) -> Bool {
        secret(for: provider) != nil
    }

    /// Passing nil removes the entry.
    public func setSecret(_ value: String?, for provider: ProviderID) throws {
        var root = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]

        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            root[provider.rawValue] = trimmed
        } else {
            root[provider.rawValue] = nil
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try data.write(to: fileURL, options: .atomic)
        // An atomic write replaces the file, so the mode has to be reapplied every time.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
