# backstage

**Let coding agents run, test, screenshot and click through macOS apps without taking over your screen.**

When an agent builds a Mac app and wants to check it works, the window normally pops up in
front of you, steals keyboard focus, and fights you for the mouse. `backstage` runs those apps
on an invisible virtual display instead. The agent can still see them (screenshots and the
accessibility tree) and use them (clicks, typing, menus, drags) while you keep working.
Your cursor, keyboard focus, frontmost app and windows aren't touched.

It ships with an [agent skill](dist/skills/backstage/SKILL.md) and an optional hook for
**Claude Code, Codex and Grok**. They teach the agent to keep its own testing hidden and to
put things on your screen only when you ask to see them.

```bash
backstage launch build/MyApp.app      # hidden; nothing appears on your screen
backstage screenshot                  # agent looks at it
backstage find --role button --text Export
backstage press w8432.0.3             # agent uses it
backstage show                        # you asked to see it: hand it over, state intact
```

## Requirements

- macOS 14 or later (tested on macOS 27.0.1, Apple Silicon)
- Xcode or Command Line Tools with Swift 5.9+
- **Permissions** for whatever runs the CLI (your terminal or agent host), in System Settings ›
  Privacy & Security: **Accessibility** and **Screen & System Audio Recording**.
  `backstage doctor` checks both.

## Install

```bash
git clone https://github.com/andrewfitz/backstage.git
cd backstage
make install                  # builds and symlinks $(PREFIX)/bin/backstage (PREFIX=/opt/homebrew)
backstage doctor              # check permissions
backstage install --hooks     # optional: skill + hook for Claude Code / Codex / Grok
```

`make install PREFIX=/usr/local` installs elsewhere. `make uninstall` stops the daemon and
removes the link.

## Quick start

```bash
backstage launch Calculator           # a .app path, bundle id, app name, or bare executable
backstage type "12+30="
backstage screenshot                  # {"path": "~/.backstage/shots/shot-….png", ...}
backstage tree                        # accessibility tree with refs
backstage click 127 215               # screenshot pixel == click point
backstage quit                        # or `backstage stop` to quit all of this session's apps
```

The full command reference is in **[docs/USAGE.md](docs/USAGE.md)**, or run `backstage help`.

## How it works

| Piece | Mechanism |
|---|---|
| Invisible screen | A background daemon creates a private Retina (2x) `CGVirtualDisplay` (the API DeskPad/BetterDisplay use), the same size in points as your main display, and parks it touching only the bottom-right corner of your desktop. If the cursor ever gets onto it, the cursor is warped back. |
| Launch without popping up | `open -g -j -n`: background, hidden, fresh instance. The windows are moved to the virtual display while still hidden, then unhidden there. |
| Windows the app opens later | An AX observer (with 50 ms polling as backup) moves them to the virtual display as soon as they're created. |
| Focus stealing | The app is never activated. If it activates itself, the daemon hands focus back to your app. |
| Screenshots | ScreenCaptureKit, filtered to that app's windows (menus, sheets and popovers included). Captures take turns across all sessions: on macOS 27, two processes capturing at once both hang. Each takes about 0.1–0.2 s. |
| Input | AX actions (press/set/focus/menus), plus keyboard and mouse events posted straight to the app's process (`CGEventPostToPid`). Mouse events get window-local coordinates. A private "you are active" event goes to the app only, so AppKit doesn't swallow the click as a focus click. Nothing goes through the HID system, so your real cursor and keyboard are never touched. Every event backstage posts is tagged (event source user data). |
| Your input stays yours | An app with an open menu (a context menu, a menu bar menu, a pop-up button's list) takes macOS's keyboard focus, even in the background, so your typing would go to the hidden app. The daemon runs an event tap on its own thread that sees every key, click and scroll after macOS has picked the receiving app: untagged input headed for a managed app is yours, so keys are handed to your frontmost app instead and clicks and scrolls are dropped. It costs a few microseconds per event. If macOS disables the tap, it is re-enabled at once; if the tap can't be installed, input commands refuse to run and `backstage status` says why. |
| Teardown | `backstage stop` quits the calling session's apps, and stops the daemon when no session has apps left. `backstage stop --all` (or the daemon getting SIGTERM/SIGINT/SIGHUP) quits every app *before* removing the display, so nothing lands on your screen. After 30 min with no managed apps in any session, the daemon exits by itself. |
| Several agents | Each agent session owns the apps it launches, so concurrent agents never pick up, type into, screenshot or stop each other's apps. Commands on one app are serialized with a per-app lock. See [Sessions](docs/USAGE.md#concepts). |

## Menu bar indicator

While agents have apps running, a menu bar icon shows how many apps are running. It
disappears when nothing is running, and goes away entirely when the daemon exits. While an
agent's app is making sound (muted, so you don't hear it), the icon turns into a small level
meter, five bars of the loudest app's recent level; with Reduce Motion on, it shows a still
waveform instead. The item's width never changes. The menu shows:

