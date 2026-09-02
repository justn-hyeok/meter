import Foundation
import MeterCore

enum CLICommand: Equatable {
    case status([ProviderID]?)
    case providers
    case enable([ProviderID])
    case disable([ProviderID])
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
        case .statusOnlyOption:
            "The --json and --strict options are only valid for status queries"
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
            return .init(command: .status(nil), json: json, strict: strict)
        }

        let rest = Array(positional.dropFirst())
        let command: CLICommand
        switch first {
        case "status": command = .status(try parseProviders(rest, allowAll: true))
        case "providers":
            guard rest.isEmpty else { throw CLIArgumentError.unexpectedArguments(first) }
            command = .providers
        case "enable", "disable":
            guard !rest.isEmpty else { throw CLIArgumentError.missingProviders(first) }
            guard let providers = try parseProviders(rest, allowAll: false), !providers.isEmpty else {
                throw CLIArgumentError.missingProviders(first)
            }
            command = first == "enable" ? .enable(providers) : .disable(providers)
        default:
            guard let providers = try parseProviders(positional, allowAll: true) else {
                return .init(command: .status(nil), json: json, strict: strict)
            }
            command = .status(providers)
        }

        if json || strict {
            guard case .status = command else { throw CLIArgumentError.statusOnlyOption }
        }
        return .init(command: command, json: json, strict: strict)
    }

    private static func parseProviders(_ values: [String], allowAll: Bool) throws -> [ProviderID]? {
        if values.isEmpty { return nil }
        if allowAll, values == ["all"] { return ProviderID.allCases }

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
        case "cursor": .cursor
        case "deepseek", "deep-seek": .deepSeek
        case "command-code", "commandcode", "goat": .commandCode
        default: nil
        }
    }
}
