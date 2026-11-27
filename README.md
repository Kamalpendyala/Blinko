# Blinko — blink reminder for macOS

Working name: **Blinko**. Native Swift menu bar app that watches blink rate
through the webcam and will nudge the user to blink. Local-first, sandboxed, no
networking code.

**Current status: Phase 0 (bootstrap) + Phase A (detection prototype) + Phase B
(reminders) + Phase C (scheduling & power) + Phase D (settings, persistence &
polish) + Phase E (20-20-20 eye breaks) implemented.** The camera runs in short
bursts — 12 s every 60 s by default — and is fully stopped in between, so the
camera indicator is dark most of the time. Settings, the guided calibration
baseline and daily aggregate counts persist in a versioned, atomic JSON store.
Phase E adds a camera-independent 20-minute break timer with a 20-second
look-away card, so eye breaks keep working even when camera access is denied.
Phase D is awaiting review and the manual checks in §“Phase D acceptance status”
(single instance, login item, 8-hour soak).

---

## What works today

- Camera → Vision landmarks → eye-openness ratio → blink state machine.
- Duty-cycled capture: one 12 s burst every 60 s by default, with the
  `AVCaptureSession` fully stopped between bursts. The cadence uses absolute
  monotonic deadlines and one tolerant timer; no per-second polling runs while
  the camera is off.
- Bursts are skipped while the screen is locked/asleep, the system is asleep,
  the user is idle (5 min), the battery is below 20 % and unplugged, Blinko is
  paused, quiet hours are active, or camera access is denied. A `ProcessInfo`
  activity assertion is held only for the duration of a burst.
- `BlinkGapPolicy`: if no blink is detected for 5 s while a face is visible, a
  reminder fires and repeats every 5 s until a blink resets the timer.
- `RateEstimator`: blinks per minute over valid-face seconds only, EMA-smoothed
  across 12 s bursts; bursts with under 3 s of valid face are discarded. Shown
  in the debug window as a diagnostic.
- Prominent non-activating reminder card centered on the active screen: large
  icon, bold title, accent border, never steals focus, clicks pass through,
  fades in/out gently, and hides as soon as a blink is detected (or after the
  configured auto-dismiss duration, default 2.5 s).
- **Blink Interval** and **Dismiss After** menu-bar submenus with presets plus
  a **Custom…** numeric field, so both timers can be changed without restarting.
- One-click **Pause Blinko / Resume Blinko**; nothing fires while paused.
- **Quiet Hours (22:00–08:00)** menu toggle. Off by default in this tuning
  build so the 5 s reminder is easy to observe.
- **20-20-20 eye breaks**: a camera-independent timer (default every 20 min)
  shows a static “look ~20 feet away for 20 seconds” card for 20 s. It works
  when the camera is denied, is not dismissed by a blink, and never catches up
  on breaks missed while paused, asleep or in quiet hours.
- Debug window with live openness trace, baseline/threshold lines, blink count,
  valid-face percentage, smoothed rate, seconds since the last blink, nudge
  count, sampling countdown, current suppression reason, **Sample Now** and
  **Preview Nudge** buttons.
- Replay harness that runs a recorded landmark CSV through the same pipeline.
- Debug-only landmark CSV recorder (derived eye points only — never pixels).
- **Settings window** (menu bar → **Settings…**, ⌘,) with validated controls for
  pause, sound, login item, burst/interval, idle and battery thresholds, reminder
  timing, quiet hours, calibration and data deletion. Invalid values are rejected
  inline with a reason (DB-05).
- **Guided calibration**: a 5 s open-eye burst computes the median baseline and
  seeds the detector; the baseline and date persist across launches.
- **Versioned JSON store** in Application Support with atomic writes, serialized
  writers, v1→v2 migration, one aggregate row per day, and `0600` permissions.
  Only settings and daily counts are stored (DB-01…07).
- **Single-instance guard** (AP-01): a second launch asks the running instance to
  open Settings via `blinko://settings` + a distributed notification, then exits.
