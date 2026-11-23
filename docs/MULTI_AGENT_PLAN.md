# Multi-agent support for Backstage

Support up to 32 concurrent agent sessions on one Mac. Work out how many can actively drive apps
and capture screenshots at once by measuring under load. Build only what the measurements show
is needed.

## Starting point

A two-client test on macOS 27.0.1 found:

- **Distinct PIDs work.** Typing into two different PIDs at the same time reached the intended
  text fields.
- **The default target is shared.** Both clients picked the most recent launch when they didn't
  pass a PID.
- **Typing into one PID interleaved characters.**
- **Either client could stop both apps.**

A temporary build with distinct display serials and positions ran two displays, and stopped one
while the other app stayed available. That experiment isn't in the repo. Commit it, or write
down how it was run, before relying on it.

The current design is already largely per-app:

- Screenshots filter to the target app's windows.
- Clicks hit-test only the target PID's windows and are posted to that PID.
- Keystrokes go to the app's own key window, not a global focus.

So one shared agent display is expected to serve many sessions. Phase 2 checks that before
anything more is built.

## Session identity

Agents can't be relied on to keep a variable set. Claude Code, Codex and Grok run each shell
tool call in a fresh shell, so `export BACKSTAGE_SESSION=…` doesn't survive to the next command.
Hook rewriting isn't a portable way to inject it either: Codex rejects `updatedInput` in
PreToolUse hooks.

- **Derive the session automatically.** Walk up the parent processes from the CLI to the
  nearest long-lived process that isn't a shell (the agent's own process). Use its PID and
  process start time as the session ID. That makes it stable for the whole agent session and
  unique even when PIDs are reused.
- **Override:** `BACKSTAGE_SESSION=<name>` wins when set, for scripts and test harnesses.
- **No shared fallback.** If no session can be worked out, use a private session scoped to the
  calling process, never a global default that other agents would share.
- **Existing records:** app records written before sessions existed belong to a `legacy`
  session that only `--all` commands touch.

A session owns its managed app instances, default target, logs and screenshot paths. Ownership
routes commands among cooperating agents in one login; it isn't a security boundary.

**What the agents expose (checked 2026-11-23).**

- **Claude Code 2.1.330.** Every Bash tool shell gets `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`
  and `CLAUDE_CODE_CHILD_SESSION=1`. These aren't in the `claude` process's own environment;
  Claude Code adds them per shell. The session ID is the top-level session. Two sibling
  subagents and their parent all saw the same `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID`; only
  `CLAUDE_EFFORT` differed. There's no per-subagent variable, so neither the variables nor
  the parent walk can tell concurrent subagents apart.
- **Codex 0.171.0.** Checked live: each Codex subagent's shells get their own
  `CODEX_THREAD_ID`, while `CODEX_SESSION_ID` is shared by a session's subagents, so the thread
  ID is the one to use and Codex subagents get separate sessions. Codex also has a daemon mode; herdr's wrapper passes `--no-daemon`. In daemon
  mode, shells may hang off a shared `codex`/`codex-exec-server` process, where only the
  thread ID tells sessions apart.
- **Grok 1.0.92.** The binary has `GROK_SESSION_ID`, but next to the hook variables
  (`GROK_HOOK_EVENT`). It isn't verified to reach tool shells.
- **herdr.** `HERDR_PANE_ID` and similar identify a terminal pane, not an agent, so they aren't
  used.

**Derivation as built (phase 1, revised after review).** First match wins:

1. `BACKSTAGE_SESSION`. `legacy` is reserved.
2. The nearest known agent ancestor's own variable: `CLAUDE_CODE_SESSION_ID` (only if
   `CLAUDE_PID` is that ancestor), `CODEX_THREAD_ID`, or `GROK_SESSION_ID`. Variables are
   inherited, so they're only trusted for the *nearest* agent, and only if that agent's own
   environment doesn't already hold the same value (read with `KERN_PROCARGS2`): an inherited
   value came from an outer agent. A Codex started from a Claude shell doesn't join Claude's
   session, and neither does a codex → claude → codex whose inner Codex sets no thread ID.
   `node`/`python`/`bun`/`deno` ancestors whose first arguments name a known agent (npm- or
   pip-installed claude, gemini, cursor-agent, amp, aider) count as that agent, and the scan
   stops at the nearest agent.
