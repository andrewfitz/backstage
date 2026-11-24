# Multi-display plan

Status: built in 1.3.0 (both phases); revised after review (Claude + Codex). Phase 1 fixes a real problem;
phase 2 is a feature built on it.

## Why

**macOS never forgets a display.** ColorSync and WindowServer register every new display
identity for good. Today each `BACKSTAGE_HOME` gets its own serial (a hash of the home's path),
and the test suites make a new temporary home on every run (the audio suite alone uses 8).
After a day of testing one Mac had **161** "Backstage (agent display)" ColorSync devices and
107 entries in WindowServer's display list. ColorSync walks its list, one XPC call per device,
whenever a display comes or goes, and settled into a loop: `colorsyncd`,
`colorsync.displayservices` and `colorsync.useragent` used about 19 CPU-hours in 13.6 hours.
Unregistering the stale devices as root brought them from about 190% CPU to about 45%.

**One display can get crowded.** Every session shares one agent display. Windows are tiled
first-fit and cascade once it's full, and an agent that wants a clean full-display screenshot or
recording gets other sessions' windows in it.

## Goals

- Backstage reuses a handful of fixed display identities instead of minting a new one per home.
  (That this caps the registries at those identities is the hypothesis phase 1's test checks:
  the device count must not grow across repeated suite runs.)
- Normal use is unchanged: one display, nothing to configure.
- Backstage's own test suites never touch the displays agents use.
- (Phase 2) An agent can choose a display of its own, and is told when its display is crowded.
  Nothing it claims hangs around.

Non-goals: automatic overflow onto a new display, crowd ranking, displays of other sizes, more
than 8 displays. Each can come later if agents need it.

## The eight displays

Every backstage display keeps vendor `0xB57A`, product `0x0001` and the name "Backstage (agent
display)" (as today: changing the name is untested and buys nothing), with one of eight fixed
serials:

| Display | Serial | Used by |
|---|---|---|
| 1 | `0x42530001` | The default home (`~/.backstage`): all agents, the normal case |
| 2–6 | `0x42530002`–`0x42530006` | Phase 1: other homes. Phase 2: extra displays of the default daemon |
| 7–8 | `0x42530007`–`0x42530008` | backstage's own test suites |

- **Choosing.** `BACKSTAGE_DISPLAY=N` asks for display N; the default home asks for 1. Without
  either, a home takes the lowest free display in 2–6.
- **Free means not online.** A display is free when no online display matches its
  vendor/product/serial. Choosing and creating run under the existing per-user `UserLock`
  (not under `$TMPDIR`, which a caller can override), held until the new display is observable,
  so two daemons starting together can't pick the same one. If listing the online displays
  fails, starting fails.
- **Teardown race.** Right after a `stop`, the old display can still be online for a moment.
  A display asked for by number is retried for up to 5 seconds before failing.
- **Errors** say what's unavailable, not who holds it (online displays carry no owner):
  `display 7 is in use`, `displays 2-6 are all in use`. There is no hash fallback: that is what
  created the pile.
- **Mode and placement** don't rely on identity: startup waits for the display, parks it,
  selects the requested mode explicitly and parks it again.

### Migration and cleanup

- The default home moves from its hash serial to display 1: one new identity, once.
- `backstage doctor` counts ColorSync devices named "Backstage (agent display)" that aren't
  attached and, past a handful, warns and prints the fix.
- `sudo backstage cleanup-displays` unregisters those unattached backstage devices
  (`ColorSyncUnregisterDevice`, which only takes effect as root; as a normal user the command
  says so and prints the sudo line). Displays are matched by name and only when not attached,
  so the user's own displays and a live backstage display are never touched. It was run by hand
  on the affected Mac and removed about 150 of 161.
- Not done by the daemon: it doesn't run as root, and a recurring sweep could race a display
  another daemon is registering. WindowServer's display list is root-owned and left alone; it
  stops growing once identities are reused.

## Phase 1: fixed identities

1. `Display.swift`: the eight serials replace `displaySerials(home:)`; choice, lock and retry
   as above. `AgentDisplay` keeps its slot.