- **Login item** via `SMAppService.mainApp` (AP-02), with the real status shown in
  Settings; no executable path is persisted.
- **Delete all data** restores defaults and empties the store (DB-06).
- Menu bar item (`LSUIElement`), no Dock icon, sandboxed with camera access.
- 87 unit tests covering EM-01…05, BD-01…10, RE-01…04, NP-01…06, GAP-01…07,
  SC-01…09, QH-01…05, DB-01…07, EB-01…08, calibration, Settings
  validation/round-trips, CSV round-trip and the clock seam.

## Requirements

- macOS 14 or newer (Apple Silicon first).
- Swift 6 toolchain. Either full Xcode or the Command Line Tools.
- No third-party runtime dependencies. `swift-testing` is a **test-only** SwiftPM
  dependency because this machine has no Xcode-bundled Testing module.

This repo is a SwiftPM package (there is no `.xcodeproj` here because Xcode is
not installed on this machine). `Package.swift` opens directly in Xcode:
`File → Open… → Blinko/Package.swift`.

## Build and test

```sh
./Scripts/test.sh        # swift test
./Scripts/build-app.sh   # builds build/Blinko.app, ad-hoc signed
./Scripts/measure-app.sh 3600 10  # sample a running app for RSS/CPU numbers
```

The build script assembles the `.app` bundle (Info.plist + entitlements) and
verifies the signature. For a stable camera permission, sign with your own
Apple Development identity instead of ad-hoc:

```sh
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/build-app.sh
```

### Memory hot-path optimizations

The live pipeline keeps per-burst allocations bounded:

- `CameraFrameSource` caps the front camera at 15 fps when the format supports
  it (configured after the input is attached, so the check uses the session's
  final format), and scopes each sample-buffer callback in an autorelease pool.
  A `waitForCallbacks()` barrier lets the pipeline drain the last in-flight
  frame without a late frame slipping in behind it.
- `VisionLandmarkExtractor` scopes each request/handler in an autorelease pool
  and copies only plain landmark values out, so no Vision observation survives
  the frame.
- `DetectionPipeline` coalesces main-queue delivery at ~30 Hz instead of one
  dispatch block per frame. The flush timer is cancellable, and pending
  deliveries are drained at burst end as well as on shutdown so the last batch
  is never dropped by the monitor's burst gate.
- `EyeMetrics` finds eye-contour extrema in one pass and reuses a single small
  buffer for the interior points, instead of allocating four temporary arrays
  per eye per frame.

A 150 s / 5 s run with the camera active on this machine showed RSS dropping
from ~220 MB baseline / ~248 MB burst peak (footprint 136 MB, peak 318 MB) to
~129–152 MB baseline / ~180 MB peak (footprint 93 MB, peak 268 MB). A fresh
launch without the debug window also avoids retaining SwiftUI view state, so
part of the baseline drop is launch-condition dependent. These changes reduce
hot-path churn but do not make the < 50 MB RSS budget achievable while macOS
counts shared AppKit/SwiftUI/Vision framework pages in RSS.

These figures predate the `EyeMetrics` allocation change; a camera-active
re-measure is pending because the ad-hoc rebuild invalidated this machine's
camera permission for Blinko.

## Run

```sh
# Menu bar app: starts monitoring and may nudge (unsandboxed development build)
swift run Blinko

# Same, plus the live detection debug window
swift run Blinko --debug

# Built app, camera + debug window
open build/Blinko.app --args --debug

# Replay a recorded landmark session (no camera, no reminders)
swift run Blinko --replay Fixtures/synthetic_session.csv

# Headless replay smoke test: prints a summary and exits
swift run Blinko --replay Fixtures/synthetic_session.csv --exit-after-replay
# [replay] frames=600 blinks=3 baseline=0.300
```

The menu bar menu contains:

- **Pause Blinko / Resume Blinko** — one click; the camera stops and no nudges
  or eye breaks fire while paused.
- **Eye Breaks: next in Nm** — submenu with an **Enabled** checkmark, interval
  presets (10/15/20/30 min) plus **Custom…** (1–60 min), and **Take Eye Break
  Now**. Works with or without camera access.
