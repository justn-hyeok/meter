# UX backlog

Things in the menu or the CLI that are not right yet. Add to it when something grates;
remove an entry when it ships.

## Not yet seen in the running app

- Light mode. Every tile screenshot so far is dark.
- The stale, waiting and error tiles. They are built but have not been seen.
- A provider with more than three windows (the "+N more" line).
- Named accounts in the tile grid.
- The drawn gauge in the menu bar itself (rendered and checked as an image only), and a
  real macOS alert banner.

## Known gaps

- The key-field tile says "paste one in the Meter menu" directly above the field it means.
  Inside the menu it should just say "Paste an OpenRouter API key".

- There is no settings window. Refresh interval (fixed at five minutes), the shortcut, and
  adding named accounts are CLI-only, and a provider is switched off only from a tile's
  right-click menu, which nothing on screen points to.
- A tile measured only in money (DeepSeek, OpenRouter) leaves most of its fixed height empty.
- Reordering has no visible handle; nothing says a tile can be dragged.
- OpenRouter cannot show credits left: that endpoint needs a management key.
- A failure that is not a sign-in problem (offline, a keychain dialog declined) still shows
  only the system's message, with no action.
- Codex history before its sessions were compressed needs `zstd` (Homebrew); without it the
  Tokens view says nothing about what it left out.

## Tokens view

- Below four or five models the view leaves a large empty area, because it takes the
  height of the tile grid. A per-tool or per-day breakdown could use that space.
- 30 days of Claude Code logs takes about 2.7 s to read (release build) and is re-read on
  every open after a minute. An incremental index of what was already read would make it
  instant.
- "Last used" shows Claude Code on a subagent's model (Sonnet) when the main session is on
  Opus. Showing the main session's model, or both, would match what people mean by
  "which model am I using".

- The token caches in `~/Library/Caches/com.justn.meter` keep an entry for every log file ever read and never prune ones whose log was deleted (757 files, 21 MB on the first Mac). Safe to delete; it rebuilds.
