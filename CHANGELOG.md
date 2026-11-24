# Changelog

## 1.2.1

- **Fix:** an agent's app was quit when one of its helper processes (an `xctest` runner, a
  worker) started audio after the app was muted, if the daemon's host lacks System Audio
  Recording. macOS refuses to change an existing tap without that grant (`'!hog'`); the daemon
  now replaces the tap with one covering every process, so the app keeps running and stays
  muted throughout.
- `backstage version` is listed in `help`.

## 1.2.0

- **Send Front Window Backstage**: a menu action and a global shortcut, ⌃⌥⌘B by default
  (`backstage settings hotkey <combo|off>`), that moves the app you're looking at onto the
  hidden display. **Show on My Screen** brings it back.
- **Keep in Menu Bar** (`backstage settings keep-in-menu-bar on`): the icon and daemon stay up
  with no apps running, so the shortcut is always available.
- `backstage settings` and a `settings` block in `status`.
- An inaudible launch that was already playing when its tap attached (common under heavy load)
  is no longer quit: the injected library made it silent from the start.

## 1.1.0

- Menu bar redesign: the live picture of the hidden display leads the menu; apps grouped by
  agent session with running time and sound indicators; long names are shortened so the menu
  never widens; the app count stays beside the icon; a footer shows the version and links here.
- Launch no longer depends on LaunchServices' completion callback, and the daemon registers
  (or quits) an app whose launch the CLI gave up on, instead of leaving it untracked.
- `backstage version` and a `version` field in `status`.

## 1.0.0

- Launch, screenshot, inspect and operate macOS apps on a private virtual display (2x,
  sized to the main display) without touching your screen, cursor, focus or frontmost app.
- Per-agent sessions with ownership and locks; an input guard that keeps your keystrokes and
  clicks out of agent apps and theirs out of yours; compatible with Claude's and Codex's
  computer-use helpers.
- Every agent app is muted (private Core Audio process taps); dev builds and test runners are
  also made inaudible from inside; sound checks are opt-in with `--audio`.
- No Dock tile or ⌘-Tab entry for agent apps.
- Menu bar indicator with a live thumbnail of the hidden display.
- Skills and an optional hook for Claude Code, Codex and Grok (`backstage install`).
