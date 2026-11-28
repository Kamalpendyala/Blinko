# AGENTS.md — Blinko

Native Swift menu-bar blink reminder, macOS 14+ (Apple Silicon first), local-only:
no networking code, no captured frames persisted. `README.md` is the spec and
acceptance record (test IDs EM/BD/RE/NP/GAP/SC/QH/DB/AP/PF); update it when
behavior changes.

## Structure and boundaries

- SwiftPM package, two targets: `BlinkoCore` is pure logic (no AVFoundation,
  Vision or AppKit); `Blinko` is the platform glue and `@main` executable.
  Tests live only in `Tests/BlinkoCoreTests`.
- Put decision logic in `BlinkoCore` behind a seam (`Clock`, `FrameSource`,
  `PowerObserver`, `ActivitySeams`) so it is unit-testable; keep OS/UI code in
  `Blinko/`. Tests follow the spec-ID naming used by existing suites.
- Tests use **Swift Testing** (`@Test`, `#expect`), not XCTest. Shared helpers
  and contour/observation factories are in `Tests/BlinkoCoreTests/Support.swift`.
- `BlinkoMain.swift` keeps a strong `AppDelegate` reference (NSApplication holds
  it weakly) and sets `.accessory` activation policy. Preserve that reference and
  the `LSUIElement` plist key: no Dock icon or window at launch.
- Per-frame hot paths use an `autoreleasepool` per callback/request and coalesce
  main-queue delivery at ~30 Hz. Preserve these in `CameraFrameSource`,
  `VisionLandmarkExtractor`, `DetectionPipeline`, and the one-pass contour
  math in `EyeMetrics`.
- Final-batch ordering is subtle: `BlinkMonitor.endBurst()` drains pending
  deliveries before `finishBurst()`; replay completion calls `pipeline.shutdown()`
  *before* reading debug counters. `stopCurrentBurst()` intentionally abandons
  pending work — do not "fix" that asymmetry.

## Commands

Run from repo root (scripts `cd` themselves):

- `./Scripts/test.sh` → `swift test`. Args pass through, so
  `./Scripts/test.sh --filter EyeMetricsTests` runs one suite. Full run is
  ~102 tests / 16 suites in ~15 s — run it after every change.
- `./Scripts/build-app.sh` → release `build/Blinko.app` (deletes and re-signs
  the existing bundle; `build/` is gitignored). Default identity is ad-hoc `-`;
  use `CODESIGN_IDENTITY="Apple Development: …"` for a stable camera grant.
- Headless replay smoke:
  `swift run Blinko --replay Fixtures/synthetic_session.csv --exit-after-replay`
  → expect `frames=600 blinks=3 baseline=0.300`. The CSV is synthetic (600
  frames, 3 blinks), created by `Scripts/make-synthetic-fixture.py`.
- Live debug: `swift run Blinko --debug` or `open build/Blinko.app --args --debug`.
- CPU/RSS sampling: `./Scripts/measure-app.sh 3600 10`, or set `BLINKO_PID`.
  `Scripts/measure-blink-app.sh` measures the separate `/Applications/Blink.app`
  (Electron) process tree — it is a comparison tool, not a Blinko measurement.

## Environment and operational gotchas

- No full Xcode here: Swift Testing is a test-only SwiftPM dependency built from
  source, with an `-L/Library/Developer/CommandLineTools/...` unsafe linker flag
  in `Package.swift`. Keep that flag; Xcode ignores it when present.
- Built `.app` is sandboxed and cannot read arbitrary `--replay` CLI paths; use
  the menu pickers or the unsandboxed `swift run` binary. In the app bundle,
  `--replay` only works inside `~/Library/Containers/com.local.blinko/Data/`.
- Ad-hoc rebuilds change the signing identity, so macOS may re-prompt camera
  access ("Camera unavailable"). Re-approve in System Settings › Privacy &
  Security › Camera, or sign with an Apple Development identity.
- Store is `~/Library/Containers/com.local.blinko/Data/Library/Application Support/Blinko/blinko-store.json`:
  schema v2, atomic temp-file+rename writes, one aggregate row per day. It holds
  only settings and daily counts — never frames, images or landmark arrays.
- Measure CPU from sampled CPU-time deltas (`measure-app.sh` uses `top -l 2`),
  not `ps %cpu` lifetime average, which includes launch/setup and burst spikes.
  The < 50 MB RSS budget is not achievable with AppKit/SwiftUI/Vision linked;
  judge changes by per-burst allocation churn, not the absolute floor.
- Development proceeds phase-by-phase on `phase-*` branches; `main` may lag
  behind the current phase branch.