- **Quiet Hours (22:00–08:00)** — checkmark toggle; suppresses reminders when on.
- **Blink Interval: N s** — presets 3/5/10/15/20/30 s plus **Custom…** (1–300 s).
- **Dismiss After: N s** — presets 1/2.5/5/10 s, **Never**, plus **Custom…** (0.5–60 s).
- **Sampling: N s / M s** — burst length / cadence presets: 8/40, 12/60
  (default), 20/120 and 30/300 s.
- **Sample Now** — start an out-of-band burst without waiting for the cadence.
- **Retry Camera** — shown when camera access was denied.
- **Settings…** (⌘,) — persistent settings, calibration, login item and
  delete-all-data.
- **Show Detection Debug…** — live trace, rate and policy state.
- **Replay Recorded Session…** and **Record Landmark Session…**.
- **Quit Blinko**.

The built `.app` is sandboxed, so it **cannot read arbitrary paths from the
command line**. Use the menu bar items instead:

- **Replay Recorded Session…** — choose a CSV via `NSOpenPanel`.
- **Record Landmark Session…** — choose where to write a CSV via `NSSavePanel`.
- **Show Detection Debug…** — open the live debug window.

`--replay` still works in the sandboxed app for files inside its own container
(`~/Library/Containers/com.local.blinko/Data/`).

## Settings, persistence and privacy

Open **Settings…** from the menu bar (⌘,). The window has six sections:

- **General** — pause, reminder sound, launch at login, privacy note.
- **Sampling & Power** — burst length, cadence, idle threshold, low-battery
  threshold.
- **Reminders** — no-blink interval, auto-dismiss and quiet hours (with
  start/end time pickers).
- **20-20-20 Breaks** — enable/disable, interval in minutes and rest duration in
  seconds; independent of the camera.
- **Calibration** — run the guided 5 s baseline capture, see the saved baseline
  and date.
- **Data & Privacy** — store path, today’s aggregate counts, and **Delete All
  Blinko Data…**.

Settings are validated before they are applied; invalid values show an inline
reason and never reach the store (DB-05). Menu-bar changes are saved immediately.

The store lives at:

```text
~/Library/Containers/com.local.blinko/Data/Library/Application Support/Blinko/blinko-store.json
```

It contains only `schemaVersion`, `settings`, and one row per day with
`date`, `validSeconds`, `blinkCount` and `nudgeCount`. Writes are atomic
(temp file + rename) and serialized on one queue, so concurrent writers cannot
lose updates (DB-04). The current schema is **v2**; v1 files migrate in memory and
are written back with the version bump only after every migration step succeeds.
A failed migration leaves the original file intact and the app starts with
defaults (DB-03). The Phase E eye-break settings (`eyeBreaksEnabled`,
`eyeBreakIntervalSeconds`, `eyeBreakRestSeconds`) use the same tolerant
`decodeIfPresent` defaults, so no schema bump or migration was needed. Eye
breaks count toward the existing per-day `nudgeCount`; no extra aggregate column
is stored.

**Single instance (AP-01):** launching a second copy sends the running instance a
`blinko://settings` URL plus a distributed notification, then quits. The running
instance opens its Settings window; no second scheduler or camera session starts.

**Login item (AP-02):** `SMAppService.mainApp` registers the app itself, so moving
the `.app` does not break the login item. Ad-hoc-signed development builds may
land in `requiresApproval`; approve them in **System Settings → General → Login
Items**, or sign with your Apple ID. The persisted `launchAtLogin` value records
your intent only — Blinko does not silently re-register if you later remove the
login item in System Settings.

**Delete all data (DB-06):** removes settings, the calibration baseline and daily
counts, restores defaults, and unregisters the login item. Camera frames were
never stored, so there is nothing else to delete.

## Debug window

