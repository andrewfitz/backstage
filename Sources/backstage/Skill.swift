// The agent skill shipped with backstage. Single source of truth: `make dist` writes it to
// dist/skills/backstage/SKILL.md and `backstage install` copies it into each agent's skill dir.

let skillMarkdown = #"""
---
name: backstage
description: Launch, test, screenshot and click through macOS GUI apps on a hidden virtual display. Use whenever you need to run a .app or GUI binary to verify a build, reproduce a bug, run a UI check, or look at an app for your own purposes. When the user explicitly asks to see something on their own screen, or you will drive the app with computer-use tools that work on the user's screen, use `backstage show` instead.
---

# backstage: use GUI apps without touching the user's screen

`backstage` runs macOS apps on a hidden virtual display. You can see apps (screenshots,
accessibility tree) and drive them (clicks, typing, menus) while the user keeps working.
If an app activates itself or opens a later window on a user display, it can briefly take
focus or appear before Backstage moves it back.

## First decide: is this for you, or for the user?

**For you: run it hidden with `backstage launch`.** This is the default. It covers anything you
do to check or understand your own work:
- launching an app you just built to confirm it starts, renders, or behaves
- reproducing a bug, smoke testing, or clicking through a flow
- taking screenshots to look at the UI yourself, before/after comparisons
- exploring an unfamiliar app or checking how a system app behaves
- anything where the user said "test", "check", "verify", "make sure", "does it work",
  "debug", "screenshot", "try it", or similar
- any case where you're unsure

**For the user: put it on their screen with `backstage show`.** Only do this when the request is
for *them* to see or use it now: "open it", "show me", "let me see", "pull it up", "launch it
for me", "I want to try it", "demo it", or a final hand-off they asked for. The one other case:
you'll drive the app with computer-use tools that work on the user's screen (below).
- If you've been driving the app hidden, `backstage show --pid P` hands over that running
  instance, state included, so there's no relaunch.
- `backstage show <app|file|url>` opens anything else on their screen.
- Never run `open`, `osascript … activate`, or `Foo.app/Contents/MacOS/Foo` directly. A hook may
  block those, and they interrupt the user.

