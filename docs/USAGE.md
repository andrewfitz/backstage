# backstage usage

The command reference. Agents use most of these commands; for you there's the menu bar, the
⌃⌥⌘B shortcut and a handful of commands (`start`, `stop --all`, `show --pid`, `list --all`,
`settings`, `doctor`), described in the [README](../README.md#sending-your-own-apps-backstage)
and in [Apps you send backstage](#apps-you-send-backstage) below.

Every command prints JSON on stdout, except `help`, `skill`, `logs` and plain `tree`. On
failure a command prints `{"ok": false, "error": "…"}` and exits with status 1. Error
messages say what to do next.

[Concepts](#concepts) · [Lifecycle](#lifecycle) · [Hidden or shown](#hidden-or-shown) ·
[Apps you send backstage](#apps-you-send-backstage) · [See](#see) · [Hear](#hear) ·
[Recording](#recording-the-hidden-display) · [Act](#act) · [Displays](#displays) ·
[Agent integration](#agent-integration) · [Environment variables](#environment-variables)

## Concepts

**Hidden display.** A virtual monitor that only backstage's daemon can see (the CLI's help
calls it the agent display). It's created when the daemon starts and parked touching only the
bottom-right corner of your desktop, never along an edge, so neither your cursor nor the Dock
can drift onto it. Apps agents launch through backstage live there, and so do apps you send
backstage. By default it's the size of your main display in points, so
screenshots have its shape (a 4K monitor at the usual 2x is 1920×1080 points), and it's a
Retina display, drawn at 2x (3840×2160 pixels for that size), so apps render as they would on
a Retina screen. The size is read when the daemon starts; changing your displays later doesn't
resize a running one. `BACKSTAGE_WIDTH`/`BACKSTAGE_HEIGHT` set another size, and
`BACKSTAGE_SCALE=1` gives a 1x display. Normally there's one, display 1, shared by every agent
and by your apps; an agent can add a display of its own (`launch --display new`), and you can
too, from the menu. See [Displays](#displays).

**Coordinates.** All points are display points, with `(0,0)` at the top-left of the hidden
display the app is on. A default `screenshot` is cropped starting at `(0,0)`, so a pixel
`(x,y)` in the image is exactly the point to pass to `click x y`. If you captured with `--scale S`,
pass the same `--scale S` to `click`/`drag`/`scroll`/`hover`, or divide by S yourself.
Sizes are in points too, whatever the display's scale: a default screenshot is downsampled to
1 pixel per point, and `--scale 2` gives the display's native Retina pixels.

**Sessions.** Several agents can use backstage at once. Each command runs in a *session*,
and a session owns the apps it launches: its default target, `list`, `logs`, screenshots and
`stop` only ever see its own apps. Naming another session's app by `--pid` or element ref is an
error. Sessions keep cooperating agents out of each other's way; they aren't a security
boundary. The session is worked out per command, first match wins:

1. `BACKSTAGE_SESSION=<name>`, if set and non-empty. `legacy` and `user` are reserved.
2. The nearest agent process above the command (claude, codex, grok, cursor-agent, gemini,
   opencode, aider, amp, goose, including one run by `node`, `python`, `bun` or `deno`, which
   is recognised from its arguments), using that agent's own session variable if it sets one
   in its shells: `CLAUDE_CODE_SESSION_ID` (Claude Code; checked against `CLAUDE_PID`),
   `CODEX_THREAD_ID` (Codex), `GROK_SESSION_ID` (Grok). A variable only counts for the
   nearest agent, and only if that agent set it rather than inheriting it. So an agent started
   from another agent's shell gets its own session, even one of the same kind.
3. Otherwise that agent process itself: its name, PID and start time.
4. No agent, and the command has a terminal (you, or a script you run in a terminal): the
   terminal session, so each terminal tab or tmux pane is its own session.
5. Otherwise the nearest ancestor that isn't a shell or wrapper (`zsh`, `bash`, `make`,
   `env`, `tmux`…), by PID and start time.
6. Otherwise the outermost shell above the command: a private session, never a shared default.

If the command's parent has already exited (`backstage … &` from a shell that finished,
`nohup`, cron, launchd), there is nothing to walk. A single agent session variable is used as
is; otherwise the command fails and asks for `BACKSTAGE_SESSION`.

`backstage status` shows the current session and where it came from.

**Claude Code subagents share their parent's session.** Claude Code runs subagents inside the
parent's process and gives their shells the parent's `CLAUDE_CODE_SESSION_ID`, so nothing tells
them apart automatically. A subagent that launches its own apps should prefix each command,
for example `BACKSTAGE_SESSION=review-1 backstage launch …`. Agents run every shell command in
a fresh shell, so an `export` doesn't carry over to the next command; use the prefix every
time. **Codex subagents get their own sessions:** each has its own `CODEX_THREAD_ID` (checked
in a live session; `CODEX_SESSION_ID` is shared by a session's subagents, so it isn't used).
`GROK_SESSION_ID` hasn't been checked in a live Grok session; if Grok doesn't set it in its
shells, its process is used instead.

**Limits.** `env -i` and `sudo` drop the agent's variables, so a command run through them
lands in a different session (the agent process's, e.g. `claude:<pid>-<start>`) from the
agent's other commands. Agents backstage doesn't know are keyed by their process, which works
as long as they don't restart; give them `BACKSTAGE_SESSION` otherwise.

**Apps from before sessions** (registry records without an owner) belong to the `legacy`
session. They're never a default target and plain `stop` leaves them alone. `list --all` shows
them, `stop --all` quits them, and an explicit `--pid` still reaches them, since no session
owns them.

**Apps the user sent backstage** belong to the `user` session; see
[Apps you send backstage](#apps-you-send-backstage).

**App selection.** Commands that act on an app take `--pid P` or `--app NAME` (a managed
app's name or bundle id), within your session (or an app the user sent backstage). With
neither, they target your session's most recently launched app.

**Element refs.** `tree` and `find` label elements like `w8432.0.3`: the window ID, then
child indices. Refs survive windows being reordered, but not UI changes inside the window,
so re-run `tree`/`find` after the UI changes. Where a command takes `--window`, it accepts a
window ref (`w8432`) or a front-to-back index (`0` = frontmost).

## Lifecycle

### `launch <target> [--env K=V]… [--timeout S] [--dock] [--audio | --inaudible] [--display N|new] [-- app args…]`
Starts the daemon if needed, then launches `target` on a hidden display. `target` can
be an `.app` path, a bundle id (`com.apple.calculator`), an app name (`Calculator`), or a bare
executable such as a `swift build` product. A bare executable is wrapped in a throwaway
`.app` so it can launch hidden; it starts in `/` (not its own directory), so give it absolute
paths. A script (`#!`) that `exec`s the real binary (`exec xctest …`) works too: the process is
found by its launch token and kept out of the Dock, and `show` can't give it a Dock tile. (A
script that runs it without `exec` registers the shell, not the app; launch the binary
directly.) Every launch is a new instance (like `open -n`), so an existing copy of the app is
never touched.

```json
{"pid": 80562, "name": "Calculator", "bundleID": "com.apple.calculator",
 "path": "/System/Applications/Calculator.app",
 "windows": [{"ref": "w9435", "index": 0, "title": "Calculator", "frame": {"x": 40, "y": 60, "w": 230, "h": 408}}],
 "log": "~/.backstage/logs/….log", "dock": "hidden", "audio": "muted",
 "audioReason": "/System/Applications/Calculator.app/Contents/MacOS/Calculator is protected by System Integrity Protection (dyld ignores DYLD_INSERT_LIBRARIES for it); muted on this Mac's outputs only, so screen sharing and recordings can still hear it"}
```
`dock`: the app has no Dock tile and isn't in ⌘-Tab (`"hidden"`). An app that makes itself a
regular app at startup gets one anyway: `"visible (app made itself a regular app)"` (it
still runs on the hidden display; only the tile shows). `--dock` launches it with a Dock
tile on purpose: `"visible (--dock)"`. Qt apps are kept out of the Dock with
`QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM=1`, which `launch` adds to their environment.
`--display new` puts the app on a fresh display reserved for your session, `--display N` on that
display, and without it the app goes where your session already has apps, else display 1 (see
[Several displays per daemon](#several-displays-per-daemon)). The result says which (`display`), and
`"crowded": true` (with a `warning`) when its window found no free spot and overlaps others.

An app that exits by itself before `launch` finishes (often a test runner or command-line tool
that simply completed) gives `"ok": false` with `"exited": true`, its `pid`, its `log`, the last
lines of its output (`outputTail`) and, for a test runner, `testSummary` (the last "Executed N
tests" line). Read those: launching again, or on another display, won't change the outcome.

`--timeout` (default 15 s) is how long to wait for the first window. A windowless app still
launches; you get a `warning`, and any window it opens later is still pulled onto the agent
display.

Before that, `launch` waits for the app's process to appear, however short `--timeout` is: up
to 60 s, or 120 s while the system is under heavy load (1-minute load average above the CPU
count); `BACKSTAGE_LAUNCH_DEADLINE=S` overrides it. LaunchServices normally reports the new
process at once, but under heavy load (or a WindowServer stall) it can answer tens of seconds
late, or never, though the app is already running. `launch` doesn't depend on that answer: it
also recognises the process by the `BACKSTAGE_LAUNCH_ID` token in its environment (or its log
as stdout) and registers it as usual, with a `warning` that LaunchServices answered late or not
at all. Once LaunchServices has answered, the process gets 15 s (30 s under load) more to be
recognised. If no process appears in time, `launch` fails, but LaunchServices may still start
the app later: the daemon then registers it to your session (`list` shows it, and `quit`/`stop`
reach it). Until then `list` shows the launch under `pendingLaunches` (for up to 10 minutes).
If your session runs `stop` in the meantime, the daemon quits the app instead.

`audio` is how the app's sound is handled (see [Hear](#hear)):

| `audio` | When | Speakers | Screen sharing, remote desktop, recordings | `audio`, `wait --sound`, `audio record` |
|---|---|---|---|---|
| `"inaudible"` | default, for a target that accepts the injected library: dev builds and test runners (`xctest`, ad-hoc signed, unsigned or development-signed binaries, bare executables) | silent | silent | refused |
| `"muted"` | default, for everything else (signed for distribution, hardened runtime, Apple, SIP-protected, scripts), or when the library is missing | silent | **hear it** | refused |
| `"metered"` | `--audio` | silent | **hear it** | measured |

- `audioReason` says why an app isn't inaudible (or what `--audio` means).
- `--audio`: keep the sound inspectable. Use it only when you need to check sound: remote and
  capture listeners (the user's screen sharing or remote-desktop session) can hear the app.
- `--inaudible`: insist on the inaudible mode. `launch` fails before starting anything for a
  target that won't accept the library, and quits the app if it didn't become inaudible.
- **How inaudible works:** `DYLD_INSERT_LIBRARIES` loads `libbackstage-inaudible.dylib` into
  the app before its own code runs. It sets `kAudioHardwarePropertyProcessIsAudible` to 0 for
  the process, so Core Audio zeroes its output before any tap or capture sees it. `launch`
  waits for the app to acknowledge that Core Audio accepted the change. If the acknowledgement
  is missing or reports failure, a default launch reports `muted` and includes the reason. A
  `DYLD_INSERT_LIBRARIES` you pass with `--env` is kept (the library is put first).
- **The same library places the app's windows.** Just before AppKit shows a window for the first
  time, it moves the window onto the app's backstage display, keeping its size and its position
  relative to the screen it would have opened on, so a new window never appears on the user's
  screen. (A window the app itself moves onto the user's screen while it's shown is moved back
  by the daemon's observer, after the fact.) Sheets, popovers, child windows and windows already
  on a backstage display are left alone. This works for every way of showing a window,
  including in test bundles that load AppKit late (`xctest`). `--audio` launches of qualifying targets get the library for this
  alone (they stay audible). `move`, closing a display and `show --pid` update where new windows
  go before moving anything. Apps that don't qualify (signed, hardened, Apple) rely on the
  daemon's observer, which moves a window after it appeared and can show it on the user's
  screen for a moment. An app that puts a window on "another screen" on purpose sees it land on
  its own display instead.
- **Which targets qualify:** the process's real executable (a bundle's `CFBundleExecutable`, or
  the bare executable itself) must be a Mach-O that dyld honours DYLD variables for: not
  SIP-protected (`/System`, `/usr`, `/bin`, `/sbin`), not an Apple platform binary, not
  setuid, no `__RESTRICT` segment or restrict flag, and either no hardened runtime or both the
  `com.apple.security.cs.allow-dyld-environment-variables` and
  `com.apple.security.cs.disable-library-validation` entitlements. It must also be a dev build
  rather than released software: unsigned, ad-hoc signed, or carrying `get-task-allow`, but
  not signed by Apple or for Developer ID or the Mac App Store without `get-task-allow`. A
  script (`#!`) doesn't qualify: its interpreter is a system binary that drops DYLD variables.
- **Children** inherit the variable and load the library when they qualify. macOS's own tools
  (`/bin/sh`, `/usr/bin/env`, `xcodebuild`…) drop DYLD variables, so whatever they start
  doesn't get it: launch the test runner itself (`xctest`), not a script or `xcodebuild` around
  it. A child that qualifies connects to Core Audio as it starts (about 30 ms each). Sound an
  app plays through services macOS starts for it (WKWebView's WebKit GPU process, other XPC
  services) isn't covered: those are muted only.
- `audioWarning` appears when the running daemon is from an older build, which measures every
  app; `backstage stop --all` replaces it.

The app is **muted** in every mode. Muting is unconditional: `launch` refuses, before
starting anything, on macOS older than 14.2 or when the daemon's tap manager isn't healthy
(its mute self-test failed). If the app's audio can't be muted later, when it first uses Core
Audio, the daemon quits it at once; a `launch` still waiting fails with that reason, and `list`
shows it under `audioFailures`.

### `list [--all]`
Your session's apps with their windows. `--all` lists every session's apps; each entry has a
`session` field (`legacy` for apps from before sessions). `audio` is the launch's mode
(`inaudible`, `muted` or `metered`, as in `launch`). `tap` is the app's audio tap
(`muted`, `armed` or `failed`); apps the daemon quit because their audio couldn't be muted are
listed under `audioFailures` for 10 minutes. `pendingLaunches` lists launches that failed
because their process hadn't appeared yet (see `launch`): `launch` (its id), `path`, `log`,
`startedAt`, and `until` (when the daemon stops waiting for it). If the app starts, the daemon
registers it to the session and it moves to `apps`. Each app's `display` says which display it's
on, and its windows' frames are relative to that display.

### `quit [--force]`
Quits the app. If it refuses, for example because of a "Save changes?" sheet, you get
`"ok": false` with a note. Inspect it with `screenshot`/`tree`, deal with the dialog, or use
`--force`.

### `logs [--lines N]`
The last N lines (default 100) of the app's stdout and stderr.

### `status` / `doctor`
Shows the permissions (Accessibility, Screen Recording), the daemon and display, the current
session (`id`, and `from`: which rule above produced it), and every session's managed apps.
When something's missing, `problems` lists what to grant and where. `settings` shows your
settings (see [`settings`](#settings)), and with a daemon running, `hotkeyRegistered` (and
`hotkeyError` if the shortcut couldn't be registered).

`backstage version` (or `--version`) prints the CLI's version as plain text; `status` reports it
as `version`.

`audio` describes muting and measuring:

```json
"audio": {"muting": "ok", "capture": "granted", "floorDb": -80,
          "host": {"pid": 1777, "name": "Terminal", "path": "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"},
          "selfTest": {"captured": true, "levelDb": -60, "expectedDb": -60, "hz": 18500,
                       "device": "Mac Studio Speakers", "ioSetupMs": 1.8}}
```
- `muting`: `ok`, or `unavailable` with a `reason` (macOS before 14.2, a daemon from an older
  build, or a tap manager that failed its start-up check). While it's `unavailable`, `launch`
  refuses. With no daemon running, `status` shows `{"daemon": "not running"}` here instead.
- `capture`: `granted` or `not granted`: whether the daemon's host has System Audio Recording,
  which `audio`, `wait --sound` and `audio record` need (muting doesn't).
- `host`: the daemon's responsible process (`pid`, `name`, `path`), the app that must hold that
  grant: the terminal or agent host that started the daemon.
- `floorDb`: the level a sound must reach to count as playing (-80 dBFS).
- In `status`, a missing grant is a `warning`, not a problem: launching still works.

`doctor` also starts the daemon if needed and runs its **audio self-test**: the daemon plays an
inaudible probe (18.5 kHz, -60 dBFS, 0.5 s) from its own process to an output-only device,
muted by a tap on itself, and checks the tap captured it. `audio.selfTest` has `captured`,
`levelDb` (what the tap measured), `expectedDb` and `hz` (the probe's), `device` (where it
played), `ioSetupMs`, and `error` when it didn't capture (no output-only device, measuring not
permitted, an API error); `selfTest` is just `{"error": …}` if the daemon couldn't run it
within 60 s. The first run is when macOS asks the daemon's host for System Audio Recording, so
`doctor` is how to grant it, and `capture` then reflects the answer. Anything but a captured
probe is reported in `problems`, with where to grant it.

While the daemon runs, `daemon` describes its hidden display:

```json
{"pid": 52426, "displayID": 108, "size": {"w": 1920, "h": 1080}, "sizeSource": "main display",
 "pixels": {"w": 3840, "h": 2160}, "scale": 2, "globalOrigin": {"x": 1920, "y": 1080},
 "screencaptureDisplay": 2, "ffmpegScreen": "Capture screen 1"}
```
`size` is in points, and `sizeSource` says where it came from: `main display`, or `env` when
`BACKSTAGE_WIDTH`/`BACKSTAGE_HEIGHT` set it. `pixels` is the backing store.
`screencaptureDisplay` and `ffmpegScreen` identify the display to standard recording tools; see
[Recording](#recording-the-hidden-display).
`display` is its slot (1–8, see [Displays](#displays)). With more than one display (or a
reservation), `displays` lists each: `display`, `displayID`, `primary`, `globalOrigin`, `apps`,
`reservedBy`/`reservedUntil`, and its own `screencaptureDisplay`/`ffmpegScreen`. `doctor` adds
`leftoverDisplays` (see [`cleanup-displays`](#cleanup-displays)).

### `start` / `stop` / `stop --all`
`start` starts the daemon. `stop` quits **your session's** apps (forcing them after 3 s).
Other sessions' apps and `legacy` apps are left alone. If no app is left in any session, `stop`
also stops the daemon. If other sessions still have apps, or a launch or `show` is in progress
somewhere, the daemon keeps running, and the result's `daemon` field says so (a daemon left
running stops itself once idle). A launch your session started before the `stop` is cancelled
rather than registered. If something fails, `ok` is false and `error` says what, but `quit`
still lists the apps that were quit.

`stop --all` is the admin form. It quits every app in every session, `legacy` and `user`
included, and stops the daemon. Both forms are safe to run twice. Apps the user sent backstage
are quit gracefully only: one that doesn't quit within 3 s (an unsaved-changes dialog) is given
back to the user's screen instead of being forced.

With Auto-Hide When Idle off (the default in `~/.backstage`), plain `stop` never stops the
daemon (`daemon` says so); `stop --all` still does.

Apps are always quit *before* the display is removed, so nothing falls onto your screen. The
daemon also exits by itself after `BACKSTAGE_IDLE_TIMEOUT` seconds (default 1800) once no
session has managed apps (only with Auto-Hide When Idle on; the timeout starts over when it's
turned on), or when no physical display is left.

**Restarts don't touch your monitor.** Each display lives in a small helper process, the display
host (`backstage __display-host`), not in the daemon, because adding or removing a display makes
macOS reconfigure every display, and some monitors blank for that. After `stop` or `stop --all`
in `~/.backstage`, the primary display stays for `BACKSTAGE_DISPLAY_LINGER` seconds (default 15;
0 in any other home, so tests' displays go with their daemon), and a daemon started meanwhile
takes it over: `stop --all && start`, or an upgrade between them, changes nothing on your
screens. Nothing is on it meanwhile (its apps were quit first), and it's parked at your
desktop's corner as usual. Extra displays, an idle exit and any other shutdown remove displays at
once. If a display's host dies, its display goes; for the primary, the daemon shuts down with it.

### `settings`

```
backstage settings                          # show them
backstage settings auto-hide on|off         # hide the menu bar icon (and stop the daemon) with no apps
backstage settings hotkey <combo|off>       # the Send Front Window Backstage shortcut
```
Stored in `$BACKSTAGE_HOME/settings.json`. The running daemon applies a change within half a
second, without a restart; the command waits for it and reports `hotkeyRegistered` (plus
`hotkeyError`, e.g. when the combo is a macOS keyboard shortcut). With no daemon, `daemon` is
`"not running"`: `backstage start` brings up the icon after a restart (nothing starts at login).

- **auto-hide** (the menu's Auto-Hide When Idle; default off in `~/.backstage`, on in any other
  home so test and agent homes don't keep a display forever). Off: the icon stays with no apps
  (icon only, no count), the daemon doesn't exit when idle, plain `stop` leaves it running, and
  the menu's Quit All quits the apps but keeps it. On: with no apps the icon goes and the idle
  timeout runs from then. Ignored with `BACKSTAGE_MENUBAR=off`. `keep-in-menu-bar on|off` is the
  older, opposite spelling; `settings` reports both `autoHide` and `keepInMenuBar`.
- **hotkey** (default `ctrl+opt+cmd+b`, ⌃⌥⌘B): two or more of `ctrl`/`control`, `opt`/`option`/
  `alt`, `shift`, `cmd`/`command`, one of them `cmd` or `ctrl`, then a letter, digit or `f1`–`f12`
  (keys by their place on a US keyboard). `default` restores ⌃⌥⌘B; `off` turns it off. It's
  reported in canonical form (`opt+cmd+b`) with `hotkeySymbols` (`⌥⌘B`). The daemon registers it
  with Carbon's `RegisterEventHotKey` (no permission needed) and needs the menu bar: there's none
  with `BACKSTAGE_MENUBAR=off`. A combo that's an enabled macOS keyboard shortcut is refused and
  logged; one another app registered the same way can't be detected, since macOS accepts both.
  Only the daemon in `~/.backstage` has a shortcut by default: a daemon with another
  `BACKSTAGE_HOME` registers one only if its settings name it (`hotkeyNote` says so).

A launch that dies before its app is registered (an agent's tool timeout, Ctrl-C) leaves a
record behind; the daemon quits the app it started, so nothing is left unowned. A launch that
fails because the app's process hadn't appeared in time hands its record to the daemon
instead, which registers the app to the session if it starts within 10 minutes (see `launch`).

After upgrading backstage, a daemon from the older version is replaced automatically if it
has no apps. If it still has apps, commands that need the daemon fail and ask you to run
`backstage stop --all` first.

## Hidden or shown

### `show --pid P` / `show --app NAME` / `show` (most recent)
Hands one of your session's hidden apps over to the user. Its windows move to the centre of
the main display, the app comes to the front, and backstage stops managing it, so it leaves
your session. Its state is kept: no relaunch. Its audio tap is removed, so the user hears it:
the result has `"audio": "unmuted"` once the daemon confirmed that. An app launched inaudible
stays inaudible (`"audio": "inaudible"`): it silenced itself, and only relaunching it undoes
that (`show <app>`, or `launch --audio` then `show --pid`). An app `launch` kept out of
the Dock becomes a regular app again first: `"dock": "restored"` (or `"visible"` if it already
had a Dock tile). Menu bar apps whose own Info.plist sets `LSUIElement` have no Dock tile to
restore; `dock` then says why. `show --pid P` also gives back an app the user sent backstage
(`list --all`, session `user`), the same way: on their screen, focused, audible again.

### `show <app|file|url>`
Opens anything on the user's screen, the way `open` would. If backstage is running a hidden
instance of the app that would open it (in any session), `show` opens a new instance for the
user instead of handing the request to the hidden one.

Use `show` only when the user asked to see something, or to drive the app with computer-use
tools that work on the user's screen (below). Each use is logged to
`~/.backstage/shown.log`.

### Computer-use tools
Computer-use tools that work on the user's screen (Claude desktop's full-screen `screenshot`,
`left_click`, `type`…) can't see the hidden display: to drive an app with them, put it on the
user's screen with `show <app>`, or `show --pid P` for one you launched hidden. After that
backstage doesn't manage it, so its input guard and cursor guard leave it alone. Never pick the
monitor named "Backstage" with them: clicks there are dropped and the pointer is moved
back to the user's screens.

Per-app background tools (Claude's `app_*` tools, Codex's `get_app_state`, `click`,
`type_text`…) capture one window wherever it is and post input to that app's process, so they
can also drive a hidden app. The input guard validates the running helpers' vendor signatures
before letting their input into managed apps
(`Claude.app/Contents/Helpers/app-cu-helper`, `…/Contents/MacOS/SkyComputerUseService`).
Name the app unambiguously when the user runs their own copy too. Don't drive one app with
backstage's input commands and computer-use input at the same time. See the README's
[Computer use](../README.md#computer-use-claude-and-codex-desktop-apps).

## Apps you send backstage

**Send Front Window Backstage** (the menu item, or **⌃⌥⌘B**) moves the frontmost app, all of
its windows, onto a hidden display; **Send Front Window To ▸** picks the display, or a new one.
The README describes it from your side: [Sending your own apps
backstage](../README.md#sending-your-own-apps-backstage). For the CLI and for agents:

- **Session `user`.** A sent app belongs to the reserved session `user`. `list --all` shows it
  there; a session's own `list` names it only under `sentByUser`, with a note.
- **Agents act on it only when asked.** Any session reaches it with an explicit `--pid` or
  `--app` (`--app` looks in the session's own apps first), so an agent can screenshot, read and
  drive it, or `move --display N` it. It's never a default target, and a session's plain `stop`
  leaves it alone. `quit --pid P` works, but it holds the user's work: quit it only when asked.
- **Coming back.** `show --pid P` (or the menu's **Show on My Screen**) gives it back: windows on
  the main display, focused, audible again. `stop --all`, the menu's **Quit All Agent Apps** and
  the app's own **Quit** quit it, gracefully only: one that doesn't quit within 3 s (an
  unsaved-changes dialog) is given back instead. Any other shutdown (the last monitor gone, a
  display that couldn't be parked) gives it back without quitting it.
- **Sound.** Its `audio` is `muted` (it was already running, so it can't be made inaudible), and
  its tap is removed when it's given back.
- **Where it goes.** Plain Send Front Window Backstage goes to the display your sent apps are
  on, else display 1. A display you create from the menu is reserved for `user`: agents'
  automatic placement never goes there, and their `launch --display N` or `move --display N`
  onto it is refused.
- **The shortcut** is a setting: [`settings hotkey`](#settings).

## See

### `screenshot [-o out.png] [--window I] [--full [--display N]] [--scale S]`
- **Default:** the app's windows (including menus, sheets and popovers), cropped from the
  display origin, so image pixel = click point.
- **`--window I`:** one window only. The JSON's `origin` is that window's position:
  `point = origin + pixel / scale`.
- **`--full`:** the whole hidden display, showing every window of all of your session's apps
  and nothing else: other sessions' apps are left out (black), wherever they are. Windows of
  separate system processes, such as the out-of-process open/save panel or a share sheet, are
  left out too (as in the default capture); inspect those with `tree`/`find`.
- **`--full` with several displays:** it captures one display: the one your session's apps
  are on, or `--display N` when they're on more than one.
- **Format:** a `.jpg`/`.jpeg` output path gives JPEG; anything else gives PNG. Without
  `-o`, files go to a per-session folder, `~/.backstage/shots/<session>/`.

```json
{"path": "~/.backstage/shots/claude_3503a10a-…-1f2e3d4c5b6a/shot-….png", "width": 460, "height": 392, "origin": {"x": 0, "y": 0}, "scale": 1, "pid": 64304}
```

### `tree [--window I] [--depth N] [--json]`
The accessibility tree. Plain output is compact text, one element per line:
```
[w9184] Window(StandardWindow) "BackstageTestApp" @40,60 420x332 {raise}
  [w9184.0] Button "Increment" @59,141 122x32 {press}
  [w9184.1] StaticText value="count: 0" @201,142 148x26
  [w9184.2] TextField @59,195 302x28 {confirm} (focused)
```
Each line shows the role, title/value/description, frame (`@x,y wxh` in display
points), supported actions, and disabled/focused state. `--json` gives the same as structured data.

### `find [text] [--text T] [--role R] [--window I]`
Elements whose role contains R and whose title/value/description/identifier contain T
(case-insensitive). Returns up to 200 matches, with refs and frames.

### `windows`
The app's windows, with refs, titles and frames.

### `window fill [--window I]` / `window size <w> <h> [--window I]`
Resizes one of the app's windows (default: its frontmost) through accessibility, without
raising or activating anything. `fill` makes it cover the whole display below the
display's menu bar, for full-display screenshots. `size` sets its size in points, keeping its
position unless it has to move to stay on the display; a size bigger than the display is an
error (start the daemon with a larger `BACKSTAGE_WIDTH`/`BACKSTAGE_HEIGHT`). This is not
macOS full screen, which would open a new Space.

```json
{"ok": true, "pid": 58295, "window": "w21293", "frame": {"x": 0, "y": 30, "w": 1920, "h": 1050}}
```
`frame` is where the window ended up. If the app limited the size (a minimum or maximum
size, or a fixed-size window), `requested` shows what was asked for and `note` says so.

### `wait --text T [--role R] [--gone] [--timeout S]`
Polls until a matching element appears (or, with `--gone`, disappears). Default timeout
10 s. Returns the element and the time it took.

## Hear

Every app backstage launches is muted: the daemon puts it (and its helper processes) under a
private, muted Core Audio process tap the moment it first uses Core Audio, so nothing it plays
reaches the speakers, whichever output device it picks. The user's own apps, the default output
device and the volume are never touched. Dev builds and test runners are also made
**inaudible** from inside, so they're silent in screen sharing, remote desktop and recordings
too (see `launch`'s `audio`).

**Measuring is opt-in: launch with `--audio`.** Only those apps are measured: `audio`,
`wait --sound` and `audio record` refuse any other app at once (`launched inaudible` or
`launched without --audio`: relaunch with `--audio`), the tap of an unmeasured app never runs
IO (so no recording indicator), and only measured apps drive the menu bar meter. A measured app
is muted on the Mac's outputs but not in system-wide captures, so use `--audio` only when you
need to check sound. `show` hands an app over unmuted. Needs macOS 14.2+; measuring (not
muting) needs **System Audio Recording** for the daemon's host (see `doctor`). Without it, muting still
covers helper processes that start audio later: macOS refuses to change an existing tap then, so
the daemon replaces the tap with one covering every process (the new one is in place before the
old one goes).

A Play/Stop check:

```bash
backstage launch ./MyPlayer.app --audio  # opt in to measuring
T=$(backstage audio | jq .time)          # the clock, before acting
backstage click --ref w8432.0.7          # Play
backstage wait --sound --since "$T"      # it played
backstage audio                          # playing, peakDb, hz: is it the right sound?
backstage click --ref w8432.0.8          # Stop
backstage wait --sound --gone            # it stopped
backstage audio record --seconds 5       # optional: the WAV, for any other tool
```

### `audio`
```json
{"pid": 80562, "tap": "muted", "processes": [80562, 80571], "ioRunning": true,
 "playing": true, "peakDb": -6.1, "rmsDb": -9.0, "hz": 440,
 "sampleRate": 48000, "channels": 2, "floorDb": -80, "time": 81234.52,
 "sounds": [{"start": 81232.21, "seconds": 2.31, "peakDb": -6.0, "rmsDb": -9.2, "ongoing": true}]}
```
- `tap`: `muted`, or `armed` (the app hasn't used Core Audio yet; it's muted the moment it
  does). A failed tap is an error: the daemon quit the app.
- `ioRunning` and `playing` tell apart no audio output at all, output running but silent, and
  sound. `playing` means the peak reached `floorDb` (-80 dBFS) within the last 0.3 s.
- `peakDb`/`rmsDb` (dBFS) and `hz` (the strongest frequency: meaningful for tones, not for
  music or speech) cover the last second. -200 dBFS means digital silence.
- `sounds`: the last 16 stretches of sound, split where the level stays under the floor for
  0.3 s. `start` is on the `time` clock.
- `time`: now, on the clock `--since` uses (system uptime in seconds).
- On an output device with more than 2 channels, `outputChannels` and `levelGainDb` appear:
  see [levels](#levels-on-multichannel-devices).
- Fails with a clear error when System Audio Recording isn't granted to the daemon's host, and
  at once for an app launched without `--audio`.

### `wait --sound [--gone] [--since T] [--min-db D] [--timeout S]`
Waits until the app plays sound: a sound that's playing now or starts during the wait.
`--since T` instead counts a sound that started at or after `T`, even if it's already over,
so short sounds aren't missed. The pattern: read `time` from `audio`, act (click Play), then
`wait --sound --since T`. `--min-db D` counts only sounds whose peak reaches `D` dBFS.
`--gone` waits until the app is silent, and returns the sound that ended. Default timeout 10 s.

```json
{"ok": true, "sound": {"start": 81232.21, "seconds": 0.1, "peakDb": -60.0, "rmsDb": -63.1, "ongoing": false}, "seconds": 0.42, "time": 81233.4}
```
A timeout exits 1 and says which case it was: `no audio output running`, `output running but
silent`, or `loudest sound peaked at -40.0 dBFS, below --min-db -30.0`. `--text` and `--sound`
can't be combined.

### `audio record [-o out.wav] [--seconds N]`
Writes a WAV of the last `N` seconds (default and maximum 15) of what the app played, from the
15 s ring the daemon keeps of its muted tap. Without `-o`, the file goes to the session's
screenshots folder, `~/.backstage/shots/<session>/audio-….wav`; an `-o` path must end in
`.wav`.

```json
{"ok": true, "pid": 80562, "path": "~/.backstage/shots/claude_3503a10a-…/audio-….wav",
 "seconds": 5, "sampleRate": 48000, "channels": 2, "format": "float32",
 "start": 81229.52, "end": 81234.52}
```
- **What's in it:** the tap's stereo mixdown, 32-bit float (`WAVE_FORMAT_IEEE_FLOAT`), the
  samples exactly as tapped. The multichannel compensation `audio` applies to its levels
  isn't applied: on a device with more than 2 channels the result has `levelGainDb`, and the
  WAV reads that much below `audio`'s `peakDb`/`rmsDb`.
- **Which seconds:** the ring is a continuous timeline of the app's output (pauses are stored
  as silence) that ends where output last ran. While the app's output runs, that's now; after
  it stops (output is considered stopped 1 s after the app stops it), the WAV still ends at
  that point, so recording after `wait --sound --gone` still gets the sound. `start` and `end`
  are on `audio`'s `time` clock, so they line up with `sounds`.
- **`seconds`** is what the file holds: less than asked if the app started playing less than
  that long ago. While output runs, a full 15 s request returns about 14.9 s: the newest
  writes may overwrite the oldest frames during the read, and those are dropped.
- **Errors:** `nothing to record` if the app hasn't played any sound since launch (no output
  ever ran), the System Audio Recording error if the grant is missing (nothing is captured
  then), and the usual ones for an app of another session or one that's gone.

### Levels on multichannel devices
A tap delivers a stereo mixdown, which averages a device's odd channels into left and its even
channels into right (measured on a 10-channel interface: a stereo sound on channels 1-2 reads
-14 dB, one on all 10 channels reads true). backstage compensates by N/2 for the widest device
the app plays to, which is exact for the usual case of stereo on one channel pair; sound
spread over more channels then reads high, by up to 20·log10(N/2) dB.

### Audio limits
- **Muted isn't inaudible.** macOS hands a muted app's sound to system-wide captures before
  the mute: screen sharing, remote desktop (Parsec uses ScreenCaptureKit), recordings, and
  global or device taps all carry it. Only the app can keep its sound out of them, which is
  what the inaudible mode makes it do; signed, hardened and Apple apps can't be made to.
- **Inaudible apps are silent to backstage too**: there's nothing to measure, so the audio
  commands refuse them, and `show` can't make them audible.
- **Alert sounds and beeps** (`NSBeep`, `AudioServicesPlaySystemSound`) are played by macOS's
  shared `systemsoundserverd`, not the app: they stay audible and unmeasured (tapping it would
  mute the user's own alerts). AppKit beeps on an unhandled keystroke, so typing into an app
  can cause one.
- **Shared playback daemons** may work the same way: speech (`AVSpeechSynthesizer`) probably
  plays outside the app (unmeasured), so it may be audible and invisible to `audio`.
- **`kill -9` of the daemon** unmutes its apps within milliseconds (a crash it can catch kills
  the apps first). A `coreaudiod` restart rebuilds the taps; sound may be heard until then.
- **macOS 14.0 and 14.1** have no process taps: `launch` refuses there.
- **The grant belongs to the daemon's host** (whichever terminal or agent started it), keyed
  to that host's binary path: a host upgrade may need it granted again. While an app plays,
  macOS's audio-recording indicator names that host.
- **An app may ask for the Microphone** the first time it plays to an audio device that has
  input streams (an audio interface, a loopback): macOS 27 asks that for output-only playback.
  The prompt appears on the user's screen in the app's name.
- Muting is in place about 16 ms (median) after the app becomes an audio client (13-89 ms over
  24 measured runs); every app measured so far took longer than that to start playing.

### The published files
The daemon writes `$BACKSTAGE_HOME/audio/<pid>-<birth>.json` (the state above) and, from the
app's first sound, `<pid>-<birth>.pcm`: a ring of the last 15 s of the tap (float32 stereo,
interleaved, after a 64-byte header; the format is documented in
`Sources/CBackstageAudio/include/CBackstageAudio.h`). Both are mode 0600 and removed with the tap.

## Recording the hidden display

backstage doesn't record video itself, but the standard macOS `screencapture` tool can record
the hidden display, or take stills of it, without any window, prompt or focus change:

```bash
n=$(backstage status | jq .daemon.screencaptureDisplay)
screencapture -x -v -V 10 -D "$n" run.mov      # 10 s of video (H.264 .mov), no sound
screencapture -x -D "$n" still.png             # one still at native resolution
```

- **Several displays:** `.daemon.screencaptureDisplay` is the primary's. For another, use its
  entry: `backstage status | jq '.daemon.displays[] | select(.display == 2) | .screencaptureDisplay'`
  (and `ffmpegScreen`). Recording a display of your own (`launch --display new`) leaves other
  sessions' windows out.
- `-D` counts the active displays from 1 in the system's order, which changes when displays
  are added or removed (another monitor, a restarted daemon). Read `screencaptureDisplay`
  right before recording.
- The video is the display's native pixels (twice its size in points), recorded only when
  something changes, so a still display gives few frames.
- It records the **whole hidden display**: other sessions' windows, and the display's copy of
  the menu bar, which shows the user's frontmost app and their menu bar items. For an image of
  your session's apps only, use `screenshot --full`.
- `-x` turns off screencapture's sounds. While anything captures the screen (backstage's own
  screenshots too), macOS shows its screen recording indicator in the menu bar; nothing else
  appears on the user's screen.
- `backstage` screenshots keep working while a recording runs.
- ffmpeg's avfoundation input names screens in the same order, which is what `ffmpegScreen`
  reports (`ffmpeg -f avfoundation -i "Capture screen 1" …`). That path isn't tested.

## Act

Everything is delivered to the app's process directly. Your cursor, keyboard and frontmost
app are never touched. Each command holds a lock on its target app from the first focus change
to the last event. If two commands drive the same app at once, one waits for the other, so
typing never interleaves. Commands on different apps don't wait for each other.

| Command | What it does |
|---|---|
| `press <ref>` | AXPress: buttons, checkboxes, menu items, links… The most reliable way to click. |
| `set <ref> <value>` | Sets an element's value (text fields, sliders, steppers). |
| `focus <ref>` | Focuses an element and makes its window the app's key window. |
| `action <ref> <AXAction>` | Any accessibility action: `AXIncrement`, `AXShowMenu`, `AXConfirm`, `AXCancel`, `AXRaise`… |
| `click <x> <y> [--right] [--double]` | A real mouse click at a display point. Makes the target window key first. |
| `click --ref <ref> [--right] [--double]` | Clicks an element: AXPress when it supports it, otherwise a mouse click at its centre. `--raw` forces the mouse. |
| `hover <x> <y>` | Sends mouse-moved events. Best-effort: hover effects and tooltips that use tracking areas won't fire. |
| `drag <x1> <y1> <x2> <y2> [--steps N]` | Mouse down, move in N steps (default 20), mouse up. |
| `scroll <x> <y> [--dy N] [--dx N]` | Pixel scroll. Negative `dy` scrolls down (default −100). |
| `type <text> [--ref R]` | Types Unicode text into the focused element, or focuses R first. Newline and tab characters in the text become Return and Tab. |
| `key <combo>… [--ref R]` | Key presses such as `return`, `esc`, `tab`, `space`, `delete`, `up`/`down`/`left`/`right`, `home`, `end`, `pageup`, `f1`–`f12`, or letters/digits/punctuation with modifiers: `cmd+s`, `cmd+shift+z`, `ctrl+alt+t`. Takes several combos in one call. |
| `menu "File > Save As…"` | Presses a menu bar item by path. Matching is case-insensitive, ignores `…`, and accepts prefixes. |

## Displays

macOS registers every new display identity for good (ColorSync, WindowServer), and ColorSync
slows down as its list grows, so backstage uses only eight fixed displays
(docs/MULTI_DISPLAY_PLAN.md):

| Display | Used by |
|---|---|
| 1 | The default home (`~/.backstage`): all agents, and the apps you send |
| 2–6 | Other homes, and extra displays of a daemon (`launch --display new`) |
| 7–8 | backstage's own test suites |

`BACKSTAGE_DISPLAY=N` picks a home's display; without it, a home other than the default takes
the lowest free of 2–6. Asking for a display that's in use fails (`display 7 is in use`) after
waiting up to 5 s (a display that just stopped can linger a moment).

### Several displays per daemon

- `launch --display new` creates a display and **reserves** it for the caller's session for
  30 minutes (an empty display the session already reserved, or that nobody holds, is reused
  instead of adding another): other sessions can't launch on it, `move` onto it, or get it from
  Send Front Window Backstage. The display itself is removed 30 minutes after the last app or
  pending launch left it (`BACKSTAGE_EXTRA_DISPLAY_GRACE`), or right away with
  [`close-display`](#close-display-n---force) (the menu's ⓧ): every display that comes or goes
  can briefly blink the user's monitor, so an empty one is kept for the next send, move or
  launch. An empty display
  costs memory (its framebuffer, roughly 33–100 MB at 3840×2160) but no CPU or GPU.
- `launch --display N` uses display N, creating it if this daemon may run it (2–6 for the
  default home), refused if another session reserved it.
- Without `--display`, a launch goes where the caller's session already has apps, else to the
  primary display.
- A launch whose window found no free spot (it overlaps others) says `"crowded": true`, with a
  warning suggesting `--display new`.
- `move --display N|new [--pid P]` moves an app and its windows; the window guard keeps it there.
- Coordinates, screenshots, `window fill`/`size`, `tree`, `find` and input are relative to the
  app's own display. `list` gives each app's `display`; `status` lists the displays
  (`daemon.displays`: apps, reservation, `screencaptureDisplay` and `ffmpegScreen` for
  recording) when there's more than one.
- The menu bar menu shows up to two displays' pictures stacked, labelled, with ‹ › to page
  through more.
- **From the menu, the user moves apps too:** each app's **Move to ▸** (a display, or **New
  Display**), and **Send Front Window To ▸** for an app of their own. A display the user creates is
  kept for them (reserved for session `user`): agents' automatic placement never goes there, and
  an agent's `launch --display N` or `move --display N` onto it is refused. Plain Send Front Window
  Backstage (and ⌃⌥⌘B) goes to the display the user's sent apps are on, else display 1. The
  user's choices override agents' reservations.
- Agents can `move --display N --pid P` an app the user sent (explicit `--pid`), like any other
  command on it.

### For display and color tools

Backstage's displays are virtual displays with stable identifiers, so tools that manage
calibration, gamma or color (Redlight, f.lux, Lunar, BetterDisplay…) can recognise and skip them:

- **Name:** always contains `Backstage` (today exactly `Backstage`; `Backstage (agent display)` up to 1.3.2).
- **Vendor / model:** `0xB57A` / `0x0001` (`CGDisplayVendorNumber` / `CGDisplayModelNumber`).
- **Serials:** `0x42530001`–`0x42530008` (displays 1–8).

Creating or removing one is a normal display reconfiguration
(`CGDisplayRegisterReconfigurationCallback` fires, and ColorSync registers the display). Backstage
keeps churn low: a daemon's primary display lives as long as the daemon (which keeps running
while its menu bar icon does; with Auto-Hide When Idle on, until 30 minutes after its last app)
and survives daemon restarts, and an extra display (`launch --display new`) is removed only after
it has been empty for 30 minutes, or when someone closes it. Its size is the main display's in
points at 2x; `BACKSTAGE_WIDTH`, `BACKSTAGE_HEIGHT` and `BACKSTAGE_SCALE=1` make it smaller.

### `move --display N|new [--pid P]`
Moves one of your apps, with its windows, to another of the daemon's displays (`new`: a fresh one,
reserved for your session). An app the user sent backstage can be moved too, with an explicit
`--pid`. Refused onto a display another session (or the user) reserved. Its coordinates, crops and
input follow it to the new display. Returns `from`, `display`, `moved` (windows placed) and
`windows`. The user moves apps from the menu (each app's **Move to ▸**).

### `close-display N [--force]`
Removes one of the daemon's extra displays now, instead of waiting for it to empty and time out.
Its apps move to the first display first (still running, windows placed there, coordinates
following them), then the display goes. The first display always stays. Refused when another
session reserved the display or has apps on it, and while a launch is putting an app there;
`--force` closes it anyway. Returns `display`, `closed`, `moved` (the PIDs that moved) and
`movedTo`. The user closes one with the ⓧ on its picture in the menu (there for every display
but the first).

### `recover [--dry-run]`
Returns windows of apps backstage doesn't run that ended up on a hidden display to the user's
main screen. It's usually an app reopening a window where it last was: backstage's displays keep
fixed identities, so macOS remembers them like any monitor, and an app once sent backstage can
come back there after the user relaunches it. The daemon does this by itself once a window has
sat on one of its displays for 3 s (`BACKSTAGE_STRAY_GRACE`), only moving it, never activating
it; an app a `backstage launch` opened (an agent's app, even one handed over with `show`) is left
to an explicit `recover`, so an agent's app never lands on the user's screen by itself. `recover`
does it now, for every display of this daemon (`BACKSTAGE_HOME`). Managed apps, their helpers
(child processes, XPC services) and apps a launch is still opening are never touched. Returns
`recovered` (and `failed`, if any window couldn't be moved); `--dry-run` lists them as `stray`
without moving anything. The menu's **Recover Lost Windows** does the same and
brings the app forward.

### `cleanup-displays`
`sudo backstage cleanup-displays` removes ColorSync's records of backstage displays that aren't
attached, left by versions that gave every home its own display identity. ColorSync only honours
this from root; `doctor` says when it's worth running (`leftoverDisplays`).

## Agent integration

### `install [--claude] [--codex] [--grok] [--cursor] [--opencode] [--hooks]`
Writes the skill to `<agent dir>/skills/backstage/SKILL.md` (`~/.claude`, `~/.codex`, `~/.grok`,
`~/.cursor`, `~/.config/opencode`). With no agent flags, it installs for every agent whose
config directory exists. (Cursor and OpenCode also read `~/.claude/skills`, so with Claude
installed they see the same skill twice; the copies are identical.)

`--hooks` also adds the PreToolUse hook to each agent's config, keeping your existing entries
and backing the file up to `*.backstage-bak` first:

| Agent | Config file | Shell tool names matched |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | `Bash` |
| Codex | `~/.codex/hooks.json` | `Bash`, `exec_command`, `shell`, `local_shell` |
| Grok | `~/.grok/config.toml` | `Bash`, `run_terminal_command`, `run_terminal_cmd` |
| Cursor | `~/.cursor/hooks.json` | the `beforeShellExecution` event (every shell command) |
| OpenCode | `~/.config/opencode/plugins/backstage.js` | a plugin whose permission hook checks each `shell` command |

Cursor gets its decision as JSON on stdout (`{"permission": "allow"}` or `"deny"` with
`user_message` and `agent_message`). The OpenCode plugin runs `backstage hook pre-tool-use` for
each shell command and denies the call with the hook's message; it's a file of backstage's own
(first line `// backstage-managed-plugin`), and install refuses to replace a different file there.

Running install again is safe. Restart agent sessions afterwards (OpenCode loads plugins when it
starts). Grok only runs hooks in trusted folders; check with `/hooks-list`.

### `uninstall [--claude] [--codex] [--grok] [--cursor] [--opencode]`
Removes the skill and only backstage's own hook entries (and its OpenCode plugin file).

### `skill`
Prints the skill. `make dist` writes it to `dist/skills/backstage/SKILL.md`.

### `hook pre-tool-use`
The hook entry point. It reads the agent's hook JSON on stdin, and for a shell command that
would put something on the user's screen it exits 2 with the reason on stderr (a "deny" in
Claude Code, Codex and Grok). For Cursor's `beforeShellExecution` it always answers in JSON on
stdout instead (`{"permission": "allow"}`, or `"deny"` with `user_message` and `agent_message`),
and OpenCode's plugin calls it with a Claude-style payload and turns a deny into a permission
denial. It blocks:
- `open …`, except `open --help`
- running `Something.app/Contents/MacOS/…` directly
- `osascript` that activates, launches or opens an app

It also looks inside `bash -c`, `sh -c` and `zsh -c`, and past `sudo`/`env`/`nohup` and
similar prefixes. Anything it can't parse, and any tool that isn't a shell, is allowed.

Two environment variables change it:
- `BACKSTAGE_SHOW=1 <command>` lets one deliberate, user-requested command through.
- `BACKSTAGE_HOOK=off` disables the hook entirely.

Every deny message also tells a computer-use agent to use `show` (or its tool's own
open-application action) when it will drive the app with screen tools. In the Claude desktop app
(`CLAUDE_CODE_ENTRYPOINT` is `claude-desktop`, `claude-desktop-3p` or `local-agent`) or the
Codex desktop app (`CODEX_INTERNAL_ORIGINATOR_OVERRIDE` is set), that advice comes first. These
variables only reorder the advice: nothing extra is allowed.

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `BACKSTAGE_DISPLAY` | 1 for the default home, else the lowest free of 2–6 | Which of the eight fixed displays this home's daemon uses (see [Displays](#displays)) |
| `BACKSTAGE_EXTRA_DISPLAYS` | `2,3,4,5,6` | Which slots this daemon may add as extra displays (set before the daemon starts; tests use `8`) |
| `BACKSTAGE_RESERVATION_SECONDS` | 1800 | How long `launch --display new` reserves a display (set before the daemon starts; at most a day) |
| `BACKSTAGE_EXTRA_DISPLAY_GRACE` | 1800 | Seconds an empty extra display waits before it's removed (set before the daemon starts) |
| `BACKSTAGE_STRAY_GRACE` | 3 | Seconds an unmanaged app's window may sit on a backstage display before the daemon returns it to the user's screen (see [`recover`](#recover---dry-run)) |
| `BACKSTAGE_HOME` | `~/.backstage` | State, logs, screenshots. Each home has its own daemon and hidden display; daemons of different homes run side by side, their displays chained diagonally off the corner, each touching the next only at a corner point |
| `BACKSTAGE_SESSION` | derived | The session this command belongs to (see Sessions); `legacy` and `user` are reserved |
| `BACKSTAGE_WIDTH` / `BACKSTAGE_HEIGHT` | main display's size | Hidden display size in points (set before the daemon starts) |
| `BACKSTAGE_SCALE` | 2 | Hidden display backing scale: `2` is Retina, `1` gives a 1x display (set before the daemon starts) |
| `BACKSTAGE_IDLE_TIMEOUT` | 1800 | Seconds with no managed apps before the daemon exits (only with Auto-Hide When Idle on) |
| `BACKSTAGE_DISPLAY_LINGER` | 15 in `~/.backstage`, else 0 | Seconds the primary display outlives a stopped daemon, for the next one to take over without a display change (at most 300) |
| `BACKSTAGE_MENUBAR` | on | `off` hides the menu bar indicator, and with it the hotkey and Auto-Hide When Idle (set before the daemon starts) |
| `BACKSTAGE_TEST_HOOKS` | — | Tests only: `1` allows `backstage __send-backstage --pid P`, the Send Front Window Backstage path the menu and hotkey run |
| `BACKSTAGE_TEST_REFUSE` | — | Tests only: one more bundle-ID prefix Send Front Window Backstage refuses |
| `BACKSTAGE_TEST_SEND_REQUESTS` | — | Tests only (set before the daemon starts): `1` makes the daemon send a pid written to `$BACKSTAGE_HOME/send-request` (`PID`, or `PID DISPLAY` for Send Front Window To) through its hotkey path, in place of the frontmost app, and move a managed app as the menu's Move to does for `PID DISPLAY` in `move-request` (result in `move-result`) |
| `BACKSTAGE_TEST_LS` | — | Tests only: `no-callback`, `no-find` (comma-separated) simulate a LaunchServices that never answers or a process `launch` can't find |
| `BACKSTAGE_FAKE_AUDIO` / `BACKSTAGE_REDUCE_MOTION` | — | Tests only (set before the daemon starts): a synthetic level for the menu bar meter; force Reduce Motion on (`1`) or off (`0`) |
| `BACKSTAGE_HOOK` | on | `off` disables the hook |
| `BACKSTAGE_SHOW` | — | `1` as a command prefix lets that command past the hook |
| `BACKSTAGE_TEST_AUDIO` | — | Tests only (set before the daemon starts): `mute-fail`, `tap-fail` or `no-capture` simulate those failures |
| `BACKSTAGE_INAUDIBLE_DYLIB` | next to the binary, else `../lib/backstage/` | Path of `libbackstage-inaudible.dylib` for `launch`; empty means none (tests: the fallback to muted) |

`BACKSTAGE_LAUNCH_ID`, `BACKSTAGE_INAUDIBLE_ACK`, `BACKSTAGE_AUDIBLE`, `BACKSTAGE_PLACEMENT` and
`BACKSTAGE_CAPTURE_RETRY` are internal (set by backstage for the processes it starts); `launch`
refuses all but the last in `--env`.