- Blue line: eye openness (mean of both eyes).
- Orange dashed: rolling baseline (median of recent open-eye frames).
- Red dashed: closed threshold (`baseline × 0.65`).
- Green dashed: open threshold (`baseline × 0.80`).
- Red ticks at the top: detected blinks.
- Header: blink count, latest openness, baseline, thresholds, valid-face share.
- Second row: smoothed rate, last burst rate, seconds since the last blink
  (`gap / interval`), auto-dismiss duration, nudge count.
- Third row: sampling state (`on 4.2/12s` or `off 37s`), configured duty cycle
  (`12s / 60s`), eye-break state (`in 12m` / `resting` / `off`), and a
  `CAMERA OFF — <reason>` badge when a gate is blocking bursts.
- **Sample Now** starts a burst immediately; **Preview Nudge** shows the
  centered reminder card without touching policy state.

Baseline is estimated automatically from the first valid frames. For a stable
starting point, open **Settings… → Calibration → Calibrate Now (5 s)**; the
median open-eye openness is saved and reused on the next launch.

Monitoring is independent of the window: closing the debug window does not stop
the duty cycle. Use **Pause Blinko** in the menu bar (or quit) to stop the camera
and suspend reminders. Under normal operation the camera is on only during the
12 s burst; the debug window's countdown and status badge show why it is off.

## Landmark CSV format

```text
timestamp,faceFound,bboxX,bboxY,bboxW,bboxH,yaw,roll,leftEye,rightEye
0.000000,1,0.250000,0.250000,0.300000,0.400000,0.000000,0.000000,0.310000 0.500000 ...
```

- Coordinates are image-normalized (0…1, origin bottom-left).
- Eye points are space-separated `x y` pairs; empty when the eye is absent.
- `yaw`/`roll` are radians and may be empty.
- The header is optional when reading.
- **This is derived data only.** No frames, images or pixel buffers are ever
  written.

`Fixtures/synthetic_session.csv` is a **synthetic** 20 s / 30 fps session with
three labelled blinks. It exercises the replay path without a camera; it is not
a real recording. Real-session validation (BD-10) needs you to record and
hand-label one session.

## Phase A acceptance status

| Item | Status |
|------|--------|
| EM-01…05 unit tests | ✅ passing |
| BD-01…09 unit tests | ✅ passing |
| BD-10 replay within ±1 of labelled truth | ✅ passing on the synthetic fixture (3 vs 3) |
| Replay harness reads a CSV from disk | ✅ verified headlessly: `frames=600 blinks=3` |
| 60 s manual camera test: ≥ 90 % recall, < 10 % false positives | ⏳ needs your camera |
| Debug window shows openness, thresholds, blink count | ✅ built; needs a visual check on your display |

Manual test procedure:

1. `swift run Blinko --debug` (or open the built app with `--debug`).
2. In normal lighting, blink deliberately about 20 times over 60 seconds.
3. The counter should be within ±2 of your count (≥ 90 % recall, < 10 % false
   positives). Record the result in this README when you run it.
4. To create a replayable real session, use **Record Landmark Session…**, then
   replay it with **Replay Recorded Session…**.

## Phase B acceptance status

| Item | Status |
|------|--------|
| RE-01…04 unit tests | ✅ passing |
| NP-01…06 unit tests | ✅ passing (NP-07 fallback retired in Phase E) |
| GAP-01…07 unit tests | ✅ passing (fires at 5 s, repeats, blink resets, no-face/pause suppression, interval changes) |
| Settings round-trip tests | ✅ passing for the adjustable intervals |
| QH-01…02 unit tests | ✅ passing |
| A reminder fires after 5 s without a blink | ✅ `BlinkGapPolicy`, repeats every 5 s |
| A blink resets the reminder timer | ✅ covered by GAP-02 |
| A blink hides a visible reminder immediately | ✅ wired through `NudgePresenter.dismiss()`; needs a camera check |
| Blink interval adjustable from the menu bar | ✅ presets + Custom… (1–300 s) |
| Auto-dismiss adjustable from the menu bar | ✅ presets + Never + Custom… (0.5–60 s) |
| One-click pause works | ✅ implemented; needs a manual click-through |
| Nothing fires while paused | ✅ policy suppression + heartbeat guard; covered by GAP-05 |
| Reminder card never steals focus, dismisses < 3 s | ✅ centered card, 2.5 s; needs a visual check |
| Camera denied + eye breaks | ✅ superseded by Phase E; the camera-independent timer now covers this case |

