import CryptoKit
import Foundation

/// What was read from each append-only log file, kept so the next read starts where the
/// last one ended.
///
/// A coding tool's session log only grows, and almost all of it is conversation that holds
/// no usage. Reading a month of it again on every open was most of the Tokens view's wait.
/// Each file's records are kept with how far into the file they were read and a hash of
/// its first bytes: an unchanged file is not opened, a grown one is read from that offset
/// on, and one that shrank or was rewritten is read again from the start.
struct TokenFileCache: Sendable {
    /// Nil keeps nothing, so every read starts from the beginning.
    let directory: URL?

    private struct Entry: Codable {
        var size: Int
        var modified: Double
        var readBytes: Int
        /// How many leading bytes `head` covers: fewer than `headLength` for a file that
        /// was shorter than that, so a small file that grows is still recognised.
        var headBytes: Int
        var head: String
        var records: [TokenRecord]
    }

    private static let headLength = 1_024

    /// Every record in `file`. `parse` is handed whole lines only: a line still being
    /// written at the end of the file is left for the next read.
    func records(in file: URL, parse: (Data) -> [TokenRecord]) -> [TokenRecord] {
        // Asked of the file system each time: a URL caches its resource values, and a log
        // that grew since would look unchanged.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else { return [] }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        let stored = load(file)
        if let stored, stored.size == size, stored.modified == modified { return stored.records }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return stored?.records ?? [] }
        defer { try? handle.close() }
        let leading = (try? handle.read(upToCount: Self.headLength)) ?? Data()
        var entry = Entry(size: size, modified: modified, readBytes: 0, headBytes: leading.count,
                          head: Self.hash(leading), records: [])
        if let stored, stored.readBytes <= size, stored.headBytes <= leading.count,
           Self.hash(leading.prefix(stored.headBytes)) == stored.head {
            entry.readBytes = stored.readBytes
            entry.records = stored.records
        }
        guard (try? handle.seek(toOffset: UInt64(entry.readBytes))) != nil,
              let appended = try? handle.readToEnd(), !appended.isEmpty else {
            save(entry, for: file)
            return entry.records
        }
        // Up to the last newline: anything after it is a line not finished yet.
        guard let end = appended.lastIndex(of: UInt8(ascii: "\n")) else {
            save(entry, for: file)
            return entry.records
        }
        let complete = appended[appended.startIndex...end]
        entry.records += parse(Data(complete))
        entry.readBytes += complete.count
        save(entry, for: file)
        return entry.records
    }

    private func location(of file: URL) -> URL? {
        directory?.appending(path: Self.hash(Data(file.path.utf8)) + ".json")
    }

    private func load(_ file: URL) -> Entry? {
        guard let url = location(of: file), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func save(_ entry: Entry, for file: URL) {
        guard let url = location(of: file), let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `~/Library/Caches/com.justn.meter/<name>`, shared by the app and the CLI.
    static func standard(_ name: String) -> TokenFileCache {
        TokenFileCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "com.justn.meter/\(name)"))
    }
}
