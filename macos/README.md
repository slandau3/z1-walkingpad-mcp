# macOS — Z1 WalkingPad menu-bar app

Native macOS control for the KingSmith WalkingPad Z1 treadmill over BLE.
Swift 6, no third-party dependencies. The wire protocol is specified in
[`../docs/protocol.md`](../docs/protocol.md) — read it before changing any
frame code. **Never** send frames starting with `0xE8` (OTA, brick risk) and
never touch the `0xFFC0`/`0xFFF0`/`0xFF00` services.

## Layout

| Piece | What |
|---|---|
| `Sources/Z1Core` | Pure CoreBluetooth + Foundation library: vendor/FTMS frames, BLE transport, `Z1Treadmill` actor, calorie metrics. No AppKit/SwiftUI. |
| `Sources/Z1MenuBar` | SwiftUI `MenuBarExtra` app (deployment target macOS 14, activation policy `.accessory` — no Dock icon). |
| `Sources/Z1Smoke` | `z1smoke` — hardware smoke test (connect, unlock, read telemetry; **never moves the belt**). |
| `Sources/Z1CoreTestSuite` + `Sources/z1tests` | Framework-free unit tests + runner executable (see "Testing"). |
| `Tests/Z1CoreTests` | `swift test` anchor (compiles/links the suite). |
| `build-app.sh` | Release build → `Z1WalkingPad.app` bundle → ad-hoc codesign. |

## Build & run

Requires a Swift 6 toolchain (Command Line Tools is enough — no full Xcode
needed). Developed with Swift 6.2.3, target `arm64-apple-macosx15.0`.

```bash
cd macos

swift build                     # debug build of everything
swift test                      # compiles the test suite (see "Testing")
swift run z1tests               # actually runs the unit tests
bash build-app.sh               # release build -> macos/Z1WalkingPad.app
bash build-app.sh --install     # ... and copy to /Applications
```

Then open the app:

```bash
open macos/Z1WalkingPad.app     # or launch from /Applications after --install
```

A `figure.walk` icon appears in the menu bar; while the belt runs it also
shows the current speed (in your chosen unit). Click it for the popover:
connect/disconnect, big speed readout with − / + steppers, Start/Stop, stats
(elapsed, distance, steps, estimated kcal), and a Settings section:

The step count is the pad's **raw hardware counter**, everywhere: the live
display updates promptly with each telemetry step delta, and session
summaries report the exact same pad-reported total — no client-side
estimation or correction is applied to steps.

- **Units** — Imperial (mph / mi+ft / lb) or Metric (km/h / km / kg); default
  Imperial. Also synced to the pad's own LED display (property 1, bit 0x0002).
- **Body weight** — entered in the current unit, stored in kg for the
  calorie math.
- **Speed step** — stepper nudge size: 0.1 / 0.2 / 0.5 in the display unit
  (converted to km/h on the wire, rounded to the pad's 0.1 km/h steps).
- **Persist stats across sessions** — off (default) means pad-as-master:
  stats follow the pad's counters and its resets. On means time, distance,
  steps and kcal keep accumulating across Stops until you hit the **Clear**
  button beside it (which also wipes the on-disk calorie state).

All settings persist across launches. Exit is at the bottom of the popover
(stops the belt, sleeps the pad, then quits).

## Bluetooth permission

On first launch macOS asks for Bluetooth permission
(`NSBluetoothAlwaysUsageDescription` is in the bundled Info.plist). If you
accidentally deny it: System Settings → Privacy & Security → Bluetooth →
enable "Z1 WalkingPad".

For the command-line tools (`z1smoke`, `z1tests`) the permission prompt is
attributed to your terminal app (Terminal/iTerm) instead.

**One BLE connection at a time:** the Z1 accepts a single BLE central. If the
KS Fit app (or the Python MCP server/CLI in this repo) is connected, this app
won't find the pad — and vice versa. Quit the other client first. The pad is
also deliberately anti-pairing: do not pair it in macOS Bluetooth settings.

## Testing

This machine has **Command Line Tools only**, and neither XCTest nor
swift-testing ships with CLT — `swift test` can compile the test target but
Apple's runner frameworks are absent, so it executes zero tests. The unit
tests are therefore a framework-free suite:

- `swift test` — compiles and links the whole suite (exit 0).
- `swift run z1tests` — **runs** all assertions, exits non-zero on failure.

Covered: unlock-frame known vector (`KS-HD-Z1D` → `71 00 05 01 2e 5a 31 44 74`),
checksum roundtrip, bad-checksum/short-frame rejection, SETTING_GET vector,
property-record parsing, telemetry parse (`04 24 fa 00 00 00 00 02 00 00 00`
→ 2.5 km/h / 0 m / 2 s / 0 steps), u24 distance, MET table anchors +
interpolation + clamping, `kcal/min(3.2, 75) = 3.9375`, `CalorieTracker`.

## Hardware smoke test

```bash
swift run z1smoke          # add a number to change the telemetry wait (default 8s)
```

Scans for `KS-HD-Z1*`, connects, performs the unlock handshake, reads the
speed range + property dump, waits for one telemetry frame (the pad only
streams while the belt runs, so "no telemetry" with an idle belt is fine),
then disconnects. It sends **no FTMS control writes** — the belt never moves.