Manual Phase B check:

1. `swift run Blinko --debug` (or open the built app with `--debug`).
2. Click **Preview Nudge**. A large card should appear in the center of the
   screen without taking focus and disappear in under 3 s.
3. Keep your eyes open without blinking. After ~5 s the card appears; if you
   still do not blink it reappears every ~5 s. The debug row shows the gap
   counter climbing to `5 / 5`.
4. Blink while the card is visible: it fades out immediately instead of waiting
   for the auto-dismiss timer, and the gap counter resets.
5. Change **Blink Interval** and **Dismiss After** from the menu bar (presets or
   **Custom…**) and confirm the new values appear in the menu titles and debug
   row. With **Dismiss After → Never**, the card stays up until a blink.
6. Choose **Pause Blinko** from the menu bar. The camera indicator goes off and
   no further reminders appear.
7. Choose **Resume Blinko**. Monitoring restarts with a fresh gap timer.
8. Quiet hours are off by default. Toggle **Quiet Hours (22:00–08:00)** to verify
   that reminders are suppressed while it is on.
9. To check the 20-20-20 breaks, open the **Eye Breaks** submenu
   (works with or without camera access). **Take Eye Break Now** shows the
   look-away card for 20 s; a blink does not dismiss it. Set the interval to
   10 min and confirm the menu title shows **Eye Breaks: next in 10m**.

## Phase C acceptance status

| Item | Status |
|------|--------|
| SC-01…09 unit tests (cadence, sleep, late ticks, clock jumps, lock, battery, idle) | ✅ passing (87 tests total) |
| QH-03…05 unit tests (DST spring-forward/fall-back, time-zone change) | ✅ passing |
| Absolute monotonic deadlines; no countdown timers between bursts | ✅ implemented |
| One tolerant one-shot timer; `ProcessInfo` assertion only during a burst | ✅ implemented |
| Overdue bursts after sleep are dropped, never queued | ✅ `handleWake` + late-grace test |
| Lock/asleep/session-inactive events suspend the cadence via `NSWorkspace` | ✅ implemented; needs manual GUI check |
| Low battery, idle and quiet-hours gates | ✅ pure gate tests; needs manual check |
| Fullscreen / screen-sharing suppression | ✅ best-effort detection; needs manual check |
| Focus / Do Not Disturb suppression | ⚠️ no public sandboxed API; flag is wired but stays false — use quiet hours |
| Camera fully stopped between bursts (`AVCaptureSession.stopRunning()`) | ✅ implemented; **camera-light check pending** |
| PF-01 RSS < 50 MB after 1 h | ⏳ not measured yet |
| PF-02 average CPU < 3 % over 1 h | ⏳ not measured yet |
| PF-03 CPU between bursts ≈ 0 % | ⏳ not measured yet |
| PF-04 Energy Impact not high | ⏳ check Activity Monitor manually |
| PF-05 no stuck camera light across sleep/wake | ⏳ needs 8 h soak |
| PF-06 camera indicator on only during bursts | ⏳ needs manual check |

Manual Phase C check:

1. Launch with `swift run Blinko --debug` or `open build/Blinko.app --args --debug`.
2. The first burst starts immediately. The debug row shows `on 0.x/12s`;
   watch the green camera indicator on the Mac.
3. After ~12 s the row changes to `off 60s` and the camera indicator must go
   dark. It should stay dark for the rest of the minute. The menu bar status
   also reads `camera off, next in Ns` (it refreshes when the menu opens).
4. Press **Sample Now** in the menu or debug window to confirm an immediate
   burst. Press **Pause Blinko**: the camera stops and no reminders appear;
   **Resume Blinko** starts a fresh burst.
