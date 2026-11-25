# Audio support for Backstage

Give agents the same thing for sound that they have for windows. An agent can check that the
app it launched plays audio, while nothing comes out of the Mac's speakers or headphones. The
menu bar shows when an agent's app is making sound.

Agents don't need to "hear" anything. They need facts: did the app produce sound, when, for how
long, how loud, and did it stop. A WAV of the muted output covers everything else.

**Phase 1 is built** (2026-11-23; see [Phase 1 results](#phase-1-results)): muting, `audio`,
`wait --sound`, `doctor`'s self-test and both test suites. The leak suite for the dedicated
Mac is written but hasn't run. **Phase 3 is built** (`audio record`, the skill and the docs;
its gate passes, see [Phases → 3](#3-audio-record-skill-and-docs)). The phase 0 spike ran on 2026-11-23 (macOS 27.0.1, Mac Studio) with
throwaway programs in `/tmp/bs-audio-spike`. Both claims the design rests on hold. A muted tap
is silent at the device, checked against a loopback. Backstage can get permission to read
one, and doesn't need it to mute. **The spike gate passes** with three carry-overs (see
[Gate](#gate-result)).

## User decisions

- **Muting is unconditional.** If muting can't be set up for a launch (macOS older than
  14.2, an unhealthy tap manager, an API error), `backstage launch` refuses with a clear
  error. There is no warn-and-continue mode.
- **A missing System Audio Recording grant doesn't block launch** (decided after the
  spike). Muting needs no permission; only *reading* the tap does (finding 1.3). Without the
  grant, `launch` still mutes and works. `audio` and `wait --sound` fail with a clear error
  telling the user to grant System Audio Recording to the daemon's host.
- **The spike ran on the user's desktop.** The user agreed to it, and clicked Allow on the
  System Audio Recording prompt.
- **Inaudible by default for test runners and dev builds; audio inspection is opt-in**
  (2026-11-23, after the [capture spike](#capture-spike-muted-apps-in-system-wide-captures-2026-11-23)).
  Launches of targets that accept DYLD injection (`xctest` and other test runners, ad-hoc,
  unsigned and development-signed builds, wrapped bare executables) are made inaudible
  automatically. Signed, hardened and Apple apps keep the muted tap. Only `launch --audio`
  is measured, for every kind of app: without it the tap only mutes (no IO, no ring, no
  levels, no menu meter) and the audio commands refuse. See
  [Inaudible launches](#inaudible-launches-built-2026-11-23).

## What the SDK says (checked 2026-11-23, macOS 27.0.1 SDK)

Headers: `CoreAudio/CATapDescription.h`, `AudioHardwareTapping.h`, `AudioHardware.h`, the
CoreAudio Swift interface, and `ScreenCaptureKit/SCStream.h`. The last column now carries the
spike's result where it ran one.

| Claim | What was found | Status |
|---|---|---|
| Process taps, macOS 14.2+ | `AudioHardwareCreateProcessTap` is 14.2. The Swift wrappers (`AudioHardwareSystem.makeProcessTap`, `AudioHardwareTap`) are 15.0. | Confirmed. Use the C API. Backstage's floor is macOS 14, so audio needs 14.2. |
| `CATapMuted` silences the app | "Audio is captured by the tap but no audio is sent from the process to the audio hardware." | **Measured, with a condition:** the tap mutes only while it belongs to an aggregate device. IO needn't run (finding 2.1). |
| A bundle-ID tap can exist before launch | `bundleIDs` and `processRestoreEnabled` (26.0). | Not needed: the on-sight gap leaked nothing (finding 5). Also unusable for wrapped executables, whose Core Audio bundle ID is empty (finding 8). |
| PID → process object | `kAudioHardwarePropertyTranslatePIDToProcessObject` returns `kAudioObjectUnknown` for a non-client. | Confirmed. The object appears at the first Core Audio call (`AudioComponentInstanceNew`, `AudioQueueNewOutput`), tens of milliseconds before the first render. |
| A tap covers the app's process tree | Nothing includes children. | **Wrong**, as before: Backstage adds helpers itself. Adding a process to a live tap works (finding 7.3). |
| Wrapped executables have unique bundle IDs | — | **Wrong, and measured:** a wrapped bare executable's Core Audio bundle ID is `''` (finding 8). |
| Taps and aggregates can be private | `privateTap`, `kAudioAggregateDeviceIsPrivateKey`. | Confirmed. Both are destroyed with their owner, including on `kill -9` (finding 7.1). |
| A tap-only aggregate device works | Nothing says an aggregate with taps and no sub-device runs. | **Measured: it runs**, clocked at the tap's 48 kHz, in real time (finding 3). |
| Tap format | `kAudioTapPropertyFormat`. | Float32, 2 ch, 48 kHz here. Read it at run time. **Level depends on the device** (finding 2.5). |
| A tap can be changed in place | `kAudioTapPropertyDescription` is settable. | **Measured: no glitch**, and a process added mid-tone is muted and captured (finding 7.3). |
| Permission is separate from Screen Recording | `tccd` pairs `kTCCServiceAudioCapture` with `NSAudioCaptureUsageDescription`. No public preflight. | **Measured:** a separate grant. It's requested at IOProc setup on the tap's aggregate, not at tap or aggregate creation (finding 1). |
| ScreenCaptureKit can't mute | — | Confirmed. |
| System sounds bypass a per-app tap | `systemsoundserverd` is its own audio client. | **Measured:** `AudioServicesPlaySystemSound` plays from `systemsoundserverd`, not from the caller (finding 6). |
| Taps die with the daemon | Stated for private aggregates only. | **Measured:** `kill -9` of the owner unmutes within about 2 ms (finding 7.1). The `coreaudiod` restart case is untested. |

## Spike findings

How it was measured:

- **The probe** was a sine at 18.5 kHz (19 kHz for a second process), −60 dBFS, with 10 ms
  ramps, 0.5–2 s long. It played from windowless command-line processes (AUHAL, AudioQueue,
  AVAudioEngine, AVPlayer, AVAudioPlayer, NSSound, system sound).
- **The tap reader** was a private tap in a private aggregate. Its IOProc ran a Goertzel
  detector at the probe frequency per 100 ms window and counted non-zero frames.
- **Ground truth was a loopback.** This Mac has `ZoomAudioDevice` (2 in / 2 out), which loops
  its output back to its input. Played to it with no tap, the probe came back at exactly −60.0
  dBFS. The probe player was pointed at it explicitly, and its input was read in parallel. It
  is not the default output, so the default device (a 10-channel Universal Audio interface)
  had no ground truth.
- **All timings** are `mach_absolute_time` across processes.

### 1. Permission

1. **Who is asked.** On this Mac the responsible process for the shell was **herdr** (the
   terminal multiplexer: zsh → claude → zsh → herdr, with herdr's parent PID 1), not Ghostty
   or claude. `responsibility_get_pid_responsible_for_pid` returned herdr for the whole chain,
   and for the two `backstage` processes running at the time. A `posix_spawn`ed daemon
   inherits whichever host spawned it.
   - herdr is a bare binary with no `Info.plist`, so no `NSAudioCaptureUsageDescription`.
     macOS 27 prompted anyway, in herdr's name: `AUTHREQ_PROMPTING service=kTCCServiceAudioCapture
     subject=/opt/homebrew/Cellar/herdr/0.9.5/bin/herdr`.
   - The call didn't fail, didn't return silence and didn't kill the caller.
   - The grant is keyed to that **versioned Cellar path**, so a herdr upgrade probably drops
     it.
2. **When.** Not at `AudioHardwareCreateProcessTap` and not at
   `AudioHardwareCreateAggregateDevice`: both returned 0 before any grant existed.
   - **The prompt came at `AudioDeviceCreateIOProcIDWithBlock`** on the tap's aggregate. That
     call blocked for 6.26 s, exactly the time the prompt was on screen (14:59:42.146 to
     14:59:48.398). The `AudioDeviceStart` that followed took 9 ms and delivered real audio.
   - **An IOProc that was created and never started** (with the grant already in place) showed
     no recording indicator (finding 9). tccd's log had gone quiet by then, so whether that
     run made a request is unknown.
   - The daemon must never make these calls on a queue that matters.
3. **Muting needs no permission.** Runs whose tapper never started IO (tap only, tap plus
   aggregate, `MutedWhenTapped`) logged no `kTCCServiceAudioCapture` request at all. The
   decisive check:
   - A tapper launched through LaunchServices from a wrapper `.app` is its own responsible
     process. Its `TCCAccessPreflight(kTCCServiceAudioCapture)` returned 2: not granted.
   - From there it created a muted tap and a tap-only aggregate with no IO. The loopback stayed
     silent for the whole probe: 0 non-zero frames.
   - **Untested:** the explicitly *denied* state. Nobody clicked Don't Allow on an audio
     capture prompt.
4. **Screen Recording doesn't cover it.** herdr already had Screen Recording
   (`kTCCServiceScreenCapture` preflight returned authorized) and was still prompted for
   `kTCCServiceAudioCapture`.
5. **Reading a tap doesn't need the Microphone.** Every tap-only reader made one
   `kTCCServiceAudioCapture` request and only *preflight* Microphone checks. These were 30+
   runs, including global and device taps. A preflight never prompts.
   - An aggregate that also contains the real output device is different. It brings that
     device's input streams with it (10 input channels on the UA interface) and makes
     Microphone *requests*. That's another reason for the tap-only aggregate.
6. **A Microphone prompt did appear, from the probe player, not from Backstage's path.** On
   macOS 27, `coreaudiod` issued `kTCCServiceMicrophone` requests (not preflights) for
   *output-only* playback.
   - **Made requests:** our unsigned probe binaries, through AUHAL, DefaultOutput,
     AVAudioEngine, AVPlayer, AVAudioPlayer and NSSound, to any device, including the
     output-only speakers.
   - **Inconsistent:** AudioQueue requested in one binary and not in a minimal one.
   - **Made none:** `afplay`, an Apple platform binary.
   - **Under herdr** this was invisible, because herdr already had the Microphone.
   - **In the wrapper:** the probe player launched through LaunchServices from a wrapper
     `.app` was its own responsible process. It raised "spike would like to access the
     microphone", subject `/private/tmp/bs-audio-spike/spike`. The player's AUHAL setup (from
     process start to `AudioUnitInitialize` returning) blocked 7.3 s, until the user answered.
   - **Under herdr, the request came during AUHAL setup:** in a timed run, the one request
     (15:28:22.167) fell between the start of `AudioComponentInstanceNew` and
     `AudioUnitInitialize` returning (22.131 to 22.176). That was a second before
     `AudioOutputUnitStart`. Later runs logged no request (tccd's log had gone quiet), so the
     exact call isn't isolated.
   - **The answer was Allow** (`authValue=2`, `type=Create` event at 15:08:23). That grant to
     the throwaway path is still in System Settings › Privacy & Security › Microphone ("spike")
     and can be removed.
   - **After an ad-hoc rebuild** of the same path, `TCCAccessPreflight(Microphone)` returned
     2 (not granted) from the wrapper, and tccd logged no deletion. That suggests the grant is
     bound to the code hash. It's an inference, not a measurement.
   - **Consequence for Backstage:** apps it launches are their own responsible processes, so
     an app under test, or the test fixture, may raise a Microphone prompt in its own name the
     first time it plays. That is macOS behaviour, independent of taps, but Backstage makes it
     happen on the user's screen. **Open:** whether a properly bundled, signed app (with or
     without `NSMicrophoneUsageDescription`) gets the same request. Phase 1 checks this with
     the real fixture.
   - Tap capture with the Microphone *denied* is untested. Given item 5, it isn't expected to
     matter.
7. **Prompts a first-time user sees:**
   - **One System Audio Recording prompt**, in the name of whatever host is responsible for
     the daemon (the terminal or agent host: herdr here, Terminal/Ghostty/iTerm elsewhere).
     It comes at the first IOProc setup, so `doctor` should be the thing that triggers it.
   - **No Microphone prompt** from Backstage itself.
   - **Possibly a Microphone prompt per launched app that plays sound** (item 6).
   - In this spike the user saw exactly one audio capture prompt (herdr) and one Microphone
     prompt ("spike", from the wrapped probe player).
   - The other TCC prompts logged in the same window were Microphone prompts for
     `com.mpcut.desktop`, another app, not this spike.
8. **How `doctor` can tell.**
   - **Private preflight:** `TCCAccessPreflight(CFSTR("kTCCServiceAudioCapture"), NULL)`
     returns 0 when granted (herdr) and 2 when never asked (the wrapper). It doesn't prompt.
     The value for "denied" wasn't observed.
   - **Public self-test (recommended):** the daemon plays the −60 dBFS probe from its own
     process. It mutes itself with its own tap and aggregate, starts IO for about 0.5 s, and
     expects the probe at the probe frequency. This is the same IOProc setup that raises the
     prompt the first time, so `doctor` doubles as the way to ask.
     - Only the two-process form (player and tapper apart) ran in the spike. A process tapping
       itself is untested.
   - It must run **in the daemon**, because the grant that matters is the daemon's
     responsible host, which may not be the host running `doctor`.
   - Use the private preflight only as a hint in the message, never as the verdict.
9. **The helper `.app` isn't needed for permission.** The bare daemon gets the prompt and the
   grant in its host's name.
   - **What a helper would fix:**
     - The grant follows whichever host started the shared daemon.
     - It's keyed to a versioned path that upgrades break.
     - The prompt and the recording indicator name "herdr" rather than Backstage.
   - **What a helper costs:**
     - A second grant.
     - A stable signing identity: an ad-hoc rebuild probably loses the grant (item 6).
   - **The fallback was not built:** not needed, and it would have meant another prompt.
     Phase 1 keeps taps in the daemon and documents the host dependence (see Design).

### 2. Mute semantics (loopback ground truth, probe on `ZoomAudioDevice`)

| Setup | Loopback (what reached the device) | Tap read |
|---|---|---|
| No tap (control) | probe at −60.0 dBFS | — |
| Unmuted tap + aggregate + IO | probe at −60.0 | −60.0 |
| `CATapMuted` tap, **no aggregate** | **probe at −60.0: not muted** | — |
| `CATapMuted` tap + aggregate, **IO never started** | silent (0 frames) | — |
| `CATapMuted` tap + aggregate + IO | silent | −60.0, all 70,408 non-zero frames |
| `CATapMutedWhenTapped` + aggregate, no IO | probe at −60.0 | — |
| `CATapMuted` tap + aggregate, no IO, tapper not granted | silent | — |

1. **The mute is the tap plus an aggregate holding it.** A tap on its own doesn't mute. No
   reader is needed, so idle apps cost no IO. A `--noio` tapper used no measurable CPU.
2. **Other output devices.** The probe went explicitly to a non-default device and was muted
   there, so an app that picks its own device is covered. The default output (UA, 10
   channels) and the speakers were checked only through the tap, with no ground truth.
3. **The level is independent of system volume.** On Mac Studio Speakers, with the device
   volume at 0.710, the tap read −60.0 for a −60 dBFS probe. Volume isn't applied before the
   tap. The volume was never changed.
4. **Playback advances in real time while muted.**
   - AUHAL rendered 80,384 frames in 1.509 s muted, against 80,384 in 1.522 s unmuted.
   - `AVAudioPlayer.currentTime` was 1.050 after 1 s, `NSSound` 1.052, and `AVPlayer` reached
     1.500 at the end of a 1.5 s file.
5. **The level depends on the output device. A carry-over.** The same −60 dBFS stereo probe
   read **−74.0** when the app played to the 10-output-channel UA interface, and −60.0 on the
   2-channel speakers and the Zoom device.
   - It read −74.0 with stereo mixdown, mono mixdown, and a device-specific process tap
     (`initWithProcesses:andDeviceUID:withStream: 0`, with and without `mixdown`).
   - `mixdown = NO` on a plain process tap made the format unreadable (`'!obj'`).
   - 14 dB is 20·log10(2/10), which fits averaging across 10 channels. The cause isn't
     confirmed.
   - That puts a −60 probe below the draft's −70 dBFS `playing` floor on this very Mac.
6. **`tapautostart` captures the first buffer but delays the app.** With
   `kAudioAggregateDeviceTapAutoStartKey` and IO started before the sound, all 70,408 frames
   were captured.
   - **The cost:** the tapped app's first render came **224–322 ms after its
     `AudioOutputUnitStart`** (3 of 3 runs), against 13–25 ms without.
   - That changes the app's behaviour. Don't use it.
7. **Starting IO when the app starts output captures the first buffer.**
   - **What was run:** a 2 ms poll of `kAudioProcessPropertyIsRunningOutput` started the
     aggregate's IO (`AudioDeviceStart`, 5 ms) as the app began.
   - **The result:** the whole probe was captured in 4 of 4 runs (AUHAL twice, AudioQueue,
     AVAudioEngine), and the app's own start latency was normal.
   - **The listener:** a listener on `kAudioProcessPropertyIsRunning` (`'pir?'`) fired at the
     same moment, and again when output stopped. A listener on
     `kAudioProcessPropertyIsRunningOutput` (`'piro'`) never fired. Listener-driven start
     wasn't run end to end (the start code sat on the `'piro'` listener).

### 3. Aggregate

- **A tap-only private aggregate runs.** It has no sub-device and was created in 6–10 ms at
  48 kHz with 2 input channels. It delivered 512-frame buffers in real time (199,168 frames in
  about 4.1 s).
- **Adding the default output as main sub-device also works, but it's worse:**
  - it brings that device's 8 inputs into the aggregate (10 input channels);
  - IO start took 182 ms;
  - it makes Microphone TCC requests;
  - it ties the aggregate to the device.
- **Decision:** tap-only.

### 4. Watchdog

With app P muted by tap A (loopback silent), a second process ran an **unmuted global tap** and,
separately, an **unmuted device tap** on P's output device
(`initExcludingProcesses:@[] andDeviceUID:`). Both carried P's probe at −60.0, every frame.

- **Taps see audio before the mute**, so no tap can act as a watchdog. The draft's "desktop
  proxy" is invalid.
- **No public API was found that reports what actually reached a device**, other than reading
  a loopback device's input. That needs the Microphone permission for the reader's host
  (herdr has it here).
- **What's valid on a desktop:** a loopback device that isn't the default output, as used in
  this spike. The fixture plays to it explicitly, the watchdog reads its input, and the user
  hears nothing either way.
- **What it doesn't prove:** the default output. That stays on the dedicated Mac.

### 5. Launch gap

- **The setup:** the probe player started playing from its first line, with no hold, to the
  loopback. A tapper that already knew the PID waited on a `kAudioHardwarePropertyProcessObjectList`
  listener (plus a 1 ms poll), then created the muted tap and aggregate and started IO.
- **The result: 0 frames leaked in 3 of 3 runs** (AUHAL twice, AudioQueue once). The tap
  captured the whole probe.
- **The timeline:**

  | Event | Time |
  |---|---|
  | Process object appears (`AudioComponentInstanceNew` / `AudioQueueNewOutput`) | 0 |
  | Mute in place (tap + aggregate) | +11–12 ms |
  | First render | about +45–85 ms |

- **The margin** was about 15 ms before `AudioOutputUnitStart` for AUHAL and about 50 ms before
  `AudioQueueStart`.
- **What's not covered:** the real daemon must also match the PID to a pending launch, which
  eats into this margin. Phase 1 must measure the daemon's own sight-to-mute time.
- **Bundle-ID taps before launch** aren't needed, and wouldn't work for bare executables
  (finding 8).

### 6. Routing

| Playback path | Process object running output | Muted by the app's tap |
|---|---|---|
| AUHAL, AudioQueue, AVAudioEngine, AVPlayer, AVAudioPlayer, NSSound | the app's own process | yes (captured, loopback silent where tested) |
| `AudioServicesPlaySystemSound` (custom sound) | `systemsoundserverd`, one shared instance | no |
| WKWebView page (WebAudio) | **unanswered**: the windowless CLI host produced no audio | — |
| AVSpeechSynthesizer, `NSBeep`, Electron | **unanswered**: not played, for safety | — |

- **System sounds:** the system sound went out unmuted at about −96 dBFS (alert volume is
  applied before the tap). It was an inaudible 18.5 kHz probe.
  - The caller had no process object until after the sound.
  - `NSBeep` presumably takes the same path. It wasn't played.

### 7. Failure windows

1. **`kill -9` of the tap owner:** P is audible about 2 ms later, which is measurement
   resolution. `coreaudiod` drops the mute at once.
   - A private tap is invisible to other processes: while a tapper ran, another process's
     `kAudioHardwarePropertyTapList` was empty. So the tap list can't show leftovers.
   - The evidence that private taps and aggregates die with their owner is the audio
     returning.
2. **Normal `AudioHardwareDestroyProcessTap` while P plays:** audible within about 10 ms. As
   expected, so a tap is never removed from a live app except by `show`.
3. **Changing the tap's process list in place** (`kAudioTapPropertyDescription`, adding a
   second process mid-tone):
   - no leak from P;
   - the added process, which started playing 19 kHz after the change, was muted (loopback
     silent) and captured at −60.0.
4. **Untested:**
   - a `coreaudiod` restart (needs root and disrupts the user's audio);
   - an output device change (needs changing the user's default device).

### 8. Core Audio bundle ID of a wrapped executable

A wrapper `.app` (LaunchServices-launched, shim `exec`s a binary outside the bundle) gives the
process a Core Audio bundle ID of `''`, like every other unbundled client. Bundle-ID taps can't
target bare executables.

### 9. Side effects and load

- **Recording indicator:** Control Center's sensor indicators listed `[aud] herdr` only while a
  tap's aggregate ran IO. They didn't while the tap and aggregate existed with IO stopped, nor
  with an IOProc created but not started. It
  then sits in "recent activity". So IO only while an app plays also keeps the indicator off
  when nothing plays.
- **CPU:** a tapper with IO and the Goertzel detector used 0.06 s of CPU per 10 s, about 0.6%
  of a core. With no IO it used 0.03 s, mostly startup. `coreaudiod`'s extra load was within
  its background noise (0.19–0.47 s per 10 s with or without a tap).
- **Unanswered:** behaviour with 32 taps and aggregates. That belongs to the load harness.

### Gate result

**The gate passes.** Items 1 and 2 have workable answers. A muted tap captured the probe at the
right frequency, and the loopback heard none of it: in every muted run, at launch included (3
of 3 runs, 0 frames).

Carry-overs into phase 1:

- **Level** depends on the output device: −74 instead of −60 on the 10-channel interface
  (finding 2.5). The level checks in the gates below use a 2-channel device until this is
  explained.
- **Denied permission** (not "never asked") is untested. The gates require positive proof
  (the self-test captures the probe), never the absence of an error.
- **The default output device has no ground truth** on this Mac, and neither do a
  `coreaudiod` restart, a device change, WKWebView, speech or `NSBeep`. (Later found: the UA
  interface loops its output back on two of its inputs, and the mute holds there; see
  [Open questions resolved](#open-questions-resolved).)

## Phase 1 results

Measured on the same Mac (macOS 27.0.1) on 2026-11-23, through the real daemon unless noted.

### As built

- **Files.** `Sources/backstage/AudioTaps.swift` (the tap manager, in the daemon),
  `Audio.swift` (the published file formats, `audio`, `wait --sound`, `doctor`'s request,
  `launch`'s checks, the ring reader and FFT), `AudioHAL.swift` (Core Audio helpers, the probe
  tone, the responsibility and TCC-preflight lookups), and the C target
  `Sources/CBackstageAudio` (the IOProc and the crash handler, so neither allocates, locks or
  touches the Swift/ObjC runtime).
- **Queues.** `tapQueue` (user-interactive) makes every tap, aggregate and IO call and runs the
  process-list, is-running, tap-format and service-restarted listeners, plus a 50 ms timer
  (IO backup, liveness every 0.25 s, a rescan of unmatched audio clients every 0.5 s).
  `ioSetupQueue` creates IOProcs and runs the self-test. `workerQueue` is the 20 Hz worker:
  it drains the IOProcs' per-buffer stats (peak, sum of squares, first/last frame above the
  floor), keeps levels and `sounds`, writes the files and caches the menu bar's levels
  (`AudioLevelSource.currentLevels()` returns that cache; the main thread never touches Core
  Audio). The main thread only hands over registry snapshots after good reads. The test
  daemons logged no slow ticks. The user's own daemon, running an early phase 1 build while
  driving a UI-test app that played audio, logged 13 slow ticks of 0.50–0.88 s in 5 minutes
  (none in the 28 minutes the previous build drove the same app); not yet attributed (the
  tick makes no audio calls; AX calls into the busy app are the likely cost).
- **Matching.** A new audio client is the app's if its PID is a managed app, a descendant of
  one (parent chain), a process macOS holds one responsible for, or carries a pending launch's
  `BACKSTAGE_LAUNCH_ID`, itself or on its responsible process (the topmost process with that
  token is the app, tapped before registration). A newly registered app triggers a rescan of
  unowned clients at once. A client with a token whose launch record is gone makes the manager read
  `apps.json` itself (the launch just registered it; the daemon's view can be a tick behind).
- **Handover.** An app seen registered, missing from a good registry read and still alive is
  confirmed with one more direct read before its tap is destroyed: a read error never unmutes.
  `show` waits for the app's published file to go and then says `"audio": "unmuted"`.
- **IO** starts from the `kAudioProcessPropertyIsRunning` listener (it fires for raw HAL IOProc
  clients too; `IsRunningOutput`'s never did), with the 50 ms timer as backup, and stops 1 s
  after output stops. IOProcs are created only once capture is known to be granted (TCC
  preflight, or `doctor`'s self-test), so an app's sound never raises the System Audio
  Recording prompt: only `doctor` does.
- **Failures.** A client already running output when first seen, or a tap/aggregate/modify
  error, marks the tap `failed`, publishes the reason (with the launch ID, so a waiting
  `launch` fails at once with it) and quits the app (gracefully, then after 1 s forcefully).
  A fatal signal in the daemon SIGKILLs every app and helper in a fixed PID table (checked
  against start times) on an alternate stack before re-raising. The test hook
  `BACKSTAGE_TEST_AUDIO=mute-fail|tap-fail|no-capture` (set for the daemon) simulates the
  failure paths. `backstage __audio-taps` runs the tap manager alone (no display), for
  diagnosing audio.

### The ring file (`audio/<pid>-<birth>.pcm`)

For phase 3's `audio record`. Also documented in `CBackstageAudio.h`, the source of truth.
Mode 0600, created at the app's first sound (first IO start), removed with the tap. A 64-byte
little-endian header, then `capacityFrames × channels` float32 samples, interleaved:

| Offset | Type | Field |
|---|---|---|
| 0 | 4 bytes | magic `BSAR` |
| 4 | uint32 | version, 1 |
| 8 | float64 | sampleRate (the tap's) |
| 16 | uint32 | channels (2: stereo mixdown) |
| 20 | uint32 | capacityFrames (15 s) |
| 24 | uint64 | framesWritten: total frames ever written; frame k is at index k % capacityFrames. Written last, with release ordering |
| 32 | uint64 | endHostTime: mach_absolute_time just after the newest frame |
| 40 | float64 | endUptime: the same in seconds, the clock of `audio`'s `time` and `--since` |
| 48 | float64 | levelGain: the multichannel compensation applied to levels (not to the samples) |
| 56 | uint64 | reserved |

The timeline is continuous: when IO restarts after a pause, the daemon first writes the pause
as zeros (up to 15 s), so the newest frame ends at `endUptime` and the frame `j` before it
started at `endUptime - (j + 1) / sampleRate`. Nothing played after `endUptime`. A reader
reads `framesWritten`, copies, and reads it again; if it advanced by more than
`capacityFrames` minus the frames copied, the copy was overwritten and must be retried
(`readRing` in `Audio.swift` does this).

### Measurements

| What | Result |
|---|---|
| Sight-to-mute (process object seen → tap and aggregate in place) | median about 16 ms, 13–89 ms over 24 first taps (a helper added to an existing tap: 2.8 ms) (daemon and manager harness); matching took 0.4–7.6 ms of it, the rest is coreaudiod creating the tap and aggregate |
| Leak, on-sight, from the first line, against the `ZoomAudioDevice` loopback | **0 frames in 13 of 13 runs** (6 through the manager harness, 6 in two `tests/audio.sh` runs, 1 with two helpers) (pending-launch token path; first HAL call to output start 35–145 ms). Negative control heard 2,398 frames of a 50 ms unmuted probe |
| Leak, fixture launched through `backstage launch` to the loopback | **not run here**: the fixture's Microphone access is undecided, and playing to a device with inputs would ask for it (below) |
| 100 ms burst, IO started by the is-running listener | one sound of 0.096 s at −60.0 dBFS, found by `wait --sound --since T` after it ended (also 97.3 ms of 100 captured in the thin-slice test) |
| 300 ms keyed bursts | 0.296–0.316 s each; peak −60.0 dBFS; `hz` 18500 and 19500 for two sessions at once, each reporting only its own |
| Helpers | two players spawned by one pending launch's process: both added to its one tap (the second by rewriting the tap's description in place, 2.8 ms after sight), 0 frames reached the loopback |
| Multichannel compensation | a stereo probe on channels 1–2 of the 10-channel UA interface: `outputChannels` 10, `levelGainDb` 14.0, peak −60.0 dBFS |
| Fixture launched through `backstage launch` (output-only device) | muted 20 ms after sight, 227 ms before the fixture's first render (it plays from its first line; its own startup takes that long) |
| `doctor`'s single-process self-test | captured at −60.0 dBFS on Mac Studio Speakers, IOProc setup 1.6–3.3 ms (grant already in place) |
| Daemon IO start | 3–17 ms |

### Open questions resolved

- **The −14 dB on multichannel devices: explained.** A stereo-mixdown tap averages the
  device's odd channels into left and its even channels into right. Measured on the
  10-channel UA interface with a raw IOProc player in the tapped process: the probe on channel
  1 only read −74.0 left / silence right; on 1–2 or 3–4, −74.0; on 1 and 3, −68.0; on all 10,
  −60.0. A non-mixdown device tap shows channels 1–2 at −60.0 and the rest silent, so the
  device really gets −60. **Compensation:** levels are multiplied by N/2 for the widest output
  device the app's processes run output on (`kAudioProcessPropertyDevices`), exact for stereo
  on one channel pair (what AUHAL, AVAudioEngine and AudioQueue do with a stereo stream);
  content spread over more channels reads high, by up to 20·log10(N/2). `audio` reports
  `outputChannels` and `levelGainDb` when it applies. **Floor: −80 dBFS** peak (compensated):
  a tap's silence is exact zero; −80 sits above the dither and denormals some "silent" apps
  emit, and holds a −60 dBFS stereo sound even uncompensated on devices up to 20 channels.
- **Microphone requests for output-only playback: found.** On macOS 27, `coreaudiod` asks TCC
  for the Microphone (a request, not a preflight) when a client **attaches IO to a device that
  has input streams**: `AudioDeviceCreateIOProcID` and `AudioDeviceStart` on `ZoomAudioDevice`
  (2 in) and the UA interface (8 in) each made one; on Mac Studio Speakers and the PA32UCDM
  monitor (0 in) none, with the IOProc never started too. AUHAL and AVAudioEngine first
  attach to the *default* output at `AudioComponentInstanceNew`, so on a Mac whose default
  output has inputs, every AUHAL/AVAudioEngine/AudioQueue player asks, whatever device it then
  picks (this is why the spike saw requests "to any device"); disabling AUHAL's input element
  changes nothing. (Measured: raw HAL IOProc, AUHAL with and without input disabled,
  AVAudioEngine; AudioQueue wasn't re-measured in phase 1.) An app launched through `open` is its own responsible process, so the
  prompt appears in its name; it is MPCut's prompt in the spike's logs (ad-hoc signed, no
  `NSMicrophoneUsageDescription`: a missing purpose string doesn't suppress it).
  - **The fixture** plays through a raw HAL IOProc on the chosen device, and refuses a device
    with inputs while its own Microphone access is undecided (`AVCaptureDevice`
    authorization status, which never prompts). `tests/audio.sh` plays to an output-only
    device. In a run of `doctor` and a tone launch with tccd's log streamed, there was no
    Microphone request from the fixture or backstage.
  - **The daemon's self-test** plays to an output-only device only (none: the self-test says
    so). Its tap-only aggregate's IOProc makes no Microphone request.
  - **Pre-granting:** macOS has no way to add an app to the Microphone list by hand; the
    decision comes from answering the prompt once. `tests/audio-leak.sh --grant-fixture-mic`
    launches the fixture (stable bundle ID `dev.backstage.testapp.audio`) to raise it on
    purpose; either answer works, since only the decision matters. An ad-hoc rebuild with a
    changed binary probably needs it again (finding 1.6).
- **Listener-driven IO start captures the first buffer: yes** (see the burst rows above).
- **A process tapping itself works**, so the self-test runs in the daemon alone.
- **The default output has ground truth after all, and the mute holds there** (2026-11-23,
  after the user heard a beep while the meter showed an `xctest` muted and playing).
  - **The instrument:** the UA interface returns its outputs 1–2 on its inputs 3–4 ("MON L/R",
    the monitor bus that feeds the speakers) and outputs 5–6 on inputs 5–6 ("VIRTUAL 1–2", which
    also reach MON at −57). An unmuted −60 dBFS probe on outputs 1–2 reads exactly −60.0 dBFS
    on inputs 3 and 4. Reading it needs the host's Microphone (herdr has it).
  - **Muted, nothing arrives:** best 18.5 kHz window −141 to −147 dB, 0 windows above −100,
    for a muted private tap plus tap-only aggregate on a raw HAL IOProc, AudioQueue,
    AVAudioEngine (also with an input tap, whose IO then ran through a `CADefaultDeviceAggregate`
    of the UA, as `xctest` built one), and AVPlayer, tapped on sight. It held with IO never
    started, with IO running, and after IO stop/start cycles. Through `backstage __audio-taps`
    and a pending launch's token, a player of two bursts 1.6 s apart: 0 windows without
    measuring, and 0 with it (the second burst after the tap's IO had stopped), with the
    listener checked to cover both bursts.
  - **The incident:** `coreaudiod` logged `HALS_Client::AddMuter: Process
    com.apple.dt.xctest.tool … muted by backstage-67890 … for all devices` when the tap was made
    and no `RemoveMuter` before the process exited. Its AudioQueue (FigPlayer) and
    AVAudioEngine output went to the UA, in-process, and were captured by the tap. The only
    other output started on the UA in that minute was `systemsoundserverd` playing the user's
    alert sound (`actionID 4096`, at the alert volume): eight times for two
    UserNotificationCenter dialogs that took focus 9–14 s before the meter came on, and once
    for **`xctest` itself** (`inClientPID 67890`, an `NSBeep`/alert-sound request) 20 s after
    it went off. Those bypass any tap (finding 6). Overlapping the meter's window: only the
    muted `xctest`, plus a client that had kept the UA running for hours (`pmset` showed a
    2 h 22 m UA context; DaVinci Resolve reported running output). Also running: a
    ScreenCaptureKit session with audio in `replayd` for 8 h (its client unattributed;
    `xctest`'s own log said "screen sharing is active"). Captures like that are taps, which
    carry an app's audio from before the mute (finding 4); they don't play it on the Mac (the MON
    inputs stayed silent while it ran), but anyone listening through a remote session, stream or
    recording hears muted apps. Which of these the user heard is not settled.
  - **Regression check:** `tests/audio.sh` finds such an input on the default output (unmuted
    probe within 3 dB of −60) and runs the two-burst leak check there, without IO and with it;
    it skips when there's no such input or the host's Microphone isn't granted.
  - **Follow-up:** the capture spike below measured that muted apps reach system-wide captures
    such as Parsec's.

### Capture spike: muted apps in system-wide captures (2026-11-23)

The question was whether any mute keeps an arbitrary app's audio out of other clients' captures:
ScreenCaptureKit audio, global taps and device taps. The trigger was the user hearing agent apps
through Parsec while the Mac's own outputs stayed silent. Throwaway programs are in
`/tmp/bs-capture-spike` (`spike.swift`, `run.sh`).

**Setup:**

- **The probe:** 20.75 kHz, −60 dBFS, 0.8 s, from a raw HAL IOProc on the UA's outputs 1–2. 18.5
  kHz collided with another agent's `tests/audio.sh` run in parallel.
- **Four observers ran at once, each in its own process:**
  - an unmuted private global tap (`initStereoGlobalTapButExcludeProcesses: @[]`);
  - an unmuted UA device tap (`initExcludingProcesses: @[] andDeviceUID:`);
  - an `SCStream` of our own, with a main-display filter that excludes nothing, `capturesAudio`
    and `excludesCurrentProcessAudio = NO` (see the side note below);
  - the UA's MON loopback as ground truth.
- **The muter** was a separate process, as in backstage.
- **The floor:** the taps and SCK read 0 non-zero samples with no probe. MON read −142 to −147 dB.
- **Levels:** the taps read −74.6 for a −60 probe because of the 10-channel mixdown (see the
  −14 dB item above).

| Variant | MON (ground truth) | Global tap | Device tap | SCK |
|---|---|---|---|---|
| Control, no mute | −60.0 | −74.6 | −74.6 | −74.6 |
| backstage's mute (`CATapMuted`, private, stereo mixdown, private tap-only aggregate), made before the observers | silent | −74.6 | −74.6 | −74.6 |
| the same, made after the observers | silent | −74.6 | −74.6 | −74.6 |
| the same, with its IO running | silent | −74.0¹ | −74.0¹ | — |
| a public tap | silent | −74.6 | −74.6 | −74.6 |
| a device and stream tap (`initWithProcesses:andDeviceUID:withStream: 0`) | silent | −74.6 | −74.6 | −74.6 |
| `CATapMutedWhenTapped`, read by its aggregate's IO | silent | −74.6 | −74.6 | −74.6 |
| a muted tap with no aggregate | −60.0, not muted | −74.0¹ | −74.0¹ | — |
| undocumented `'pomt'` set to 1 on the app's process object from another process, no tap | silent | −74.6 | −74.6 | −74.6 |
| the app sets its own `kAudioDevicePropertyProcessMute` = 1 | −78.2 in one 100 ms window at start, then silent | −103.7, one window | the same | the same |
| **the app sets its own `kAudioHardwarePropertyProcessIsAudible` = 0** | silent | **absent (0 samples)** | **absent** | **absent** |
| the same, set by an injected dylib (`DYLD_INSERT_LIBRARIES`), plus backstage's mute with IO | silent | absent | absent | absent; **backstage's own tap also read 0 samples** |

¹ From the earlier 18.5 kHz runs, before the frequency change.

1. **No universal fix exists.** Order doesn't matter. Neither does muted vs muted-when-tapped,
   private vs public, or mixdown vs device and stream.
   - Every tap mute stops the app at the device stage only. Every other client's tap reads the
     app's stream before that point, at full level.
   - `'pomt'` behaves the same way.
   - Global "exclusive" taps exclude only the processes their *creator* lists.
2. **HAL process properties.**
   - **The scan:** every selector `[a-z][a-z?#!]{3}` was tried on another process's audio
     object (635k calls, 20 s). It found `bcls clas oplg ownd patk pbid pdv# pimt piri piro pir?
     pomt ppid prdi prti stdv`. Only `pimt` and `pomt` are settable.
   - **`'pomt'`:** any process can set it, with no permission. It mutes at the device like
     `CATapMuted`, with no tap or aggregate.
   - **`'pomt'` outlives its setter:** the setter exited 0.5 s before the playback, and the
     playback was still silent.
   - **`kAudioHardwarePropertyProcessIsAudible`** exists only on the system object, and only
     for the calling process. A PID or process-object qualifier is ignored: a set returned 0,
     and the target still reached MON at −60. The process object doesn't have it.
3. **Only the app itself can keep its audio out of captures,** with
   `kAudioHardwarePropertyProcessIsAudible = 0`. This zeroes the audio in the client, before any
   tap.
   - Every tap goes silent, backstage's included, so `audio`, `wait --sound` and `audio record`
     would see silence. Capture silence and metering exclude each other.
   - **Getting an arbitrary app to set it** takes code injection. A one-function
     `DYLD_INSERT_LIBRARIES` dylib with a constructor did it for our ad-hoc probe.
   - **Where injection works:** `xctest` is ad-hoc signed with `get-task-allow` and no
     hardened runtime, so it would work for the incident's app and most local debug builds.
   - **Where it doesn't:** hardened-runtime apps without
     `com.apple.security.cs.allow-dyld-environment-variables`, and Apple's platform apps. So it
     isn't universal.
4. **Parsec uses ScreenCaptureKit, and SCK audio is a global process tap.**
   - **Parsec:** `parsecd` loads `~/.parsec/parsecd-150-105c.dylib`, which links
     ScreenCaptureKit and implements `SCStreamOutput`. Parsec's log shows `acapture =
     screen_capture_kit` at every host start, the last at 09:58:52 today, matching `replayd`'s
     session. No Parsec audio driver is installed.
   - **SCK:** `replayd` builds SCK audio with
     `newAudioTapForSystemAudioCapture:withIncludedPidsList:withExcludedPidsList:…`, either as a
     "system tap" with excluded PIDs or as a "process tap" with included PIDs. Its tap is
     private: our `kAudioHardwarePropertyTapList` was empty.
   - **What our own `SCStream` showed:** it caught a windowless probe at −74.6, exactly what the
     global tap read, so a display filter's audio is system-wide.
   - **Who can exclude an agent app:** only the capturer, by naming it in
     `excludingApplications`.
5. **Side note on `excludesCurrentProcessAudio = YES`:** it also dropped our probe, a *sibling*
   process with the same responsible process (herdr). SCK apparently excludes the capturer's
   whole host, not just its PID: `replayd` computes "hostProcessIds", and this was seen once.
   A test of SCK capture must turn the option off.
6. **Parsec was undisturbed.** Its log shows no capture errors across the runs. Every tap,
   aggregate and stream was destroyed, and no spike process remains.
   - **One unexplained run:** in the first device-and-stream-tap run, the player's
     `AudioDeviceStart` returned 5.4 s late, 0.15 s after the muted tap was destroyed. It wasn't
     reproduced in two later runs.

### Inaudible launches (built 2026-11-23)

The capture spike's last row, turned into the default. Files: `Sources/BackstageInaudible/`
(the library), `Sources/backstage/Inaudible.swift` (modes, eligibility, confirmation).

- **The library:** `libbackstage-inaudible.dylib`, one constructor. It sets
  `kAudioHardwarePropertyProcessIsAudible = 0` on the system object before the app's own code
  runs; if Core Audio isn't reachable it retries every 100 ms for 10 s, and it sets it again
  after a `coreaudiod` restart (`kAudioHardwarePropertyServiceRestarted`; untested, needs root).
  It writes nothing to the app's output. The launched process acknowledges the result in a
  file `launch` names (`BACKSTAGE_INAUDIBLE_ACK`, removed from its environment so children
  don't). `make build` rebuilds it universal (arm64, x86_64) and ad-hoc signs it: dyld
  terminates a process whose inserted library can't load (measured: a missing path exits 134),
  so an x86_64 child under Rosetta needs its slice. `make install` puts it in
  `$(PREFIX)/lib/backstage/` by rename (running apps have the old one mapped); backstage looks
  next to itself first (the build directory, the test copies in `/tmp/backstage-test-*`).
- **Eligibility,** checked on the real executable (the bundle's `CFBundleExecutable`, or the
  bare executable the wrapper's symlink points at). Measured with throwaway binaries:
  - ad-hoc, unsigned: loads.
  - hardened runtime alone, or with only `allow-dyld-environment-variables`: dyld silently
    ignores the variable (not fatal). With `disable-library-validation` as well: loads.
  - So eligible = a Mach-O with a slice the library has, not SIP-protected or a platform
    binary, not setuid, no `__RESTRICT`/restrict flag, hardened only with both entitlements,
    no library validation, and a dev build: not Apple, Developer ID or Mac App Store signed
    unless it has `get-task-allow`. Scripts aren't: `/bin/sh` and `/usr/bin/env` pass no
    DYLD variables to their children (measured), and neither do other platform binaries.
  - On this Mac: the fixture (swiftc, ad-hoc), `xctest` (ad-hoc, `get-task-allow`, universal)
    and wrapped bare executables are eligible; Calculator (SIP), Xcode (Mac App Store),
    Firefox, Chrome, Ghostty (Developer ID) and a fixture copy signed `--options runtime`
    aren't.
- **Delivery:** LaunchServices passes `DYLD_INSERT_LIBRARIES` through
  `_kLSOpenOptionEnvironmentVariablesKey` (measured: the constructor ran and the library was
  mapped). The `launch` wrapper is a symlink, so nothing strips it.
- **Confirmation.** After identifying the process, `launch` waits up to 2 s for its
  acknowledgement of Core Audio success. A missing or unsuccessful acknowledgement falls
  back to `muted` with the reason. With `--inaudible`, the app is quit and the launch fails.
- **Cost per injected process:** about 30 ms at start (connecting to Core Audio: 1.4 ms →
  31.9 ms per spawn of a trivial binary; loading CoreAudio alone is about 3 ms, and nearly
  every process loads it anyway, Foundation included), and the process becomes an audio
  client, so it's tapped. 40 injected children of an injected parent: none failed. The tap
  manager now retries a tap update without clients that are gone instead of failing the app.
- **Modes:** `"audio": "inaudible" | "muted" | "metered"` in `launch` and `list`, with
  `audioReason` when not inaudible. The tap stays on inaudible apps (belt and braces).
  Unmetered apps' taps never run IO, so an inaudible app's silent tap can't produce false
  results, and no recording indicator shows. The audio commands refuse unmetered apps before
  the permission check. Daemons from before modes measure everything; `launch` then adds
  `audioWarning`.
- **Measured** (fixture, 20.25 kHz −60 dBFS probe from its first line, 3 s observers started
  before launch; `tests/audio.sh`):

  | Launch | Unmuted global tap | Our SCStream (`excludesCurrentProcessAudio` off) | Tap IO |
  |---|---|---|---|
  | default (`inaudible`) | 0 tone windows, 0 non-zero frames | 0 tone windows, 0 non-zero frames (157 buffers) | never started |
  | `--audio` (`metered`) | 16 windows, −60.1 dBFS | 12 windows, −60.1 dBFS | on while playing |

### Phase 1 gate

| Item | Status |
|---|---|
| 0 frames leak through a Backstage launch from the first line; sight-to-mute recorded | Sight-to-mute recorded (above). 0 frames in 13/13 on-sight runs of a first-line player matched by its launch token, through the daemon. The fixture-through-`launch` variant is **pending** the fixture's one-time Microphone decision on this Mac (`tests/audio.sh` runs it once decided) |
| Two sessions, two frequencies, each `audio` its own | Pass |
| 100 ms burst = one sound of about that length; `--since` finds it after it ended; first buffer captured | Pass (0.096 s) |
| Levels explained on a multichannel device; floor and docs reflect them | Pass: explained, compensated, floor −80 dBFS |
| `launch` refuses when muting can't be set up; a later tap failure quits the app and shows `failed`; `doctor` reports host and self-test | Pass (simulated failures through `BACKSTAGE_TEST_AUDIO`) |
| Fixture raises no Microphone prompt, or the docs say how to pre-grant | Pass: no request at all on output-only devices; pre-granting documented for loopback runs |
| Leak suite passes on the dedicated Mac | **Pending**: `tests/audio-leak.sh` written; it refuses without `--dedicated` and a loopback as default and system output |
| No slow ticks; existing suites pass, with and without the permission | Pass with the permission (`make test`); without it, `tests/audio.sh` covers launch, `audio` and `doctor` via `BACKSTAGE_TEST_AUDIO=no-capture` |

Still untested: a `coreaudiod` restart (the listener rebuilds every tap), an output device change
(a tap-format listener restarts IO), the explicitly denied permission state, WKWebView,
Electron, speech and `NSBeep` routing, 32 taps. The dedicated-Mac suite covers the first and
the audible sources.

## Mechanism: one muted process tap per app

- **One tap per managed app, inside its own private, tap-only aggregate.** The tap lists that
  app's own process objects: `CATapMuted`, private, stereo mixdown. The aggregate is part of
  the mute: without it the tap doesn't mute. Taps aren't device-specific, so an app that picks
  its own output device is still covered (measured on a non-default device).
- **Per process, so per session.** The user's apps, their copy of the same app, the default
  output device and the system volume aren't touched. Two sessions running the same app get
  separate taps, which is why metering can't use bundle-ID taps.
- **The app doesn't notice.** A muted app's playback advances in real time (measured).
- **No driver.** Nothing is installed.

Rejected:

- **A virtual output device driver** (BlackHole-style). It needs an admin install, and macOS
  has no per-app output routing, so using it means changing the user's default output. A
  loopback device is used in tests only, as a measuring instrument.
- **ScreenCaptureKit audio.** It captures an app's audio but can't mute it.
- **`tapautostart`.** It delays the app's own output start by 0.2–0.3 s.
- **An aggregate clocked by the real output device.** It pulls in that device's inputs (and
  Microphone requests), starts slowly, and has to be rebuilt on device changes.

## Design

**The daemon owns the taps**, because muting must outlive each CLI command. Core Audio calls
are synchronous and can block, so the tap manager runs on its own queue, never on the 50 ms
guard tick.

- **IOProc setup blocks during a prompt.** The first `AudioDeviceCreateIOProcIDWithBlock` can
  block for as long as a permission prompt is on screen (6 s measured), so IO setup gets a
  queue of its own.
- **The grant comes from the daemon's host.** The daemon's permission is that of the host
  that spawned it (responsibility is inherited through `posix_spawn`). With several agent
  hosts, the first to start the daemon decides. `doctor` reports which host that is
  (`responsibility_get_pid_responsible_for_pid` on the daemon). A helper `.app` with a stable
  identity remains the fix if this proves confusing (finding 1.9).

**Which processes.** The manager listens to the process-object list. A new audio client is
added to an app's tap (by rewriting the tap's description in place) when its PID is:

- a managed app, or a process carrying a pending launch's `BACKSTAGE_LAUNCH_ID`;
- a descendant of one (Chromium and Electron audio helpers are children); or
- a process macOS holds one responsible for. Measured: the private
  `responsibility_get_pid_responsible_for_pid` maps a Chrome helper to Chrome, and an XPC
  service with parent PID 1 (`QuickLookUIService`) to its host app. WebKit's GPU and
  WebContent services should map the same way; none was running to check.

**Tap on sight, not on registration.** The manager matches new audio clients against the
pending launch records (`launching/<id>.json`). It creates the tap and its aggregate before
registration.

- **The spike's margin:** the process object appears tens of milliseconds before the first
  render. The spike muted in 11–12 ms and leaked nothing.
- **What eats the margin:** the daemon's matching step (reading the process's environment for
  `BACKSTAGE_LAUNCH_ID`). Phase 1 measures its sight-to-mute time against the loopback.
- **Helpers:** the same applies each time a helper first appears.

**Mute first, then meter.** Creating the tap and aggregate needs no permission and starts no
IO. That is the whole mute, so it never waits on TCC.

**When IO runs.** IO runs only while one of the tap's processes is running output.

- **Trigger:** a listener on `kAudioProcessPropertyIsRunning`, which fired at the start and
  the end in the spike. Confirm with `kAudioProcessPropertyIsRunningOutput`, which has to be
  polled because its listener never fired.
- **Start and stop:** `AudioDeviceStart` (5 ms) on true, and stop on false.
- **Why:** the spike captured every frame this way. It also keeps the system's audio-recording
  indicator off while no agent app is playing.
- **If phase 1 can't make the listener path capture the first buffer reliably,** IO runs for
  the tap's whole life. The indicator then shows for as long as any agent app has audio open.

**If muting can't be set up, `launch` refuses** (user decision). Before starting the app,
it refuses with exit 1 and `{"ok": false, "error": …}` when:

- macOS is older than 14.2: "audio muting needs macOS 14.2 or later";
- the daemon's tap manager isn't healthy (it failed to start, or its mute self-test failed).

A missing System Audio Recording grant is *not* a refusal case (see User decisions). The
self-test reports it, `doctor` shows it, and the `audio` commands fail with that reason.

**Failures after `launch` returns.** Taps are created on sight, so most tap failures come
after `launch` has returned, often when the app first plays. That covers a tap or aggregate
creation error, or a client that isn't muted before the phase 1 deadline. Then the daemon:

- quits the app at once (same path as `stop`);
- records the reason (OSStatus as four characters, or the measured sight-to-mute time);
- reports it from `audio` and `list` as `"tap": "failed"` with a `reason`.

A failure that happens while `launch` is still waiting makes `launch` itself fail with that
error.

The error names the host to grant in System Settings › Privacy & Security › Screen & System
Audio Recording › System Audio Recording Only, and says to run `backstage doctor`.

**`doctor`** asks the daemon to run the self-test (finding 1.8) and reports:

- `granted`, `not granted` or `prompting`;
- the daemon's responsible host;
- whether a muted tap captured the probe, and at what level.

Until the denied state is observed, anything but a captured probe counts as not granted.

**Measuring.** The IOProc does two things per buffer, with no allocation, locks or
Objective-C: block peak and sum of squares, and a copy into a preallocated ring. A 20 Hz
worker does the rest: sound start/stop, levels, and the published files below. Levels are
"tap level". Phase 1 must explain the −14 dB on multichannel devices and either compensate
(from the tapped process's output device, `kAudioProcessPropertyDevices`) or document it.

**Publishing.** There's no CLI-to-daemon request channel and this doesn't add one. Per app,
the daemon atomically rewrites `audio/<pid>-<birth>.json` on each change and while there's
sound. It keeps the last 15 s of samples in `audio/<pid>-<birth>.pcm` (about 6 MB, created at
the app's first sound, removed with the tap, mode 0600 like logs). The CLI reads both. It
computes the dominant frequency and writes WAVs itself. (`doctor`'s self-test request is the
one exception: it can use a trigger file the daemon watches, like the registry.)

**`show` unmutes.** Handing an app to the user destroys its tap, so they hear it. The result
says so.

**Teardown and failure.**

- **Normal stop.** Quit the app, wait for it to exit, then destroy its aggregate and tap. A tap
  is never removed from a live app, except by `show` (destroying it unmutes within about 10 ms).
- **Daemon crash.** A fatal-signal handler kills the managed apps from a preallocated PID
  table (`kill` is async-signal-safe) before the daemon dies. This also stops windows falling
  onto the user's screen.
- **`kill -9`.** Nothing can run, and the apps are audible about 2 ms later (measured) until
  quit. It's the same class of limit as their windows moving to the main screen today.
  Document it.
- **`coreaudiod` restart.** Rebuild every tap on `kAudioHardwarePropertyServiceRestarted`.
  Sound may be heard until then (untested).
- **Output device change** (headphones, Bluetooth, AirPlay). A tap-only aggregate has no
  device clock, so only the tap format may change. Listen for `kAudioTapPropertyFormat` and
  restart IO (untested).

## Agent-facing commands

Scoped to the session and targeted with `--pid`/`--app` like every other command. Exit status
0, or 1 with `{"ok": false, "error": "…"}`. No new exit codes.

| Command | Does |
|---|---|
| `audio` | Status of the app's audio |
| `wait --sound [--gone] [--since T] [--min-db D] [--timeout S]` | Blocks until sound is playing, or with `--gone`, has stopped |
| `audio record [-o out.wav] [--seconds N]` | WAV of the last N seconds (default and maximum 15). Without `-o` it goes to the session's folder, like screenshots. Returns `path`, `seconds`, `sampleRate`, `channels`. |

```json
{"pid": 80562, "tap": "muted", "processes": [80562, 80571], "ioRunning": true,
 "playing": true, "peakDb": -6.1, "rmsDb": -9.0, "hz": 440,
 "sampleRate": 48000, "channels": 2, "time": 81234.52,
 "sounds": [{"start": 81232.21, "seconds": 2.31, "peakDb": -6.0, "rmsDb": -9.2, "ongoing": true}]}
```

- **`tap`** is `muted`, `armed` (the app hasn't used Core Audio yet) or `failed` (with a
  `reason`; the daemon has quit the app). There is no `unavailable`: a launch that can't be
  muted is refused.
- **`ioRunning` and `playing`** separate three cases: no audio output at all, output running
  but silent, and sound.
- **`playing`** means the peak was above a fixed floor within the last 0.3 s. The daemon
  splits `sounds` at the same floor. `wait --min-db D` counts only a sound whose peak reaches
  D.
  - The floor is −80 dBFS on compensated levels (phase 1; the draft's −70 was too high for
    multichannel devices, finding 2.5).
- **Levels and `hz`** cover the last second. `hz` is the strongest frequency: useful for
  tones, close to meaningless for music or speech.
- **`sounds`** are the last 16 stretches of sound. They replace the draft's `audio reset`:
  shared counters would race between a session's subagents, and a list needs no reset.
- **`time`** is system uptime, the clock `--since` uses.

`wait --sound` is a mode of the existing `wait`, not a new command: same `--gone`,
`--timeout` (default 10 s) and `seconds` in the result. `--text` and `--sound` can't be
combined.

- **Short sounds.** A click sound can end before `wait` starts. With `--since T`, a sound
  that started at or after T counts even if it's over. The pattern: read `time` from `audio`,
  act, then `wait --sound --since T`.
- **Result:** `{"ok": true, "sound": {…}, "seconds": 0.42}`. With `--gone`, `sound` is the
  one that just ended.
- **Timeout:** exit 1, and the error says which case it was: "no audio output running",
  "output running but silent", or "peak −82 dBFS, below the floor".

Cut from the draft: `audio waveform` (ffmpeg draws one from the WAV), `audio reset`, the
clipping count, and recording forward in time.

## Menu bar

- **The icon becomes the meter.** While any managed app is making sound, the status item's
  icon is replaced by five rounded bars in the same box. The app count stays beside it. The
  item's width never changes, so nothing in the menu bar moves when a sound starts or stops.
- **It shows the real signal.** The bars are the last five level readings, newest on the
  right, on a −60 to 0 dBFS scale. Loudest app wins.
- **Template drawing**, so it follows light, dark and tinted menu bars.
- **Low cost.** A 12 fps timer runs only while there's sound and stops 1 s after silence,
  when the icon fades back.
- **Reduce Motion:** a static `waveform` symbol replaces the animation.
- **VoiceOver:** the item's label gains "playing audio, muted", updated on state changes
  only. The tooltip names the app.
- **In the menu:** each app's line gets a speaker symbol and "playing" or "silent", refreshed
  by the existing 1 s timer.
- macOS shows its own audio-recording indicator, attributed to the daemon's host, while IO
  runs (finding 9). Backstage's meter appears at the same times.

## Phase 0: spike (done 2026-11-23)

Answered in [Spike findings](#spike-findings). The throwaway programs are in
`/tmp/bs-audio-spike`: `main.swift` holds the `tone`, `tap`, `loop`, `info` and `preflight`
subcommands, and `mute.sh`, `gap.sh`, `watch.sh`, `fail.sh` and `route.sh` hold the scenarios.
Every tap and aggregate was destroyed by its owner, or died with it. No spike process
remains (`pgrep`). Private taps can't be listed from another process, so the check is the
processes. The two wrapper `.app`s were unregistered from LaunchServices and deleted.

Still open, for phase 1 or the dedicated Mac:

| Question | Why open |
|---|---|
| Denied-permission behaviour (capture silence? mute still holds?) | Nobody clicked Don't Allow on an audio capture prompt. The "never asked" case was tested. |
| Microphone requests from launched apps' playback (finding 1.6) for bundled, signed apps | **Resolved in phase 1**: any client attaching IO to a device with inputs; bundled ad-hoc apps prompt too. Developer ID apps: still unseen |
| The −14 dB level on the 10-channel device | **Resolved in phase 1**: stereo mixdown averages odd/even channels |
| Listener-driven IO start capturing the first buffer | **Resolved in phase 1**: it does |
| `doctor`'s single-process self-test | **Resolved in phase 1**: it works |
| Default output device ground truth | No loopback is the default here |
| `coreaudiod` restart, output device change | Need root, or changing the user's device |
| WKWebView, Electron, AVSpeechSynthesizer, `NSBeep` routing | No sound in a windowless host, or unsafe to play unmuted |
| 32 taps and aggregates | Load harness |

## Tests

**Probe tone.** The fixture gets `TESTAPP_TONE=<hz>`: a sine at −60 dBFS, 18 kHz or above,
keyed on and off in a fixed pattern with ramped edges (a hard edge clicks in the audible
band), starting before the app's first window. It's inaudible by construction, measurable
exactly, and unlike anything in the user's music. Two sessions use two frequencies.
`TESTAPP_TONE_DEVICE=<uid>` sends it to a given device instead of the default.

**What can observe the real output.**

- **Ground truth: a loopback device's input.** That is exactly what `coreaudiod` sent to the
  device. Reading it needs the Microphone permission for the reader's host.
- **On a desktop:** any loopback that isn't the default output (`ZoomAudioDevice` on this
  Mac, or BlackHole). The fixture plays to it with `TESTAPP_TONE_DEVICE`, so the user hears
  nothing whether or not the mute works. This proves the mute and the launch gap for an app
  that picks its device, which the spike showed is the same mechanism. It runs in
  `make test` when such a device exists.
- **On a desktop whose default output loops back on its own inputs** (a UA Apollo's "MON L/R"
  inputs 3–4): the probe player plays to the default output, and the leak check reads that
  input only, counting 18.5 kHz windows (the other inputs carry live signal). Inaudible either
  way. `tests/audio.sh` finds the input with an unmuted probe.
- **On the dedicated Mac or account:** a loopback driver as both default output and system
  (alert) output covers the default-device path, device changes and system sounds. The account
  must be the active console session, as for load runs: macOS may already silence a
  background session.
- **Not valid: taps.** A global or device tap carries the app's audio from before the mute
  (finding 4), and so does comparing against the muted tap.
  `kAudioDevicePropertyDeviceIsRunningSomewhere` is true whenever any process runs the device.

**Suites.**

- **`tests/audio.sh`, in `make test`.** The probe through Backstage: `audio`,
  `wait --sound`, `--gone`, `--since`, two sessions, `show`, `doctor`'s self-test, `launch`
  refusing when muting can't be set up, and `record` from phase 3. It never leaks on purpose.
  With a non-default loopback present, it also runs the leak checks against it.
- **`tests/audio-leak.sh`, dedicated Mac only.** Like the load harness, it refuses to run
  without `--dedicated` and a loopback as both default and system output.
  - **Negative test first.** The fixture plays a 50 ms probe burst with no tap. The watchdog
    must report it. A watchdog that misses this fails the suite.
  - **Then the same launch through Backstage:** the watchdog must report nothing.
  - **Then the failure windows and audible sources:** `kill -9`, a `coreaudiod` restart, a
    device change, speech, system sounds. These are measured and recorded against the
    documented limits, not required to be silent.

## Phases

### 1. Tap manager, `audio`, `wait --sound` (built; see [Phase 1 results](#phase-1-results))

Muting (tap + tap-only aggregate), on-sight tapping, helper mapping, IO on running output, the
published files, `doctor`'s self-test, `launch` refusal, `show`, teardown, the crash handler,
and both test suites.

**Gate.**
- On a non-default loopback, a fixture playing from its first line leaks 0 frames through a
  Backstage launch. The daemon's sight-to-mute time is recorded.
- Two sessions play different probe frequencies at once, and each `audio` reports only its
  own.
- A 100 ms probe burst is reported as one sound of about that length, and
  `wait --sound --since T` finds it after it has ended. The first buffer is captured with IO
  started on running output.
- Levels are explained on a multichannel device, or the floor and docs reflect them.
- `launch` refuses when muting can't be set up. A tap failure after `launch` returns quits
  the app and shows as `"tap": "failed"`. `doctor` reports the daemon's host and the
  self-test result.
- The fixture raises no Microphone prompt when launched, or the docs say how to pre-grant it.
- The leak suite passes on the dedicated Mac.
- The daemon logs no slow ticks, and the existing suites pass unchanged, with and without the
  permission.

### 2. Menu bar meter

**Gate.**
- The meter appears within 200 ms of sound and goes after it stops.
- The status item's frame is identical before, during and after.
- The daemon stays under 1% CPU while it animates.
- Reduce Motion shows the static symbol.

### 3. `audio record`, skill and docs

The skill learns the pattern: read `time` → click Play → `wait --sound --since T` → check
`audio` → click Stop → `wait --sound --gone`. The README's requirements gain macOS 14.2 and the
System Audio Recording permission for the terminal or agent host (separate from Screen
Recording, in the same Settings pane), and explain the host dependence.

**Gate.** The WAV of a probe has the right frequency, level and duration, checked with a tool
outside Backstage.

**Built 2026-11-23.** `audio record [-o out.wav] [--seconds N]` (`cmdAudioRecord` in
`Audio.swift`) returns `{"ok", "pid", "path", "seconds", "sampleRate", "channels", "format":
"float32", "start", "end"}`, plus `levelGainDb` on a multichannel device.

- **The WAV** is written by the CLI from the ring: 32-bit float (`WAVE_FORMAT_IEEE_FLOAT` with
  a `fact` chunk), the tap's samples unchanged. The plan applies `levelGain` to levels only, so
  the WAV isn't compensated, and the result reports the gain instead.
- **Which seconds.** The last N seconds of the ring, ending at its newest frame (`end`), as the
  ring format defines "the last N seconds". While output runs, that's now. After output stops
  (IO stops 1 s later), the WAV still ends there, so Stop → `wait --sound --gone` → record
  still holds the sound. `start`/`end` are on the `time` clock.
- **Full-ring reads.** `readRing`'s lap check had no slack for a read of the whole ring, so a
  15 s read of a playing app could never succeed. It now drops the oldest frames the writer
  may have overwritten during the copy (what it published, plus 0.1 s in flight unless it has
  been idle for 0.25 s), and retries only when the file was recreated or lapped entirely. A
  15 s read of a playing app gives about 14.9 s (measured), and a stopped one the full 15 s
  (by construction, not measured). The `levelGainDb` field is untested here: the test device
  is stereo.
- **Gate: pass** (`tests/audio.sh`, macOS 27.0.1, Mac Studio Speakers, 48 kHz). The 18.5 kHz,
  -60 dBFS, 300/700 ms probe recorded for 4 s. `afinfo` reports 2 ch, 48000 Hz, Float32 and
  4.000000 s. `tests/wavcheck.swift` decodes the WAV with AVAudioFile and analyses it with its
  own Goertzel scan, sharing no code with backstage. It found 3 whole bursts at 18500.0 Hz,
  peak -60.00 dBFS, RMS -63.01 dBFS (a sine's -3.01 dB), each 0.296 s long, with 1.18 s of
  tone in the 4 s. A 100 ms burst recorded after it ended was one 0.096 s burst at
  18500 Hz, 0 ms from where `wait --sound` placed it. 15 back-to-back full reads while the
  app played all succeeded, at 14.889–14.900 s, and the 15 s WAV held 15 bursts.

## Limits to document

- **System sounds.** `AudioServicesPlaySystemSound` plays through `systemsoundserverd`, which
  every app shares (measured), and so do alert sounds: a tapped `xctest` run through Backstage
  asked it for the user's alert sound (`actionID 4096`), which played on the default output
  at the alert volume (seen in `systemsoundserverd`'s log, 2026-11-23). Tapping it would mute
  the user's own alerts, so beeps stay audible and unmeasured. AppKit beeps on an unhandled
  keystroke, so agents can already cause this today.
- **Shared playback daemons.** The same may apply to speech (unmeasured).
- **Screen sharing, streaming and screen recording with audio carry muted apps at full level**
  (measured; see the [capture spike](#capture-spike-muted-apps-in-system-wide-captures-2026-11-23)).
  - **Who hears them:** Parsec, ScreenCaptureKit, OBS and anything else built on global or
    device taps. Muted apps stay silent on the Mac's own outputs, but anyone listening through
    such a capture hears them.
  - **No API fixes it from outside the app:** no tap kind or order, and no settable HAL
    property.
  - **What works:** only the app itself can stay out of captures, by not producing sound (its
    own mute switch, like MPCut's `MPCUT_MUTED=1`, passed with `launch --env`) or by setting
    `kAudioHardwarePropertyProcessIsAudible = 0` on itself. `launch` now makes eligible
    targets (dev builds, test runners) do the latter by default
    ([Inaudible launches](#inaudible-launches-built-2026-11-23)); signed, hardened and Apple
    apps, and any `--audio` launch, are still carried.
  - **The cost:** either way, `audio` and `wait --sound` then see silence, so they refuse
    inaudible launches.
  - **For the user:** pause the remote session's or recorder's audio while agents play sound
    from apps that can't be made inaudible.
- **`kill -9`** unmutes the apps within milliseconds, and a `coreaudiod` restart probably does
  too.
- **macOS 14.0 and 14.1** have no taps: `launch` refuses there.
- **The permission belongs to the daemon's host.** It's keyed to that host's binary path, so
  an upgrade of the host may need it granted again. The system's audio-recording indicator
  names that host while an agent app plays.
- **Apps under test may ask for the Microphone** the first time they play to a device with
  input streams, on macOS 27 (finding 1.6; the trigger is in Phase 1 results).

## Optional (only if something shows a need)

- **A helper `.app` owning the taps**, with a stable signing identity: if the host-dependent
  grant (finding 1.9) causes trouble.
- **Bundle-ID tap before launch** (macOS 26+): only if phase 1 measures a gap. Not for bare
  executables (finding 8).
- **A reaper process** that quits the apps when the daemon dies: only if `kill -9` turns out
  to matter in practice.
- **One shared aggregate for all taps:** only if load runs show per-app aggregates are too
  costly.
- **A per-app "Listen" toggle** in the menu, switching that tap to `CATapUnmuted`. Off by
  default and logged, like `show`.
- **`audio waveform`**, a spectrum, longer or forward recording.
- **Audio counters in the load harness.**
- **`launch --inaudible`: built**, and the default for eligible targets (see
  [Inaudible launches](#inaudible-launches-built-2026-11-23)). Inject a one-function dylib
  (`DYLD_INSERT_LIBRARIES`) that sets `kAudioHardwarePropertyProcessIsAudible = 0` in the app.
  The original note, from the capture spike:
  - **It works:** the app is absent from global taps, device taps and ScreenCaptureKit.
  - **The cost:** backstage's own tap reads silence too.
  - **Where it can run:** non-hardened binaries only. That covers `xctest`, ad-hoc and most
    debug builds. It can't reach hardened or Apple apps, so `launch` would have to refuse those
    or say it can't.
- **`'pomt'` as a second mute:** set it on each tapped process object as well as the tap. It is
  undocumented, but it needs no permission and outlives its setter (measured), so it could
  cover the daemon's `kill -9`. It would also outlive a `show` that forgets to clear it. Only if
  `kill -9` turns out to matter in practice.

## Out of scope

- **Speech-to-text and other content analysis.** `audio record` gives a WAV; the agent runs
  whatever tool it has.
- **Feeding audio into an app (microphone input).** That needs a virtual input device or the
  app's cooperation.
- **Permission prompts from the app under test.** A microphone or camera prompt appears on the
  user's screen. Backstage can't move system prompts. Suggest pre-granting, or test builds
  that skip the request.
- **Apps that take exclusive (hog mode) access to a device.**

## Delivery order

0. Spike: done. The gate passes with the carry-overs above.
1. Tap manager, `audio`, `wait --sound`, and both test suites: built; the dedicated-Mac leak
   suite and the fixture-through-launch loopback check are pending.
2. Menu bar meter.
3. `audio record`, skill and docs.
4. Optional items, each only when its trigger is met.
