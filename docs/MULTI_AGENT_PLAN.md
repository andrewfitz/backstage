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
- **Codex 0.171.0.** The binary has `CODEX_THREAD_ID` in its shell-environment code, and Codex
  subagents run as their own threads. This is from `strings` only and hasn't been checked in a
  live session. Codex also has a daemon mode; herdr's wrapper passes `--no-daemon`. In daemon
  mode, shells may hang off a shared `codex`/`codex-exec-server` process, where only the
  thread ID tells sessions apart.
- **Grok 1.0.92.** The binary has `GROK_SESSION_ID`, but next to the hook variables
  (`GROK_HOOK_EVENT`). It isn't verified to reach tool shells.
- **herdr.** `HERDR_PANE_ID` and similar identify a terminal pane, not an agent, so they aren't
  used.

**Derivation as built (phase 1).** First match wins:

1. `BACKSTAGE_SESSION`. `legacy` is reserved.
2. The nearest known agent ancestor's own variable: `CLAUDE_CODE_SESSION_ID` (only if
   `CLAUDE_PID` is that ancestor), `CODEX_THREAD_ID`, or `GROK_SESSION_ID`. Variables are
   inherited, so they're only trusted for the *nearest* agent. A Codex started from a Claude
   shell doesn't join Claude's session.
3. That agent process: name, PID and start time.
4. The nearest non-shell, non-wrapper ancestor: PID and start time.
5. The outermost shell ancestor. That keeps one script's commands together without falling
   back to a shared default.

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
| `lifecycle.lock` (was `session.lock`) | **shared** by each launch from daemon start until its app is registered, and by `show`; **exclusive** for daemon shutdown (non-blocking, retried each tick) and for `stop`'s "anything left?" check | the daemon never quits or vanishes around an app it can't see yet. Launches in different sessions run concurrently. |
| `locks/session-<key>` | exclusive: launch registration, `quit`, `stop`, `show` | double stop. `stop` writes a timestamp in the file, and a launch that started earlier quits its app instead of registering it. |
| `locks/app-<pid>-<birth>` | exclusive: every input command (press, set, focus, action, click, hover, drag, scroll, type, key, menu) | interleaved input into one app |
| `lock` (exists) | apps.json read-modify-write | — |

Acquisition order: client → lifecycle → session → app → state. A launch still holds
`lifecycle.lock` (shared) while LaunchServices identifies the new process: an unregistered app
must not outlive the display. That wait blocks only daemon shutdown, never other sessions.
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
  windows on that display.
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

1. Session identity, ownership, and the two-agent regression test. **Done.**
2. `--isolated-home`, if the verification passes.
3. Shared-display concurrency checks.
4. Load runs and published capacity numbers.
5. Exclusive displays, only if steps 3 or 4 require them.

Not planned: several agents deliberately working on one app together. That would need an
explicit, expiring handoff and is out of scope until someone needs it.
