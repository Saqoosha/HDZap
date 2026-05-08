# M5StickS3 Screen Redesign — Editorial-Lite

**Date:** 2026-04-27
**Status:** Approved (brainstorm) — pending implementation plan
**Scope:** firmware/include/stick_display.h + main.cpp call sites only

## Summary

Redesign the M5StickS3 LCD to match the visual language of the iOS Editorial Console while keeping the firmware operating on data it already has. No BLE protocol changes. UID is the new hero of the screen, formatted as comma-separated decimal digits to match what the HDZero goggle itself shows. Last lap (number + time) takes the bottom band. A two-indicator status strip (BLE, RADIO) and a sticky message slot occupy the footer.

## Why this scope

The M5Stick is the operator's at-a-glance status display. The two questions it has to answer instantly are:

1. *"Am I paired to the right goggle?"* — UID
2. *"Did my last LAP tap reach?"* — Last lap card + RADIO indicator

Mirroring the full iOS session (90 s bar, pace, FINAL/DONE) would require a new BLE characteristic that pushes session state at ~10 Hz. The product value is small — the operator is already looking at the phone — so this design stays inside what the firmware can compute locally from the lap history and link state.

## Visual language

The M5StickS3 LCD is a dark panel by hardware default. The editorial paper-white palette would not survive on it (the Editorial console also used the inverse pairing on dark surfaces in the prototype). We invert: black background, ink-white text, hairline rules at ~18 % white, the same accent pink (`#db65a9`) for live/lap-arrival state, the same green/red/yellow used today for status verdicts.

**Color tokens** (resolved against M5GFX 16-bit RGB565):

| Token        | Hex      | Use                                                   |
|--------------|----------|-------------------------------------------------------|
| ink          | `#FFFFFF`| Primary text                                          |
| sub          | ~55 % w  | Captions, labels                                      |
| dim          | ~32 % w  | Inactive metrics, comma separators in UID             |
| hair         | ~18 % w  | 1 px horizontal rules                                 |
| accent       | `#DB65A9`| Lap arrival flash, BIND mode                          |
| ok-green     | `#9BE38A`| BLE up, RADIO up, TEST OK                             |
| warn-yellow  | `#FFD86B`| BIND in progress, transitional                        |
| warn-orange  | `#FF9F4A`| LAPS FULL, retry strips                               |
| err-red      | `#FF6464`| BLE off, RADIO down, TEST LOST, NVS fail              |

Opacities are baked into RGB565 by darkening toward black, since the panel has no alpha. We pre-compute a small lookup of constants in `stick_display.h` so no runtime math is needed.

**Typography** uses M5GFX bundled fonts. Hero numerics need a tabular-numeric proportional font; we use a built-in vector font (e.g. `lgfxJapanGothic_28` or one of the GFX free fonts that ships with `M5GFX`) for the UID hero and the lap-time line, falling back to the legacy 6×8 / 12×16 bitmap fonts for caption rows. Font selection is finalized during implementation against actual rendering on hardware — the design constrains size class, not the specific font asset.

## Layout — V2 (UID + Lap two-band)

```
┌──────────────────────────────────────────┐
│  UID                          ● BLE      │   ← caption row (sub)
│                                          │
│  96,210,83,138,178,158                   │   ← UID hero (~22-26 px)
│  ─────────────────────────────────────   │   ← hair rule
│  LAST LAP            TIME                │   ← caption row (sub)
│  07                  00:14.382           │   ← lap number + time
│  ─────────────────────────────────────   │   ← hair rule
│  ● RADIO            7 LAPS · NO ERR      │   ← strip (sub / sticky)
└──────────────────────────────────────────┘
```

Vertical regions (rotation = 1, height = 135):

| Region            | y range    | Owner                                  |
|-------------------|------------|----------------------------------------|
| UID band          | 0 .. 60    | UID hero + UID caption + BLE pill      |
| Hair rule         | 60 .. 61   | static                                 |
| Lap band          | 64 .. 110  | Last-lap number (left) + time (right)  |
| Hair rule         | 110 .. 111 | static                                 |
| Strip             | 113 .. 135 | RADIO indicator + sticky message slot  |

The strip is the same sticky surface today's `m_msg` lives on — preserving the property that "errors persist across status / lap redraws until cleared."

## States

The state machine lives entirely in firmware-visible signals. No new fields cross BLE.

