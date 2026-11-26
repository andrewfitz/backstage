# Changelog

## 1.3.6

- **New windows no longer flash on your screen.** A window an agent's dev build or test runner
  opened appeared on your screen for a moment before the daemon moved it backstage (a test
  suite showing windows could flash dozens). The injected library now moves each window onto
  the hidden display just before it's first shown, for every way of showing a window and in test
  bundles that load AppKit late. `--audio` launches get this too. Signed, hardened and Apple
  apps can't take the library, and a window an app moves onto your screen while it's shown is
  still moved back after the fact, as before. An app that puts a window on another screen on
  purpose (a second-monitor feature) gets it on its own hidden display instead.
- The daemon's log says what kind of move the window observer made and from where.

## 1.3.5

- **Restarts no longer blink your monitor.** Adding or removing a display makes macOS reconfigure
  every display (10 reconfigurations for one restart, measured), and some monitors blank for it.
  Displays now live in a small helper process, the display host, and after `stop`/`stop --all`
  the primary display stays 15 s for the next daemon to take over: `stop --all && start` and
  upgrades change nothing on your screens (0 reconfigurations). `BACKSTAGE_DISPLAY_LINGER` sets
  the time; other homes default to 0. The upgrade to this version still blinks once.

## 1.3.4

- **Fix: test runners launched through a script escaped.** A script that `exec`s another binary
  (`exec xctest …` with its output sent elsewhere) was never recognised as the launch's process:
  `launch` gave up, the daemon dropped the launch after 10 minutes, and the runner kept running
  unmanaged, with a Dock tile and ⌘-Tab entry. It's now identified by its launch token, and a
  script's wrapper keeps it out of the Dock across the `exec`.
- **Menu bar:** the icon's dashed back rectangle is 70% transparent.
- **Auto-Hide When Idle** replaces Keep in Menu Bar, with the opposite meaning, and is off by
  default: the icon (and the hotkey) now stays with no apps running unless you check it
  (`backstage settings auto-hide on|off`; `keep-in-menu-bar` still works). Only in
  `~/.backstage`: other homes (tests, other agents) still hide and exit when idle. A setting you
  saved before is kept.

## 1.3.3

- The hidden displays are now named just **Backstage** (in System Settings › Displays and
  anywhere else macOS shows a monitor's name), not "Backstage (agent display)". `doctor` and
  `cleanup-displays` still recognise displays registered under the old name.

## 1.3.2

- **Close a display:** every display but the first has an ⓧ on its picture in the menu, and
  `backstage close-display N [--force]` does the same from a terminal. Its apps move to the
  first display and keep running; the first display always stays. An agent can't close another
  session's display without `--force`.

## 1.3.1

- **Lost windows come back.** Backstage's displays keep fixed identities, so macOS remembers them
  like any monitor, and an app once sent backstage could reopen its window there after being
  relaunched, out of reach. The daemon now returns windows of apps it doesn't run to your main
  screen once they've sat on a hidden display for 3 seconds (moving them only, never taking
  focus). Apps a `backstage launch` opened are left to an explicit recovery, so an agent's app
  never lands on your screen by itself. **Recover Lost Windows** in the menu and
  `backstage recover [--dry-run]` do it on demand, for that daemon's displays. Managed apps, their
  helpers, and apps a launch is still opening are never touched.
- **Menu:** Keep in Menu Bar shows its checkmark at the end of the row, so the menu no longer
  indents every row for a checkmark column.
- **Fix:** a forced quit that macOS accepted without ending the app (seen with `xctest`) left
  `stop --all` waiting 30 s and the daemon running; a forced quit now always ends with SIGKILL.

## 1.3.0

- **Fix: ColorSync CPU.** Every `BACKSTAGE_HOME` got its own display identity, and test suites
  use a fresh home per run, so macOS registered a new display each time (161 in a day on one
  Mac) and ColorSync's daemons spent hours of CPU walking the list. Backstage now uses eight
  fixed displays: 1 for the default home, 2–6 for other homes and extra displays, 7–8 for its
  own tests (`BACKSTAGE_DISPLAY`). `doctor` reports leftovers; `sudo backstage cleanup-displays`
  removes them once.
- **Several displays per daemon:** `launch --display new` gives a session a display of its own
  (reserved for 30 minutes, removed 30 minutes after its last app leaves, since a display coming or going can blip the user's monitor); `launch --display N`; `move --display`;
  launches follow their session's display; `"crowded": true` when a window found no free spot.
  Coordinates, screenshots and input are relative to the app's own display.
- **Menu:** with several displays, two pictures side by side with labels, and ‹ › to page. Each
  app's **Move to ▸** puts it on another display (or a new one), and **Send Front Window To ▸**
  sends your app to the display you pick; a display you create is kept for you, and later sends
  follow your apps there.
- The audio meter in the menu bar has four bars, exactly as wide as the icon.
- **Fixes:** a daemon started under heavy load could find no Core Audio process object yet,
  report muting unavailable and refuse every launch (it now waits up to 3 s); `stop` gave up
  after 8 s while the daemon was finishing a launch's shutdown (now 30 s, and it says why); a
  daemon that fails to start now says why (it used to say only "see daemon.log"); a bug-fix pass
  across the daemon, CLI, input, capture and audio.
- **For display and color tools:** backstage's displays have stable identifiers (name contains
  "Backstage", vendor `0xB57A`, model `0x0001`); see docs/USAGE.md.
- Protocol 3: replace a running older daemon with `backstage stop --all`.

## 1.2.2

- **Fix:** the daemon didn't start when `backstage` was run by bare name from a folder holding
  anything named `backstage` (a checkout of this repo, say): it tried to spawn that instead of
  itself ("failed to spawn daemon: Permission denied").
- The injected library is linked with room for its install name to be rewritten, which
  Homebrew's bottles need.
- README: a picture of the menu bar indicator.

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
