# backstage

**Let coding agents run, test, screenshot and click through macOS apps without taking over your screen.**

When an agent builds a Mac app and wants to check it works, the window normally pops up in
front of you, steals keyboard focus, and fights you for the mouse. `backstage` runs those apps
on an invisible virtual display instead. The agent can still see them (screenshots and the
accessibility tree) and use them (clicks, typing, menus, drags) while you keep working.
Input goes directly to the managed app. If an app activates itself or opens a later window
on your display, it can briefly take focus or appear before Backstage moves it back.

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

<p align="center">
  <img src="docs/images/menu-bar.png" width="345"
       alt="The backstage menu: a live picture of the hidden display, then the apps each agent session is running (Claude, Codex and Grok), with the version and a GitHub link at the bottom">
  <br>
  <sub>The <a href="#menu-bar-indicator">menu bar indicator</a> while three agents test apps out of sight.</sub>
</p>

## Requirements

- macOS 14.2 or later (tested on macOS 27.0.1, Apple Silicon). Agent apps are always muted,
  which needs 14.2's audio taps: on 14.0 and 14.1, `launch` refuses.
- Xcode or Command Line Tools with Swift 5.9+
- **Permissions** for whatever runs the CLI (your terminal or agent host), in System Settings ›
  Privacy & Security: **Accessibility** and **Screen & System Audio Recording** (Screen
  Recording). For agents to check what an app plays (`launch --audio`, then `backstage audio`,
  `wait --sound`, `audio record`), the host also needs **System Audio Recording Only**: a
  separate switch from Screen Recording, in the same Settings pane. Muting works without it,
  helper processes included.
  - **Which host.** The audio grant is checked against the app that started the backstage
    daemon (the terminal or agent host that ran the first `backstage` command), not the
    `backstage` binary. If agents run from several hosts, the one that started the running
    daemon is the one that needs it; `backstage doctor` names it (`audio.host`). The grant is
    keyed to that host's binary path, so updating the host may need it granted again.
  - `backstage doctor` checks all of them. Its audio self-test is what makes macOS ask for
    System Audio Recording the first time.

## Install