| State            | Trigger                                        | Visual delta vs idle                                                                              |
|------------------|-----------------------------------------------|---------------------------------------------------------------------------------------------------|
| IDLE / READY     | BLE connected, no laps yet                    | Lap number = "—", time = "—:—.———", strip = "RADIO ● · READY"                                     |
| LAP RECEIVED     | `g_lap_received` fires                        | Lap number flashes pink for ~1 s, then settles to white                                           |
| BLE DISCONNECTED | `g_ble_connected` false                       | Top pill turns red "○ BLE OFF". Last lap fades to dim. Strip = "RADIO ● · PHONE LINK LOST"        |
| ESP-NOW DOWN     | `espnow_ready` false                          | UID dims to ~50 %. Strip = "○ RADIO DOWN · OSD LOST". Both indicators red.                       |
| TEST OSD         | `g_osd_test_requested` resolves               | Lap band hijacked for ~3 s: caption "★ TEST OK" / "✗ TEST LOST", verdict word in green / red     |
| BINDING          | `g_bind_requested` resolves                   | Whole UID band yellow. Lap band hijacked: caption "BIND PACKET → GOGGLE", verdict word "SENT" / "FAIL" |
| LAPS FULL        | `addLap` returns false                        | Strip turns orange: "LAPS FULL"                                                                   |
| RETRY            | render-state machine retries                  | Strip turns orange: "RETRY"                                                                       |
| OSD LOST         | render-state machine exhausts retries         | Strip turns red: "OSD LOST"                                                                       |
| NVS FAIL         | `nvs_store::saveUid` returns false            | Strip turns red: "NVS SAVE FAIL"                                                                  |
| OSD CLEARED      | `g_osd_clear_requested` succeeds              | Strip = cyan "OSD CLEARED" (existing behavior preserved)                                          |
| RESET            | `g_osd_reset_laps_requested` succeeds         | Lap band returns to "—" / "—:—.———", strip cleared                                                |

The lap-area takeover for TEST and BINDING is bounded (already auto-clears via the existing message-strip flow). After the takeover window the lap band returns to the most recent lap from `lapDisplay`.

The pink flash on LAP RECEIVED is a single 1 s color transition driven from the existing `update()` tick — no new timer subsystem.

## API

`StickDisplay` keeps its current public surface so `main.cpp` doesn't need restructuring beyond minor argument tweaks:

```cpp
class StickDisplay {
public:
    void begin();
    void showStatus(const uint8_t uid[6], bool bleConnected, bool radioReady);  // radioReady is new
    void showLap(uint8_t num, uint32_t ms);
    void showTestResult(bool ok);                              // new — replaces showMessage("TEST OK"...)
    void showBindResult(bool ok);                              // new — replaces showMessage("BIND SENT"...)
    void showMessage(const char* msg, uint16_t color = ...);   // unchanged — strip
    void clearMessage();
    void update();
};
```

`radioReady` is a new third argument on `showStatus`. `showTestResult` and `showBindResult` exist to encode the lap-band takeover (which `showMessage` cannot do today — it only writes to the 16 px strip). The existing `showMessage` calls in `main.cpp` keep working without change.

`main.cpp` callers update:

- `setup()`: `showStatus(g_uid, false, espnow_ready)`
- BLE-state handler: `showStatus(g_uid, g_ble_connected, espnow_ready)`
- After `applyStagedUid`: same `showStatus` signature
- TEST OSD success / failure → `showTestResult(true|false)` instead of `showMessage("TEST OK"...)`
- BIND success / failure → `showBindResult(true|false)` instead of `showMessage("BIND SENT"...)`

All other `showMessage` sites (LAPS FULL, RETRY, OSD LOST, ESPNOW DOWN, NVS SAVE FAIL, OSD CLEARED, RESET variants) keep using the strip and stay as-is.

## Drawing strategy

The non-overlapping region invariant from the current implementation is preserved. Each region has a fixed (x, y, w, h) and its draw routine fills only that rectangle, so a lap update never paints over the UID, and the strip never paints over the lap band. This keeps redraws cheap and avoids any flicker from full-screen clears.

The pink flash and dim transitions are achieved by re-drawing the affected region with a different foreground color — no compositing, no animation framework. The existing `update()` tick fires often enough (every loop iteration) to drive a 1 s flash by remembering when the lap was received and re-drawing the lap number once when the flash ends.

## What is explicitly out of scope

- New BLE characteristics or protocol additions
- Animations beyond the single 1 s color transition
- Custom font asset loading from SPIFFS / LittleFS — we use M5GFX-bundled fonts only
- Mirroring iOS session state (elapsed, remaining, pace, FINAL LAP)
- Multi-page screens / button-driven navigation
- Per-state haptic / buzzer cues

## Risks / open questions

- **Decimal UID width:** worst case `255,255,255,255,255,255` is 23 chars. At ~22 px hero font on a 240 px display we have ~12 chars per line — the UID will overflow on a single line. Implementation will need to either use a smaller font for the hero (e.g. ~18 px), or break the UID across two lines (rejected in V3 mockup). The V2 mockup assumes the smaller-font path.
- **Bundled font availability:** the chosen vector font must ship with M5GFX 0.x as configured in `platformio.ini`. We verify this in the implementation plan before committing to a specific font asset.
- **Color fidelity:** the M5StickS3 panel is small and contrast varies with viewing angle. The chosen colors are visually distinct in well-lit conditions; on-hardware verification is part of the implementation plan.
