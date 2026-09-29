import Foundation
import MeterCore

/// Which providers a status query covers.
///
/// `all` is its own case. It used to expand to every provider in declaration order, and
/// the query then recognised it by comparing against that list - so typing all five names
/// in that order was taken for `all` and printed in the menu's order instead of as typed.
enum ProviderSelection: Equatable {
    /// Those switched on in settings, in the menu's order.
    case enabled
    /// Every provider, switched on or not, in the menu's order.
    case all
    /// Exactly these, in the order typed.
    case named([ProviderID])
}

enum CLICommand: Equatable {
    case status(ProviderSelection)
    case doctor
    case providers
    case enable([ProviderID])
    case disable([ProviderID])
    case setKey(ProviderID)
    case clearKey(ProviderID)
    case help
    case version
}

struct CLIOptions: Equatable {
    let command: CLICommand
    let json: Bool
    let strict: Bool
}

enum CLIArgumentError: LocalizedError, Equatable {
    case unknownOption(String)
    case unknownCommandOrProvider(String)
    case missingProviders(String)
    case unexpectedArguments(String)
    case statusOnlyOption
    case oneProviderRequired(String)
    case providerTakesNoKey(ProviderID)

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option):
            "Unknown option: \(option)"
        case .unknownCommandOrProvider(let value):
            "Unknown command or provider: \(value)"
        case .missingProviders(let command):
            "The \(command) command requires at least one provider"
        case .unexpectedArguments(let command):
            "The \(command) command does not accept arguments"
        case .oneProviderRequired(let command):
            "The \(command) command takes exactly one provider"
        case .providerTakesNoKey(let provider):
            "\(provider.title) does not use a stored key; Meter reads its credential from this machine"
        case .statusOnlyOption:
            "The --json and --strict options are only valid for status and doctor queries"
        }
    }
}

enum CLIArgumentParser {
    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var json = false
        var strict = false
        var positional: [String] = []

        for argument in arguments {
            switch argument {
            case "--json": json = true
            case "--strict": strict = true
            case "--help", "-h": return .init(command: .help, json: false, strict: false)
            case "--version", "-V": return .init(command: .version, json: false, strict: false)
            default:
                if argument.hasPrefix("-") { throw CLIArgumentError.unknownOption(argument) }
                positional.append(argument)
            }
        }

        guard let first = positional.first else {
            return .init(command: .status(.enabled), json: json, strict: strict)
        }

        let rest = Array(positional.dropFirst())
        let command: CLICommand
        switch first {
        case "status": command = .status(try parseSelection(rest))
        case "set-key", "clear-key":
            guard let providers = try parseProviders(rest), providers.count == 1 else {
                throw CLIArgumentError.oneProviderRequired(first)
            }
            guard providers[0].acceptsStoredKey else {
                throw CLIArgumentError.providerTakesNoKey(providers[0])
            }
            command = first == "set-key" ? .setKey(providers[0]) : .clearKey(providers[0])
        case "doctor":
            guard rest.isEmpty else { throw CLIArgumentError.unexpectedArguments(first) }
            command = .doctor
        case "providers":
            guard rest.isEmpty else { throw CLIArgumentError.unexpectedArguments(first) }
            command = .providers
        case "enable", "disable":
            guard !rest.isEmpty else { throw CLIArgumentError.missingProviders(first) }
            guard let providers = try parseProviders(rest), !providers.isEmpty else {
                throw CLIArgumentError.missingProviders(first)
            }
            command = first == "enable" ? .enable(providers) : .disable(providers)
        default:
            command = .status(try parseSelection(positional))
        }

        if json || strict {
            switch command {
            case .status, .doctor: break
            default: throw CLIArgumentError.statusOnlyOption
            }
        }
        return .init(command: command, json: json, strict: strict)
    }

    private static func parseSelection(_ values: [String]) throws -> ProviderSelection {
        if values == ["all"] { return .all }
        guard let providers = try parseProviders(values) else { return .enabled }
        return .named(providers)
    }

    private static func parseProviders(_ values: [String]) throws -> [ProviderID]? {
        if values.isEmpty { return nil }

        var providers: [ProviderID] = []
        for value in values {
            guard let provider = provider(named: value) else {
                throw CLIArgumentError.unknownCommandOrProvider(value)
            }
            if !providers.contains(provider) { providers.append(provider) }
        }
        return providers
    }

    private static func provider(named value: String) -> ProviderID? {
        switch value.lowercased() {
        case "codex": .codex
        case "claude": .claude
        case "cursor": .cursor
        case "deepseek", "deep-seek": .deepSeek
        case "command-code", "commandcode", "goat": .commandCode
        default: nil
        }
    }
}