3. That agent process: name, PID and start time.
4. No agent, with a controlling terminal: the terminal session (`getsid`, plus the leader's
   start time), so each tab or tmux pane is a session. Not used without a terminal: agent tool
   shells are session leaders of their own (Claude's are, checked), so an agent missing from
   the known list would get a session per command.
5. The nearest non-shell, non-wrapper ancestor: PID and start time.
6. The outermost shell ancestor. That keeps one script's commands together without falling
   back to a shared default.

A caller whose parent has exited (reparented to launchd: `&` from a finished shell, nohup,
cron, launchd jobs) has no chain. launchd is never a key, since every such caller would share
it: a single agent variable is used as is, and anything else is an error asking for
`BACKSTAGE_SESSION`. Known limits: `env -i`/`sudo` drop the variables, so the same Claude
session becomes `claude:<pid>-<start>` there; Grok's variable is unverified.

The variable comes before the PID because hosts can serve several sessions from one process
(Codex daemon mode, and possibly IDE or desktop hosts). The cost: if an agent starts a new
session ID in the same process (for example Claude's `/clear`), its earlier apps stay with the
old session. Only `stop --all` or the menu bar reach them then.

**Subagents.** Claude Code subagents share a session. The skill tells them to prefix each
command with `BACKSTAGE_SESSION=<unique-name>` when they launch their own apps.

## Architecture: stay CLI-side, serialize with file locks

Commands keep running in the short-lived CLI process, as today. The daemon keeps its current
jobs only: the display, window guarding, and cursor guarding. Coordination uses `flock` in
`BACKSTAGE_HOME`:

| Lock | Held for | Fixes |
|---|---|---|
| per app (`locks/app-<pid>-<birth>`) | a whole input command: focus plus every event in a click, drag or key/type sequence | interleaved typing into one app |
| per session (`locks/session-<id>`) | launch registration, quit, stop | double stop; stop racing a launch |
| global state lock (exists) | reading or writing the app list | none new |

**As built (phase 1).** The old global `session.lock` serialized every launch, stop and show
across all agents. It's now `lifecycle.lock`, so the name no longer clashes with sessions, and
it changed shape:

| Lock | Mode, holder | Guards |
|---|---|---|
| `client.lock` (exists) | exclusive: daemon start, and `stop`/`stop --all` while they wait for the daemon to exit | one daemon starter; no launch while the daemon is going away |
| `lifecycle.lock` (was `session.lock`) | **shared** by each launch from daemon start until its app is registered, and by `show`; **exclusive** for daemon shutdown (non-blocking, retried each tick), for `stop --all`, and (non-blocking: if busy, the daemon is left to its idle timer) for `stop`'s "anything left?" check | the daemon never quits or vanishes around an app it can't see yet. Launches in different sessions run concurrently. |
| `locks/session-<key>` | exclusive: launch registration, `quit`, `stop`, `show` | double stop. `stop` writes a timestamp in the file, and a launch that started earlier quits its app instead of registering it. |
| `locks/app-<pid>-<birth>` | exclusive: every input command (press, set, focus, action, click, hover, drag, scroll, type, key, menu) | interleaved input into one app |
| `lock` (exists) | apps.json read-modify-write | — |

Acquisition order: client → lifecycle → session → app → state. A launch still holds
`lifecycle.lock` (shared) while LaunchServices identifies the new process: an unregistered app
must not outlive the display. That wait (up to ~15 s) blocks daemon shutdown and `stop --all`.
It used to block other sessions too: a `stop` waited for `lifecycle.lock` exclusively while
holding `client.lock`, so every other session's launch queued behind it. `stop` now only
tries the lock and, if a launch is in flight, leaves the daemon to its idle timer.
Waiting for the first window happens after registration, with no lock held.

- **Waits run unlocked.** Long waits (LaunchServices, the first window, `wait --text`) happen
  outside any lock, and the result is revalidated before it's published.
- **No new cross-session scheduler.** Contention between sessions is left to macOS, with no
  fair-share scheduling in Backstage. Revisit only if measurements show one session starving
  others.

## 1. Ownership and independent teardown

- **Failing test first.** Write a two-agent end-to-end test that fails today. Give each agent its
  own session (via `BACKSTAGE_SESSION` in the harness) and launch two instances of the same
  fixture with distinct text and visual markers.
- **Store ownership with each app.** Record the owning session next to each app's PID and
  process start time. Apply one ownership check to every target selector and command: explicit
  `--pid`, `--app`, element refs, `logs`, `quit`, and `show`. The "most recent app" default is
  per session.
- **`show` ends ownership.** It removes the app from its session as it hands the app to the user.
- **Scope `stop` to the session.** `stop` quits only the calling session's apps. `stop --all`
  is the admin form: it quits everything and stops the daemon. Calling either twice is safe.
- **Daemon lifetime.** The daemon exits after the idle timeout once *no sessions* have live
  apps.
- **No `--full` on a shared display.** Reject `screenshot --full` whenever other sessions have
  windows on that display. (Superseded: `--full` now captures only the session's own windows;
  see the review fixes below.)
- **Update the docs.** Explain sessions and the new `stop` scope in the skill, README and
  `docs/USAGE.md`.

**Gate.**
- Both agents run ordinary commands without PIDs, and each gets its own text, app list, logs
  and screenshots.
- Targeting another session's app by explicit PID or ref fails.
- Stopping A while B is typing leaves B's app and input intact.
- The existing single-agent suite passes unchanged with no session configured.

**Status: done (2026-11-23).** `tests/multi.sh` (`make test-multi`, part of `make test`) covers
every gate item, with the non-interference watchdog running throughout. It failed on the
pre-session code (shared default target, interleaved typing, A's `stop` quitting B's app) and
passes now, along with `make test-cli`, `make test-agents` and `tests/e2e.sh`, unchanged and
with no session configured. Where the build departs from the text above:

- **Legacy apps are reachable by explicit `--pid`.** They're never a default target, and
  never in a session's `list` or plain `stop`. But nobody owns them, so an explicit PID still
  reaches them, as `tests/cli.sh` expects. `list --all` and `stop --all` cover them.
- **Plain `stop` also stops the daemon when no session has apps left.** That keeps
  single-agent behaviour and keeps test runs from leaking a virtual display for the idle
  timeout. It checks under exclusive `lifecycle.lock` with `client.lock` held, so it can't
  race another session's launch.
- **`show` locks the owning session**, as well as taking `lifecycle.lock` shared.
- **Found while testing: per-app screenshots included other instances of the same app.**
  ScreenCaptureKit's application filter matched every instance of the bundle, so session A's
  screenshot showed B's copy of the fixture. Captures now include only the target PID's
  windows.
- **The menu bar counts sessions**, not agent processes.

**Review fixes (after phase 1).**
- **`screenshot --full` captures the session's own windows.** The old check ("refuse while
  another session has windows") was racy and missed processes nobody registered (the open/save
  panel service, share sheets). `--full` now captures every window of the caller's apps, from
  the same ScreenCaptureKit snapshot, over the whole display: the per-app capture generalized
  to the session's PIDs.
- **Protocol version in `daemon.json`.** An older daemon doesn't know sessions, drops them when
  it rewrites `apps.json`, and its shutdown waits on the old `session.lock`, which new CLIs never
  take. A launch that finds a daemon from another protocol replaces it if it has no apps, and
  otherwise refuses, asking for `backstage stop --all`. Commands needing the daemon refuse it too.
  The new daemon also tries the old `session.lock` before shutting down, for old CLIs.
- **A shutdown request is published.** When a SIGTERM (or losing every display) has to wait for
  a launch to finish, the daemon marks itself `stopping` in `daemon.json` right away. New
  launches wait for it to exit and start a fresh daemon, rather than registering an app the
  pending shutdown would quit.
- **Provisional launch records.** `launch` writes `launching/<id>.json` (session, CLI PID and
  start, bundle/executable, log) before `open` and removes it once the app is registered. If
  the CLI dies in between, the daemon finds the app it started (launch token or log, as
  `launch` does), quits it, and drops the record; it isn't idle while records exist.
- **`show <target>` stays off hidden instances.** Bare executables get their own "shown"
  wrapper, and if backstage manages a hidden instance of the app that would open the target,
  `show` opens a new instance (`open -n`).
- **Lock files are pruned** when provably unused: app locks of dead processes on `stop`/`quit`,
  and session locks of sessions with no apps or launches whose file is a day old, unlinked
  under a non-blocking lock. `StateLock` re-checks after locking that its file wasn't
  unlinked. Screenshot folders are left alone: they hold files agents may still read.

## 2. Same app, many instances

The bigger risk at 32 agents is instances of one app clashing with each other, not the
display. Instances share Preferences, Application Support, caches and any single-instance
locks.

- **`launch --isolated-home`.** Set `CFFIXED_USER_HOME` to a per-session directory so a Cocoa
  app's home directory, preferences and support files are redirected. First verify that
  CoreFoundation and AppKit honour it on macOS 27, for both the fixture and one real app. Drop
  the flag if they don't, and document the limitation instead.
- **Clipboard.** It's system-wide and can't be isolated. The skill should tell agents to use
  `set`/`type` instead of cmd+C/cmd+V.

**Gate.** Two isolated instances of the fixture write different values to the same
preference key, and each reads back its own value.

**Status: done: not built (2026-11-23).** The gate fails on macOS 27.0.1, so there's no
`--isolated-home` flag. The limitation is documented in the README's Limits and the skill
instead: instances of one app share preferences and app data, so agents shouldn't rely on
per-instance settings, and should use `set`/`type` rather than the clipboard. What a spike
found:

- **`CFFIXED_USER_HOME` reaches the app and redirects Foundation paths.** It arrives through
  `open -g -j -n --env`. `NSHomeDirectory()` and the Application Support, Caches, Library and
  Documents URLs all resolve under the fake home, and a file written to Application Support
  landed there.
- **It doesn't redirect preferences.** `UserDefaults.standard`, `UserDefaults(suiteName:)` and
  `CFPreferencesSetAppValue` all wrote to the real `~/Library/Preferences` through cfprefsd.
  Two concurrent instances with different fake homes read each other's values: A wrote
  `AAA`, B read `AAA` before writing `BBB`, and A then read `BBB`. If the fake home doesn't
  exist, preference writes are silently lost. None of these changed it: setting `HOME` too,
  fake homes under `/private/tmp`, creating `Library/Preferences` first, or
  `__CFPREFERENCES_AVOID_DAEMON=1`.
- **Also not redirected:** `NSTemporaryDirectory()`/`TMPDIR`, and `getpwuid()`'s `pw_dir` or
  `$HOME` for code that doesn't use Foundation. Sandboxed apps (containers) weren't tested.
- **Lesson for later gates.** A read-back in the same process can pass falsely, because it
  reads its own cached value. Check from a fresh process and look at the files on disk.

Ideas only, not planned: run each instance as a separate macOS user, or launch a re-signed copy
of the app with its own bundle ID so its preferences domain differs.

## 3. Check the shared display under concurrency

- **Place windows to cut overlap.** Overlap is expected to be harmless for capture and input,
  but placement should still keep it down. Size the agent display from the configured session
  count (it's already set by `BACKSTAGE_WIDTH`/`HEIGHT`), and fall back to cascading when it's
  full.
- **Write the failure checks.** Look for foreign or missing pixels in per-app screenshots
  covering overlapping windows, occluded windows, menus, sheets and popovers. Check input
  reaches the right app while other apps' windows sit on top.

**Gate.**
- A deliberately slow launch plus a burst of captures in session A doesn't stop B from typing
  and quitting.
- The pixel and input checks pass.

If any check fails, record the failing workload. That failure is the trigger for the optional
phase below.

**Status: done (2026-11-23).** `tests/concurrency.sh` (`make test-concurrency`, part of
`make test`) covers both gate items, with the watchdog running throughout. Sessions A and B
run fixture instances with red and green pads on a 1000×900 agent display.

**Placement.** New windows go to the first free spot: rows top to bottom, left to right, with
20 pt gaps, and candidate edges taken from the windows already there. The fallback is the old
cascade when nothing fits.
- A window counts as occupying the display only if at least half of it is on the display.
- A launch also avoids the frames of its own windows placed just before, which are still
  hidden.
- The display's size stays `BACKSTAGE_WIDTH`/`HEIGHT`; it isn't derived from a session count.
- Accepted: two launches placing at the same moment can pick the same spot, since each
  other's windows are still hidden. Overlap turned out harmless.

**What the test checks.**
- **Placement:** two windows side by side, the third wraps to a second row, none overlap,
  all on the display.
- **Pixels:** each session's screenshot has all of its own pad pixels (within 2 % of an
  un-overlapped baseline) and none of the other app's:
  - B exactly on top of A, then A on top of B (a fixture menu item moves the window and
    orders it front);
  - partly overlapping;
  - the covered app's context menu, sheet and popover. Each is a pad-colored swatch behind
    `TESTAPP_OVERLAYS=1`, and its pixels must show up in its own app's screenshot only. The
    app on top is placed so its window, and so its screenshot, covers where they open.
- **Input:** a coordinate click and typing reach the covered app, in both directions, while the
  other app's window is in front (z-order checked from the window list), and the app on top
  gets nothing.
- **Gate:** A2 blocks its main thread for 8 s in `applicationDidFinishLaunching`
  (`TESTAPP_SLOW_LAUNCH`), while two loops in A capture A1 back to back. Meanwhile B types
  40 characters, takes a screenshot and quits. All of B's commands must finish while A's launch
  and burst are still running. The daemon must log no `slow tick` (a guard-loop pass over
  0.5 s).

**Measured** (this Mac, during `make test`; ms):

| | p50 | p95 / max |
|---|---|---|
| B `type`, 40 characters, idle (n=3) | 2062 | 2359 |
| B `type`, 40 characters, under A's slow launch and burst | 2267 | – |
| B `quit` under load | 142 | – |
| B `screenshot`, idle (n=3) / under load (n=1) | 145 / 318 | 148 / – |
| A's burst captures (n=62) | 156 | 198 / 328 |
| A's slow launch, wall clock (8 s blocked) | 8972 | – |

Typing costs about 50 ms a character whether or not A is busy. Gate limits: B's typing under
load may take at most 1.5× its slowest idle run plus 500 ms, and `quit` under 5 s.

**Found and fixed.**
- **Concurrent ScreenCaptureKit captures hang** (macOS 27.0.1, not specific to backstage).
  - When two processes of the same program capture at once (`SCShareableContent` or
    `captureImage`), every one of them hangs. Seen in 5 of 5 pairs and triples of a standalone
    probe, and in 5 of 5 pairs of unserialized `backstage screenshot`s.
  - A different program capturing alongside didn't collide: 0 of 10 probe/backstage pairs, and
    a backstage capture next to two hung probes completed. So the collision looks like it
    needs two clients of the same program. That's inferred from these runs, not confirmed.
  - The stuck calls stay stuck until their process exits; a lone capture afterwards works.
    With an `flock` held to process exit, 9 of 9 captures completed in 76–106 ms.
  - The first gate run hung all of A's burst, and B's screenshot, for over three minutes.
- **The capture fix, in `Capture.swift`.**
  - Captures take `capture.lock` and keep it until the process exits. The first version
    released the lock right after the ScreenCaptureKit calls and had a 20 s timeout. On that
    build, 2 of 4 test runs still hung while serialized:
    - two of A's burst captures (20 s and 40 s) just as A2's slow launch finished, with no
      menu open;
    - the wedge below.
  - On the lock-to-exit build, no serialized capture hung: 4 `tests/concurrency.sh` runs
    (3 inside `make test`; one failed on a test bug, since fixed) and 2 load runs. That a capture collides
    with the previous process's teardown is a guess, not shown.
  - A capture with no answer within 4 s gives up the lock and re-runs the command once, in a
    fresh process image (`exec`), which ends the stuck call. Forced with two unserialized
    captures:
    - when the other gave up at 3 s, the retry succeeded after 4.2 s (3 of 3);
    - when both stayed, one failed after two attempts (8.1 s) and the other succeeded.
  - A spurious "user declined TCCs" (-3801) is retried once. That path hasn't been seen in a
    run since.
  - The menu bar's thumbnails only try the lock, and skip a refresh if it's taken. Untested:
    it needs the menu opened by hand.
  - `tests/load.sh 2 capture,mixed --duration 20` afterwards: 257 screenshots, 0 failed.
    Capture p50/p95 was 209/387 ms and mixed 171/258 ms; `capture.lock` wait was p50 121 ms,
    p95 295 ms.
- **The daemon's guard loop stalled while an app's main thread was blocked.**
  - It retried observer registration every 250 ms, and each attempt waited out the 3 s AX
    timeout: 3 s ticks, three times, during the slow launch. Window and cursor guarding were
    off for most of that time.
  - Registration now uses a 0.1 s timeout and retries at most once a second.
  - The daemon logs any tick over 0.5 s, and the test asserts there are none.
- **Accessory (`LSUIElement`-style) apps were never on screen after launch.**
  - Launched hidden, they keep their windows ordered out after being unhidden, until they
    think they're active. So every `screenshot` failed (phase 4's `TESTAPP_ACCESSORY` finding).
    AXRaise or AXMain alone didn't bring them in.
  - `launch` now sends the same private "you're active" event the first input sends, then
    raises the windows, which were already checked to be on the agent display.
  - Verified with a scratch script: the accessory fixture is on screen and capturable right
    after launch (3.1 s launch), and the watchdog passed. No test in the repo covers it.

