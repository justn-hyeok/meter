import Darwin
import Foundation
import MeterCore

/// Read by the SIGINT handler, which cannot capture context.
private nonisolated(unsafe) var terminalToRestore: termios?

struct CLIResult {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
}

struct MeterCLIApplication {
    static let version = "0.4.23"

    let service: UsageService
    let settings: MeterSettings
    let secrets: SecretStore

    init(
        service: UsageService = UsageService(),
        settings: MeterSettings = MeterSettings(),
        secrets: SecretStore = .default
    ) {
        self.service = service
        self.settings = settings
        self.secrets = secrets
        settings.migrateIfNeeded()
    }

    func run(_ options: CLIOptions) async -> CLIResult {
        switch options.command {
        case .help:
            return .init(standardOutput: Self.help, standardError: "", exitCode: 0)
        case .version:
            return .init(standardOutput: "meter \(Self.version)", standardError: "", exitCode: 0)
        case .providers:
            return .init(standardOutput: CLITextFormatter.providers(settings: settings, accounts: Account.all(in: secrets)), standardError: "", exitCode: 0)
        case .enable(let targets):
            return update(targets, enabled: true)
        case .disable(let targets):
            return update(targets, enabled: false)
        case .setKey(let account):
            return setKey(for: account)
        case .clearKey(let account):
            return clearKey(for: account)
        case .doctor:
            return doctor(json: options.json, strict: options.strict)
        case .status(let selection):
            return await status(selection, json: options.json, strict: options.strict)
        }
    }

    /// Every account on this machine, in the arranged order.
    private var accounts: [Account] { settings.order(of: Account.all(in: secrets)) }

    /// A provider name stands for all of its accounts; `provider#name` for that one only.
    private func resolve(_ targets: [AccountTarget]) -> Resolution {
        let known = accounts
        var resolved: [Account] = []
        for target in targets {
            switch target {
            case .provider(let provider):
                resolved += known.filter { $0.provider == provider && !resolved.contains($0) }
            case .account(let account):
                guard known.contains(account) else {
                    return .failure(CLIResult(
                        standardOutput: "",
                        standardError: "No account \(account.rawValue). Add it with 'meter set-key \(account.provider.rawValue) --name \(account.name ?? "")'.",
                        exitCode: 64
                    ))
                }
                if !resolved.contains(account) { resolved.append(account) }
            }
        }
        return .accounts(resolved)
    }

    private enum Resolution {
        case accounts([Account])
        case failure(CLIResult)
    }

    private func update(_ targets: [AccountTarget], enabled: Bool) -> CLIResult {
        let accounts: [Account]
        switch resolve(targets) {
        case .accounts(let resolved): accounts = resolved
        case .failure(let result): return result
        }
        for account in accounts { settings.setEnabled(enabled, for: account) }
        let action = enabled ? "Enabled" : "Disabled"
        let names = accounts.map(\.rawValue).joined(separator: ", ")
        return .init(standardOutput: "\(action): \(names)", standardError: "", exitCode: 0)
    }