- a **live thumbnail** of each hidden agent display, refreshed every second while the menu is open
- **stats:** agent sessions, apps, windows, and how long Backstage has been running
- **each app**, with the agent that launched it (claude, codex, grok…), its age, and whether it's
  playing audio or silent. Its submenu has **Show on My Screen** (the same as `backstage show`)
  and **Quit**
- **Open Screenshots & Logs Folder**, and **Quit All Agent Apps**

The daemon runs as a menu-bar-only app: no Dock icon, and it never takes focus. Set
`BACKSTAGE_MENUBAR=off` to run without the icon.

## Installing into Claude Code, Codex and Grok

```
backstage install --hooks      # every agent found in ~ (or pick: --claude --codex --grok)
backstage uninstall
make dist                      # regenerate dist/skills/backstage/SKILL.md for packaging
```

- **Skill:** written to `~/.claude/skills/backstage/`, `~/.codex/skills/backstage/` and
  `~/.grok/skills/backstage/`. All three read the standard `SKILL.md` format. The source of
  truth is `Sources/backstage/Skill.swift`; `dist/skills/backstage/SKILL.md` is generated from it.
- **Hook (`--hooks`):** a `PreToolUse` shell hook, merged into Claude's `settings.json`, Codex's
  `hooks.json` and Grok's `config.toml`. Your existing entries are kept, a `.backstage-bak`
  backup is made, and running install twice is safe. Restart agent sessions afterwards; Grok
  only runs hooks for folders you've trusted.

### Your work or mine?

The agent decides, because it knows what you asked for. The hook makes sure it decides on purpose.

| Situation | What the agent does |
|---|---|
| Its own work: building then checking it launches, tests, reproducing a bug, screenshots for itself, exploring an app, or being unsure | `backstage launch …`, hidden |
| You asked to see it: "open it", "show me", "let me see", "launch it for me", "I want to try it" | `backstage show <app\|file\|url>` |
| It tested hidden and you now want to see the result | `backstage show --pid P`: the same running instance moves to your screen with its state, and backstage stops managing it |
| It finished hidden work you might want to see | It asks: "Want me to open it on your screen?" |

The hook blocks the raw ways of popping things onto your screen and points the agent to
`launch` or `show`. Those are `open …`, running `Foo.app/Contents/MacOS/Foo`, and `osascript`
that activates or opens an app, including inside `bash -c`. It reads the input formats of
Claude (`Bash`), Codex (`exec_command`/`shell`, string or argv) and Grok
(`run_terminal_command`). Blocking means exit code 2 with a reason, which all three treat as
"deny and tell the model".
- To get past the hook for something you asked for: `BACKSTAGE_SHOW=1 <command>`.
- To turn it off: `BACKSTAGE_HOOK=off`.
- Everything `show` does is logged to `~/.backstage/shown.log`.

## Cheat sheet

