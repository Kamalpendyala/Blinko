# Blinko — blink reminder for macOS

Working name: **Blinko**. Native Swift menu bar app that watches blink rate
through the webcam and will nudge the user to blink. Local-first, sandboxed, no
networking code.

**Current status: Phase 0 (bootstrap) + Phase A (detection prototype) + Phase B
(rate estimates and reminders) complete.** Phase C (duty-cycled scheduling and
power management) is not built yet, so the camera runs continuously while
monitoring is active.

---

## What works today

- Camera → Vision landmarks → eye-openness ratio → blink state machine.
- `RateEstimator`: blinks per minute over valid-face seconds only, EMA-smoothed
  across 12 s bursts; bursts with under 3 s of valid face are discarded.
- `NudgePolicy`: nudges only when the smoothed rate stays below 8 blinks/min for
  3 consecutive bursts, with a 10 min cooldown and a 3/hour cap.
- Subtle non-activating nudge panel (never steals focus, clicks pass through,
  auto-dismisses in 2.5 s) plus a menu bar icon pulse.
- One-click **Pause Blinko / Resume Blinko**; nothing fires while paused.
- Camera-denied fallback: optional fixed 20 min reminders (20-20-20 style).
- Debug window with live openness trace, baseline/threshold lines, blink count,
  valid-face percentage, smoothed rate, low-streak counter, nudge count and a
  **Preview Nudge** button.
- Replay harness that runs a recorded landmark CSV through the same pipeline.
- Debug-only landmark CSV recorder (derived eye points only — never pixels).
- Menu bar item (`LSUIElement`), no Dock icon, sandboxed with camera access.
- 37 unit tests covering EM-01…05, BD-01…10, RE-01…04, NP-01…07, QH-01…02,
  CSV round-trip and the clock seam.

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
```

The build script assembles the `.app` bundle (Info.plist + entitlements) and
verifies the signature. For a stable camera permission, sign with your own
Apple Development identity instead of ad-hoc:

```sh
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/build-app.sh
```

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
  or fallback reminders fire while paused.
- **Enable / Disable Timed Reminders** — shown when the camera is unavailable.
- **Retry Camera** — shown when camera access was denied.
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

## Debug window

- Blue line: eye openness (mean of both eyes).
- Orange dashed: rolling baseline (median of recent open-eye frames).
- Red dashed: closed threshold (`baseline × 0.65`).
- Green dashed: open threshold (`baseline × 0.80`).
- Red ticks at the top: detected blinks.
- Header: blink count, latest openness, baseline, thresholds, valid-face share.
- Second row: smoothed rate, last burst rate, low-rate streak, nudge count.
- **Preview Nudge** shows the overlay without changing the policy state.

Baseline is estimated automatically from the first valid frames. The explicit
~5 s calibration flow is Phase D.

Monitoring is independent of the window: closing the debug window no longer
stops capture. Use **Pause Blinko** in the menu bar (or quit) to stop the camera.
Phase C adds duty cycling, so the camera will be off between bursts.

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
| NP-01…07 unit tests | ✅ passing (NP-07b covers no catch-up after suppression) |
| QH-01…02 unit tests | ✅ passing |
| A nudge fires only per policy | ✅ covered by unit tests (3 low bursts, cooldown, 3/hour cap) |
| One-click pause works | ✅ implemented; needs a manual click-through |
| Nothing fires while paused | ✅ policy suppression + heartbeat guard; covered by NP-06 |
| Nudge panel never steals focus, dismisses < 3 s | ✅ implemented (2.5 s); needs a visual check |
| Camera denied + fallback enabled | ✅ 20 min interval, menu toggle, covered by NP-07 |

Manual Phase B check:

1. `swift run Blinko --debug` (or open the built app with `--debug`).
2. Click **Preview Nudge** in the debug window. The overlay should appear near
   the top-right without taking focus and disappear in under 3 s.
3. Keep your eyes open without blinking for about 40 s. The debug row should
   show the low-rate streak reaching 3 and one nudge. (Quiet hours default to
   22:00–08:00 and suppress reminders; the menu bar shows **quiet hours** when
   that is why nothing fired.)
4. Choose **Pause Blinko** from the menu bar. The camera indicator goes off and
   no further nudges or fallback reminders appear.
5. Choose **Resume Blinko**. Monitoring restarts with a fresh rate estimate.
6. To check the camera-denied fallback, deny camera access, then choose
   **Enable Timed Reminders**; the first reminder is due after 20 min.

## Layout

```text
Sources/
  BlinkoCore/                     pure logic, no AVFoundation/Vision/AppKit
    Core/Clock.swift              Clock, SystemClock, FakeClock
    Core/RateEstimator.swift      BurstSummary, RateEstimator (RE-01…04)
    Core/BurstAccumulator.swift   valid-face seconds + blink count per burst
    Core/NudgePolicy.swift        rate/fallback policy, suppression (NP-01…07)
    Core/QuietHours.swift         quiet-window evaluation (QH-01…02)
    Detection/                    FaceObservation, LandmarkExtractor,
                                  EyeMetrics, BlinkDetector
    Capture/                      FrameSource seams, LandmarkCSV,
                                  ReplayFrameSource
    Persistence/Store.swift       Store protocol + settings/aggregate types (Phase D)
    System/PowerObserver.swift    PowerObserver seam (Phase C)
  Blink/
    App/                          AppDelegate, MenuBarController, launch options
    Capture/CameraFrameSource.swift
    Detection/VisionLandmarkExtractor.swift
    Pipeline/DetectionPipeline.swift
    Monitor/BlinkMonitor.swift    live pipeline + 12 s burst slicing + policy
    Nudge/                        NudgePanel, NudgePresenter
    Debug/                        DebugModel, DebugView, DebugWindowController