- **The user's keystrokes reached agent apps through their open menus.** Found here, older
  than phase 3 (`tests/e2e.sh` opens a context menu too).
  - Symptom: in a 41-right-click run, 8 characters no script sent landed in the fixture's
    text field, each just after one of its context menus closed.
  - Cause: an app tracking a menu takes the WindowServer's keyboard focus
    (`CPSStealKeyFocusReturningID` in AppKit and HIToolbox), even in the background, so
    keyboard navigation works in an inactive app's context menu. It holds the focus until the
    menu closes. The frontmost app doesn't change, so the old watchdog saw nothing. Keys
    queued in the app during the menu reached its text field once the menu loop returned.
  - Shown with a scratch probe that polled `SLPSGetKeyFocusProcess`, the system-wide AX
    focused app and the menu windows, and ran a listen-only event tap that logged each key or
    click's target process (never key codes). Results:
    - The key focus moved to the fixture 10-15 ms before its menu window appeared and came
      back to the user's app within 20 ms of the menu closing.
    - It moved with and without the private activation event (`primeActivation`), for a
      mouse right-click and for a menu bar menu opened by AXPress. So it isn't priming,
      `focusWindowOf` or the way the menu opens.
    - 40 of the user's real key events (19 downs and 21 ups) had the fixture as their
      target, in 4 menus. They came from the HID system, here sent by a remote-desktop
      client. None reached the user's app.
    - The menus closed by `key esc` gave focus back at once. The AXCancel and click-elsewhere
      arms weren't compared: the user's own clicks or keys closed those menus first.
  - Nothing outside the app can stop it taking the focus, so the fix filters input instead
    (`Sources/backstage/InputGuard.swift`):
    - Every event backstage posts is tagged in `kCGEventSourceUserData`. Its own events
      pass through session event taps too (`CGEventPostToPid` included), so the tag is what
      tells them apart.
    - The daemon runs an active tap at the annotated-session location (after the
      WindowServer picks the target process), on its own thread, never the daemon's main
      loop, whose AX calls can take seconds.
    - Untagged input headed for a managed app is someone else's. HID-sourced keys are
      reposted to the user's frontmost app, tagged as redirected. Other keys, clicks and
      scrolls are dropped.
    - A timeout-disabled tap is re-enabled and counted. Without the tap, input commands
      refuse and `status` reports a problem.
  - Measured: 1-6 µs per event on average.
    - The slowest callback was 219 µs in `make test` (`tests/focus.sh`), plus one 10 ms
      outlier on the first redirect of a scratch run. None took over 1 ms in any test run.
    - The tap was never disabled by timeout, so the re-enable path is untested.
  - Redirects:
    - In a 4-menu scratch run with the user typing, all 41 of their key events aimed at the
      fixture were reposted to their terminal, tagged as redirected.
    - During `make test`'s `focus.sh`, another 51 were.
    - Delivery is shown by the watchdog tap seeing each tagged copy aimed at the user's app,
      not by checking the text that arrived.
    - The e2e, multi and concurrency daemons dropped and redirected nothing.
  - Tests:
    - `tests/watch.swift` now has a listen-only tap appended after the daemon's. It fails on
      any untagged key, click or scroll reaching the test app, or tagged input reaching the
      user's frontmost app. It also polls the key-focus process and reports how long the test
      app held it (more than 15 s fails as a menu left open).
    - Against the pre-fix build, one untagged key landed in the fixture's field and the
      watchdog flagged it.
    - `tests/focus.sh` (in `make test`) runs 6 right-click cycles. Each posts untagged keys
      to the fixture during and after the menu. It checks the field stays empty, the guard
      dropped them all, backstage's own typing still lands, and the fixture really held the
      focus.
    - `backstage __guard-selftest` (in `tests/cli.sh`) runs the classifier on constructed
      events.
    - `tests/concurrency.sh` now fails, rather than warns, if A's text changes around its menu.
  - Left over (README, Limits):
    - A user click closed an agent's open menu, twice in the bisect. Their click still
      reached their own app.
    - Untagged keys that aren't from the HID system are dropped, not handed over. One such
      pair, from an unknown process, was aimed at the fixture in the bisect.
    - Clicks and scrolls aimed at a managed app are dropped, not redirected: no window of
      the user's would match them.
    - The guard's managed set and the user's frontmost app come from the daemon's main loop,
      so they lag a little: one tick, longer if the tick is slow.
    - Unverified: keys under Secure Input may skip event taps altogether.
  - A lone `leftMouseUp` reached B in an earlier concurrency run, right after its
    `set`+`focus` and before any click was sent. It was probably the end of a click the
    user started on their own screen. Unverified: no user click reached a fixture in these
    probe runs. The guard drops such events now, and the watchdog would flag one that got
    through.

