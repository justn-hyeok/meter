# UX backlog

Things in the menu or the CLI that are not right yet. Add to it when something grates;
remove an entry when it ships.

## Not yet seen in the running app

- Light mode. Every tile screenshot so far is dark.
- The stale, waiting, error and key-field tiles. They are built but have not been seen.
- A provider with more than three windows (the "+N more" line).
- Named accounts in the tile grid.

## Known gaps

- The menu bar icon is still the SF Symbol gauge, not the red arc the tile design called
  for. MenuBarExtra only paints a system image reliably, so a drawn arc needs its own try.
- There is no settings window. Refresh interval (fixed at five minutes), the shortcut, and
  adding named accounts are CLI-only, and a provider is switched off only from a tile's
  right-click menu, which nothing on screen points to.
- A tile measured only in money (DeepSeek, OpenRouter) leaves most of its fixed height empty.
- Error messages say what failed but not what to do: "Claude unavailable: <system error>"
  instead of "sign in with `claude`" or "allow keychain access".
- Reordering has no visible handle; nothing says a tile can be dragged.
- OpenRouter cannot show credits left: that endpoint needs a management key.
