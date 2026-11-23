---
name: backstage
description: Launch, test, screenshot and click through macOS GUI apps on an invisible display so nothing pops up on the user's screen or steals their focus. Use whenever you need to run a .app or GUI binary to verify a build, reproduce a bug, run a UI check, or look at an app for your own purposes. When the user explicitly asks to see something on their own screen, use `backstage show` instead.
---

# backstage: use GUI apps without touching the user's screen

`backstage` runs macOS apps on a hidden virtual display. You can see apps (screenshots,
accessibility tree) and drive them (clicks, typing, menus) while the user keeps working,
undisturbed. Their cursor, keyboard focus, frontmost app and windows are never touched.

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
for me", "I want to try it", "demo it", or a final hand-off they asked for.
- If you've been driving the app hidden, `backstage show --pid P` hands over that running
  instance, state included, so there's no relaunch.
- `backstage show <app|file|url>` opens anything else on their screen.
- Never run `open`, `osascript … activate`, or `Foo.app/Contents/MacOS/Foo` directly. A hook may
  block those, and they interrupt the user.

When you finish hidden work the user might want to see, say so and offer:
"Want me to open it on your screen?" Don't show it unasked.

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
backstage logs                          # the app's stdout/stderr
backstage quit                          # always clean up; `backstage stop` quits everything
```

- **Building first:** build as usual (`xcodebuild`, `swift build`, `make`…), then `backstage
  launch` the resulting `.app` or executable. Pass app arguments after `--`, and environment
  with `--env K=V`.
- **Seeing:** prefer `tree`/`find` for structure and text, and `screenshot` for visual checks.
  Re-run `tree`/`find` after the UI changes, because refs can go stale.
- **Acting:** `press`/`set`/`menu` are the most reliable. Use coordinate `click`/`drag`/`scroll`
  for custom-drawn views. `hover` is best-effort: tooltips won't appear.
- **Several apps:** commands target the most recent launch. Pass `--pid P` (from
  `launch`/`list`) to be explicit.
- **Output** is JSON on stdout. Errors come back as `{"ok": false, "error": …}` with exit status 1
  and say what to do next.

## Limits to know

- Apps launch as a fresh instance (`-n`), so the user's own copy is untouched. Single-instance
  apps that hand off to an existing copy (Safari, Mail) don't suit this.
- A launched app appears in the user's Dock and ⌘-Tab, like any running app. Quit it when done.
- Web pages: for your own checks use a headless browser or HTTP. Use `backstage show <url>`
  only if the user wants it open in front of them.
- If `backstage doctor` reports missing permissions, tell the user what to grant. The host
  terminal/agent needs Accessibility and Screen Recording.