**Found, not fixed.** None of these comes from sharing the display, so none triggers
exclusive displays.
- **A ScreenCaptureKit wedge.** Seen once, on the release-after-calls build.
  - A capture taken while a context menu was open hung, and so did every capture after it:
    sequential ones, of either app, after the menu closed and after the stuck processes had
    exited. It lasted about 5 minutes, until the test's apps quit and its display went away.
  - Not seen since. A retry can't help a wedge that persists, so watch for it in phase 4.
  - Exclusive displays wouldn't help either: replayd is system-wide.
- **Background context menus sometimes don't appear.** The menu's tracking loop runs (esc
  closes it), but no menu window is ever shown. This happened in 1 of 20 right-clicks with
  one app, 2 of 31 with two apps apart, and 4 of 30 overlapped, so it isn't about overlap.
  The test closes the menu and right-clicks once more.
- **Placement fell back to cascading once.** In one of the runs above, the third window
  landed at a cascade slot, not the free second row, so `freeSpot` found no room. No managed
  window explains it. Windows now count only if at least half of each is on the agent display,
  in case it was another app's window hanging over the display's edge, but that's a guess.
  The test now lists the windows on the display when placement fails.
- **Sheets on macOS 27** are shown as a panel over the window, which is dimmed. Captures show
  exactly that.

