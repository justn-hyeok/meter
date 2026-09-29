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
        secret(for: Account(provider))
    }

    public func secret(for account: Account) -> String? {
        guard let value = document()[account.rawValue] as? String, !value.isEmpty else { return nil }
        return value
    }

    public func hasSecret(for provider: ProviderID) -> Bool {
        secret(for: provider) != nil
    }

    /// Named accounts with a key, per provider in the order their names sort.
    public func namedAccounts() -> [Account] {
        document().compactMap { key, value -> Account? in
            guard let value = value as? String, !value.isEmpty,
                  let account = Account(rawValue: key), account.name != nil else { return nil }
            return account
        }
        .sorted { ($0.provider.sortIndex, $0.name ?? "") < ($1.provider.sortIndex, $1.name ?? "") }
    }

    /// Passing nil removes the entry.
    ///
    /// Holds an exclusive lock across the read-modify-write: the app's Save button and a
    /// `meter set-key` in a terminal are separate processes on one file, and two unlocked
    /// read-modify-writes drop whichever key the loser had just added.
    public func setSecret(_ value: String?, for provider: ProviderID) throws {
        try setSecret(value, for: Account(provider))
    }

    public func setSecret(_ value: String?, for account: Account) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let descriptor = open(fileURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw SecretStoreError.unwritable(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SecretStoreError.unwritable(String(cString: strerror(errno)))
        }

        var root = Self.parse(readAll(descriptor))
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            root[account.rawValue] = trimmed
        } else {
            root[account.rawValue] = nil
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw SecretStoreError.unwritable(String(cString: strerror(errno)))
        }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                guard n > 0 else { throw SecretStoreError.unwritable(String(cString: strerror(errno))) }
                written += n
            }
        }
        // The file may have existed with a wider mode before Meter adopted it.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func document() -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return Self.parse(data)
    }

    /// Values are read one key at a time. Casting the whole document to [String: String]
    /// meant a single unexpected value hid every other key and the next write dropped them.
    private static func parse(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func readAll(_ descriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(descriptor, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }
}

public enum SecretStoreError: LocalizedError, Equatable {
    case unwritable(String)

    public var errorDescription: String? {
        switch self {
        case .unwritable(let reason): "could not write the key file: \(reason)"
        }
    }
}
