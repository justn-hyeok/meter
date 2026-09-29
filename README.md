# Meter

[한국어](README.ko.md)

Meter is a private macOS menu bar app and CLI that keeps usage and quota information for Codex, Claude, Cursor, DeepSeek API, Command Code GOAT, and OpenCode Go in one place.

## Features

- Codex default and model-specific rolling limits
- Claude subscription session and weekly limits, including per-model windows
- Cursor plan usage and on-demand spending
- DeepSeek API balance
- Command Code GOAT monthly credits and rolling limits
- OpenCode Go 5-hour, weekly, and monthly limits
- Per-provider toggles that persist across launches
- Launch at login
- **⌃⌥M** opens and closes the menu from anywhere
- Drag provider cards to reorder them; the `meter` CLI prints in the same order
- Automatic refresh every five minutes and manual refresh from the menu
- Last-good data preserved when a refresh temporarily fails
- Dynamic menu bar gauge based on the highest known usage percentage across enabled providers
- A standalone `meter` command for interactive use and automation

## Requirements

- macOS 14 or later
- A local Codex app or Codex CLI login for Codex usage
- A Claude Code login for Claude subscription usage
- The Cursor desktop app, signed in, for Cursor usage
- A DeepSeek API key, pasted into Meter or left in `DEEPSEEK_API_KEY`, for DeepSeek balance
- A Command Code CLI login, or `COMMAND_CODE_API_KEY`, for Command Code usage
- OpenCode Go connected in OpenCode, or a key given with `meter set-key opencode-go`, for OpenCode Go usage
- A code signing certificate, so keychain permission survives rebuilds — see [Signing](#signing)

Every provider except Cursor is enabled by default. Cursor needs its desktop app installed, so it is the one you opt into, from the Meter menu or with `meter enable cursor`.

Run `meter doctor` to see where each credential comes from and whether it is present. No browser needs to be installed or running for any provider.

## Install

Download `Meter-0.4.22-macos-universal-app.zip` from the [v0.4.22 release](https://github.com/justn-hyeok/meter/releases/tag/v0.4.22), extract it, and move `Meter.app` to `/Applications`.

**Required after downloading:** the release is not notarized, so macOS refuses to launch it until you clear the quarantine flag the browser attached. Run this once after moving the app:

```sh
xattr -dr com.apple.quarantine /Applications/Meter.app
```

The old Control-click → **Open** shortcut no longer works since macOS 15 (Sequoia). The only other way is to try to open it once, then choose **Open Anyway** in System Settings → Privacy & Security.

> Want this step gone? Notarization needs a $99/year Apple Developer membership. Send me $99 and it disappears.

Building it yourself also skips this, and keeps macOS from re-asking for keychain permission - see [Signing](#signing).

SHA-256 checksums for the app and CLI archives are included in the release notes.

Meter runs only in the menu bar and does not appear in the Dock.

## Provider setup

### Codex

Meter first reads quotas through the official local Codex app-server method `account/rateLimits/read`. This exposes the default limit and model-specific limits such as GPT-5.3-Codex-Spark. If the local app-server is unavailable, Meter falls back to the authenticated `wham/usage` request using the existing `~/.codex/auth.json` session.

No additional Meter login is required. Meter does not log credentials or raw authentication responses.

### Claude

1. Sign in with `claude` (Claude Code) if you have not already.
2. Choose **Always Allow** the first time macOS asks for keychain permission.

Claude Code keeps the subscription OAuth token in the login keychain and refreshes it,
so Meter reads that item and calls the account usage endpoint. Windows are read from the
response's self-describing `limits` array rather than the codenamed keys beside it,
which come and go as plans change.

### Cursor

1. Sign in to the Cursor desktop app.
2. Enable **Cursor** in Meter or run `meter enable cursor`.
3. Choose **Always Allow** the first time macOS asks for keychain permission.

Cursor keeps its WorkOS session in the login keychain and refreshes the token itself, so Meter reads that item and calls the dashboard endpoint directly. No browser is involved.

### DeepSeek API

Paste the key into the DeepSeek card in the Meter menu, or pipe it in:

```sh
meter set-key deepseek
```

`set-key` reads from stdin with terminal echo off, so the key never reaches shell history. It is stored at `~/Library/Application Support/Meter/credentials.json` with mode `0600`, where both the app and the CLI can read it - an app launched from Finder inherits nothing from your shell, which is why the environment variable alone was not enough. `DEEPSEEK_API_KEY` still wins when it is set, so existing setups keep working, and `meter clear-key deepseek` removes a stored key.

The collector uses DeepSeek's official `/user/balance` endpoint. Balance-only data does not affect the menu bar gauge because it has no known spending limit.

### Command Code GOAT

Sign in once with Command Code's own CLI:

```sh
cmd login
```

Meter then calls the same `alpha/billing/credits` and `alpha/usage/summary` routes that CLI uses, with the same API key. It looks for the key in `COMMAND_CODE_API_KEY`, then in a key handed to Meter with `meter set-key command-code`, then in `~/.commandcode/auth.json`. No browser is involved, and nothing needs to be running.

### OpenCode Go

Connect OpenCode Go once in OpenCode (`/connect`, then OpenCode Go). OpenCode keeps the key in `~/.local/share/opencode/auth.json`, and Meter reads only the `opencode-go` entry from that file. It looks for the key in `OPENCODE_GO_API_KEY`, then in a key handed to Meter with `meter set-key opencode-go`, then in OpenCode's file.

OpenCode has no documented usage API for Go. Meter calls `opencode.ai/zen/go/v1/usage`, the route the OpenCode console reads, with that key. It shows the 5-hour, weekly, and monthly windows as percentages.

## Privacy and reliability

- Credentials, cookies, and tokens are never written to logs.
- Credentials are read from the local keychain, from files the vendors' own CLIs write, and from keys you give Meter, and are sent only to the service that issued them.
- Every provider is reached through the API its own first-party client uses.
- JWTs are read for their `sub` claim only. Meter never verifies, mints, or forwards a token elsewhere.
- Cursor, Command Code, and OpenCode Go use private dashboard endpoints and may require maintenance if those dashboards change.
- A failed refresh keeps the last successful snapshot and marks it stale instead of erasing it.
- Every provider request times out after 15 seconds.

## Troubleshooting

- **Codex unavailable:** Sign in through the Codex app or CLI, then refresh Meter.
- **Cursor unavailable:** Sign in to the Cursor app, then refresh Meter.
- **Command Code unavailable:** Run `cmd login`, or give Meter a key with `meter set-key command-code`.
- **OpenCode Go unavailable:** Connect OpenCode Go in OpenCode with `/connect`, or run `meter set-key opencode-go`.
- **A keychain prompt on every launch:** the build is ad-hoc signed, so each rebuild is a new identity. See [Signing](#signing).
- **DeepSeek unavailable:** Run `meter set-key deepseek`. `DEEPSEEK_API_KEY` works for the CLI but an app launched from Finder never sees it, which `meter doctor` reports as `blocked`.
- **No Dock icon:** This is expected; use the gauge icon in the menu bar.

## Development

Build and run with Swift Package Manager:

```sh
swift test
./Scripts/build-dev.sh
swift run MeterApp
```

`Scripts/build-dev.sh` builds the debug products and signs them, which is what stops macOS from asking for keychain permission again after every rebuild. `swift Scripts/make-icon.swift` redraws `Resources/AppIcon.icns` with CoreGraphics; the result is committed so a normal build needs nothing extra.

### Signing

Meter reads credentials that other applications own, and macOS records that permission against the app's designated requirement:

```
ad-hoc      => cdhash H"97720ab1..."                 changes on every rebuild
certificate => identifier "com.justn.meter" and ...  stable
```

An ad-hoc signature therefore revokes Meter's own keychain access every time it is rebuilt. `Scripts/sign.sh` prefers a Developer ID certificate and falls back to an Apple Development certificate, which a free Apple ID provides. Set `METER_SIGN_IDENTITY` to choose one explicitly. Notarization is only needed to give the app to another Mac.

## CLI

The `meter` CLI uses the same providers and enabled-provider settings as the menu bar app. It fetches fresh usage directly and does not require the app to be running.

```sh
swift run meter
swift run meter codex
swift run meter cursor command-code --json
swift run meter doctor
swift run meter set-key deepseek
swift run meter providers
swift run meter enable cursor
swift run meter disable deepseek
```

With no provider argument, `meter` queries the providers enabled in the shared settings. `meter all` also queries disabled providers, while `meter codex` is shorthand for `meter status codex`. The `providers` command lists the current enabled state.

`meter set-key <provider>` stores an API key for the providers whose credential Meter cannot find on the machine, reading it from stdin; `meter clear-key <provider>` removes it. `meter doctor` reports where each credential comes from and whether it is present. It makes no network request and never shows a keychain prompt, so it stays usable when a provider is broken. With `--strict` it exits 1 when an enabled provider has no credential.

The default exit status is 0 when at least one provider succeeds. Use `--strict` to exit 1 when only some selected providers fail. The command exits 2 when every selected provider fails and 64 for invalid arguments. JSON output includes a versioned `schemaVersion` envelope and unavailable providers in `snapshots`. Schema 2 renamed Cursor's spend bucket id from `on-demand` to `spend` and added `blocked` to doctor's `availability`. Schema 3 changes no fields; it marks that `snapshots` and doctor's `credentials` follow the order arranged in the menu (or, for named providers, the order typed). That ordering already appeared under schema 2 in 0.4.16–0.4.19 (0.4.19 only for doctor), so read entries by `provider` rather than by position.

The v0.4.22 release also includes `meter-0.4.22-macos-universal-cli.zip`. Extract it, move `meter` to a directory on your `PATH`, and clear its quarantine flag the same way (`xattr -d com.apple.quarantine <path>/meter`), or build and install it into `~/.local/bin` from this checkout:

```sh
./Scripts/install-cli.sh
```

Set `PREFIX` to install elsewhere:

```sh
PREFIX=/usr/local ./Scripts/install-cli.sh
```

Build a universal Apple Silicon and Intel app bundle with an ad-hoc signature:

```sh
./Scripts/package-app.sh
```

The bundle is written to `dist/Meter.app`.

Build the versioned app and universal CLI archives together for a GitHub release:

```sh
./Scripts/package-release.sh
```

Optional executable overrides:

- `CODEX_CLI_PATH`: alternate Codex CLI executable
- `METER_SIGN_IDENTITY`: code signing certificate used by the packaging scripts

## License

Private project. No public license is granted.