## 4. Measure capacity

Run on a **separate macOS user account or a dedicated Mac**, never the desktop someone is
working on. Thirty-two app instances plus capture bursts will be felt there.

- **Runs:** the same versioned fixture at 2, 8, 16 and 32 sessions.
- **Record:** machine model, RAM, macOS version, display geometry, app workload, capture
  resolution and sample counts.
- **Measure separately:** idle sessions, concurrent input, a cold-launch burst, and sustained
  captures. Also include a mixed run where a few agents capture continuously while the rest
  interact.

| Measure | Decision it informs |
|---|---|
| Wrong-target input, foreign screenshot pixels, cross-session termination | Release gate: zero observed failures at every supported level |
| p50/p95 latency for input, `SCShareableContent` and capture; lock wait time | Concurrency limits. Capture is Backstage's most likely bottleneck, so measure it on its own |
| CPU and memory for the daemon, WindowServer and apps; memory pressure | Separating Backstage's overhead from the apps' own cost, which will likely dominate |
| Live processes, locks and memory after repeated launch/stop cycles | That teardown returns everything and nothing builds up over time |

Agree on latency targets before the load run. Publish the highest tested concurrency that
meets them, along with the idle-session result. If one host falls short of 32 active agents,
use the numbers to size more hosts.

**Status: harness ready, full runs pending a separate machine (2026-11-23).** The harness is
`tests/load.sh` (`make load`, not part of `make test`), with `tests/load.py` (orchestrator and
one client process per session) and `tests/probe.swift` (`SCShareableContent` timing and
display geometry). [LOAD_TESTING.md](LOAD_TESTING.md) covers what it runs, what it records and
checks, and how to run the 2/8/16/32 matrix on a separate account or Mac. It's only been run
here as a 2-session smoke, because this Mac is a working desktop. The harness refuses more than
4 sessions without `--dedicated`.

