# backstage usage

Every command prints JSON on stdout, except `help`, `skill`, `logs` and plain `tree`. On
failure a command prints `{"ok": false, "error": "…"}` and exits with status 1. Error
messages say what to do next.

## Concepts

**Agent display.** A virtual monitor that only backstage's daemon can see. It's created on
first use and parked touching only the bottom-right corner of your desktop. Apps launched
through backstage live there. By default it's the size of your main display in points, so
screenshots have its shape (a 4K monitor at the usual 2x is 1920×1080 points), and it's a
Retina display, drawn at 2x (3840×2160 pixels for that size), so apps render as they would on
a Retina screen. The size is read when the daemon starts; changing your displays later doesn't
resize a running agent display. `BACKSTAGE_WIDTH`/`BACKSTAGE_HEIGHT` set another size, and
`BACKSTAGE_SCALE=1` gives a 1x display.

**Coordinates.** All points are agent-display points, with `(0,0)` at the top-left of the
agent display. A default `screenshot` is cropped starting at `(0,0)`, so a pixel `(x,y)` in
the image is exactly the point to pass to `click x y`. If you captured with `--scale S`,
pass the same `--scale S` to `click`/`drag`/`scroll`/`hover`, or divide by S yourself.
Sizes are in points too, whatever the display's scale: a default screenshot is downsampled to
1 pixel per point, and `--scale 2` gives the display's native Retina pixels.

**Sessions.** Several agents can use backstage at once. Each command runs in a *session*,
and a session owns the apps it launches: its default target, `list`, `logs`, screenshots and
`stop` only ever see its own apps. Naming another session's app by `--pid` or element ref is an
error. Sessions keep cooperating agents out of each other's way; they aren't a security
boundary. The session is worked out per command, first match wins:

1. `BACKSTAGE_SESSION=<name>`, if set and non-empty. `legacy` is reserved.
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