**Driving it with computer-use tools?** Tools that screenshot the user's screen and move their
real mouse can't see the hidden display: use `backstage show` (see
[Computer-use tools](#computer-use-tools)).

When you finish hidden work the user might want to see, say so and offer:
"Want me to open it on your screen?" Otherwise don't show it unasked.

## Core loop

```bash
backstage launch path/to/MyApp.app      # also: bundle id, app name, or a bare executable
backstage screenshot                    # → {"path": "….png"}; read the image
backstage tree                          # accessibility tree; refs like w8432.0.3
backstage find --role button --text Save
backstage press w8432.0.3               # or: click --ref w8432.0.3
backstage click 412 230                 # screenshot pixel == click point
backstage type "hello" --ref w8432.0.5  # focus a field, then type
backstage key cmd+s
backstage menu "File > Export…"
backstage wait --text "Saved" --timeout 10
backstage wait --sound --since 81234.5  # did it play? (needs `launch --audio`; `time` from `backstage audio`)
backstage logs                          # the app's stdout/stderr
backstage quit                          # always clean up; `backstage stop` quits all your apps
```

- **Building first:** build as usual (`xcodebuild`, `swift build`, `make`…), then `backstage
  launch` the resulting `.app` or executable. Pass app arguments after `--`, and environment
  with `--env K=V`. A bare executable starts in `/`, so pass it absolute paths.
- **Seeing:** prefer `tree`/`find` for structure and text, and `screenshot` for visual checks.
  Re-run `tree`/`find` after the UI changes, because refs can go stale.
- **Retina:** the display renders at 2x. A screenshot is 1 pixel per point by default;
  `--scale 2` gives full detail (then pass `--scale 2` to `click`, or halve the pixel).
- **Full-display shots:** `backstage window fill` makes the window cover the display (below its
  menu bar); `backstage window size 1280 800` sets an exact size in points.
- **Recording:** to record 10 s of the agent display, run
  `screencapture -x -v -V 10 -D "$(backstage status | jq .daemon.screencaptureDisplay)" out.mov`
  (`-x` keeps it silent). It captures the whole agent display, including other sessions'
  windows. Never record or capture the user's own screens.
- **Acting:** `press`/`set`/`menu` are the most reliable. Use coordinate `click`/`drag`/`scroll`
  for custom-drawn views. `hover` is best-effort: tooltips won't appear.
- **A display of your own:** `launch --display new` puts the app on a fresh hidden display
  reserved for your session (for 30 minutes; it goes away when its apps quit). Use it for a
  clean full-display screenshot or recording, a full-screen app, or when a launch result says
  `"crowded": true` (no free spot: windows overlap). Your later launches follow you there;
  `move --display N` moves an app. Coordinates are always relative to the app's own display.
- **Several apps:** commands target your most recent launch. Pass `--pid P` (from
  `launch`/`list`) to be explicit.
- **Other agents share the hidden display.** Each agent session only sees and drives the
  apps it launched (its own `list`, default target, logs and screenshots). Another
  session's PID or ref is an error, and `backstage stop` only quits your own apps. Never use
  `stop --all` unless the user asks: it quits every agent's apps.
- **Apps the user sent backstage:** the user can move one of their own running apps to the
  hidden display for you (Send Front Window Backstage, ⌃⌥⌘B). It's listed by
  `backstage list --all` under session `user` (your `list` names it under `sentByUser`). Work on
  it only when the user asks you to, always with an explicit `--pid P` (or `--app`): it's never
  your default target, and your `stop` leaves it running. It's the user's live app with their
  work in it: don't quit it unless they ask. `backstage show --pid P` gives it back to them.
  The user may keep their sent apps on a display of their own (`list` shows each app's
  `display`); leave it there, and don't put your apps on it (`--display N` onto it is refused).
- **Subagents:** Claude Code subagents share their parent's session (Codex subagents get
  their own). If you're a subagent launching your own apps, or you start subagents that do,
  give each its own session by prefixing every command:
  `BACKSTAGE_SESSION=<unique-name> backstage …`. Use the prefix on every call; `export`
  doesn't carry over to the next command.