- **Latency targets** still need agreeing before the full run.
- **Lock wait and `SCShareableContent`** are measured from outside the CLI by probes. To split
  one command's latency (lock waits, `SCShareableContent`, capture, encode, AX walk) the CLI
  needs opt-in timing output, for example `BACKSTAGE_TIMING=1` adding a `timing` object to the
  JSON.
- **`TESTAPP_ACCESSORY=1`** (`.accessory` fixture, no Dock icon) exists for runs where 32 Dock
  icons matter. In the smoke run, every `screenshot` of an accessory fixture failed with "no
  visible windows on the agent display". The cause isn't investigated yet, and it may affect
  real accessory or `LSUIElement` apps too. The harness allows the option only for idle,
  input, launch and cycles.
- **Found by the smoke run: concurrent `SCShareableContent` calls can hang.** When two
  processes call it within about 2–5 ms of each other, one never gets a reply.
  - It reproduces without backstage, in a standalone program, on macOS 27.0.1.
  - Through backstage, two simultaneous `screenshot`s both hung in 6 of 6 trials. With 2
    sessions capturing continuously, 2 of 48 shots failed: one hung for the full 20 s, and one
    got a spurious "user declined TCCs" (-3801).
  - The capture path has no timeout, so the agent waits until its own tool times out.
  - The fix is in progress with phase 3, uncommitted when this was written: `capture.lock`
    around the ScreenCaptureKit calls, plus a 20 s timeout.
  - Rerun the capture and mixed workloads once it lands. The harness reports `capture.lock`
    wait, and its probe takes the same lock.
  - A 2-session check on a build with the lock had no hangs; `capture.lock` wait was p50
    115 ms. But 2 of 52 shots still got a spurious -3801 while serialized, so a retry on -3801
    is likely needed too.
  - Details are in LOAD_TESTING.md.

