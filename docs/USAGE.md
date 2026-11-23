# backstage usage

Every command prints JSON on stdout, except `help`, `skill`, `logs` and plain `tree`. On
failure a command prints `{"ok": false, "error": "…"}` and exits with status 1. Error
messages say what to do next.

## Concepts

**Agent display.** A virtual monitor that only backstage's daemon can see. It's created on
first use and parked touching only the bottom-right corner of your desktop. Apps launched
through backstage live there.

**Coordinates.** All points are agent-display points, with `(0,0)` at the top-left of the
agent display. A default `screenshot` is cropped starting at `(0,0)`, so a pixel `(x,y)` in
the image is exactly the point to pass to `click x y`. If you captured with `--scale S`,
pass the same `--scale S` to `click`/`drag`/`scroll`/`hover`, or divide by S yourself.

**App selection.** Commands that act on an app take `--pid P` or `--app NAME` (a managed
app's name or bundle id). With neither, they target the most recently launched managed app.

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

### `list`
Managed apps with their windows.

### `quit [--force]`
Quits the app. If it refuses, for example because of a "Save changes?" sheet, you get
`"ok": false` with a note. Inspect it with `screenshot`/`tree`, deal with the dialog, or use
`--force`.

### `logs [--lines N]`
The last N lines (default 100) of the app's stdout and stderr.

### `status` / `doctor`
Shows the permissions (Accessibility, Screen Recording), the daemon and display, and the
managed apps. When something's missing, `problems` lists what to grant and where.

### `start` / `stop`
Start or stop the daemon. `stop` quits managed apps (forcing them after 3 s) *before*
removing the display, so nothing falls onto your screen. The daemon also exits by itself
after `BACKSTAGE_IDLE_TIMEOUT` seconds (default 1800) with no managed apps, or when no
physical display is left.

## Hidden or shown

### `show --pid P` / `show --app NAME` / `show` (most recent)
Hands a hidden app over to the user. Its windows move to the centre of the main display,
the app comes to the front, and backstage stops managing it. Its state is kept: no relaunch.

### `show <app|file|url>`
Opens anything on the user's screen, the way `open` would.

Use `show` only when the user asked to see something. Each use is logged to
`~/.backstage/shown.log`.

## See

### `screenshot [-o out.png] [--window I] [--full] [--scale S]`
- **Default:** the app's windows (including menus, sheets and popovers), cropped from the
  display origin, so image pixel = click point.
- **`--window I`:** one window only. The JSON's `origin` is that window's position:
  `point = origin + pixel / scale`.
- **`--full`:** the whole agent display.
- **Format:** a `.jpg`/`.jpeg` output path gives JPEG; anything else gives PNG. Without
  `-o`, files go to `~/.backstage/shots/`.

```json
{"path": "~/.backstage/shots/shot-1795452686123.png", "width": 460, "height": 392, "origin": {"x": 0, "y": 0}, "scale": 1, "pid": 64304}
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

### `wait --text T [--role R] [--gone] [--timeout S]`
Polls until a matching element appears (or, with `--gone`, disappears). Default timeout
10 s. Returns the element and the time it took.

## Act

Everything is delivered to the app's process directly. Your cursor, keyboard and frontmost
app are never touched.

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
| `BACKSTAGE_WIDTH` / `BACKSTAGE_HEIGHT` | 1920 / 1200 | Agent display size (set before the daemon starts) |
| `BACKSTAGE_IDLE_TIMEOUT` | 1800 | Seconds with no managed apps before the daemon exits |
| `BACKSTAGE_MENUBAR` | on | `off` hides the menu bar indicator (set before the daemon starts) |
| `BACKSTAGE_HOOK` | on | `off` disables the hook |
| `BACKSTAGE_SHOW` | — | `1` as a command prefix lets that command past the hook |
