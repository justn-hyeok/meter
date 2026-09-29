import Darwin
import Foundation

public struct UsageCacheAttempt: Codable, Sendable {
    public let at: Date
    public let succeeded: Bool
    public let message: String?
}

public struct UsageCacheDetail: Sendable {
    public let account: Account
    public let snapshot: UsageSnapshot?
    public let lastAttempt: UsageCacheAttempt?
}

/// Shared, credential-free observations for the app and CLI.
public struct UsageCache: Sendable {
    public static let `default` = UsageCache()
    public static let maximumAge: TimeInterval = 360

    private let fileURL: URL

    public init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Meter/usage-cache.json")) {
        self.fileURL = fileURL
    }

    public func read(now: Date = .now, maximumAge: TimeInterval = UsageCache.maximumAge) -> [Account: UsageSnapshot] {
        guard let document = loadDocument() else { return [:] }
        var observations: [Account: UsageSnapshot] = [:]
        for snapshot in document.snapshots {
            guard snapshot.state != .unavailable, !snapshot.buckets.isEmpty else { continue }
            let age = now.timeIntervalSince(snapshot.fetchedAt)
            guard age >= -60 else { continue }
            if snapshot.state == .stale || age > maximumAge {
                observations[snapshot.accountID] = UsageSnapshot(
                    provider: snapshot.provider,
                    buckets: snapshot.buckets,
                    fetchedAt: snapshot.fetchedAt,
                    source: snapshot.source,
                    state: .stale,
                    message: snapshot.message ?? "cached observation from \(snapshot.fetchedAt.formatted())"
                ).for(snapshot.accountID)
                continue
            }
            observations[snapshot.accountID] = snapshot
        }
        return observations
    }

    public func details(for accounts: [Account], now: Date = .now) -> [UsageCacheDetail] {
        let snapshots = read(now: now)
        let attempts = loadDocument()?.attempts ?? [:]
        return accounts.map { account in
            UsageCacheDetail(account: account, snapshot: snapshots[account], lastAttempt: attempts[account.rawValue])
        }
    }

    public var isReadable: Bool { loadDocument() != nil }

    public func invalidatedAt(for account: Account) -> Date? {
        loadDocument()?.invalidations[account.rawValue]
    }

    /// Merge under a separate lock so two CLI refreshes cannot discard each other's accounts.
    public func save(_ updates: [UsageSnapshot], attemptedAt: Date = .now,
                     startedAt: Date? = nil) throws {
        try mutate { document in
            var entries = Dictionary(document.snapshots.map { ($0.accountID, $0) },
                                     uniquingKeysWith: { _, newer in newer })
            for snapshot in updates {
                let account = snapshot.accountID
                if let invalidated = document.invalidations[account.rawValue],
                   (startedAt ?? attemptedAt) <= invalidated { continue }
                if let previous = document.attempts[account.rawValue], previous.at > attemptedAt { continue }
                document.attempts[account.rawValue] = UsageCacheAttempt(
                    at: attemptedAt, succeeded: snapshot.state == .live,
                    message: snapshot.state == .live ? nil : snapshot.message
                )
                guard snapshot.state != .unavailable, !snapshot.buckets.isEmpty else { continue }
                if let existing = entries[account], existing.fetchedAt > snapshot.fetchedAt { continue }
                entries[account] = snapshot
            }
            document.snapshots = Array(entries.values)
        }
    }

    public func invalidate(_ account: Account, at: Date = .now) throws {
        try mutate { document in
            document.snapshots.removeAll { $0.accountID == account }
            document.attempts.removeValue(forKey: account.rawValue)
            document.invalidations[account.rawValue] = at
        }
    }

    private func mutate(_ update: (inout Document) -> Void) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { flock(lock, LOCK_UN) }

        var document = loadDocument() ?? Document(version: 3, snapshots: [], attempts: [:], invalidations: [:])
        update(&document)
        document.version = 3
        let data = try JSONEncoder().encode(document)
        let temporary = directory.appending(path: ".usage-cache-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { unlink(temporary.path) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            close(descriptor)
            throw error
        }
        close(descriptor)
        guard rename(temporary.path, fileURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func loadDocument() -> Document? {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              (1...3).contains(document.version) else { return nil }
        return document
    }

    private struct Document: Codable {
        var version: Int
        var snapshots: [UsageSnapshot]
        var attempts: [String: UsageCacheAttempt]
        var invalidations: [String: Date]

        init(version: Int, snapshots: [UsageSnapshot], attempts: [String: UsageCacheAttempt], invalidations: [String: Date]) {
            self.version = version
            self.snapshots = snapshots
            self.attempts = attempts
            self.invalidations = invalidations
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            snapshots = try container.decode([UsageSnapshot].self, forKey: .snapshots)
            attempts = try container.decodeIfPresent([String: UsageCacheAttempt].self, forKey: .attempts) ?? [:]
            invalidations = try container.decodeIfPresent([String: Date].self, forKey: .invalidations) ?? [:]
        }
    }
}
