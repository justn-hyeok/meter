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
    static let version = "0.4.20"

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
            return .init(standardOutput: CLITextFormatter.providers(settings: settings), standardError: "", exitCode: 0)
        case .enable(let providers):
            return update(providers, enabled: true)
        case .disable(let providers):
            return update(providers, enabled: false)
        case .setKey(let provider):
            return setKey(for: provider)
        case .clearKey(let provider):
            return clearKey(for: provider)
        case .doctor:
            return doctor(json: options.json, strict: options.strict)
        case .status(let selection):
            return await status(selection, json: options.json, strict: options.strict)
        }
    }

    private func update(_ providers: [ProviderID], enabled: Bool) -> CLIResult {
        for provider in providers { settings.setEnabled(enabled, for: provider) }
        let action = enabled ? "Enabled" : "Disabled"
        let names = providers.map(\.rawValue).joined(separator: ", ")
        return .init(standardOutput: "\(action): \(names)", standardError: "", exitCode: 0)
    }

    private func setKey(for provider: ProviderID) -> CLIResult {
        guard let secret = Self.readSecret(prompt: "Paste the \(provider.title) key and press Enter: "),
              !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(standardOutput: "", standardError: "No key was read from input.", exitCode: 64)
        }
        do {
            try secrets.setSecret(secret, for: provider)
            return .init(standardOutput: "Stored a key for \(provider.rawValue)", standardError: "", exitCode: 0)
        } catch {
            return .init(standardOutput: "", standardError: "Could not store the key: \(error.localizedDescription)", exitCode: 2)
        }
    }

    private func clearKey(for provider: ProviderID) -> CLIResult {
        do {
            try secrets.setSecret(nil, for: provider)
            return .init(standardOutput: "Removed the stored key for \(provider.rawValue)", standardError: "", exitCode: 0)
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
        let statuses = CredentialDoctor.diagnose(settings.providerOrder)
        let enabled = Set(settings.enabledProviders())
        let blocked = statuses.filter { enabled.contains($0.provider) && !$0.isUsable }
        let exitCode: Int32 = strict && !blocked.isEmpty ? 1 : 0
        do {
            let output = json ? try CLIJSONFormatter.doctor(statuses) : CLITextFormatter.doctor(statuses)
            return .init(standardOutput: output, standardError: "", exitCode: exitCode)
        } catch {
            return .init(standardOutput: "", standardError: "Could not encode output: \(error.localizedDescription)", exitCode: 2)
        }
    }

    private func status(_ selection: ProviderSelection, json: Bool, strict: Bool) async -> CLIResult {
        let selected = switch selection {
        case .enabled: settings.enabledProviders()
        case .all: settings.providerOrder
        case .named(let providers): providers
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
      meter set-key <provider>
      meter clear-key <provider>

    Providers:
      codex, claude, cursor, deepseek, command-code

    Selection:
      With no provider, status queries the providers enabled in Meter settings.
      The 'all' selector queries every provider, including disabled providers.
      'meter codex' is shorthand for 'meter status codex'.

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