**App selection.** Commands that act on an app take `--pid P` or `--app NAME` (a managed
app's name or bundle id), within your session. With neither, they target your session's most
recently launched app.

**Element refs.** `tree` and `find` label elements like `w8432.0.3`: the window ID, then
child indices. Refs survive windows being reordered, but not UI changes inside the window,
so re-run `tree`/`find` after the UI changes. Where a command takes `--window`, it accepts a
window ref (`w8432`) or a front-to-back index (`0` = frontmost).

## Lifecycle

### `launch <target> [--env K=V]… [--timeout S] [-- app args…]`
Starts the daemon if needed, then launches `target` hidden on the agent display. `target` can
be an `.app` path, a bundle id (`com.apple.calculator`), an app name (`Calculator`), or a bare
executable such as a `swift build` product. A bare executable is wrapped in a throwaway
`.app` so it can launch hidden. Every launch is a new instance (`open -n`), so an existing
copy of the app is never touched.

```json
{"pid": 80562, "name": "Calculator", "bundleID": "com.apple.calculator",
 "path": "/System/Applications/Calculator.app",
 "windows": [{"ref": "w9435", "index": 0, "title": "Calculator", "frame": {"x": 40, "y": 60, "w": 230, "h": 408}}],
 "log": "~/.backstage/logs/….log"}
```
`--timeout` (default 15 s) is how long to wait for the first window. A windowless app still
launches; you get a `warning`, and any window it opens later is still pulled onto the agent
display.

### `list [--all]`
Your session's apps with their windows. `--all` lists every session's apps; each entry has a
`session` field (`legacy` for apps from before sessions).

### `quit [--force]`
Quits the app. If it refuses, for example because of a "Save changes?" sheet, you get
`"ok": false` with a note. Inspect it with `screenshot`/`tree`, deal with the dialog, or use
`--force`.

### `logs [--lines N]`
The last N lines (default 100) of the app's stdout and stderr.

### `status` / `doctor`
Shows the permissions (Accessibility, Screen Recording), the daemon and display, the current
session (`id`, and `from`: which rule above produced it), and every session's managed apps.
When something's missing, `problems` lists what to grant and where.

While the daemon runs, `daemon` describes the agent display:

```json
{"pid": 52426, "displayID": 108, "size": {"w": 1920, "h": 1080}, "sizeSource": "main display",
 "pixels": {"w": 3840, "h": 2160}, "scale": 2, "globalOrigin": {"x": 1920, "y": 1080},
 "screencaptureDisplay": 2, "ffmpegScreen": "Capture screen 1"}
```
`size` is in points, and `sizeSource` says where it came from: `main display`, or `env` when
`BACKSTAGE_WIDTH`/`BACKSTAGE_HEIGHT` set it. `pixels` is the backing store. `screencaptureDisplay` and `ffmpegScreen`
identify the display to standard recording tools; see [Recording](#recording-the-agent-display).

### `start` / `stop` / `stop --all`
`start` starts the daemon. `stop` quits **your session's** apps (forcing them after 3 s).
Other sessions' apps and `legacy` apps are left alone. If no app is left in any session, `stop`
also stops the daemon. If other sessions still have apps, or a launch or `show` is in progress
somewhere, the daemon keeps running, and the result's `daemon` field says so (a daemon left
running stops itself once idle). A launch your session started before the `stop` is cancelled
rather than registered. If something fails, `ok` is false and `error` says what, but `quit`
still lists the apps that were quit.

`stop --all` is the admin form. It quits every app in every session, `legacy` included, and
stops the daemon. Both forms are safe to run twice.

Apps are always quit *before* the display is removed, so nothing falls onto your screen. The
daemon also exits by itself after `BACKSTAGE_IDLE_TIMEOUT` seconds (default 1800) once no
session has managed apps, or when no physical display is left.

A launch that dies before its app is registered (an agent's tool timeout, Ctrl-C) leaves a
record behind; the daemon quits the app it started, so nothing is left unowned.

After upgrading backstage, a daemon from the older version is replaced automatically if it
has no apps. If it still has apps, commands that need the daemon fail and ask you to run
`backstage stop --all` first.

## Hidden or shown

### `show --pid P` / `show --app NAME` / `show` (most recent)
Hands one of your session's hidden apps over to the user. Its windows move to the centre of
the main display, the app comes to the front, and backstage stops managing it, so it leaves
your session. Its state is kept: no relaunch.

### `show <app|file|url>`
Opens anything on the user's screen, the way `open` would. If backstage is running a hidden
instance of the app that would open it (in any session), `show` opens a new instance for the
user instead of handing the request to the hidden one.

Use `show` only when the user asked to see something. Each use is logged to
`~/.backstage/shown.log`.

## See

### `screenshot [-o out.png] [--window I] [--full] [--scale S]`
- **Default:** the app's windows (including menus, sheets and popovers), cropped from the
  display origin, so image pixel = click point.
- **`--window I`:** one window only. The JSON's `origin` is that window's position:
  `point = origin + pixel / scale`.
- **`--full`:** the whole agent display, showing every window of all of your session's apps
  and nothing else: other sessions' apps are left out (black), wherever they are. Windows of
  separate system processes, such as the out-of-process open/save panel or a share sheet, are
  left out too (as in the default capture); inspect those with `tree`/`find`.
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
Each line shows the role, title/value/description, frame (`@x,y wxh` in agent-display
points), supported actions, and disabled/focused state. `--json` gives the same as structured data.

### `find [text] [--text T] [--role R] [--window I]`
Elements whose role contains R and whose title/value/description/identifier contain T
(case-insensitive). Returns up to 200 matches, with refs and frames.

### `windows`
The app's windows, with refs, titles and frames.

### `window fill [--window I]` / `window size <w> <h> [--window I]`
Resizes one of the app's windows (default: its frontmost) through accessibility, without
raising or activating anything. `fill` makes it cover the whole agent display below the
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

## Recording the agent display

backstage doesn't record video itself, but the standard macOS `screencapture` tool can record
the hidden display, or take stills of it, without any window, prompt or focus change:

```bash
n=$(backstage status | jq .daemon.screencaptureDisplay)
screencapture -x -v -V 10 -D "$n" run.mov      # 10 s of video (H.264 .mov), no sound
screencapture -x -D "$n" still.png             # one still at native resolution
```

- `-D` counts the active displays from 1 in the system's order, which changes when displays
  are added or removed (another monitor, a restarted daemon). Read `screencaptureDisplay`
  right before recording.
- The video is the display's native pixels (twice its size in points), recorded only when
  something changes, so a still display gives few frames.
- It records the **whole agent display**: other sessions' windows, and the display's copy of
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
| `click <x> <y> [--right] [--double]` | A real mouse click at an agent-display point. Makes the target window key first. |
| `click --ref <ref> [--right] [--double]` | Clicks an element: AXPress when it supports it, otherwise a mouse click at its centre. `--raw` forces the mouse. |
| `hover <x> <y>` | Sends mouse-moved events. Best-effort: hover effects and tooltips that use tracking areas won't fire. |
| `drag <x1> <y1> <x2> <y2> [--steps N]` | Mouse down, move in N steps (default 20), mouse up. |
| `scroll <x> <y> [--dy N] [--dx N]` | Pixel scroll. Negative `dy` scrolls down (default −100). |
| `type <text> [--ref R]` | Types Unicode text into the focused element, or focuses R first. Newline and tab characters in the text become Return and Tab. |
| `key <combo>… [--ref R]` | Key presses such as `return`, `esc`, `tab`, `space`, `delete`, `up`/`down`/`left`/`right`, `home`, `end`, `pageup`, `f1`–`f12`, or letters/digits/punctuation with modifiers: `cmd+s`, `cmd+shift+z`, `ctrl+alt+t`. Takes several combos in one call. |
| `menu "File > Save As…"` | Presses a menu bar item by path. Matching is case-insensitive, ignores `…`, and accepts prefixes. |

## Agent integration

### `install [--claude] [--codex] [--grok] [--hooks]`
Writes the skill to `~/.<agent>/skills/backstage/SKILL.md`. With no agent flags, it installs
for every agent whose config directory exists.

`--hooks` also adds the PreToolUse hook to each agent's config, keeping your existing entries
and backing the file up to `*.backstage-bak` first:

| Agent | Config file | Shell tool names matched |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | `Bash` |
| Codex | `~/.codex/hooks.json` | `Bash`, `exec_command`, `shell`, `local_shell` |
| Grok | `~/.grok/config.toml` | `Bash`, `run_terminal_command`, `run_terminal_cmd` |

Running install again is safe. Restart agent sessions afterwards. Grok only runs hooks in
trusted folders; check with `/hooks-list`.

### `uninstall [--claude] [--codex] [--grok]`
Removes the skill and only backstage's own hook entries.

### `skill`
Prints the skill. `make dist` writes it to `dist/skills/backstage/SKILL.md`.

### `hook pre-tool-use`
The hook entry point. It reads the agent's hook JSON on stdin, and for a shell command that
would put something on the user's screen it exits 2 with the reason on stderr (a "deny" in
Claude Code, Codex and Grok). It blocks:
- `open …`, except `open --help`
- running `Something.app/Contents/MacOS/…` directly
- `osascript` that activates, launches or opens an app

It also looks inside `bash -c`, `sh -c` and `zsh -c`, and past `sudo`/`env`/`nohup` and
similar prefixes. Anything it can't parse, and any tool that isn't a shell, is allowed.

Two environment variables change it:
- `BACKSTAGE_SHOW=1 <command>` lets one deliberate, user-requested command through.
- `BACKSTAGE_HOOK=off` disables the hook entirely.

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `BACKSTAGE_HOME` | `~/.backstage` | State, logs, screenshots |
| `BACKSTAGE_SESSION` | derived | The session this command belongs to (see Sessions); `legacy` is reserved |
| `BACKSTAGE_WIDTH` / `BACKSTAGE_HEIGHT` | main display's size | Agent display size in points (set before the daemon starts) |
| `BACKSTAGE_SCALE` | 2 | Agent display backing scale: `2` is Retina, `1` gives a 1x display (set before the daemon starts) |
| `BACKSTAGE_IDLE_TIMEOUT` | 1800 | Seconds with no managed apps before the daemon exits |
| `BACKSTAGE_MENUBAR` | on | `off` hides the menu bar indicator (set before the daemon starts) |
| `BACKSTAGE_HOOK` | on | `off` disables the hook |
| `BACKSTAGE_SHOW` | — | `1` as a command prefix lets that command past the hook |