5. Change **Sampling** to `8 s every 40 s` and confirm the debug `Duty` readout
   and the indicator timing follow the new values.
6. Sleep the Mac (or lock the screen) during a burst and wake/unlock after a few
   minutes. There must be no burst until a full interval after wake, and no
   flood of nudges. The low-rate streak is reset after a long sleep.
7. Unplug and let the battery drop below 20 % (or use a simulated environment);
   the badge should read `CAMERA OFF — LOW BATTERY`. Plugging back in resumes
   sampling. Leaving the keyboard/mouse untouched for 5 min should show
   `CAMERA OFF — IDLE`.
8. Start a fullscreen app or a screen-sharing session; the badge should show
   the corresponding reason. Focus/DND cannot be detected by a sandboxed app —
   use **Quiet Hours** when you need a guaranteed silence window.
9. For PF-01…03, leave the app running for an hour and record numbers with:

   ```sh
   ./Scripts/measure-app.sh 3600 10
   # or, for a specific process:
   BLINKO_PID=1234 ./Scripts/measure-app.sh 3600 10
   ```

   Record the printed RSS/CPU summary here after review. For PF-03, sample
   manually during the `off` part of a burst; `top` should show ≈ 0.0 % CPU.

Recorded budgets (fill in after running the procedure above):

| Metric | Measured | Budget |
|--------|----------|--------|
| RSS after 1 h | — | < 50 MB |
| Average CPU over 1 h | — | < 3 % |
| CPU between bursts | — | ≈ 0 % |

## Phase D acceptance status

| Item | Status |
|------|--------|
| DB-01 fresh install at latest schema | ✅ automated test |
| DB-02 v1→v2 migration preserves data and bumps the version atomically | ✅ automated test |
| DB-03 failed migration rolls back; app still starts on defaults | ✅ automated test |
| DB-04 concurrent settings writes serialized, no lost update | ✅ automated test (50 writers) |
| DB-05 invalid settings rejected with a reason shown in the UI | ✅ automated test + inline Settings errors |
| DB-06 delete all data | ✅ automated test + confirmed UI flow |
| DB-07 no frames, images or landmark arrays in the store | ✅ automated test + sandbox file inspection |
| Guided 5 s calibration seeds and persists the baseline | ✅ collector tests + implementation; camera check pending |
| AP-01 second instance opens the first instance's Settings | ✅ implemented (URL scheme + distributed notification); manual check pending |
| AP-02 login item survives moving the app | ✅ `SMAppService.mainApp`; manual check pending |
| AP-03…07 camera denial/in-use/unplug, non-stealing nudge | ✅ implemented in earlier phases; manual checks pending |
| AP-08 zero outbound connections | ✅ no networking frameworks linked; `nettop` check pending |
| PF-01…06 RSS, CPU, energy, 8 h soak, camera indicator | ⏳ manual; use `./Scripts/measure-app.sh` from the Phase C section |
| 87 automated tests in 15 suites | ✅ `swift test` passing |

Manual Phase D check:

1. Launch and press ⌘, (or **Settings…**). Change the burst/interval, no-blink
   interval, sound and quiet hours; click **Save**. Restart the app and confirm
   the values are still there. Enter `1` as the burst length and confirm an
   inline error appears and **Save** refuses it.
2. With the camera working, run **Calibrate Now (5 s)** with your eyes open.
   The saved baseline and date appear in Settings and survive a restart.
3. Launch a second copy (`open build/Blinko.app`). The first instance's Settings
   window should come forward and the second process should exit; only one
   scheduler/camera session exists (confirm with `--debug`).
4. Enable **Launch Blinko at login**, move `Blinko.app` to another folder, and
   log out/in. It should still start, and Settings should show **Enabled**.
   Ad-hoc builds may need approval in **System Settings → General → Login Items**.
5. Check **Data & Privacy**: the store path is shown and today's counts increase
   after bursts and nudges. The file contains only `schemaVersion`, `settings`
   and per-day `aggregates`.
6. Click **Delete All Blinko Data…**. Settings return to defaults, counts reset,
   and the login item is unregistered.
