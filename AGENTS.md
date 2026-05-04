# HDZero OSD Lap Timer

## Project Overview

iPhone manual lap timer → BLE → ESP32 bridge → ESP-NOW → HDZero goggle OSD.
FPV drone racing use case: operator taps LAP on phone, lap time appears on pilot's goggle.

## Repository Structure

```
firmware/     ESP32 PlatformIO project (Arduino framework)
app/          iOS SwiftUI app (iOS 18+, xcodegen)
docs/         Research reports and architecture docs
scripts/      Test scripts
```

## Build Commands

```sh
# Firmware
cd firmware && pio run                    # build
cd firmware && pio run -t upload          # flash
cd firmware && pio device monitor         # serial 115200

# iOS
cd app && xcodegen generate               # regenerate .xcodeproj after changes
# Then build in Xcode (BLE requires physical device)
```

## Key Technical Constraints

- **NEVER use delay() between ESP-NOW packets** — breaks packet delivery
- ESP-NOW max 10 packets per OSD cycle (clear + 8 writes + draw)
- OSD grid: 50x18, lowercase ASCII maps to FPV glyphs (auto-uppercase in osd.h)
- BLE UUIDs must match between firmware (ble_service.h) and iOS (BluetoothManager.swift)
- Service UUID: `f47ac10b-58cc-4372-a567-0e02b2c3d489` (bumped from `…d479` when the Battery characteristic was added; iOS CoreBluetooth caches GATT per-peripheral for unbonded devices, so a new service UUID is the only reliable cache-invalidation hook short of rebooting the iPhone). **Adding a characteristic without a service bump is safe ONLY when no existing iOS build attempts to read or write it** — iOS won't see the new char until the service UUID changes. CHR_SLEEP_CONFIG (`…d48a`) was added without a bump on this basis; bump to `…d48b` (or next free) in the same change that ships an iOS build using the char.
- `BLEServer::createService()` must be passed an explicit `numHandles` covering `1 (service decl) + 2 per characteristic + 1 per BLE2902 descriptor` — the default of 15 silently truncates overflow characteristics. The call uses 32 for headroom; recompute and bump if a future GATT addition pushes the count past ~28.
- Bind phrase UID derivation: MD5(`-DMY_BINDING_PHRASE="<phrase>"`), first 6 bytes, bit0 cleared
- VTX not required for backpack OSD display
- Binding overwrites existing UID — scenarios 1 & 2 avoid this by reusing existing UID

## Architecture Boundaries