```
backstage launch /path/to/MyApp.app        # or bundle id, app name, or a bare executable
backstage screenshot                       # -> {"path": ".../shot-….png", ...}; pixel (x,y) == click point (x,y)
backstage tree                             # accessibility tree with refs like w8432.0.3
backstage find --role button --text Save   # search the tree
backstage press w8432.0.3                  # AXPress
backstage click 120 157                    # real mouse click at screenshot coordinates
backstage click --ref w8432.0.3            # click an element
backstage type "hello" --ref w8432.0.2     # focus a field, then type
backstage key cmd+s
backstage menu "File > Save As…"
backstage wait --text "Saved" --timeout 10
backstage logs                             # the app's stdout/stderr
backstage window fill                      # window covers the whole agent display (or: window size 1280 800)
backstage quit
```

- Commands return JSON. Plain `tree` prints indented text, `logs` streams the requested lines, and `help` prints usage. Use `tree --json` for structured output.
- Coordinates are agent-display points, with (0,0) at the top-left of the virtual display. A
  default `screenshot` is cropped starting at (0,0), so a pixel in the image is the same as
  the point you click. `--scale 0.5` gives smaller images; divide the pixel by the scale before clicking.
- The agent display has your main display's size in points and is Retina (2x), so apps render as on a Retina screen. A default screenshot
  is still 1 pixel per point; `--scale 2` gives the native pixels.
- To record the agent display, use `screencapture` with the index from `status`:
  `screencapture -x -v -V 10 -D "$(backstage status | jq .daemon.screencaptureDisplay)" run.mov`.
  It records the whole display, including other sessions' windows. See [docs/USAGE.md](docs/USAGE.md#recording-the-agent-display).
