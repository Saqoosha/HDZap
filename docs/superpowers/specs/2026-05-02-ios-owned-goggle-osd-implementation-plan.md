# iOS-Owned Goggle OSD Implementation Plan

**Date:** 2026-05-02
**Status:** Implemented — pending build/hardware verification
**Scope:** iOS timer/settings UI, BLE text-frame protocol, firmware BLE-to-ESP-NOW OSD bridge

## Summary

Move goggle OSD content ownership to the iOS app. The app calculates target
pace, diff, required/banked time, average lap, and projected final lap count.
The M5StickS3 firmware becomes a bridge: it receives already-formatted OSD
text over BLE and sends that text to the HDZero goggle over ESP-NOW.

The goggle should show a compact three-line block at the bottom center:

```text
LAP 4 22.345
AVG 22.222 PACE 6L
D+1.00 NEED -0.2/L
```

The iOS app should show the same information in a richer layout so the phone
and goggle never disagree.

## Product Decisions

- The race window is configurable (default 90 s). The settings-view
  reconstruction in the same release exposes it as a 60–180 s slider
  (5 s step), persisted via `@AppStorage("raceSessionLimit")`.
- Target lap count is also a user setting.
- Target lap seconds are derived from both:

```text
targetLapSec = raceSessionLimit / (targetLapCount - 1)
```

- Default target lap count is 7. Default race window is 90 s.
- Minimum target lap count is 2, because `targetLapCount - 1` must be positive.
- For target lap count 7, target lap seconds are `90 / (7 - 1) = 15.0`.
- M5StickS3 does not calculate session metrics.
- Firmware may truncate or reject too-long text, but it must not reinterpret it.

## Data Ownership

| Data / behavior | Owner |
|-----------------|-------|
| Lap history | iOS `LapTimer` |
| Target lap count setting | iOS app storage |
| Target lap seconds | iOS derived metric |
| Average lap | iOS derived metric |
| Pace / projected final lap count | iOS derived metric |
| Diff vs target | iOS derived metric |
| Need/bank per remaining lap | iOS derived metric |
| Goggle OSD text formatting | iOS |
| BLE packet staging | Firmware |
| ESP-NOW send, retry, delivery status | Firmware |

## Metrics

Inputs:

```text
sessionLimitSec = 90
targetLapCount = user setting, default 7
currentLapCount = completed laps after the latest tap
elapsedSec = timer elapsed at the latest tap
lastLapSec = latest completed lap duration
avgLapSec = total completed lap time / currentLapCount
```

Target pace:

```text
targetLapSec = sessionLimitSec / (targetLapCount - 1)
```

Diff:

```text
expectedSec = currentLapCount * targetLapSec
diffSec = elapsedSec - expectedSec
```

Example:

```text
targetLapCount = 7
targetLapSec = 15.0
elapsedSec = 31.0
currentLapCount = 2
expectedSec = 30.0
diffSec = +1.0
```

Need or bank:

```text
remainingLaps = max(1, targetLapCount - currentLapCount)
perLapSec = -diffSec / remainingLaps
```

Labels:

```text
diffSec > 0: D+1.00 NEED -0.2/L
diffSec < 0: D-1.00 BANK +0.2/L
diffSec = 0: D+0.00 ON TARGET
```

Meaning:

- `NEED -0.2/L`: each remaining lap needs to be 0.2 seconds faster than target pace.
- `BANK +0.2/L`: each remaining lap has 0.2 seconds of margin against target pace.

Projected final lap count:

```text
remainingSec = max(0, sessionLimitSec - elapsedSec)
futureLaps = ceil(remainingSec / avgLapSec)
paceLaps = currentLapCount + futureLaps
```

This matches the existing iOS pace-snapshot behavior: pace updates on lap taps,
not every animation frame.

## OSD Text Formatting

The iOS app emits three ASCII strings. Firmware uppercases anyway, but iOS
should format them uppercase to make debugging direct.

Line 1:

