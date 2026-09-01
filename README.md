# Meter

[한국어](README.ko.md)

Meter is a private, menu-bar-only macOS app that keeps usage and quota information for Codex, Cursor, DeepSeek API, and Command Code GOAT in one place.

## Features

- Codex default and model-specific rolling limits
- Cursor plan usage and on-demand spending
- DeepSeek API balance
- Command Code GOAT monthly credits and rolling limits
- Per-provider toggles that persist across launches
- Automatic refresh every five minutes and manual refresh from the menu
- Last-good data preserved when a refresh temporarily fails
- Dynamic menu bar gauge based on the highest known usage percentage

## Requirements

- macOS 14 or later
- A local Codex app or Codex CLI login for Codex usage
- `DEEPSEEK_API_KEY` in the app process environment for DeepSeek balance
- Aside Browser and its CLI installed and running, with active Cursor and Command Code sessions

Codex and DeepSeek are enabled by default. Cursor and Command Code are disabled by default and can be enabled from the Meter menu.

## Install

Download `Meter-0.2.1-macos-universal-unsigned.zip` from the [v0.2.1 release](https://github.com/justn-hyeok/meter/releases/tag/v0.2.1), extract it, and move `Meter.app` to `/Applications`.

The release has an ad-hoc signature and is not notarized. If macOS blocks the first launch, Control-click `Meter.app` in Finder, choose **Open**, and confirm once.

SHA-256: `caed20061ee192656f8ede70bc93566fa9aa48f7ca48ac43be313a2736e15831`

Meter runs only in the menu bar and does not appear in the Dock.

## Provider setup

### Codex

Meter first reads quotas through the official local Codex app-server method `account/rateLimits/read`. This exposes the default limit and model-specific limits such as GPT-5.3-Codex-Spark. If the local app-server is unavailable, Meter falls back to the authenticated `wham/usage` request using the existing `~/.codex/auth.json` session.

No additional Meter login is required. Meter does not log credentials or raw authentication responses.

### Cursor

1. Open `https://cursor.com/dashboard/spending` in Aside Browser and sign in.
2. Keep Aside Browser running.
3. Enable **Cursor** in Meter.

Meter requests the dashboard's JSON endpoint inside the existing Aside browser session. It does not read or store browser cookies.

### DeepSeek API

Set `DEEPSEEK_API_KEY` in the environment that launches Meter. The collector uses DeepSeek's official `/user/balance` endpoint.

This version does not include an in-app API-key field. An app launched from Finder does not normally inherit variables from your interactive shell, so DeepSeek support is currently most practical when running Meter from a configured development environment.

Balance-only data does not affect the menu bar gauge because it has no known spending limit.

### Command Code GOAT

1. Open `https://commandcode.ai/justn-hyeok/settings/usage` in Aside Browser and sign in.
2. Keep Aside Browser running.
3. Enable **Command Code GOAT** in Meter.

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
swift run Meter
```

Build a universal Apple Silicon and Intel app bundle with an ad-hoc signature:

```sh
./Scripts/package-app.sh
```

The bundle is written to `dist/Meter.app`.

Optional executable overrides:

- `CODEX_CLI_PATH`: alternate Codex CLI executable
- `ASIDE_CLI_PATH`: alternate Aside CLI executable

## License

Private project. No public license is granted.