- Each agent session sees only the apps it launched. With no `--pid` or `--app`, commands target your session's most recently launched app. An explicit PID must belong to a live managed launch of your session.
- The session comes from the agent automatically (Claude Code's session ID, Codex's thread ID, or the agent process; for a person, the terminal tab). Subagents of one Claude Code session share it, so give each its own with a prefix: `BACKSTAGE_SESSION=sub1 backstage launch …`; Codex subagents get their own. Details in [docs/USAGE.md](docs/USAGE.md#concepts).
- `screenshot --full` shows the whole agent display with all of your session's apps and nothing from other sessions.
- Screenshots use PNG by default. Choose a `.jpg` or `.jpeg` output path for JPEG. The maximum output area is 67,108,864 pixels.
- Element refs (`w<windowID>.<child>.<child>…`) survive window reordering. Re-run `tree`/`find`
  after the UI changes.
- Run `backstage help` for everything: `drag`, `scroll`, `hover`, `set`, `action`, `list`,
  `windows`, `status`, `stop`, `stop --all`.

Settings (environment for the daemon): `BACKSTAGE_WIDTH`/`BACKSTAGE_HEIGHT` (points, default: your main display's size),
`BACKSTAGE_SCALE` (default 2, Retina; `1` for a 1x display),
`BACKSTAGE_IDLE_TIMEOUT` (seconds, default 1800), `BACKSTAGE_HOME` (default `~/.backstage`),
`BACKSTAGE_MENUBAR=off` (no menu bar icon). Per command: `BACKSTAGE_SESSION=<name>` picks the session.

## Limits (read these)

- **Dock and ⌘-Tab.** An agent-launched app gets a Dock icon and shows up in the app switcher,
  just like any running app.
- **Windows an app opens later** (not at launch) can exist on your screen for a few
  milliseconds before the AX observer moves them. The watchdog measures this during the GUI test. Actual timing depends on the app,
  system load, and how quickly macOS delivers the accessibility notification. At launch the CLI
  checks window placement before asking macOS to unhide the app.
- **Self-activating apps.** If an app forces itself frontmost, the daemon tries to give focus
  back. This path is untested: macOS 14+ refused the test fixture's `activate()` call, so it
  never triggered.
- **The app thinks it's active.** Before the first input, the app is sent one private
  "you're active" event; without it AppKit eats clicks. The app sees a single
  `didBecomeActive`, like a human switching to it once. Accessory (`LSUIElement`) apps get it
  at launch, because they keep their windows hidden until then. Nothing changes for your real
  frontmost app.
- **Open menus and your typing.** While an agent app's menu is open it holds the keyboard
  focus. The input guard hands keys from your keyboard (or a remote-desktop tool posting HID
  events) to your frontmost app, so they arrive as usual. Some edges remain:
  - Keys another program posts to that app without going through the HID system are dropped,
    not handed over.
  - Your clicks and scrolls can't be aimed at a hidden app (the cursor is kept off its
    display). Any that the system routes there anyway are dropped.
  - In testing, a click of yours closed the agent's open menu; your click still reached your
    own app. The agent has to open the menu again.
  - The guard is fed the set of managed apps and your frontmost app by the daemon's main
    loop, so a just-launched app or an app switch is covered after a short delay, typically
    under 50 ms.
  - Not verified: keys under Secure Input (a password field has focus) may skip event taps
    altogether.
- **Hover is best-effort.** Tracking-area hover effects and tooltips follow the real cursor,
  so `hover` generally won't trigger them.
- **Custom-drawn UI** (canvases, games, video timelines) has no accessibility tree. Use
  screenshot + coordinate `click`/`drag`/`scroll`; those are tested on a custom NSView. Apps that
  poll the *real* mouse position or button state, rather than reading events, won't see them.
- **Second copies of apps you're already running.** Apps launch with `-n`, a new instance, so
  your copy is never touched. Single-instance apps that hand off to an existing instance
  (Safari, Mail…) aren't suitable.
- **Instances of one app share preferences and app data.** Every copy of an app, yours and
  each agent's, reads and writes the same preferences and Application Support files, so one
  instance's settings changes show up in the others. Don't rely on per-instance settings.
  (`CFFIXED_USER_HOME` doesn't isolate preferences on macOS 27.) The clipboard is shared
  too: put text in with `set` or `type` rather than ⌘C/⌘V.
- **Monitor unplugged or powered off.** If no real display is left, the daemon shuts down,
  quitting agent apps, so your windows don't get stranded on the invisible display.
- **Private APIs.** `CGVirtualDisplay`, `CGEventSetWindowLocation`, `_AXUIElementGetWindow`.
  These are stable for years but undocumented, and a macOS update could break them. Tested on macOS 27.0.1.
- **Screen Recording prompts.** macOS may periodically ask you to re-confirm Screen Recording
  for the host terminal.
- **Daemon killed with `kill -9`.** The display vanishes and its windows migrate to your main
  screen. Normal stops and crashes caught by signals quit the apps first.
- **A real "Backstage (agent display)" monitor** appears in System Settings › Displays while the
  daemon runs.

## Development

```bash
make build          # swift build -c release
make test-cli       # offline CLI / process-ownership regression tests
make test-agents    # hook decisions + install/uninstall in a throwaway HOME + dist skill sync
make test           # all of the above, then a GUI fixture app driven through every command
                    # while a watchdog (~1.5 ms sampling) checks nothing reaches your screen,
                    # then the two-session test (tests/multi.sh; also `make test-multi`)
                    # and the shared-display test: overlapping windows, menus, sheets,
                    # popovers, and a slow launch (tests/concurrency.sh; `make test-concurrency`)
make dist           # regenerate dist/skills/backstage/SKILL.md from Sources/backstage/Skill.swift
make load           # load harness, 2-session smoke (not in `make test`); full runs need a
                    # separate account or Mac: see docs/LOAD_TESTING.md
```

Layout: `Sources/backstage/` (CLI and daemon), `Sources/CVirtualDisplay/` (private API header),
`dist/skills/` (the skill for packaging), `tests/` (fixture app, watchdog, test scripts),
`docs/USAGE.md` (reference).
