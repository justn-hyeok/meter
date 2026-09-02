# Meter

[한국어](README.ko.md)

Meter is a private macOS menu bar app and CLI that keeps usage and quota information for Codex, Cursor, DeepSeek API, and Command Code GOAT in one place.

## Features

- Codex default and model-specific rolling limits
- Cursor plan usage and on-demand spending
- DeepSeek API balance
- Command Code GOAT monthly credits and rolling limits
- Per-provider toggles that persist across launches
- Automatic refresh every five minutes and manual refresh from the menu
- Last-good data preserved when a refresh temporarily fails
- Dynamic menu bar gauge based on the highest known usage percentage
- A standalone `meter` command for interactive use and automation

## Requirements

- macOS 14 or later
- A local Codex app or Codex CLI login for Codex usage
- `DEEPSEEK_API_KEY` in the app process environment for DeepSeek balance
- Aside Browser and its CLI installed and running, with active Cursor and Command Code sessions

Codex and DeepSeek are enabled by default. Cursor and Command Code are disabled by default and can be enabled from the Meter menu or with `meter enable`.

## Install

Download `Meter-0.3.0-macos-universal-unsigned.zip` from the [v0.3.0 release](https://github.com/justn-hyeok/meter/releases/tag/v0.3.0), extract it, and move `Meter.app` to `/Applications`.

The release has an ad-hoc signature and is not notarized. If macOS blocks the first launch, Control-click `Meter.app` in Finder, choose **Open**, and confirm once.

SHA-256 checksums for the app and CLI archives are included in the release notes.

Meter runs only in the menu bar and does not appear in the Dock.

## Provider setup

### Codex

Meter first reads quotas through the official local Codex app-server method `account/rateLimits/read`. This exposes the default limit and model-specific limits such as GPT-5.3-Codex-Spark. If the local app-server is unavailable, Meter falls back to the authenticated `wham/usage` request using the existing `~/.codex/auth.json` session.

No additional Meter login is required. Meter does not log credentials or raw authentication responses.

### Cursor

1. Open `https://cursor.com/dashboard/spending` in Aside Browser and sign in.
2. Keep Aside Browser running.
3. Enable **Cursor** in Meter or run `meter enable cursor`.

Meter requests the dashboard's JSON endpoint inside the existing Aside browser session. It does not read or store browser cookies.

### DeepSeek API

Set `DEEPSEEK_API_KEY` in the environment that launches Meter. The collector uses DeepSeek's official `/user/balance` endpoint.

This version does not include an in-app API-key field. An app launched from Finder does not normally inherit variables from your interactive shell. The CLI does inherit its shell environment, so run `meter deepseek` from a shell where `DEEPSEEK_API_KEY` is already configured.

Balance-only data does not affect the menu bar gauge because it has no known spending limit.

### Command Code GOAT

1. Open `https://commandcode.ai/justn-hyeok/settings/usage` in Aside Browser and sign in.
2. Keep Aside Browser running.
3. Enable **Command Code GOAT** in Meter or run `meter enable command-code`.

Meter requests the credits and usage-summary JSON endpoints within that authenticated browser session.

This private build is pinned to the `justn-hyeok` Command Code workspace. Change the dashboard path in `CommandCodeUsageProvider` before building it for another workspace.

## Privacy and reliability

- Credentials, cookies, and tokens are never written to logs.
- Aside makes authenticated Cursor and Command Code requests inside the browser page context.
- Cursor and Command Code use private dashboard endpoints and may require maintenance if those dashboards change.
- A failed refresh keeps the last successful snapshot and marks it stale instead of erasing it.
- Aside collection attempts time out after 20 seconds; Codex app-server attempts time out after 15 seconds.

## Troubleshooting

- **Codex unavailable:** Sign in through the Codex app or CLI, then refresh Meter.
- **Cursor or Command Code unavailable:** Confirm Aside Browser is running and the relevant dashboard still shows a signed-in session.
- **DeepSeek unavailable:** Confirm the process that launched Meter contains `DEEPSEEK_API_KEY`.
- **No Dock icon:** This is expected; use the gauge icon in the menu bar.

## Development

Run the app and tests with Swift Package Manager:

```sh
swift test
swift run MeterApp
```

## CLI

The `meter` CLI uses the same providers and enabled-provider settings as the menu bar app. It fetches fresh usage directly and does not require the app to be running.

```sh
swift run meter
swift run meter codex
swift run meter cursor command-code --json
swift run meter providers
swift run meter enable cursor
swift run meter disable deepseek
```

With no provider argument, `meter` queries the providers enabled in the shared settings. `meter all` also queries disabled providers, while `meter codex` is shorthand for `meter status codex`. The `providers` command lists the current enabled state.

The default exit status is 0 when at least one provider succeeds. Use `--strict` to exit 1 when only some selected providers fail. The command exits 2 when every selected provider fails and 64 for invalid arguments. JSON output includes a versioned `schemaVersion` envelope and unavailable providers in `snapshots`.

The v0.3.0 release also includes `meter-0.3.0-macos-universal.zip`. Extract it and move `meter` to a directory on your `PATH`, or build and install it into `~/.local/bin` from this checkout:

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
- `ASIDE_CLI_PATH`: alternate Aside CLI executable

## License

Private project. No public license is granted.