7. Leave the app running for 8 h with sleep/wake cycles. Record RSS/CPU and
   confirm the camera indicator is dark between bursts (PF-01…06), and use
   `nettop -m tcp -p <pid>` to confirm zero outbound connections (AP-08).

## Phase E acceptance status

| Item | Status |
|------|--------|
| EB-01…08 unit tests (cadence, rest window, no overlap, suppression, manual, interval, disable) | ✅ passing |
| Breaks default to on (20 min interval, 20 s rest) | ✅ implemented; Settings + menu toggle |
| Works with camera denied or unavailable | ✅ timer is independent of the camera path |
| Static card, no live countdown | ✅ no polling; menu/debug countdown computed on demand |
| A blink does not dismiss an eye-break card | ✅ `NudgePresenter.dismissOnBlink()` |
| Missed breaks are rescheduled, never replayed late | ✅ monotonic one-shot timer, no catch-up |
| Legacy `fallbackRemindersEnabled` key ignored | ✅ covered by tolerant decode test |
| No schema bump or new aggregate column | ✅ v2 store; breaks fold into `nudgeCount` |
| One tolerant one-shot timer; no per-second polling | ✅ `EyeBreakTimer` + menu/debug on-demand countdown |
| 87 automated tests in 15 suites | ✅ `swift test` passing |

Manual Phase E check:

1. Launch the app; after 20 min (or set the interval to 1 min) the look-away card
   appears for 20 s and then disappears on its own. Confirm it is static (no
   ticking countdown).
2. Blink repeatedly while the card is visible: the card stays up until the rest
   timer ends.
3. Deny camera access in System Settings; confirm breaks still fire and the menu
   reads **Camera unavailable — 20-20-20 breaks on**.
4. Pause Blinko and set the interval to 1 min; wait past a deadline, then resume.
   Confirm one fresh break a full interval later, with no burst of missed cards.
5. Use **Take Eye Break Now** and confirm the next automatic break is one full
   interval after the rest ends.

## Layout

```text
Sources/
  BlinkoCore/                     pure logic, no AVFoundation/Vision/AppKit
    Core/Clock.swift              Clock, SystemClock, FakeClock
    Core/BlinkGapPolicy.swift     no-blink watchdog, adjustable cadence (GAP-01…07)
    Core/RateEstimator.swift      BurstSummary, RateEstimator (RE-01…04)
    Core/BurstAccumulator.swift   valid-face seconds + blink count per burst
    Core/NudgePolicy.swift        rate policy, suppression (NP-01…06)
    Core/EyeBreakTimer.swift      camera-independent 20-20-20 timer (EB-01…08)
    Core/QuietHours.swift         quiet-window evaluation (QH-01…05)
    Core/CalibrationCollector.swift median baseline for guided calibration
    Core/SamplingScheduler.swift  absolute-time duty cycle (SC-01…07)
    Core/BurstGate.swift          pure gating decision (SC-08/09)
    System/ActivitySeams.swift    IdleMonitor, BatteryMonitor, PresenceMonitor
    Detection/                    FaceObservation, LandmarkExtractor,
                                  EyeMetrics, BlinkDetector
    Capture/                      FrameSource seams, LandmarkCSV,
                                  ReplayFrameSource
    Persistence/Store.swift       Store protocol + settings/aggregate types
    Persistence/JSONStore.swift   atomic versioned JSON store + migrations
    System/PowerObserver.swift    PowerObserver seam
  Blink/
    App/                          AppDelegate, MenuBarController, launch options
    Settings/                     SettingsModel, SettingsView, SettingsWindowController
    System/LoginItemController.swift  SMAppService wrapper
    Capture/CameraFrameSource.swift
    Detection/VisionLandmarkExtractor.swift
    Pipeline/DetectionPipeline.swift
    Monitor/BlinkMonitor.swift    duty-cycled pipeline + gap watchdog
    Nudge/                        NudgePanel, NudgePresenter
    Debug/                        DebugModel, DebugView, DebugWindowController
    System/                       SystemPowerObserver, SystemSensors,
                                  SystemPresenceMonitor, BurstActivity
Tests/BlinkoCoreTests/            Swift Testing suites (EM/BD/RE/NP/GAP/SC/QH/DB/Calibration/CSV/Clock)
Resources/                        Info.plist, Blinko.entitlements
Scripts/                          build-app.sh, test.sh, measure-app.sh,
                                  fixture generator
Fixtures/synthetic_session.csv    synthetic replay sample
```