- `msp.h` — packet building only, no I/O
- `espnow_link.h` — ESP-NOW init/send/reinit + broadcast helper, no business logic
- `osd.h` — OSD commands via ESP-NOW, no layout knowledge
- `ble_service.h` — BLE GATT server, stages payloads + sets flags for main loop
- `bind.h` — ELRS bind protocol, stateless (broadcast via espnow_link)
- `tx_sniff.h` — ESP-NOW recv callback for TX UID capture; sniff_start/stop register/unregister the global recv_cb slot; g_sniff_uid + g_sniff_captured guarded by g_sniff_mux. `g_sniff_active` (set on success of sniff_start, cleared on sniff_stop) is read by main.cpp's deep-sleep gate so a deep sleep can't silently drop the BLE-staged sniff session.
- `osd_text_display.h` — iOS-owned 4-row goggle OSD text. Per-row dirty bitmap; `render()` writeStrings just the dirty rows + draw (no clear), and the goggle's overlay buffer keeps prior content between writes. `m_dirty` survives across retries so the state machine can re-emit the same bits; `clearDirtyBits(mask)` is the surgical drop, called from main.cpp on verify-success / give-up.
- `nvs_store.h` — UID persistence (sentinel-protected) + deep-sleep timeout (`slpmin`, single-byte putUChar — no sentinel needed; one NVS entry can't be torn at the entry level). Namespace "hdzero".
- `power_log.h` — SPIFFS-backed CSV append at `/power.csv` for issue #5 phase 2/3 measurement runs. Schema = `millis,voltage_mv,percent,charging,panel_asleep,ble_connected`; main.cpp throttles to one row per 30 s and sentinel-marks out-of-range VBAT readings as -1. Schema-mismatch detection on boot wipes incompatible old logs (with CR strip so println-written headers compare equal); a stale `/power.csv.tmp` from an interrupted rotate is also cleaned up at boot. Auto-rotates at ~110 KB to keep the most recent ~80 KB inside the 128 KB SPIFFS partition; if the rotate write fails the original is preserved (no half-rotated tmp ever replaces the source). `dumpToSerial()` runs in `setup()` so plug-in-USB-after-battery-run prints the trail without a separate tool.
- `stick_display.h` — M5StickS3 LCD status display, no business logic. Battery widget (top row of UID band, left of BLE pill) is fed by `main.cpp` via `setBattery(percent, charging)`; the display owns layout only.
- `battery_monitor.h` — AXP2101 percent + charging poll, alarm tier (NONE/LOW/CRITICAL) with hysteresis, silenced-latch + beep cadence. Side-effect free — `main.cpp` consumes its outputs and drives the LCD, BLE notify, and the speaker.
- `main.cpp` — event loop; consumes staged BLE data under `g_ble_mux`, runs heavy work (NVS, ESP-NOW reinit) outside the BLE task, and hosts the render-retry state machine (`IDLE` → `PENDING` → `WAITING_ACK`). Snapshots the dispatched dirty mask at render time so verify-success can clear *only* the bits we sent (BLE writes during WAITING_ACK survive). OSD delivery uses MAC-layer feedback from `esp_now_register_send_cb` (counters in `espnow_link.h`) — if any packet in a cycle fails to deliver, `render()` is re-dispatched up to `MAX_RENDER_RETRIES` times. The `IDLE && hasDirty → requestRender` catch-up trigger picks up bits that arrived during a verify window or while ESP-NOW was down. `cancelRender()` drops the cycle when stale state would be rendered (UID change, OSD clear, laps reset). Owns issue #5 power-saving glue: phase-1 LCD-off (30 s idle, `markActivity()` resets on button or OSD-text dirty), phase-2-redux runtime tuning (`setCpuFrequencyMhz(80)`, BLE/WiFi TX power), phase-3 deep sleep (`g_sleep_timeout_ms` from NVS-backed `slpmin`, ext1 wake on BtnA/BtnB; gate also guards on `g_sniff_active` and pending `g_sleep_minutes_changed`), and the per-30-s power-log append (sentinel-marks VBAT readings outside [2500, 4400] mV). The sleep-config consumer block runs BEFORE the sleep gate so an iOS write at the idle threshold is never lost.

## Conventions

- Firmware: C++ headers in include/, single source in src/
- iOS: @MainActor + @Observable (not ObservableObject), @Environment for DI
- BLE callbacks stage paired state under `g_ble_mux` (UID staging, lap frame); idempotent single-flag commands use bare `volatile`. See `ble_service.h` shared-state docstring. Heavy work (NVS, ESP-NOW reinit) runs in main loop, not in callbacks.
- `CBCentralManager` delegate queue MUST be main (`queue: nil`). `BluetoothManager` is `@MainActor`; `recordError` runtime-asserts main-actor isolation.
- NVS namespace: "hdzero"; keys: `"uid"` (6 bytes) + `"init"` (sentinel for torn-save detection). Save order is remove sentinel → write uid → write sentinel; loadUid warns but still returns a present uid when the sentinel is absent (fail-soft — dropping a valid UID on every torn save would be worse than a log line).
- Unicast MAC invariant: `uid[0] & 0x01 == 0` at every assignment site

## Hardware

- Target / current: M5StickS3 (ESP32-S3, 1.14" LCD, 2 buttons, AXP2101 PMIC)
- Goggle: HDZero with ELRS backpack
- Buttons: BtnA + BtnB silence the battery low/critical alarm (sticky message stays; tier escalation re-arms beeps). No other firmware feature consumes button input.