Smoke example: **not representative.** This is `make load` on the final harness and the
current build, which has phase 3's `capture.lock` and 20 s timeout (git `abcce6f` plus
uncommitted work). It ran 2 sessions plus the anchor app on a working M4 Max desktop (Mac16,9,
48 GB, macOS 27.0.1) with other agents and apps running: 6 s per steady workload, 2 launch
rounds and 3 cycles, PNG at scale 1 (900×392), `.regular` fixtures, and the menu bar off.
Latencies are client wall-clock p50/p95 ms for commands started inside the measured window.

| Workload | ops/s | Latency p50 / p95 ms | `SCShareableContent` p50 / p95 | `capture.lock` wait p50 / p95 |
|---|---|---|---|---|
| idle | – | – | 16 / 43 | 0 / 53 |
| input | 5.2 | type 717 / 967, set 253 / 348, press 344 / 355, click 526 / 568, read 38 / 49 | 14 / 31 | 0 / 9 |
| capture | 1.2 | screenshot 215 / 20277 (n=7): one capture timed out, and the other session waited behind it | 18 / 104 (n=3) | 69 / 193 (n=4) |
| mixed (1 capture, 1 input) | 5.8 | screenshot 241 / 456 (n=21), type 877 / 1040 | 22 / 111 | 95 / 289 |
| launch burst | 0.3 launches/s | launch 1291 / 1407, stop 188 / 228 | 18 / 105 | 0 / 10 |
| leak cycles | 0.6 launches/s | launch 1071 / 1315, stop 148 / 177 | 17 / 54 | 0 / 10 |