Mapping to the spec's §3 tree: SwiftPM requires target roots, so `App/`,
`Capture/`, `Detection/`, `Core/`, `Nudge/`, `Persistence/`, `System/` live
inside `Sources/BlinkoCore` (logic) and `Sources/Blinko` (platform glue).

## Privacy and safety

- No networking code; the built binary links no networking frameworks
  (verified with `otool -L`).
- Frames are processed in memory and released immediately.
- Only derived landmark rows are written, and only when recording is explicitly
  started.
- Sandbox is on, with `com.apple.security.device.camera` and user-selected
  read/write for CSV import/export.

## Known limitations

- **Sandbox vs. CLI paths:** the built `.app` cannot read arbitrary paths from
  `--replay`; use the menu pickers or the unsandboxed `swift run` binary.
- **Ad-hoc signing:** rebuilding may cause macOS to ask for camera permission
  again. Sign with your Apple ID for a stable grant.
- **No Xcode here:** Swift Testing is built from source as a test-only
  dependency, with a Command Line Tools linker search path in `Package.swift`.
  With Xcode installed this path is simply ignored.
- **Vision yaw/roll:** thresholds are 25° yaw / 30° roll; extreme angles reject
  the frame by design.
- **Frame drops:** a blink that falls entirely inside a dropped-frame gap cannot
  be observed. Gaps up to 100 ms are covered by BD-08.
- **DND / Focus suppression:** macOS exposes no public Focus-status API for a
  sandboxed ad-hoc app, so the suppression flag is wired but remains false.
  Use **Quiet Hours** when silence must be guaranteed.
- **Fullscreen / screen-sharing detection is best-effort:** a frontmost window
  matching a display size counts as fullscreen, and a small list of known
  screen-sharing bundle IDs is checked. Unusual window layouts or new remote
  tools may not be detected; **Pause Blinko** is always available.
- **Camera light is on during bursts:** expected for a 12 s window each minute.
  Between bursts the capture session is stopped; if the indicator stays on,
  quit and report it.
- **Settings window changes apply on Save:** menu-bar shortcuts apply and persist
  immediately; both paths write the same store. Closing the window with unsaved
  edits discards them.
- **Eye breaks are independent of the camera:** the 20-20-20 timer runs whether
  camera access is granted or denied, and is not affected by camera bursts.
- **Some policy state is intentionally in memory:** the nudge history and rate
  streak reset on launch. Pause state, reminder cadence, calibration and daily
  counts persist; one aggregate row is kept per calendar day.

## Next phases

- **Phase B:** ✅ `BlinkGapPolicy` 5 s no-blink watchdog, centered reminder card,
  one-click pause, quiet-hours toggle.
  `RateEstimator` / `NudgePolicy` remain as diagnostics.
- **Phase C:** ✅ duty-cycled scheduling, sleep/wake/idle/battery/fullscreen
  gating, quiet-hours wiring, menu-selectable cadence. Manual CPU/RSS and camera
  indicator checks still need to be recorded above.
- **Phase D:** ✅ Settings window with validation, guided 5 s calibration,
  versioned atomic JSON store + migrations, single-instance guard, login item,
  delete-all-data, DB-01…07 automated tests. Manual AP/PF checks and the 8-hour
  soak still need to be recorded above before sign-off.
- **Phase E:** ✅ camera-independent 20-20-20 breaks (default 20 min / 20 s), a
  static look-away card that blinks do not dismiss, menu + Settings controls,
  EB-01…08 automated tests. The manual checks above still need to be recorded.