Tests/BlinkoCoreTests/            Swift Testing suites (EM/BD/RE/NP/QH/CSV/Clock)
Resources/                        Info.plist, Blinko.entitlements
Scripts/                          build-app.sh, test.sh, fixture generator
Fixtures/synthetic_session.csv    synthetic replay sample
```

Mapping to the spec's §3 tree: SwiftPM requires target roots, so `App/`,
`Capture/`, `Detection/`, `Core/`, `Nudge/`, `Persistence/`, `System/` live
inside `Sources/BlinkoCore` (logic) and `Sources/Blinko` (platform glue).
`SamplingScheduler` and the fullscreen/DND monitors are still Phase C.

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
- **DND / Focus / fullscreen suppression:** Phase C. macOS exposes no public
  Focus-status API, so that detection will be best-effort and documented.
- **Continuous camera in Phase B:** duty cycling lands in Phase C. Until then
  the camera stays on while monitoring is active, so use **Pause Blinko** when
  you do not want it on. The nudge panel can also appear over a fullscreen app
  until Phase C adds fullscreen suppression.
- **No Settings UI yet:** quiet hours (22:00–08:00, enabled), sound (off) and
  the 12 s / 60 s cadence are compile-time defaults. Phase D adds the UI.
- **Fallback interval is fixed at 20 min** (20-20-20 style) and is offered only
  when the camera is unavailable or denied.
- **Policy state is in memory:** pause state, nudge history and daily aggregates
  are not persisted until Phase D.

## Next phases

- **Phase B:** ✅ `RateEstimator`, `NudgePolicy`, non-activating nudge panel,
  one-click pause, fallback interval reminders.
- **Phase C:** duty-cycled scheduling, sleep/wake/idle/battery/fullscreen
  suppression, quiet hours wiring, measured CPU/RSS.
- **Phase D:** JSON store + migrations, Settings UI, calibration flow,
  single-instance guard, login item, delete-all-data, 8-hour soak, README
  completion.
