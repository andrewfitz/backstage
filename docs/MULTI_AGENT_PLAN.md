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

## Architecture: stay CLI-side, serialize with file locks

Commands keep running in the short-lived CLI process, as today. The daemon keeps its current
jobs only: the display, window guarding, and cursor guarding. Coordination uses `flock` in
`BACKSTAGE_HOME`:

| Lock | Held for | Fixes |
|---|---|---|
| per app (`locks/app-<pid>-<birth>`) | a whole input command: focus plus every event in a click, drag or key/type sequence | interleaved typing into one app |
| per session (`locks/session-<id>`) | launch registration, quit, stop | double stop; stop racing a launch |
| global state lock (exists) | reading or writing the app list | none new |

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
  windows on that display.
- **Update the docs.** Explain sessions and the new `stop` scope in the skill, README and
  `docs/USAGE.md`.

**Gate.**
- Both agents run ordinary commands without PIDs, and each gets its own text, app list, logs
  and screenshots.
- Targeting another session's app by explicit PID or ref fails.
- Stopping A while B is typing leaves B's app and input intact.
- The existing single-agent suite passes unchanged with no session configured.

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

1. Session identity, ownership, and the two-agent regression test.
2. `--isolated-home`, if the verification passes.
3. Shared-display concurrency checks.
4. Load runs and published capacity numbers.
5. Exclusive displays, only if steps 3 or 4 require them.

Not planned: several agents deliberately working on one app together. That would need an
explicit, expiring handoff and is out of scope until someone needs it.