- **Other numbers:** daemon start 1.5 s; daemon about 0.4 % CPU and 15 MB RSS; about 90 MB
  RSS per fixture; registry and lifecycle lock waits p95 under 0.4 ms; memory pressure normal.
- **Leak cycles:** nothing left over: 1 fixture and 1 registration (the anchor), 3 lock files,
  daemon 14.9 MB, 11 fds and 4 threads, all flat from round to round.
- **Release gate:** no wrong-target input, no foreign pixels, no cross-session termination,
  and the watchdog passed.
- **The run failed, as did every smoke run.** The failures were capture hangs or -3801 errors;
  this run's was the timed-out capture.
- **The capture lock doesn't stop hangs.** Every ScreenCaptureKit call was serialized under
  `capture.lock` here, the probe's included, and one capture still got no reply for 20 s.
  Because captures are serialized, one stuck capture now holds up every session's
  screenshots for the full timeout. At 32 sessions that's the key capacity risk.
  - Normal captures take 15–300 ms, so a much shorter timeout (2–5 s) with a retry would
    bound the stall.
  - Find out what triggers the hang. A candidate is a call made right after another
    process's ScreenCaptureKit connection closes.

## Optional: exclusive displays (only if measurements require them)

Build this only if phase 3 or 4 shows a real workload that fails on the shared display, or if
full-desktop capture becomes a stated requirement. Each virtual display costs WindowServer
memory, macOS may cap how many can exist, and every extra display complicates where displays
sit and where the cursor can wander.

If it's needed:

- **Requests and limits.** An exclusive display is requested at launch. A configurable limit
  applies, with excess requests queued with a timeout.
- **Identity and position.** Each display gets a unique serial and a non-overlapping position
  chained off the existing agent display, so the cursor guard still covers all of them. The
  real bounds are verified before any window is placed.
- **Release.** A display is released only after its apps have quit or been handed over.
- **Recovery.** Reservations are reconciled after a client crash, a daemon restart, or monitors
  being rearranged.

## Delivery order

1. Session identity, ownership, and the two-agent regression test. **Done.**
2. `--isolated-home`, if the verification passes. **Done: not built** (the gate failed).
3. Shared-display concurrency checks. **Done**; no workload needed an exclusive display.
4. Load runs and published capacity numbers. **Harness ready**; full runs pending a separate
   machine.
5. Exclusive displays, only if steps 3 or 4 require them.

Not planned: several agents deliberately working on one app together. That would need an
explicit, expiring handoff and is out of scope until someone needs it.
