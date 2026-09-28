# Meter

[한국어](README.ko.md)

Meter is a private macOS menu bar app and CLI that keeps usage and quota information for Codex, Claude, Cursor, DeepSeek API, and Command Code GOAT in one place.

## Features

- Codex default and model-specific rolling limits
- Claude subscription session and weekly limits, including per-model windows
- Cursor plan usage and on-demand spending
- DeepSeek API balance
- Command Code GOAT monthly credits and rolling limits
- Per-provider toggles that persist across launches
- Optional notifications when a window crosses 80% or 95%
- Launch at login
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
- A Chromium browser (Aside, Chrome, Dia, Brave, or Edge) signed in to Command Code
- A code signing certificate, so keychain permission survives rebuilds — see [Signing](#signing)

Codex, Claude, and DeepSeek are enabled by default. Cursor and Command Code are disabled by default and can be enabled from the Meter menu or with `meter enable`.

Run `meter doctor` to see where each credential comes from and whether it is present. No browser needs to be installed or running for any provider.

## Install

Download `Meter-0.3.1-macos-universal-unsigned.zip` from the [v0.3.1 release](https://github.com/justn-hyeok/meter/releases/tag/v0.3.1), extract it, and move `Meter.app` to `/Applications`.

The release has an ad-hoc signature and is not notarized. If macOS blocks the first launch, Control-click `Meter.app` in Finder, choose **Open**, and confirm once.

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

1. Sign in to `https://commandcode.ai` in a supported Chromium browser.
2. Enable **Command Code GOAT** in Meter or run `meter enable command-code`.
3. Choose **Always Allow** for that browser's Safe Storage keychain item.

Meter reads the browser's cookie store from disk, decrypts it with that key, and calls the credits and usage-summary endpoints itself. The browser does not need to be running.

**Known limitation, not being pursued:** the dashboard endpoints reject API keys, Command Code publishes no usage endpoint, its CLI only renders usage inside an interactive session, and the browser profiles checked hold nothing but analytics cookies for `commandcode.ai` - the session lives in local storage. The only route left is its private `internal/` endpoints, which is not somewhere Meter is going to grow new machinery to reach. The provider reports as unavailable, and `meter doctor` prints the cookie inventory it found.

## Privacy and reliability

- Credentials, cookies, and tokens are never written to logs.
- Sessions are read from the local keychain and from browser cookie stores, and are sent only to the service that issued them.
- Cookie stores are opened read-only and immutable, so a running browser is never disturbed.
- JWTs are read for their `sub` claim only. Meter never verifies, mints, or forwards a token elsewhere.
- Cursor and Command Code use private dashboard endpoints and may require maintenance if those dashboards change.
- A failed refresh keeps the last successful snapshot and marks it stale instead of erasing it.
- Every provider request times out after 15 seconds.

## Troubleshooting

- **Codex unavailable:** Sign in through the Codex app or CLI, then refresh Meter.
- **Cursor unavailable:** Sign in to the Cursor app, then refresh Meter.
- **Command Code unavailable:** Sign in at `commandcode.ai` in a supported browser, then run `meter doctor` to see what Meter found.
- **A keychain prompt on every launch:** the build is ad-hoc signed, so each rebuild is a new identity. See [Signing](#signing).
- **DeepSeek unavailable:** Confirm the process that launched Meter contains `DEEPSEEK_API_KEY`.
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

The default exit status is 0 when at least one provider succeeds. Use `--strict` to exit 1 when only some selected providers fail. The command exits 2 when every selected provider fails and 64 for invalid arguments. JSON output includes a versioned `schemaVersion` envelope and unavailable providers in `snapshots`.

The v0.3.1 release also includes `meter-0.3.1-macos-universal.zip`. Extract it and move `meter` to a directory on your `PATH`, or build and install it into `~/.local/bin` from this checkout:

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