```text
LAP 4 22.345
```

Rules:

- Lap number is not zero-padded in the compact goggle line.
- Last lap time uses seconds with three decimals and no unit suffix.
- If a lap exceeds 999 seconds, clamp or compact before sending.

Line 2:

```text
AVG 22.222 PACE 6L
```

Rules:

- Average uses seconds with three decimals.
- Pace uses integer projected final lap count plus `L`.

Line 3:

```text
D+1.00 NEED -0.2/L
D-1.00 BANK +0.2/L
D+0.00 ON TARGET
```

Rules:

- Diff normally uses two decimals.
- Per-lap need/bank uses one decimal to keep the OSD line short.
- Use ASCII `+` and `-`, not typographic minus.
- If the compact line would exceed the BLE row budget, reduce diff precision
  before truncating semantic labels.

## BLE Protocol

Add a new write characteristic:

```text
CHR_OSD_TEXT_UUID = f47ac10b-58cc-4372-a567-0e02b2c3d487
```

Use a default-MTU-safe row protocol. Each BLE write carries one row:

```text
[row:u8][ascii text bytes]
```

Fields:

| Field | Meaning |
|-------|---------|
| `row` | `0`, `1`, or `2` for the three bottom OSD rows |
| text | ASCII text, max 19 bytes so the whole write stays within 20 bytes |

Write sequence per rendered OSD frame:

```text
write row 0: [0]["LAP 4 22.345"]
write row 1: [1]["AVG 22.222 PACE 6L"]
write row 2: [2]["D+1.00 NEED -0.2/L"]
```

Firmware staging:

- Row `0` starts a new staged frame and clears the row-ready bitmask.
- Rows `0`, `1`, and `2` are copied into fixed buffers.
- When row `2` arrives and all three rows are ready, firmware requests an OSD render.
- If a row is out of range, empty, or too long, firmware logs and ignores it.
- The row protocol is intentionally dumb: no math, no target settings, no lap parsing.

Why row writes instead of one full frame:

- It stays safe under the default 20-byte ATT payload limit.
- It avoids relying on BLE MTU negotiation.
- It keeps the firmware parser small.

## Firmware Plan

Files:

- `firmware/include/ble_service.h`
- `firmware/src/main.cpp`
- `firmware/include/lap_display.h` or a new `firmware/include/osd_text_display.h`
- `docs/ARCHITECTURE.md` after implementation

Steps:

1. Add `CHR_OSD_TEXT_UUID`.
2. Add staged row buffers:

```cpp
inline volatile bool g_osd_text_received = false;
inline char g_osd_rows[3][20] = {};
inline uint8_t g_osd_rows_ready = 0;
```

3. Guard staged rows with `g_ble_mux`.
4. Add `OSDTextCallback` for the new characteristic.
5. In `main.cpp`, consume `g_osd_text_received` in the main loop.
6. Replace the lap-derived render request with a text-frame render request.
7. Keep the existing render retry state machine.
8. Render bottom center:

```text
row 15: line 1
row 16: line 2
row 17: line 3
col = max(0, (50 - strlen(line)) / 2)
```

9. Render cycle:

```text
clear -> write row 15 -> write row 16 -> write row 17 -> draw
```

Packet budget:

```text
clear + 3 writes + draw = 5 ESP-NOW packets
```

This is below the existing 10-packet ceiling.

Compatibility:

- Keep the existing lap-time characteristic initially.
- iOS can stop using it once OSD text is confirmed.
- Older iOS versions can still send lap times to older firmware.
- New iOS should treat the OSD text characteristic as required for the new
  goggle display and surface a firmware-version error if it is missing.

## iOS Plan

Files:

- `app/HDZap/Models/LapTimer.swift`
- `app/HDZap/Models/BluetoothManager.swift`
- `app/HDZap/Views/TimerView.swift`
- `app/HDZap/Views/ConnectionView.swift`
- `app/HDZap/Views/EditorialTheme.swift`

Steps:

1. Add a persisted target lap count setting.

