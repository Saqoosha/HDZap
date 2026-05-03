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
- Service UUID: `f47ac10b-58cc-4372-a567-0e02b2c3d489` (bumped from `…d479` to defeat iOS CoreBluetooth's per-peripheral GATT cache when Battery was added)
- `BLEServer::createService()` requires explicit `numHandles` (currently 32) — default 15 silently truncates overflow characteristics, last visible symptom was iOS only seeing 5 of 8 chars
- Bind phrase UID derivation: MD5(`-DMY_BINDING_PHRASE="<phrase>"`), first 6 bytes, bit0 cleared
- VTX not required for backpack OSD display
- Binding overwrites existing UID — scenarios 1 & 2 avoid this by reusing existing UID

## Architecture Boundaries

- `msp.h` — packet building only, no I/O
- `espnow_link.h` — ESP-NOW init/send/reinit + broadcast helper, no business logic
- `osd.h` — OSD commands via ESP-NOW, no layout knowledge
- `ble_service.h` — BLE GATT server, stages payloads + sets flags for main loop
- `bind.h` — ELRS bind protocol, stateless (broadcast via espnow_link)
- `tx_sniff.h` — ESP-NOW recv callback for TX UID capture; sniff_start/stop register/unregister the global recv_cb slot; g_sniff_uid + g_sniff_captured guarded by g_sniff_mux
- `osd_text_display.h` — iOS-owned 4-row goggle OSD text. Per-row dirty bitmap; `render()` writeStrings just the dirty rows + draw (no clear), and the goggle's overlay buffer keeps prior content between writes. `m_dirty` survives across retries so the state machine can re-emit the same bits; `clearDirtyBits(mask)` is the surgical drop, called from main.cpp on verify-success / give-up.
- `nvs_store.h` — UID persistence, namespace "hdzero"
- `stick_display.h` — M5StickS3 LCD status display, no business logic. `sleepPanel()` / `wakePanel()` / `isPanelAsleep()` own the panel power state for issue #5 phase 1; `sleepPanel()` calls `M5.Display.sleep()` only — do NOT prepend `setBrightness(0)` or it corrupts LGFX's `_brightness` cache and `wakeup()` restores brightness=0. `wakePanel()` waits 5 ms after `wakeup()` (ST7789 SLPOUT settling) then forces a full repaint.
- `main.cpp` — event loop; consumes staged BLE data under `g_ble_mux`, runs heavy work (NVS, ESP-NOW reinit) outside the BLE task, and hosts the render-retry state machine (`IDLE` → `PENDING` → `WAITING_ACK`). Snapshots the dispatched dirty mask at render time so verify-success can clear *only* the bits we sent (BLE writes during WAITING_ACK survive). OSD delivery uses MAC-layer feedback from `esp_now_register_send_cb` (counters in `espnow_link.h`) — if any packet in a cycle fails to deliver, `render()` is re-dispatched up to `MAX_RENDER_RETRIES` times. The `IDLE && hasDirty → requestRender` catch-up trigger picks up bits that arrived during a verify window or while ESP-NOW was down. `cancelRender()` drops the cycle when stale state would be rendered (UID change, OSD clear, laps reset). Owns the LCD idle-timeout (`IDLE_TIMEOUT_MS` = 30 s) and `markActivity()` helper; activity = button press OR OSD-text dirty-row arrival, BLE config events deliberately don't count.

## Conventions

- Firmware: C++ headers in include/, single source in src/
- iOS: @MainActor + @Observable (not ObservableObject), @Environment for DI
- BLE callbacks stage paired state under `g_ble_mux` (UID staging, lap frame); idempotent single-flag commands use bare `volatile`. See `ble_service.h` shared-state docstring. Heavy work (NVS, ESP-NOW reinit) runs in main loop, not in callbacks.
- `CBCentralManager` delegate queue MUST be main (`queue: nil`). `BluetoothManager` is `@MainActor`; `recordError` runtime-asserts main-actor isolation.
- NVS namespace: "hdzero"; keys: `"uid"` (6 bytes) + `"init"` (sentinel for torn-save detection). Save order is remove sentinel → write uid → write sentinel; loadUid warns but still returns a present uid when the sentinel is absent (fail-soft — dropping a valid UID on every torn save would be worse than a log line).
- Unicast MAC invariant: `uid[0] & 0x01 == 0` at every assignment site
- `M5.BtnA/B.wasPressed()` is non-consuming (pure read of a latched edge), so multiple consumers can observe the same press in one tick — current pattern: `markActivity()` (LCD wake) + `batteryMonitor.silence()` (alarm silence; no-ops when tier==None) both fire on the same edge. Don't add a "consume" wrapper — the multi-observer model is the design.

## Hardware

- Target / current: M5StickS3 (ESP32-S3, 1.14" LCD, 2 buttons, AXP2101 PMIC)
- Goggle: HDZero with ELRS backpack
