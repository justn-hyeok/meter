# Contributing to Meter

Thanks for helping keep Meter useful as provider APIs change. Small, focused fixes are easiest to review.

## Report a problem

Open an [issue](https://github.com/justn-hyeok/meter/issues) with your macOS and Meter versions, the affected provider, steps to reproduce, and the expected and actual result. `meter doctor` and `meter cache status` can help distinguish credential and stale-data problems.

Never post API keys, cookies, OAuth tokens, raw authentication files, or personal usage records. Redact any CLI output or fixture before sharing it.

Report suspected vulnerabilities through the [private security channel](SECURITY.md), not a public issue.

## Send a change

1. Branch from the repository's default branch and keep the change scoped to one problem.
2. Keep provider collection and shared models in `Sources/MeterCore`; the app and CLI should interpret the same snapshot. Mark undocumented provider endpoints and unknown limits honestly.
3. Add a redacted fixture or a regression test when a provider response or observable behavior changes. Run `swift test` on macOS 14 or later.
4. In the pull request, describe the behavior change, the verification you ran, and anything you could not verify without a live account.

Meter is distributed under the [MIT License](LICENSE). Contributions merged into this repository are distributed under the same license.
