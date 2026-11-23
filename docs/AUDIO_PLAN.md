# Audio support for Backstage

Give agents the same thing for sound that they have for windows. An agent can check that the
app it launched plays audio, while nothing comes out of the Mac's speakers or headphones. The
menu bar shows when an agent's app is making sound.

Agents don't need to "hear" anything. They need facts: did the app produce sound, when, for how
long, how loud, and did it stop. A WAV of the muted output covers everything else.

Nothing is built yet. The phase 0 spike ran on 2026-11-23 (macOS 27.0.1, Mac Studio) with
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
  `coreaudiod` restart, a device change, WKWebView, speech or `NSBeep`.

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
  - The draft's −70 dBFS floor is too high for multichannel devices (finding 2.5). Set the
    floor once phase 1 has settled level compensation.
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
| Microphone requests from launched apps' playback (finding 1.6) for bundled, signed apps | Only unsigned CLI binaries were seen |
| The −14 dB level on the 10-channel device | Cause unconfirmed |
| Listener-driven IO start capturing the first buffer | Only the poll-driven start was run end to end (4 of 4 captured) |
| `doctor`'s single-process self-test | Only the two-process form ran |
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

### 1. Tap manager, `audio`, `wait --sound`

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

## Limits to document

- **System sounds.** `AudioServicesPlaySystemSound` plays through `systemsoundserverd`, which
  every app shares (measured), and `NSBeep` and alert sounds presumably do too. Tapping it
  would mute the user's own alerts, so beeps stay audible and unmeasured. AppKit beeps on an
  unhandled keystroke, so agents can already cause this today.
- **Shared playback daemons.** The same may apply to speech (unmeasured).
- **`kill -9`** unmutes the apps within milliseconds, and a `coreaudiod` restart probably does
  too.
- **macOS 14.0 and 14.1** have no taps: `launch` refuses there.
- **The permission belongs to the daemon's host.** It's keyed to that host's binary path, so
  an upgrade of the host may need it granted again. The system's audio-recording indicator
  names that host while an agent app plays.
- **Apps under test may ask for the Microphone** the first time they play, on macOS 27
  (finding 1.6).

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

Idea only, not planned: have the app mute itself at launch
(`kAudioHardwarePropertyProcessIsAudible`, set from an injected library). It would close the
launch gap and survive the daemon, but only for apps that allow injection, and whether a tap
still captures such a process is unknown.

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
1. Tap manager, `audio`, `wait --sound`, and both test suites.
2. Menu bar meter.
3. `audio record`, skill and docs.
4. Optional items, each only when its trigger is met.
