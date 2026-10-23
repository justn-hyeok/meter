import Foundation
import SQLite3

/// Reads the messages OpenCode stores in its SQLite database.
///
/// OpenCode writes the database in WAL mode while it runs, so the newest messages live in
/// the `-wal` file rather than the database file. The connection is read-only and is never
/// allowed to checkpoint, so a read leaves the running app's log untouched.
public struct OpenCodeLogSource: TokenLogSource {
    public let tool = UsageTool.openCode

    private let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public static var `default`: OpenCodeLogSource {
        OpenCodeLogSource(databaseURL: defaultDatabaseURL())
    }

    /// OpenCode follows the XDG base directory when `XDG_DATA_HOME` is set and falls back
    /// to `~/.local/share`. Both are injectable so the resolution can be tested without
    /// reading the real data directory.
    public static func defaultDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let dataHome = environment["XDG_DATA_HOME"], !dataHome.isEmpty {
            return URL(fileURLWithPath: dataHome, isDirectory: true).appending(path: "opencode/opencode.db")
        }
        return homeDirectory.appending(path: ".local/share/opencode/opencode.db")
    }

    public func records(since: Date?) throws -> [TokenRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }

        var database: OpaquePointer?
        let status = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(databaseURL.path)"
            if let database { sqlite3_close(database) }
            throw OpenCodeLogSourceError.open(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)

        var sql = """
            SELECT m.id, m.session_id, m.time_created, m.data, s.directory
            FROM message m
            JOIN session s ON s.id = m.session_id
            """
        if since != nil { sql += "\nWHERE m.time_created >= ?" }
        sql += "\nORDER BY m.time_created, m.id"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw OpenCodeLogSourceError.query(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        if let since {
            // Message times are whole milliseconds, so rounding up keeps the boundary exact
            // for a `since` carrying a fraction of one.
            let milliseconds = Int64((since.timeIntervalSince1970 * 1_000).rounded(.up))
            sqlite3_bind_int64(statement, 1, milliseconds)
        }

        var records: [TokenRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let record = Self.record(from: statement) { records.append(record) }
            case SQLITE_DONE:
                return records
            default:
                throw OpenCodeLogSourceError.query(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private static func record(from statement: OpaquePointer) -> TokenRecord? {
        guard let id = text(statement, 0),
              let sessionID = text(statement, 1),
              let payload = text(statement, 3) else { return nil }
        let timeCreated = sqlite3_column_int64(statement, 2)
        let directory = text(statement, 4)

        guard let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
              let message = root as? [String: Any],
              message["role"] as? String == "assistant",
              let provider = message["providerID"] as? String,
              let model = message["modelID"] as? String,
              let tokens = message["tokens"] as? [String: Any] else { return nil }

        let input = integer(tokens["input"])
        let output = integer(tokens["output"])
        // OpenCode reports reasoning beside output; the contract counts it inside output.
        let reasoning = integer(tokens["reasoning"])
        let cache = tokens["cache"] as? [String: Any]
        let counts = TokenCounts(
            input: input,
            output: output + reasoning,
            cacheRead: integer(cache?["read"]),
            cacheWrite: integer(cache?["write"]),
            reasoning: reasoning
        )
        // A message that was started but never answered has a row and no usage in it.
        guard counts.total > 0 else { return nil }

        let time = message["time"] as? [String: Any]
        let created = (time?["created"] as? NSNumber)?.int64Value ?? timeCreated
        let cost = (message["cost"] as? NSNumber)?.doubleValue
        return TokenRecord(
            id: id,
            tool: .openCode,
            provider: provider,
            model: model,
            timestamp: Date(timeIntervalSince1970: Double(created) / 1_000),
            sessionID: sessionID,
            project: directory,
            tokens: counts,
            costUSD: (cost ?? 0) > 0 ? cost : nil
        )
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}

public enum OpenCodeLogSourceError: LocalizedError, Sendable {
    case open(String)
    case query(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): "cannot open the OpenCode database: \(message)"
        case .query(let message): "cannot read the OpenCode database: \(message)"
        }
    }
}