```swift
@AppStorage("targetLapCount") private var targetLapCount = 7
```

2. Add a race target section to the existing gear/settings sheet
   (`ConnectionView` today).
3. Use a `Stepper` or numeric input with range `2...99`.
4. Display the derived target pace in that section:

```text
Target 7L @ 15.00s
```

5. Add a small metrics helper, for example `RaceMetrics`.
6. Use that helper in `TimerView` for both iOS display and OSD line generation.
7. Extend the summary band to include target/diff/need-bank.
8. Add `BluetoothManager.sendOSDText(lines:)`.
9. Discover the new OSD text characteristic.
10. On lap tap:

```text
lapTimer.lap()
calculate RaceMetrics snapshot
update iOS pace/diff/need display
send three OSD text rows over BLE
```

11. On reset:

- Clear local laps.
- Send existing reset/clear command to firmware.
- Clear or reset iOS metrics display.

## iOS UI Placement

Timer summary should include the same facts as the goggle, but with clearer
labels:

```text
Target   7L @ 15.00
Avg      22.222
Pace     6L
Diff     +1.00
Need     -0.2/L
```

If the session is ahead of target:

```text
Diff     -1.00
Bank     +0.2/L
```

If no laps exist yet:

- Avg: `-`
- Pace: `-`
- Diff: `-`
- Need/Bank: `-`
- OSD text should not be sent until the first lap, unless the user explicitly
  taps Test OSD.

## Edge Cases

- `targetLapCount < 2`: prevent in UI and clamp in metrics.
- `currentLapCount == 0`: no avg, pace, diff, or need/bank.
- `currentLapCount >= targetLapCount`: use remaining laps `1` for display math
  so division remains defined, but prefer an achieved/over-target label in iOS.
- `avgLapSec <= 0`: no pace projection.
- BLE not ready: keep local iOS state, surface the existing BLE error, do not
  roll back the lap.
- OSD text characteristic missing: show a firmware update error for the new
  display path.
- Text longer than 19 bytes: compact in iOS first, then firmware truncates only
  as a final guard.

## Tests and Verification

iOS:

- Unit-test `RaceMetrics` for:
  - target 7 -> 15.0 seconds
  - elapsed 31.0, lap count 2 -> `D+1.00 NEED -0.2/L`
  - ahead-of-target -> `BANK +.../L`
  - no-lap state
  - target lap count clamp
- Verify `TimerView` shows Target, Avg, Pace, Diff, and Need/Bank.
- Verify `ConnectionView` persists target lap count through app restart.

Firmware:

- Build with PlatformIO:

```sh
cd firmware && pio run
```

- Verify BLE characteristic discovery includes `...d487`.
- Verify row writes stage exactly one frame.
- Verify row `2` triggers one render request only after all rows are present.
- Verify render cycle stays at 5 ESP-NOW packets.
- Verify reset and clear still cancel pending renders.

Hardware:

- Connect iPhone to M5StickS3.
- Set target lap count to 7.
- Record laps at known elapsed times.
- Confirm iOS and goggle show the same diff and need/bank values.
- Confirm line block appears bottom center on HDZero goggle.
- Confirm radio retry/OSD LOST behavior still works.

## Implementation Order

1. Add iOS `RaceMetrics` and local UI display.
2. Add target lap count setting to the existing settings sheet.
3. Add BLE OSD text characteristic in firmware.
4. Add firmware row staging and bottom-center render path.
5. Add iOS BLE discovery and `sendOSDText(lines:)`.
6. Wire `TimerView.recordLap()` to send the three OSD rows.
7. Run iOS and firmware builds.
8. Hardware-test goggle placement and BLE/ESP-NOW reliability.

## Out of Scope

- Making M5Stick calculate target pace.
- Sending binary lap/session data for firmware interpretation.
- Making target session length configurable.
- Changing the 90-second time-attack model.
- Redesigning the M5Stick LCD screen.
- Committing, pushing, or deploying.