    private func setKey(for account: Account) -> CLIResult {
        if account.name != nil, secrets.secret(for: account) == nil {
            let named = secrets.namedAccounts().filter { $0.provider == account.provider }
            guard named.count < Account.limitPerProvider - 1 else {
                return .init(
                    standardOutput: "",
                    standardError: "\(account.provider.title) already has \(Account.limitPerProvider) accounts, the default and \(named.map { "'\($0.name ?? "")'" }.joined(separator: " and ")). Remove one with 'meter clear-key \(account.provider.rawValue) --name <name>'.",
                    exitCode: 64
                )
            }
        }
        guard let secret = Self.readSecret(prompt: "Paste the \(account.title) key and press Enter: "),
              !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(standardOutput: "", standardError: "No key was read from input.", exitCode: 64)
        }
        do {
            try secrets.setSecret(secret, for: account)
            return .init(standardOutput: "Stored a key for \(account.rawValue)", standardError: "", exitCode: 0)
        } catch {
            return .init(standardOutput: "", standardError: "Could not store the key: \(error.localizedDescription)", exitCode: 2)
        }
    }

    private func clearKey(for account: Account) -> CLIResult {
        do {
            try secrets.setSecret(nil, for: account)
            let removed = account.name == nil ? "the stored key for \(account.rawValue)" : "account \(account.rawValue)"
            return .init(standardOutput: "Removed \(removed)", standardError: "", exitCode: 0)
        } catch {
            return .init(standardOutput: "", standardError: "Could not remove the key: \(error.localizedDescription)", exitCode: 2)
        }
    }

    /// Reads from stdin so the key never reaches shell history, with echo off on a terminal.
    static func readSecret(prompt: String) -> String? {
        guard isatty(STDIN_FILENO) == 1 else {
            return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }

        var original = termios()
        // Without this check a failing tcgetattr would leave `original` zeroed, and the
        // restore below would push that onto the terminal instead of putting it back.
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return readLine(strippingNewline: true) }

        FileHandle.standardError.write(Data(prompt.utf8))
        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)

        // Ctrl-C at the prompt would otherwise terminate the process with echo still off,
        // leaving the user's shell silently not echoing until they run `stty sane`.
        terminalToRestore = original
        signal(SIGINT) { _ in
            if var restore = terminalToRestore { tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore) }
            _exit(130)
        }
        defer {
            signal(SIGINT, SIG_DFL)
            terminalToRestore = nil
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        return readLine(strippingNewline: true)
    }

    private func doctor(json: Bool, strict: Bool) -> CLIResult {
        let accounts = accounts
        let statuses = accounts.map { CredentialDoctor.diagnose($0) }
        let enabled = Set(accounts.filter(settings.enabled))
        let blocked = statuses.filter { enabled.contains($0.accountID) && !$0.isUsable }
        let exitCode: Int32 = strict && !blocked.isEmpty ? 1 : 0
        do {
            let output = json ? try CLIJSONFormatter.doctor(statuses) : CLITextFormatter.doctor(statuses)
            return .init(standardOutput: output, standardError: "", exitCode: exitCode)
        } catch {
            return .init(standardOutput: "", standardError: "Could not encode output: \(error.localizedDescription)", exitCode: 2)
        }
    }

    private func status(_ selection: ProviderSelection, json: Bool, strict: Bool) async -> CLIResult {
        let selected: [Account]
        switch selection {
        case .enabled: selected = accounts.filter(settings.enabled)
        case .all: selected = accounts
        case .named(let targets):
            switch resolve(targets) {
            case .accounts(let resolved): selected = resolved
            case .failure(let result): return result
            }
        }
        guard !selected.isEmpty else {
            return .init(
                standardOutput: "",
                standardError: "No providers enabled. Run 'meter enable codex' or select one explicitly.",
                exitCode: 2
            )
        }

        let snapshots = await service.fetch(selected)
        let healthyCount = snapshots.count { $0.state == .live }
        let unhealthyCount = snapshots.count - healthyCount
        let exitCode: Int32 = healthyCount == 0 ? 2 : (strict && unhealthyCount > 0 ? 1 : 0)

        do {
            let output = json
                ? try CLIJSONFormatter.status(snapshots)
                : CLITextFormatter.status(snapshots, style: .detect())
            return .init(standardOutput: output, standardError: "", exitCode: exitCode)
        } catch {
            return .init(standardOutput: "", standardError: "Could not encode output: \(error.localizedDescription)", exitCode: 2)
        }
    }

    static let help = """
    Usage:
      meter [<provider> ...] [--json] [--strict]
      meter status [<provider> ...] [--json] [--strict]
      meter doctor [--json] [--strict]
      meter providers
      meter enable <provider> ...
      meter disable <provider> ...
      meter set-key <provider> [--name <name>]
      meter clear-key <provider> [--name <name>]

    Providers:
      codex, claude, cursor, deepseek, command-code, opencode-go

    Selection:
      With no provider, status queries the providers enabled in Meter settings.
      The 'all' selector queries every provider, including disabled providers.
      'meter codex' is shorthand for 'meter status codex'.
      A provider name covers all of its accounts; 'deepseek#work' names one.

    Accounts:
      DeepSeek, Command Code and OpenCode Go can hold up to three accounts: the default
      one and two named ones. Add one with 'meter set-key deepseek --name work' and
      remove it with 'meter clear-key deepseek --name work'.

    Commands:
      status       Query provider usage
      doctor       Report where each credential comes from and whether it is present,
                   without any network request or keychain prompt
      set-key      Read a provider's API key from stdin and store it for both the app
                   and this CLI. Only providers Meter cannot find a credential for.
      clear-key    Remove a stored key

    Options:
      --json       Print a stable JSON envelope
      --strict     Exit 1 when any selected provider is unavailable
      -h, --help   Show help
      -V, --version

    Exit status:
      0  Query succeeded, or at least one provider succeeded without --strict
      1  At least one provider was unavailable with --strict, or doctor --strict
         found an enabled provider with no credential
      2  Every selected provider was unavailable
      64 Invalid command or arguments
    """
}

@main
struct MeterCLI {
    static func main() async {
        let result: CLIResult
        do {
            let options = try CLIArgumentParser.parse(Array(CommandLine.arguments.dropFirst()))
            result = await MeterCLIApplication().run(options)
        } catch {
            result = .init(
                standardOutput: "",
                standardError: "\(error.localizedDescription)\n\n\(MeterCLIApplication.help)",
                exitCode: 64
            )
        }

        write(result.standardOutput, to: .standardOutput)
        write(result.standardError, to: .standardError)
        exit(result.exitCode)
    }

    private static func write(_ value: String, to handle: FileHandle) {
        guard !value.isEmpty else { return }
        handle.write(Data((value + "\n").utf8))
    }
}
