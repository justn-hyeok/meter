import Foundation
import MeterCore

/// What a provider argument names: every account of a provider, or one account written
/// `provider#name`.
enum AccountTarget: Equatable {
    case provider(ProviderID)
    case account(Account)
}

/// Which accounts a status query covers.
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
    case named([AccountTarget])
}

enum CLICommand: Equatable {
    case status(ProviderSelection)
    case doctor
    case providers
    case enable([AccountTarget])
    case disable([AccountTarget])
    case setKey(Account)
    case clearKey(Account)
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
    case providerTakesNoNamedAccounts(ProviderID)
    case invalidAccountName(String)
    case missingAccountName
    case nameOnlyForKeys

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
        case .providerTakesNoNamedAccounts(let provider):
            "\(provider.title) has one account, the one signed in on this Mac. Named accounts are for DeepSeek, Command Code and OpenCode Go"
        case .invalidAccountName(let name):
            "Invalid account name '\(name)': use up to 20 characters, without '#' or surrounding spaces"
        case .missingAccountName:
            "--name needs a value"
        case .nameOnlyForKeys:
            "--name is only valid for set-key and clear-key"
        case .statusOnlyOption:
            "The --json and --strict options are only valid for status and doctor queries"
        }
    }
}

enum CLIArgumentParser {
    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var json = false
        var strict = false
        var name: String?
        var positional: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--name" {
                guard index < arguments.count else { throw CLIArgumentError.missingAccountName }
                name = arguments[index]
                index += 1
                continue
            }
            if argument.hasPrefix("--name=") {
                name = String(argument.dropFirst("--name=".count))
                continue
            }
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
            if name != nil { throw CLIArgumentError.nameOnlyForKeys }
            return .init(command: .status(.enabled), json: json, strict: strict)
        }
        if name != nil, first != "set-key", first != "clear-key" { throw CLIArgumentError.nameOnlyForKeys }

        let rest = Array(positional.dropFirst())
        let command: CLICommand
        switch first {
        case "status": command = .status(try parseSelection(rest))
        case "set-key", "clear-key":
            guard let targets = try parseTargets(rest), targets.count == 1 else {
                throw CLIArgumentError.oneProviderRequired(first)
            }
            let account: Account
            switch targets[0] {
            case .account(let named): account = named
            case .provider(let provider):
                guard provider.acceptsStoredKey else { throw CLIArgumentError.providerTakesNoKey(provider) }
                if let name {
                    guard provider.acceptsNamedAccounts else { throw CLIArgumentError.providerTakesNoNamedAccounts(provider) }
                    guard Account.isValid(name: name) else { throw CLIArgumentError.invalidAccountName(name) }
                    account = Account(provider, name: name)
                } else {
                    account = Account(provider)
                }
            }
            command = first == "set-key" ? .setKey(account) : .clearKey(account)
        case "doctor":
            guard rest.isEmpty else { throw CLIArgumentError.unexpectedArguments(first) }
            command = .doctor
        case "providers":
            guard rest.isEmpty else { throw CLIArgumentError.unexpectedArguments(first) }
            command = .providers
        case "enable", "disable":
            guard !rest.isEmpty else { throw CLIArgumentError.missingProviders(first) }
            guard let targets = try parseTargets(rest), !targets.isEmpty else {
                throw CLIArgumentError.missingProviders(first)
            }
            command = first == "enable" ? .enable(targets) : .disable(targets)
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
        // Case-insensitive like the provider names: `meter CODEX` worked and `meter ALL` did not.
        if values.count == 1, values[0].lowercased() == "all" { return .all }
        guard let targets = try parseTargets(values) else { return .enabled }
        return .named(targets)
    }

    private static func parseTargets(_ values: [String]) throws -> [AccountTarget]? {
        if values.isEmpty { return nil }

        var targets: [AccountTarget] = []
        for value in values {
            let target = try target(named: value)
            if !targets.contains(target) { targets.append(target) }
        }
        return targets
    }

    /// `deepseek` for every DeepSeek account, `deepseek#work` for the one named work.
    private static func target(named value: String) throws -> AccountTarget {
        guard let separator = value.firstIndex(of: "#") else {
            guard let provider = provider(named: value) else { throw CLIArgumentError.unknownCommandOrProvider(value) }
            return .provider(provider)
        }
        let name = String(value[value.index(after: separator)...])
        guard let provider = provider(named: String(value[..<separator])) else {
            throw CLIArgumentError.unknownCommandOrProvider(value)
        }
        guard provider.acceptsNamedAccounts else { throw CLIArgumentError.providerTakesNoNamedAccounts(provider) }
        guard Account.isValid(name: name) else { throw CLIArgumentError.invalidAccountName(name) }
        return .account(Account(provider, name: name))
    }

    private static func provider(named value: String) -> ProviderID? {
        switch value.lowercased() {
        case "codex": .codex
        case "claude": .claude
        case "cursor": .cursor
        case "deepseek", "deep-seek": .deepSeek
        case "command-code", "commandcode", "goat": .commandCode
        case "opencode-go", "opencodego", "opencode": .openCodeGo
        default: nil
        }
    }
}