2. `status`/`doctor` report `display: {slot, serial}`; `doctor` adds the leftover-device check.
3. `cleanup-displays` (root only), documented in USAGE.
4. Tests on 7–8: the Makefile targets and each GUI suite export `BACKSTAGE_DISPLAY=7` (homes
   used one after another all reuse 7); the second, concurrent home in `multi.sh` uses 8. The
   menu bar is per suite as today: `send.sh` needs it, because the hotkey needs the menu bar.
5. New checks (tests/displays.sh), within the two-display test budget:
   - The registered backstage device count doesn't grow across a second run (counted after
     displays 7 and 8 have each been used once).
   - Two homes started at the same moment get displays 7 and 8; a third asking for 7 fails with
     `display 7 is in use` after the retry window.
   - A home asking for no display gets the lowest free of 2–6 (checked by the slot reported,
     using a display already registered, so the device count stays flat).
6. Docs: README, USAGE (`BACKSTAGE_DISPLAY`, `cleanup-displays`), CHANGELOG.

## Phase 2: one daemon, several displays

The default daemon can run displays 1–6 instead of only 1. Sessions, ownership, locks, the input
guard, audio and the menu stay in one process. Agents choose; nothing overflows by itself.

### Model

- The daemon owns a pool of displays. Display 1 exists while the daemon runs; 2–6 are created
  when asked for and removed once they hold no apps and no pending launches.
- **Allocation is the daemon's**, atomically, over its socket: the CLI asks for a display
  (`new` or `N`) and the daemon answers with the slot. The slot is carried in the pending
  launch record and the managed app record, so the daemon's delayed-launch path registers the
  app on the same display.
- **State and protocol:** `DaemonInfo` lists every display (slot, ID, bounds); `ManagedApp` and
  pending launch records get `display`. Protocol 2; records without a display decode as
  display 1.

### Choosing a display

- `launch --display N` puts the app on display N (created if needed). `launch --display new`
  takes the lowest free display and **reserves** it for the caller's session.
- A **reservation expires** 30 minutes after it was made or after 10 minutes without a command
  from that session, whichever comes first. Expiry only ends exclusivity; the display goes away
  when its apps quit. A reserved display refuses other sessions' numbered launches, `move`s and
  Send Front Window Backstage.
- Without `--display`, a launch goes where the caller's session already has apps, else display 1.
- **Crowded:** when placement finds no free spot and cascades, `launch` says so
  (`"crowded": true`, plus a warning suggesting `--display new`), so the agent can choose.

### Containment and guards

Every path that keeps windows on "the" agent display routes by the app's assigned display:

- The window observer, the delayed reveal and the periodic sweep move a window to *its app's*
  display, and treat windows of the daemon's other displays as their own, not foreign (otherwise
  the sweep would pull display 2's windows onto display 1).
- Parking: each display is parked serially, meeting every other display (the user's and its
  siblings) at most at a corner point. The Dock guard repairs whichever display the Dock moved
  onto.
- The cursor guard already covers every backstage display; unchanged.
- The last user display disappearing still shuts the whole daemon down.
- Send Front Window Backstage moves all the process's windows to display 1 (or the sender's
  choice in a later version), as today. `show` keeps its handoff: the app's record is removed
  before its windows go home, and the sweep must not reclaim them in between.

### What agents see

- Each command resolves the target app's display and uses its ID and bounds: screenshot crops
  and coordinates, `window fill`/`size`, `windows`/`tree`/`find`/`wait`, and click, hover, drag
  and scroll. Coordinates stay agent-display points with (0,0) at the top-left of the app's
  display, so nothing an agent does today changes.
- `screenshot --full` keeps its session filter; if the session spans displays, it needs
  `--display N`.
- `list` shows each app's `display`. `status` lists every display (slot, apps, reservation)
  and its `screencapture -D` and ffmpeg indices, computed from one fresh snapshot of the active
  displays (hot-plugging renumbers them).
- The skill gains a short section: `--display new` for a clean display of your own, and what
  `crowded` means.

## Menu

The live picture stays the first thing in the menu.

- **One display:** exactly as today.
- **Two or more:** up to **two thumbnails stacked**, each with a chip naming the display
  (`Display 2 · 3 apps`). Each thumbnail's height is capped (about 150 points) so the pair fits
  with the app list.
- **More than two:** the pair is one stack with **‹ ›** arrows and `1–2 of 4` in a slim row
  under it. Paging moves two displays at a time; the page is kept while the menu is open and
  reset when it closes.