- **Sound:** every app you launch is silent for the user. Use `launch --audio` only when you
  need to check sound. See [Checking sound](#checking-sound).
- **Output** is JSON on stdout. Errors come back as `{"ok": false, "error": …}` with exit status 1
  and say what to do next.

## Checking sound

Every app you launch is muted (macOS 14.2+): nothing it plays reaches the speakers.

- **By default, dev builds and test runners are silent everywhere**, including the user's
  screen-sharing or remote-desktop session and recordings: `launch` makes them inaudible from
  inside (`"audio": "inaudible"`). Other apps (signed, hardened, Apple) are muted on the Mac's
  speakers only (`"audio": "muted"`); someone watching the Mac remotely may hear them.
- **Use `--audio` only when you need to check sound.** `launch --audio` keeps the sound
  inspectable (`"audio": "metered"`): still muted on the speakers, but the user's
  screen-sharing or remote session can hear it. Without it, `audio`, `wait --sound` and
  `audio record` refuse the app: relaunch with `--audio` if you need them.

With `--audio`, you check sound with facts: did it play, when, how long, how loud, at what
frequency, and did it stop.

```bash
backstage launch path/to/MyApp.app --audio  # 0. opt in to measuring
T=$(backstage audio | jq .time)          # 1. the clock, before you act
backstage click --ref w8432.0.7          # 2. click Play
backstage wait --sound --since "$T"      # 3. it played (also finds a short sound already over)
backstage audio                          # 4. playing, peakDb/rmsDb (dBFS), hz, sounds
backstage click --ref w8432.0.8          # 5. click Stop
backstage wait --sound --gone            # 6. it stopped
backstage audio record --seconds 5       # deeper checks: WAV of the last 5 s → {"path": …}
```

- `audio` levels cover the last second: `playing` (above the -80 dBFS floor in the last 0.3 s),
  `peakDb`/`rmsDb` (0 is full scale, -200 is digital silence), `hz` (the strongest frequency:
  meaningful for tones, not for music or speech) and the last 16 `sounds` with start times
  and lengths.
- `wait --sound` timeouts say which case it was: no audio output running, output running but
  silent, or too quiet for `--min-db`.
- `audio record [-o out.wav] [--seconds N]` writes a float32 WAV of the last N s (default and
  max 15) of the app's output, ending where its output last ran (also after it stopped).
  Without `-o` it goes next to your screenshots. Use it for whatever tool you have: `afinfo`,
  `ffmpeg`, speech-to-text, a spectrum. Its samples are as tapped: on a device with more than
  2 channels they read `levelGainDb` below `audio`'s levels.
- If these say System Audio Recording isn't granted, tell the user what `backstage doctor` says
  to enable; muting and launching still work.
- `backstage show` unmutes the app it hands over: the user will hear it from then on (except an
  app launched inaudible, which stays silent until it's relaunched).

## Computer-use tools

Agents in the Claude and Codex desktop apps can also have computer-use tools. Two kinds:

- **Screen tools** take screenshots of the user's display and use the real mouse pointer and
  keyboard (Claude's `screenshot`, `left_click`, `type`, `key`…). They can't see or reach
  backstage's hidden display, so an app you drive this way must be on the user's screen:
  `backstage show <app>`, or `backstage show --pid P` to hand over one you launched hidden
  (state included). Never pick the monitor named "Backstage (agent display)" (`switch_display`):
  clicks there are dropped and the pointer is pulled back to the user's screens.
- **Per-app background tools** capture one app's window wherever it is and post input straight
  to that app (Claude's `app_screenshot`, `app_click`, `app_type`, `app_key`, `app_menu`…;
  Codex's `get_app_state`, `click`, `type_text`, `press_key`…). These can also work on an app
  you `backstage launch`ed, which then stays hidden: backstage lets their input into its apps.
  Name the app unambiguously: if the user runs their own copy too, a name or bundle id can pick
  theirs (Codex takes a full app path). If the tool can't find, see or click the hidden app,
  hand it over with `backstage show --pid P`. Don't use a tool's own way of bringing a hidden
  app's window to the user's screen (Claude's `app_bring_to_current_space`): backstage moves
  it straight back. `show --pid P` is the way.

- After `show`, the app is the user's: backstage no longer manages it, it isn't muted, and
  `backstage` commands (including `quit`/`stop`) no longer reach it.
- Don't drive one app with backstage's input commands (`click`, `type`, `key`…) and computer-use
  input at the same time: they share its keyboard focus and menus, and a backstage `key esc` may
  read as the user pressing Esc, which can stop a computer-use session.

## Limits to know

- Apps launch as a fresh instance (`-n`), so the user's own copy is untouched. Single-instance
  apps that hand off to an existing copy (Safari, Mail) don't suit this.
- A launched app gets no Dock tile and isn't in ⌘-Tab (`launch` returns `"dock": "hidden"`).
  An app that makes itself a regular app at startup shows up in the user's Dock anyway
  (`"dock": "visible (app made itself a regular app)"`); it still runs hidden, so carry on, but
  quit it as soon as you're done. Quit every app when done.
- On a heavily loaded Mac `launch` can take up to two minutes. If it fails because the app's
  process didn't appear, don't relaunch at once: `backstage list` shows it under
  `pendingLaunches`, and the app moves to `apps` (yours to use and quit) if it starts late.
- All instances of an app (the user's and other agents') share its preferences and app data.
  Don't rely on per-instance settings, and expect settings another instance changed.
- The clipboard is shared with the user and other agents. Put text in with `set`/`type`, not
  cmd+C/cmd+V.
- An open menu (`click --right`, a pop-up button) can be closed by the user's clicks at any
  time: if it's gone, open it again. Close menus you no longer need (`key esc`).
- Web pages: for your own checks use a headless browser or HTTP. Use `backstage show <url>`
  only if the user wants it open in front of them.
- If `backstage doctor` reports missing permissions, tell the user what to grant. The host
  terminal/agent needs Accessibility and Screen Recording, and System Audio Recording for
  `audio`/`wait --sound`.
- Alert sounds and beeps (`NSBeep`, system sounds) are played by macOS, not the app: they
  aren't muted or measured. An app you launch may ask for the Microphone the first time it
  plays to an audio device that has inputs: tell the user rather than clicking anything.
"""#
