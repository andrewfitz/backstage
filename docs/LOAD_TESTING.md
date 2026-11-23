# Load testing

`tests/load.sh` measures how many agent sessions one Mac can serve. It implements phase 4 of
[the multi-agent plan](MULTI_AGENT_PLAN.md#4-measure-capacity). It isn't part of `make test`.

## Where to run it

Run full loads on **a separate macOS user account or a dedicated Mac**, never on a desktop
someone is using. Thirty-two fixture apps plus capture bursts will be felt there: CPU,
WindowServer, Dock icons and the Screen Recording indicator. The harness refuses more than 4
sessions unless you pass `--dedicated`.

Run it from Terminal in that account's logged-in GUI session, not over SSH: virtual displays,
ScreenCaptureKit and synthetic input need the GUI session. Make the account the active console
session (switched to, not running in the background behind another user), and leave the Mac
alone until the run finishes.

*Untested assumption:* that a background Fast User Switching session won't work. Nobody has
tried it yet, so check it on the first run before relying on a shared Mac's second account.

One-time setup on that account:

1. Install the Xcode command line tools (`xcode-select --install`) and clone the repo.
2. Run `make build`, then `"$(swift build -c release --show-bin-path)/backstage" status`.
3. Grant Accessibility and Screen Recording to Terminal (System Settings › Privacy & Security),
   then reopen Terminal. `status` should print `"ok" : true`.
4. Close other apps, and turn off notifications and anything scheduled (backups, Spotlight
   indexing of a fresh clone) so they don't skew the numbers.

## Running

```bash
make load                                   # 2-session smoke: every workload, short (~2 min)
tests/load.sh 2 all                         # 2 sessions, every workload, full length
tests/load.sh 8 input,capture --dedicated   # chosen workloads
tests/load.sh --build-only                  # compile the helpers only
```

The full matrix, about 10–20 minutes per session count:

```bash
for n in 2 8 16 32; do tests/load.sh "$n" all --dedicated; done
# Optional: without Dock icons, to see the Dock's share of the cost (no capture workloads)
tests/load.sh 32 idle,input,launch,cycles --dedicated --accessory
```

Arguments: `<sessions> [workloads]`, where workloads is a comma list or `all`. Options:

| Option | Default | Meaning |
|---|---|---|
| `--duration S` | 30 | seconds for each steady workload (idle, input, capture, mixed) |
| `--rounds R` | 3 | cold-launch burst rounds |
| `--cycles C` | 10 | launch/stop cycles for the leak check |
| `--capture-sessions K` | sessions/4, at least 1 | sessions that capture in the mixed run; the rest type |
| `--scale S`, `--format png\|jpg` | 1, png | screenshot settings |
| `--op-timeout S` | 60 | a screenshot with no reply after this long counts as **hung**, and its client is killed. It's set above backstage's own 20 s capture timeout, so queued captures behind a stuck one aren't miscounted. |
| `--accessory` | off | fixtures run with `TESTAPP_ACCESSORY=1` (`.accessory` policy, no Dock icon). Recorded in the results. Only with `idle,input,launch,cycles`: in the smoke run, every `screenshot` of an `.accessory` fixture failed with "no visible windows on the agent display" (cause not investigated). |
| `--dedicated` | off | confirms a separate account or Mac; required above 4 sessions, and drops the smoke label from the summary |
| `--results DIR` | `load-results/` (gitignored) | where the timestamped results folder goes |

`BACKSTAGE_WIDTH`/`BACKSTAGE_HEIGHT` size the agent display as usual and are recorded.
`BACKSTAGE_MENUBAR` defaults to `off` for load runs. The `make load` defaults are
`LOAD_SESSIONS=2 LOAD_WORKLOADS=all LOAD_ARGS="--duration 6 --rounds 2 --cycles 3"`.

If a run is interrupted, the script prints its `BACKSTAGE_HOME`. Clean up with
`BACKSTAGE_HOME=<that path> backstage stop --all`. Never `kill -9` the daemon: its windows would
fall onto the real screen.

## What a run does

Each run uses a fresh `BACKSTAGE_HOME` under `/tmp` and builds the fixture (`tests/TestApp.swift`)
once, as one bundle (`dev.backstage.testapp.load`). Every session is a separate client process
(`tests/load.py worker`) with its own `BACKSTAGE_SESSION` (`s00`, `s01`…), driving its own
fixture instance with its own marker text and pad colour (red for even sessions, green for odd).

1. Start the daemon (timed), and launch one idle **anchor** app in its own session. It keeps the
   daemon alive across workloads, because a session's last `stop` otherwise takes the daemon
   down, which would hide its memory growth. So `sessions + 1` fixtures are live.
2. Take a 3-second baseline: the daemon and the anchor only.
3. Run each workload. Steady workloads launch every session's app at once and wait for all of
   them. They then run for `--duration` with every session active, and that window is what's
   measured. Then the even sessions `stop` while the odd ones keep working for a short tail.
   The odd sessions then check their apps are the same processes before stopping.

| Workload | Each session does |
|---|---|
| `idle` | nothing: N launched, idle apps |
| `input` | a loop: `set` the field empty, `type <marker>-<n> --ref field`, read the field back (`find`), `press` Increment, raw `click` on the pad |
| `capture` | `screenshot -o` (a fixed per-session file) as fast as it can, and pixel-checks each shot |
| `mixed` | K sessions capture continuously and the rest run the input loop |
| `launch` | cold-launch burst: all N `launch` at once, type a marker and verify it, then all `stop` at once; `--rounds` times |
| `cycles` | leak check: all N launch, then all stop, `--cycles` times, with a snapshot after each |

Once a steady run is halfway through, every session also tries to `type`, `screenshot` and
`quit` its neighbour's app by `--pid`, and each must be rejected.

## What it records

`load-results/<timestamp>-n<sessions>/results.json` holds everything. `summary.md` next to it
is a short readable version. The work folder printed at the end (`/tmp/backstage-load.XXXX`)
keeps worker logs, fixture logs and any failing screenshots.

- **Setup:** machine model, CPU, cores, RAM, macOS version and build, every display's geometry
  (points and pixels, the agent display included), the git revision and dirty flag, a hash of
  the fixture source, its activation policy, and the configuration and environment.
- **Latency, as p50/p95/max/mean with n.** Each CLI command (`launch`, `set`, `type`, `read`,
  `press`, `click`, `screenshot`, `stop`) is timed as client wall-clock, process start
  included, which is what an agent experiences. Only commands inside the measured window
  count.
- **`SCShareableContent`:** `tests/probe.swift` makes the same call backstage makes before every
  app screenshot (`excludingDesktopWindows(true, onScreenWindowsOnly: true)`) every 250 ms,
  from outside backstage. It runs only with Screen Recording already granted, so it can't
  trigger a permission prompt. Each call holds `BACKSTAGE_HOME/capture.lock`, the lock
  backstage's own captures take (see the finding below), so the probe can't collide with them.
  A call that gets no reply in 20 s is reported, and the probe exits.
- **Lock wait:** a probe `flock`s three locks every 100 ms and times how long it waited: the app
  registry lock (`lock`, exclusive), `lifecycle.lock` (shared, as launches take it) and
  `capture.lock` (exclusive, as screenshots take it). Each session drives
  its own app, so per-app input locks don't contend across sessions. `tests/multi.sh` covers
  two clients on one app.
- **Throughput:** operations per second, total and per command, plus launches per second for
  the bursts.
- **Resources, sampled every second:** CPU % (from deltas in cumulative CPU time) and RSS for
  the daemon, WindowServer, the Dock and the fixtures. Also memory pressure
  (`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical), free memory
  percentage (`memory_pressure -Q`), and swap used at the start and end of each workload.
- **Leaks:** after each launch round and leak cycle, live fixture processes, registered apps,
  lock, log and wrapper files, and the daemon's RSS, file descriptors and threads, plus
  WindowServer RSS. Growth is reported from the first round to the last.

## What fails a run

The release-gate items (zero observed failures at every supported level):

- **Wrong-target input.** Each typed text must read back exactly from the session's own field.
  The Increment label must equal the session's own presses. The fixture log must hold only
  the session's own text, and exactly its own pad clicks and increments. Typing into another
  session's app by `--pid` must be rejected.
- **Foreign screenshot pixels.** Shots are points × scale, so one pad (380×130 pt) is about
  49,400 × scale² pixels. Using `tests/pixels.swift`, every shot must have fewer than
  max(1000, 2% of a pad) pixels of the other colour, and between 0.5 and 1.5 pads of its own.
  More than that means another session's same-coloured pad got in, which the check catches
  even in the first shot. Capturing another
  session's app by `--pid` must be rejected. Failing shots are kept in `failures/`.
- **Cross-session termination.** `quit --pid` on another session's app must be rejected. Odd
  sessions' apps must survive the even sessions' `stop`s, and the anchor app must survive
  every workload.
- **Non-interference.** `tests/watch.swift` runs throughout. Any fixture window on a user
  screen, a fixture becoming frontmost, or the cursor leaving the user's displays fails the
  run.

Also failures: command errors and hung commands (counted per command as `hung:<op>`), apps
left running or registered after a workload, and daemon file descriptors growing by one or
more per cycle.

Steady workloads start every session on the same timestamp, so the first commands are a true
burst: the worst case for collisions. On macOS 27.0.1 that already finds one (below).

## Known finding: simultaneous `SCShareableContent` calls hang

Found by the first smoke run (2026-11-23, macOS 27.0.1). When two processes call
`SCShareableContent` within about 2–5 ms of each other, one of them never gets a reply, and
the call has no timeout.

- **Through backstage:** two sessions running `screenshot` at the same moment both hung, in
  6 of 6 trials. Run one after the other, each took 0.14 s.
- **Without backstage:** a standalone program that makes one `SCShareableContent` call hung in
  one of two copies started together, every time. It didn't hang with a 5 ms or larger gap.
- **No crash:** `replayd` stayed up throughout. The stuck client sits in `runAsync`
  (`Capture.swift`), waiting for the reply.

Agents capturing independently will sometimes collide like this. Without a timeout, the
screenshot then hangs until the agent's own tool times out. The fix is in progress in
`Sources/` as part of the phase 3 work (uncommitted when this was written).
`Capture.swift` holds `BACKSTAGE_HOME/capture.lock` around the ScreenCaptureKit calls and gives
up after 20 s. After that lands, rerun the capture and mixed workloads.

- **Lock wait:** the `capture` lock-wait figures show what serializing captures costs as
  sessions grow.
- **Hangs:** the harness reports any remaining ones as hung screenshots instead of hiding them.

A later 2-session run on a build with that lock had no hangs. Waiting for `capture.lock` cost
p50 115 ms and p95 225 ms with two sessions capturing back to back. Two of 52 screenshots
still failed, though, with a spurious `SCStreamErrorDomain` -3801 ("The user declined TCCs"),
even though permission is granted and the calls were serialized. That looks like a separate
ScreenCaptureKit problem under rapid captures from several processes. It's not a harness artifact: in
the mixed runs, with one capturing session plus the same probe and watchdog, 0 of about 60
shots failed. One retry on -3801 in
`Capture.swift` is the likely fix.

Then the final `make load` on the same kind of build. With every ScreenCaptureKit call
serialized (the probe's too), one capture still got no reply and hit backstage's 20 s
timeout, and the other session's screenshot waited behind it for 20.3 s. So serializing
avoids the simultaneous-call collision but not every hang. It also turns one hang into a
stall for every session. A much shorter timeout with a retry, and a root cause, are still
needed.

## Caveats

- The watchdog samples in a tight loop and keeps one core busy. The probes add one
  `SCShareableContent` call every 250 ms and a few `flock`s every 100 ms.
- CPU of the short-lived CLI client processes isn't captured. Only their count is.
- Lock waits are measured from outside, not per command. Splitting a command's latency into
  lock wait, `SCShareableContent`, capture and encode needs timing output from the CLI itself
  (see the plan).
- Latency targets need agreeing before the full run (see the plan). A smoke run on a working
  desktop says nothing about capacity.
