import Foundation
import MeterCore

/// `meter tokens` and `meter models`: what the coding tools on this Mac spent, read from
/// their own logs.
enum TokensCommand {
    static func tokens(ledger: TokenLedger, window: String, grouping: TokenGrouping, json: Bool, now: Date = .now) -> CLIResult {
        .init(standardOutput: "", standardError: "meter tokens is not implemented yet", exitCode: 2)
    }

    static func models(ledger: TokenLedger, window: String, json: Bool, now: Date = .now) -> CLIResult {
        .init(standardOutput: "", standardError: "meter models is not implemented yet", exitCode: 2)
    }
}
