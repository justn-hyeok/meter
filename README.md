# Meter

A private macOS menu bar monitor for Codex, Cursor, DeepSeek API, and Command Code GOAT usage.

The v0 reads Codex quota using the existing local Codex login and reads DeepSeek balance from its official API. Cursor Spending and Command Code GOAT usage are read from the providers' JSON endpoints inside the existing authenticated Aside Browser session. They default to off and require Aside to be installed, running, and signed in to the provider sites.

Codex currently relies on an undocumented ChatGPT backend endpoint and may need maintenance when its response or authentication changes. Meter reads the credential only from the existing `~/.codex/auth.json` file and never logs it. DeepSeek currently reads `DEEPSEEK_API_KEY` from the process environment, which is intended for command-line development rather than a packaged login-item build.

## Development

```sh
swift test
swift run Meter
```

## App bundle

Build a universal Apple Silicon and Intel release bundle with an ad-hoc local signature:

```sh
./Scripts/package-app.sh
open dist/Meter.app
```

The bundle is written to `dist/Meter.app`. It is a menu-bar-only app and does not appear in the Dock. This local build is not notarized for distribution to other Macs.

Automatic refresh defaults to five minutes. Provider toggles are persisted in `UserDefaults`.

The Aside collectors locate the CLI at `~/.local/bin/aside` by default. Set `ASIDE_CLI_PATH` to an alternate executable path. Meter never reads or logs browser cookies or tokens; Aside makes the authenticated requests within the browser page context.

Cursor and Command Code do not publish individual-plan usage APIs, so these collectors call the private JSON endpoints used by their dashboards. They may need maintenance when a provider changes its endpoint or response schema. Each Aside collection attempt is limited to 20 seconds.

Balance-only providers do not contribute to the menu-bar warning gauge because a remaining balance does not imply a known spending limit. A failed refresh preserves the last successful snapshot as stale.