With [Homebrew](https://brew.sh):

```bash
brew install andrewfitz/backstage/backstage
backstage doctor              # check permissions
backstage install --hooks     # optional: skill + hook for Claude Code / Codex / Grok
```

Prebuilt for macOS 15 and later on Apple Silicon; elsewhere Homebrew builds it from source
(needs Xcode). Installing by the full name trusts the tap's formula. After
`brew upgrade backstage`, run `backstage stop --all && backstage start` so the daemon runs the
new version (this quits the apps agents have open backstage).

From source:

```bash
git clone https://github.com/andrewfitz/backstage.git
cd backstage
make install                  # builds and copies $(PREFIX)/bin/backstage (PREFIX=/opt/homebrew)
                              # and $(PREFIX)/lib/backstage/libbackstage-inaudible.dylib
```

`make install PREFIX=/usr/local` installs elsewhere. `make uninstall` stops the daemon and
removes both. Use one or the other: a `make install` copy in `/opt/homebrew/bin` stops
Homebrew from linking its own.

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
What changed in each version: [CHANGELOG.md](CHANGELOG.md).

## How it works

| Piece | Mechanism |
|---|---|
| Invisible screen | A background daemon creates a private Retina (2x) `CGVirtualDisplay` (the API DeskPad/BetterDisplay use), the same size in points as your main display, and parks it touching only the bottom-right corner of your desktop (never along an edge, so neither your cursor nor the Dock can drift onto it). If the cursor ever gets onto it, the cursor is warped back. |
| Launch without popping up | LaunchServices' own open call (the one behind `open -g -j -n`): background, hidden, fresh instance. The windows are moved to the virtual display while still hidden, then unhidden there. |
| No Dock tile | The same call passes a private LaunchServices option that starts the app as a UIElement, the way menu bar apps run: no Dock tile, not in ⌘-Tab, no change to the app's bundle. `launch` reports `"dock": "hidden"`, or `"visible (app made itself a regular app)"` for an app that undoes it (see [Limits](#limits-read-these)). `show` makes the app a regular app again before handing it over. |
| Windows the app opens later | An AX observer (with 50 ms polling as backup) moves them to the virtual display as soon as they're created. |
| Your windows that wander backstage | An app you relaunch can reopen a window where it last was, which may be a hidden display (macOS remembers backstage's fixed displays like any monitor). The daemon returns windows of apps it doesn't run to your main screen after 3 s, moving them without taking focus; **Recover Lost Windows** and `backstage recover` do it at once. Apps an agent launched are never put on your screen this way. |
| Focus stealing | The app is never activated. If it activates itself, the daemon hands focus back to your app. |
| Screenshots | ScreenCaptureKit, filtered to that app's windows (menus, sheets and popovers included). Captures take turns across all sessions: on macOS 27, two processes capturing at once both hang. Each takes about 0.1–0.2 s. |
| Input | AX actions (press/set/focus/menus), plus keyboard and mouse events posted straight to the app's process (`CGEventPostToPid`). Mouse events get window-local coordinates. A private "you are active" event goes to the app only, so AppKit doesn't swallow the click as a focus click. Nothing goes through the HID system, so your real cursor and keyboard are never touched. Every event backstage posts is tagged (event source user data). |
| Your input stays yours | An app with an open menu (a context menu, a menu bar menu, a pop-up button's list) takes macOS's keyboard focus, even in the background, so your typing would go to the hidden app. The daemon runs an event tap on its own thread that sees every key, click and scroll after macOS has picked the receiving app: untagged input headed for a managed app is yours, so keys are handed to your frontmost app instead and clicks and scrolls are dropped. It costs a few microseconds per event. If macOS disables the tap, it is re-enabled at once; if the tap can't be installed, input commands refuse to run and `backstage status` says why. |
| Silence | Every agent app is muted the moment it first uses Core Audio: a private, muted process tap per app (helper processes included), inside a private tap-only aggregate device. Nothing reaches your speakers, whatever device the app picks; your apps, output device and volume aren't touched. If an app can't be muted, it isn't launched, or is quit. Dev builds and test runners are also made inaudible from inside (a small injected library), so they're silent in screen sharing, remote desktop and recordings too. Only apps launched with `--audio` are measured (`backstage audio`, `wait --sound`). |
| Teardown | `backstage stop` quits the calling session's apps, and stops the daemon when no session has apps left. `backstage stop --all` (or the daemon getting SIGTERM/SIGINT/SIGHUP) quits every app *before* removing the display, so nothing lands on your screen. After 30 min with no managed apps in any session, the daemon exits by itself, unless Keep in Menu Bar is on. |
| Several agents | Each agent session owns the apps it launches, so concurrent agents never pick up, type into, screenshot or stop each other's apps. Commands on one app are serialized with a per-app lock. See [Sessions](docs/USAGE.md#concepts). |
| More room | An agent can take a hidden display of its own with `launch --display new` (reserved for its session for 30 minutes, removed 30 minutes after its last app leaves, or right away with `close-display` or the menu's ⓧ), and a launch says `"crowded": true` when its window found no free spot. Backstage only ever uses eight fixed display identities, so macOS's display registry doesn't grow. See [Displays](docs/USAGE.md#displays). |

## Sound

Every app an agent launches is silent for you from the moment it first uses Core Audio, so an
agent can test a media player, a game or a notification sound while you hear nothing. How
silent depends on the app, and on whether the agent asked to inspect its sound:

| `launch` | Apps | Your speakers | Screen sharing, remote desktop (Parsec), recordings | `audio`, `wait --sound` |
|---|---|---|---|---|
| default | dev builds and test runners: `xctest`, ad-hoc signed, unsigned or development-signed builds, bare executables | silent | **silent** | refused |
| default | everything else: signed, hardened or Apple apps | silent | can hear it | refused |
| `--audio` | any | silent | can hear it | measured |

- **Inaudible (the default for dev builds and test runners).** Before the app's own code runs,
  an injected library (`libbackstage-inaudible.dylib`, through `DYLD_INSERT_LIBRARIES`) makes
  the app tell Core Audio it's inaudible. Core Audio then zeroes its sound before anything can
  capture it, so it's absent from your screen-sharing or remote-desktop stream, from
  recordings and from every other system-wide capture. Only the app itself can do this, so it
  only works for apps that accept the library: not hardened-runtime apps (unless they allow
  DYLD variables and other libraries), not Apple's apps. `launch` reports `"audio":
  "inaudible"`. Children of the app inherit it when they accept it too.
- **Muted (the default for everything else).** A muted process tap keeps the app off your
  Mac's outputs, but macOS hands its sound to system-wide captures before that point, so
  someone listening through screen sharing or a remote-desktop session can hear it. `launch`
  reports `"audio": "muted"` and why it couldn't be inaudible (`audioReason`).
- **`--audio`: inspect the sound.** Muted the same way, and measured. Use it only when the
  agent needs to check sound; remote and capture listeners can hear the app. `--inaudible`
  forces the inaudible mode and fails for an app that won't accept it.

With `--audio`, the agent gets facts from the muted output:

```bash
backstage audio                        # playing? peakDb/rmsDb (dBFS), hz, recent sounds, time
backstage wait --sound --since 81234.5 # it played (even a short sound that's already over)
backstage wait --sound --gone          # it stopped
backstage audio record --seconds 5     # a WAV of the last 5 s (max 15), for any other tool
```

The usual check: read `time` from `audio`, click Play, `wait --sound --since T`, check
`audio` (`playing`, `peakDb`, `hz`), click Stop, `wait --sound --gone`. `audio record` writes
what the app played (float32, as tapped) for deeper checks such as speech-to-text or a
spectrum. `backstage show` hands an app to you unmuted, except an inaudible one, which stays
silent until it's relaunched. Measuring needs System Audio Recording (see
[Requirements](#requirements)); muting doesn't. Reference: [docs/USAGE.md](docs/USAGE.md#hear).

## Menu bar indicator

While apps are running backstage, an icon sits in the menu bar: a display behind a display, with
the number of running apps beside it. It disappears when nothing is running (unless you turn on
**Keep in Menu Bar**), and goes away entirely when the daemon exits. Its tooltip says who is using how many apps. While an app
launched with `--audio` is making sound (muted, so you don't hear it), the icon turns into a
small level meter, four bars of the loudest app's recent level, no wider than the icon; with Reduce Motion on, it shows
a still waveform instead. The icon's box never changes size. The menu shows:

- a **live picture** of the hidden agent display, refreshed every second while the menu is open.
  Point at an app's row and its windows are picked out in the picture. With several displays
  (`launch --display new`), two pictures sit side by side, each labelled, with ‹ › to page through more,
  and an ⓧ on every display but the first closes it (its apps move to the first display and keep running)
- **each app**, grouped by the agent session that launched it ("Claude — myproject": the agent,
  then the name given with `BACKSTAGE_SESSION` or the folder the agent works in), with how long
  it has been running, and a note if it has no windows or is playing sound (apps launched with
  `--audio`). Its submenu has **Show on My Screen** (the same as `backstage show`), **Move to ▸**
  (another hidden display, or a new one), **Quit** (hold Option for **Force Quit**), and its
  bundle ID and process ID
- **Send Front Window Backstage** (⌃⌥⌘B), described below; **Send Front Window To ▸**, the same
  onto a display you pick (say, a display of your own while agents work on display 1: later sends
  follow it there); **Recover Lost Windows**, which brings back windows of your own apps that
  ended up on a hidden display (an app reopening where it was while backstage; the daemon also
  does this by itself after 3 s, and `backstage recover` from a terminal); and **Open
  Screenshots & Logs Folder**
- **Quit All Agent Apps**: every app running here, including ones you sent backstage
- **Keep in Menu Bar**, described below
- a quiet footer with the version and a link to this repository

Long app and session names are shortened in the middle, so nothing widens the menu.

The daemon runs as a menu-bar-only app: no Dock icon, and it never takes focus. Set
`BACKSTAGE_MENUBAR=off` to run without the icon (and without the hotkey and Keep in Menu Bar).

### Keep in Menu Bar

Check **Keep in Menu Bar** (or run `backstage settings keep-in-menu-bar on`) and the icon stays
with nothing running: icon only, no count, and the menu says "No apps running" above the live
picture of the empty display. The daemon then doesn't exit when idle, and a session's plain
`backstage stop` leaves it running (`stop --all` still stops it). **Quit All Agent Apps** quits
the apps but keeps the icon. Turn it off and, with no apps left, the daemon exits after the usual
idle timeout. The setting lives in `~/.backstage/settings.json`. It doesn't start anything at
login: after a restart, `backstage start` brings the icon back (a login item may come later).

### Send Front Window Backstage

The reverse of **Show on My Screen**: press **⌃⌥⌘B** (Control-Option-Command-B), or choose
**Send Front Window Backstage** from the menu, and the app you're using moves to the hidden
display. backstage manages whole processes, so all of the app's windows go, not just the front
one. Keyboard focus goes back to the app you used before it. The icon blinks twice and VoiceOver
announces "Sent … backstage"; nothing else happens on your screen.
- **Your agents can use it.** It shows in the menu under **Sent by you**. Any agent session can
  drive it with an explicit `--pid` (or `--app`) after finding it with `backstage list --all`
  (session `user`). It's never a session's default target, and a session's plain `stop` leaves it
  alone. Only `stop --all`, **Quit All Agent Apps** or its own **Quit** quit it. If it doesn't
  quit when the daemon stops (an unsaved-changes dialog), or its sound can't be muted, it comes
  back to your screen instead: backstage never force-quits your app by itself.
- **Bring it back** with **Show on My Screen** (or `backstage show --pid P`): its windows come
  back to your screen, it's focused, and you hear it again.
- **Muted, not inaudible.** It was already running, so it can only be muted with a tap (see
  [Sound](#sound)): screen sharing and recordings can still hear it.
- **Its Dock tile stays**, because you opened it normally. Clicking the tile or ⌘-Tabbing to it
  doesn't bring it forward: the daemon hands focus straight back, and the input guard keeps your
  typing out of it. Use Show on My Screen.
- **Never sent** (the icon gives a small shake instead, and the reason goes to
  `~/.backstage/daemon.log`): Finder, the Dock, Control Center, Notification Center, Spotlight,
  loginwindow and anything else in `/System/Library`; menu bar and background apps; backstage
  itself; an app that's already backstage; an app in full screen; an app with no open window; and
  apps you need in front of you to stay in control: Terminal, Ghostty, iTerm, Warp, kitty,
  Alacritty, WezTerm, herdr, Claude, ChatGPT/Codex, Parsec, and the terminal or agent host the
  daemon runs under. The menu item is disabled, with the reason in its tooltip, when the
  frontmost app is one of these.
- **The shortcut** works whenever the daemon runs, so it pairs with Keep in Menu Bar. Change it
  with `backstage settings hotkey <combo>` (two or more modifiers, one of them ⌘ or ⌃, and a
  letter, digit or F1–F12; keys are named by their place on a US keyboard), or turn it off with
  `backstage settings hotkey off`. The running daemon picks the change up at once. The menu shows
  the current shortcut beside the item; if it couldn't be registered (it's a macOS keyboard
  shortcut), the item shows none, and `backstage status` and the daemon log say why. A shortcut
  another app registered the same way can't be detected (macOS accepts both). Only the daemon in
  `~/.backstage` has a shortcut by default; one started with another `BACKSTAGE_HOME` (tests, for
  instance) registers one only if its own settings name it.

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

## Using with computer use (Claude/Codex desktop apps)

The Claude desktop app and Codex (its desktop app, and Codex sessions that have the Computer
Use plugin) give agents computer-use tools. They come in two kinds, and backstage works with
each differently:

| Tools | How they see and act | With backstage |
|---|---|---|
| **Screen tools**: Claude's full-screen control (`screenshot`, `left_click`, `type`, `key`, `switch_display`…) | Screenshots of a whole display; input posted to the HID system from Claude.app's own process, so the real pointer moves and keys go to the focused app | Can't see the hidden display. The app must be on your screen: the agent runs `backstage show <app>`, or `backstage show --pid P` to hand over an app it launched hidden. If it picks the monitor "Backstage (agent display)", its clicks are dropped and your pointer is pulled back |
| **Per-app background tools**: Claude's `app_*` tools (`app_screenshot`, `app_click`, `app_type`, `app_key`, `app_menu`…), Codex's `get_app_state`, `click`, `type_text`, `press_key`… | Capture one app's window wherever it is (ScreenCaptureKit, per window); accessibility actions, and input posted straight to the app's process (Claude: `Claude.app/Contents/Helpers/app-cu-helper`; Codex: `Codex Computer Use.app`'s `SkyComputerUseService`) | Also work on an app backstage launched, which stays hidden: the input guard lets these helpers' input into managed apps |

- **The hook** still blocks `open` and friends inside these apps, because most sessions there
  never use computer use. Its message adds: driving the app with screen tools means
  `backstage show` (or the computer-use tool's own open-application action). In the Claude
  desktop app (`CLAUDE_CODE_ENTRYPOINT` `claude-desktop`, `claude-desktop-3p`, `local-agent`)
  and the Codex desktop app (`CODEX_INTERNAL_ORIGINATOR_OVERRIDE` set) that advice comes first.
- **The input guard** only ever touches input headed for apps backstage manages. Once an app is
  handed over with `show --pid`, it's yours and computer use drives it like any other app.
  Into a managed app it lets through, besides backstage's own tagged input, untagged input
  posted by the two helpers above. Before this, Claude's helper posted keys from an HID-state
  source, so the guard would have handed an agent's `app_key`/raw `app_type` keys for a hidden
  app to your frontmost app. Input from your keyboard and mouse, from remote tools such as
  Parsec, and from Claude's full-screen tools (which follow the real pointer and focus) is still
  redirected or dropped.
- **Naming the app:** if you also run your own copy of an app the agent launched hidden, a name
  or bundle id matches both instances (Codex's tool reports "Multiple apps share this bundle
  identifier"). A build at its own path is unambiguous (Codex accepts a full path).
- **Don't mix** backstage's input commands and computer-use input on one app at once: they share
  its keyboard focus and menus. Claude's computer-use runtime watches key-downs, probably for Esc
  to cancel, so a backstage `key esc` may stop it (not verified).
- **Not verified end to end:** nobody ran Claude's or Codex's computer-use tools against a
  hidden app. The capture APIs they import are the ones `backstage screenshot` uses for the
  agent display. `tests/computer-use.sh` checks the vendor signatures of installed helpers,
  rejects vendor-unsigned fixtures, and exercises the input classifier. How Codex's service
  posts its input isn't known: it resolves those functions at run time under names it builds
  then. If it posted to the HID system rather than to the app, its keys could land in a hidden
  app while that app's open menu holds the keyboard focus.

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
backstage audio                            # muted app's sound: playing, peakDb, hz, sounds, time
backstage wait --sound --since 81234.5     # did it play (since `time`)? --gone: has it stopped?
backstage audio record --seconds 5         # -> {"path": ".../audio-….wav", ...}: the last 5 s it played
backstage logs                             # the app's stdout/stderr
backstage window fill                      # window covers the whole agent display (or: window size 1280 800)
backstage launch MyApp.app --display new   # a hidden display of your own (clean recordings, full screen)
backstage move --display 1                 # move your app to another display
backstage close-display 2                  # remove display 2 (its apps move to display 1)
backstage recover                          # bring stray windows back to the user's screen
backstage screenshot --full --display 2    # one whole display, your session's windows only
backstage quit
```

- Commands return JSON. Plain `tree` prints indented text, `logs` streams the requested lines, and `help` prints usage. Use `tree --json` for structured output.
- Coordinates are agent-display points, with (0,0) at the top-left of the app's virtual display. A
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
Your settings: `backstage settings keep-in-menu-bar on|off` and `backstage settings hotkey <combo|off>`
(see [Menu bar indicator](#menu-bar-indicator)); `backstage settings` and `status` show them.

## Limits (read these)

- **Dock and ⌘-Tab.** Launched apps get no Dock tile and stay out of ⌘-Tab, except apps that
  make themselves regular apps at startup (`setActivationPolicy(.regular)` or
  `TransformProcessType`: Keka, apps built on Qt and other cross-platform toolkits, and some
  `swift build` products). Those get a Dock tile within half a second, and nothing outside the
  app can take it away again; `launch` then returns `"dock": "visible (app made itself a regular
  app)"`. For Qt apps backstage sets `QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM=1`, which
  stops it. In your own app, skip `setActivationPolicy(.regular)` when it runs from a bundle
  (it's the default there). Injecting a library that blocks the call was tried and left out: it
  only works for unsigned, non-hardened builds, and needs a launch shim that itself brings the
  Dock tile back. `launch --dock` launches with a Dock tile on purpose.
- **Bare executables start in `/`.** LaunchServices runs them directly (a shim that `cd`s first
  makes them regular apps again), so their working directory is `/`, as for any app opened from
  Finder. Pass absolute paths. `Bundle.main`, `@executable_path` and `@rpath` still resolve to
  the executable's own directory.
- **Windows an app opens later** (not at launch) can exist on your screen for a few
  milliseconds before the AX observer moves them. The watchdog measures this during the GUI test. Actual timing depends on the app,
  system load, and how quickly macOS delivers the accessibility notification. At launch the CLI
  checks window placement before asking macOS to unhide the app.
- **Self-activating apps.** macOS 14+ refuses `activate()` from a regular background app, but
  an app running without a Dock tile (a UIElement) may activate itself. The daemon hands focus
  straight back: in the end-to-end test the fixture's `activate()` held the keyboard focus for
  10–20 ms. `launch --dock` apps are refused as before.
- **The app thinks it's active.** Before the first input, the app is sent one private
  "you're active" event; without it AppKit eats clicks. The app sees a single
  `didBecomeActive`, like a human switching to it once. Apps without a Dock tile get it at
  launch, because they keep their windows hidden until then. Nothing changes for your real
  frontmost app.
- **Open menus and your typing.** While an agent app's menu is open it holds the keyboard
  focus. The input guard hands keys from your keyboard (or a remote-desktop tool posting HID
  events) to your frontmost app, so they arrive as usual. Some edges remain:
  - Keys another program posts to that app without going through the HID system are dropped,
    not handed over. Computer-use helpers driving the app are let through (see
    [Using with computer use](#using-with-computer-use-claudecodex-desktop-apps)).
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
- **Private APIs.** `CGVirtualDisplay`, `CGEventSetWindowLocation`, `_AXUIElementGetWindow`,
  and LaunchServices' `_LSOpenURLsWithCompletionHandler` with `_kLSOpenOptionUIElementLaunchKey`
  (no Dock tile) and `_LSSetApplicationInformationItem` (`show` restoring it). If an update drops
  the LaunchServices pieces, apps get a Dock tile again and nothing else changes.
  These are stable for years but undocumented, and a macOS update could break them. Tested on macOS 27.0.1.
- **Screen Recording prompts.** macOS may periodically ask you to re-confirm Screen Recording
  for the host terminal.
- **Daemon killed with `kill -9`.** The display vanishes and its windows migrate to your main
  screen. Normal stops and crashes caught by signals quit the apps first.
- **A real "Backstage (agent display)" monitor** appears in System Settings › Displays while the
  daemon runs.
- **Sound limits.** Details in [docs/USAGE.md](docs/USAGE.md#audio-limits).
  - **Muted isn't inaudible.** A muted app (a signed, hardened or Apple app, or any app
    launched with `--audio`) is silent on your Mac's outputs, but screen sharing, remote desktop
    (Parsec), screen recordings and other system-wide captures still carry its sound. Only dev
    builds and test runners can be made inaudible everywhere.
  - **Inaudible apps can't be measured**, by anyone: `audio`, `wait --sound` and `audio record`
    refuse them. An app made inaudible stays so after `show`.
  - **Children of an inaudible app** load the library too, if they accept it (macOS's own
    tools drop it). Each one connects to Core Audio as it starts (about 30 ms) and gets tapped.
    An app that runs scripts through `/bin/sh` loses it for everything those scripts start,
    and sound played by services macOS starts for the app (WKWebView's WebKit GPU process) is
    only muted.
  - **System sounds stay audible.** Alert sounds and beeps (`NSBeep`,
    `AudioServicesPlaySystemSound`) are played by macOS's shared `systemsoundserverd`, not the
    app. Muting it would mute your own alerts too, so they're neither muted nor measured.
    AppKit beeps on an unhandled keystroke, so an agent's typing can cause one.
  - **Shared playback daemons** may work the same way: speech (`AVSpeechSynthesizer`, `say`)
    probably plays outside the app, and is unmeasured.
  - **`kill -9` of the daemon** unmutes its apps within milliseconds (a crash it can catch
    quits them first). A `coreaudiod` restart probably does too, until the daemon rebuilds the
    taps.
  - **macOS 14.0 and 14.1** have no audio taps: `launch` refuses there.
  - **The permission belongs to the daemon's host** (the terminal or agent host that started
    it), keyed to its binary path, so a host upgrade may need it granted again. macOS's
    audio-recording indicator names that host while an agent app plays.
  - **Apps may ask for the Microphone** the first time they play to an audio device that has
    input streams (an audio interface, a loopback): macOS 27 asks that even for output only.
    The prompt appears on your screen in the app's name.

## Development

```bash
make build          # swift build -c release, plus the injected library (universal)
make test-cli       # offline CLI / process-ownership regression tests
make test-agents    # hook decisions + install/uninstall in a throwaway HOME + dist skill sync
make test           # all of the above, then a GUI fixture app driven through every command
                    # while a watchdog (~1.5 ms sampling) checks nothing reaches your screen,
                    # then the two-session test (tests/multi.sh; also `make test-multi`)
                    # and the shared-display test: overlapping windows, menus, sheets,
                    # popovers, and a slow launch (tests/concurrency.sh; `make test-concurrency`),
                    # computer-use helper signing and input classification
                    # (tests/computer-use.sh; `make test-computer-use`), then audio: muting, levels, sounds, show, refusals, and `audio record`'s
                    # WAVs checked by tests/wavcheck.swift (tests/audio.sh; `make test-audio`;
                    # leak checks run when a loopback device exists), then Send Front Window
                    # Backstage and Keep in Menu Bar (tests/send.sh; `make test-send`), then
                    # the fixed display serials (tests/displays.sh; `make test-displays`),
                    # several displays per daemon: --display new, reservations, move,
                    # close-display, the menu's layouts (tests/multidisplay.sh;
                    # `make test-multidisplay`), and stray windows coming back
                    # (tests/strays.sh; `make test-strays`). GUI suites use displays 7-8 only
tests/audio-leak.sh --dedicated   # audio leak suite: dedicated Mac with a loopback as default output
make dist           # regenerate dist/skills/backstage/SKILL.md from Sources/backstage/Skill.swift
make load           # load harness, 2-session smoke (not in `make test`); full runs need a
                    # separate account or Mac: see docs/LOAD_TESTING.md
```

Layout: `Sources/backstage/` (CLI and daemon), `Sources/CVirtualDisplay/` (private API header),
`Sources/CBackstageAudio/` (the audio taps' IOProc and the crash handler, in C),
`Sources/BackstageInaudible/` (the library injected into inaudible launches, in C),
`dist/skills/` (the skill for packaging), `tests/` (fixture app, watchdog, test scripts),
`docs/USAGE.md` (reference).
