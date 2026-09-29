import Foundation
import MeterCore

enum CLITextFormatter {
    /// One line per window, laid out like the menu: label, two-tone bar, figure, reset.
    static func status(_ snapshots: [UsageSnapshot], now: Date = .now, style: TerminalStyle = .plain) -> String {
        let tightest = tightestWindow(in: snapshots)
        return snapshots.map { snapshot in
            let stale = snapshot.state == .stale
            var header = style.wrap(snapshot.provider.title, [.bold])
            if stale {
                header += "  " + style.wrap("(stale: \(snapshot.message ?? "showing the last figures that arrived"))", [.dim])
            }
            var lines = [header]
            if snapshot.buckets.isEmpty {
                lines.append("  " + style.wrap("unavailable  \(snapshot.message ?? "No usage data")", [.dim]))
            } else {
                for bucket in snapshot.buckets {
                    let isTightest = tightest == "\(snapshot.provider.rawValue)/\(bucket.id)"
                    let emphasis: [TerminalStyle.Attribute] = (isTightest ? [.bold] : []) + (stale ? [.dim] : [])
                    let row = [
                        style.wrap(fit(bucket.label, width: 20), emphasis),
                        UsageBarRenderer.render(bucket.fractionUsed, width: 10, style: style, dimmed: stale),
                        style.wrap(pad(UsageFormat.value(bucket), width: 10), emphasis),
                        style.wrap(pad(UsageFormat.reset(bucket, now: now) ?? "—", width: 3), [.dim]),
                    ]
                    lines.append("  " + row.joined(separator: "  "))
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The menu's rule, applied to the providers in the order they are printed.
    static func tightestWindow(in snapshots: [UsageSnapshot]) -> String? {
        TightestLimit.find(in: snapshots).map { "\($0.provider.rawValue)/\($0.bucketID)" }
    }

    private static func fit(_ value: String, width: Int) -> String {
        if value.count > width { return String(value.prefix(width - 1)) + "…" }
        return value + String(repeating: " ", count: width - value.count)
    }

    private static func pad(_ value: String, width: Int) -> String {
        value.count >= width ? value : String(repeating: " ", count: width - value.count) + value
    }

    static func providers(settings: MeterSettings) -> String {
        settings.providerOrder.map { provider in
            "\(settings.enabled(provider) ? "enabled " : "disabled")  \(provider.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(provider.title)"
        }.joined(separator: "\n")
    }

    static func doctor(_ statuses: [CredentialStatus]) -> String {
        statuses.map { status in
            [
                padded(status.availability.rawValue, to: 8),
                padded(status.provider.rawValue, to: 13),
                padded(status.source, to: 32),
                status.detail,
            ].joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func padded(_ value: String, to width: Int) -> String {
        guard value.count < width else { return value }
        return value + String(repeating: " ", count: width - value.count)
    }

}

/// Whether output is going to a person at a terminal or somewhere else.
///
/// Colour only for the first. Piped output, `NO_COLOR` and a dumb terminal get plain text,
/// so `meter | grep` never sees escape codes. `--json` is unaffected either way.
enum TerminalStyle: Equatable {
    case plain
    case color(trueColor: Bool)

    enum Attribute: String {
        case bold = "1"
        case dim = "2"
    }

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTerminal: Bool = isatty(STDOUT_FILENO) == 1
    ) -> TerminalStyle {
        guard isTerminal, environment["NO_COLOR"] == nil, environment["TERM"] != "dumb" else { return .plain }
        let colorTerm = environment["COLORTERM"]?.lowercased() ?? ""
        return .color(trueColor: colorTerm == "truecolor" || colorTerm == "24bit")
    }

    func wrap(_ text: String, _ attributes: [Attribute]) -> String {
        sgr(text, attributes.map(\.rawValue))
    }

    func sgr(_ text: String, _ codes: [String]) -> String {
        guard case .color = self, !codes.isEmpty, !text.isEmpty else { return text }
        return "\u{1B}[\(codes.joined(separator: ";"))m\(text)\u{1B}[0m"
    }

    /// The menu's pair: spent in orange, left in blue.
    var used: String { trueColor ? "38;2;217;89;38" : "38;5;166" }
    var left: String { trueColor ? "38;2;57;135;229" : "38;5;33" }
    var leftBackground: String { trueColor ? "48;2;57;135;229" : "48;5;33" }

    private var trueColor: Bool {
        if case .color(let trueColor) = self { return trueColor }
        return false
    }
}

/// Draws a usage bar in eighths of a cell, so 25% and 29% look different in ten columns.
enum UsageBarRenderer {
    private static let partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    static func render(_ fraction: Double?, width: Int, style: TerminalStyle, dimmed: Bool = false) -> String {
        guard let fraction else {
            // No limit to divide by, so a filled bar would be a claim Meter cannot make.
            return String(repeating: " ", count: width)
        }
        let eighths = Int((min(max(fraction, 0), 1) * Double(width * 8)).rounded())
        let full = eighths / 8
        let remainder = eighths % 8
        let rest = width - full - (remainder > 0 ? 1 : 0)
        let dim = dimmed ? ["2"] : []

        guard case .color = style else {
            return String(repeating: "█", count: full) + partials[remainder] + String(repeating: "░", count: rest)
        }
        // The partial cell is drawn in orange on a blue background, so spent and left meet
        // inside one character instead of leaving a gap.
        return style.sgr(String(repeating: "█", count: full), dim + [style.used])
            + (remainder > 0 ? style.sgr(partials[remainder], dim + [style.used, style.leftBackground]) : "")
            + style.sgr(String(repeating: "█", count: rest), dim + [style.left])
    }
}

private struct CLIJSONEnvelope: Encodable {
    // 2: Cursor's spend bucket id changed from "on-demand" to "spend".
    let schemaVersion = 2
    let generatedAt: Date
    let snapshots: [UsageSnapshot]
}

private struct CLIDoctorEnvelope: Encodable {
    // 2: availability gained "blocked".
    let schemaVersion = 2
    let generatedAt: Date
    let credentials: [CredentialStatus]
}

enum CLIJSONFormatter {
    static func doctor(_ statuses: [CredentialStatus], now: Date = .now) throws -> String {
        try encode(CLIDoctorEnvelope(generatedAt: now, credentials: statuses))
    }

    static func status(_ snapshots: [UsageSnapshot], now: Date = .now) throws -> String {
        try encode(CLIJSONEnvelope(generatedAt: now, snapshots: snapshots))
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