- **Capture cost:** only visible thumbnails refresh, one capture in flight at a time, and a
  result for a display that's no longer visible is dropped. The refresh rate stays once a second.
- **App rows** stay grouped by session; with more than one display, each row's detail says which
  (`Display 2 · Running for 12 min`). Pointing at a row picks out its windows if its display is
  visible, and highlights the arrow toward it if not. The menu doesn't page by itself.
- Count beside the icon: total apps. Footer unchanged.
- Layouts with three and six displays are tested with synthetic data, not real displays.

```
┌──────────────────────────────┐
│ ┌──────────────────────────┐ │
│ │ [Display 1 · 3 apps]     │ │
│ └──────────────────────────┘ │
│ ┌──────────────────────────┐ │
│ │ [Display 2 · 1 app]      │ │
│ └──────────────────────────┘ │
│        ‹   1–2 of 3   ›      │
│ Claude — checkout-flow       │
│  ▣ Calculator                │
│    Display 1 · Running 12 min│
│ Codex — word-lookup          │
│  ▣ Dictionary                │
│    Display 2 · Running 3 min │
│ ──────────────────────────── │
│ Send Front Window Backstage  │
│ …                            │
│ Backstage v1.x · GitHub      │
└──────────────────────────────┘
```

## Agent use cases

1. **One agent testing its app** (the common case). Display 1, no flags; nothing changes.
2. **Display 1 is crowded.** An agent's launch result says `crowded`; it relaunches with
   `--display new` and gets a display to itself. Its screenshots and clicks work the same.
3. **A clean full-display screenshot or recording.** An agent recording a demo, or checking a
   full-screen layout, runs `launch --display new`: no other session's windows in the picture,
   and `status` gives the display's capture index for ffmpeg or `screencapture -D`.
4. **Full-screen and multi-window apps.** An app that goes full screen takes over a whole
   display (its own Space). On a shared display that hides everyone else's windows; on its own
   it doesn't.
5. **Testing multi-monitor behaviour.** An app with "Move to Display" or a presenter view needs
   two screens: one session launching on two numbered displays.
6. **The user sends a window backstage** (⌃⌥⌘B). It lands on display 1, never on a display an
   agent reserved.
7. **backstage's own tests** run on 7–8 while the user's agents keep working on 1–6, without
   adding a ColorSync device per run.

## CLI summary

| Phase | Command or setting | What it does |
|---|---|---|
| 1 | `BACKSTAGE_DISPLAY=N` | Which of the eight displays a home uses |
| 1 | `sudo backstage cleanup-displays` | Remove leftover backstage display devices (one-time) |
| 1 | `status` / `doctor` | Display slot and serial; leftover-device warning |
| 2 | `launch --display N\|new` | A numbered display, or a fresh one reserved for your session |
| 2 | `move --display N` | Move an app to another display |
| 2 | `screenshot --full --display N` | Capture a whole display |
| 2 | `status`, `list` | Displays with apps, reservations and capture indices; each app's display |

## Testing

Phase 1: tests/displays.sh (above); every GUI suite runs on 7–8 under the shared GUI lock; a
helper counts registered backstage devices before and after.

Phase 2 (in the test home, on displays 7 and 8 via `BACKSTAGE_DISPLAY=7` as the home's first
display and 8 as its extra):
- `launch --display new` lands on 8; screenshots, clicks and `window fill` on it line up with the
  same fixture on 7.
- The sweep leaves display 8's windows on 8; the observer puts an app's new windows on its own
  display.
- A reservation refuses another session's launch, move and Send, and expires (shortened by a
  test-only setting).
- Display 8 goes away once its apps quit; the device count is unchanged.
- `crowded` is reported when a launch cascades.
- Protocol 2 reads protocol-1 records as display 1.
- Menu: synthetic layouts for 1, 2, 3 and 6 displays; paging; one capture in flight.
- The non-interference watchdog throughout.

## Later, on a separate Mac

Reuse one slot across homes at different sizes and scales, and check both registries, the actual
mode, placement and the Dock. Not run on a working Mac.

## Rollout

1. Phase 1, released alone (the ColorSync fix). Users with a pile run
   `sudo backstage cleanup-displays` once; `doctor` tells them.
2. Phase 2 in the next release.
