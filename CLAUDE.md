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
- Service UUID: `f47ac10b-58cc-4372-a567-0e02b2c3d479`
- Bind phrase UID derivation: MD5(`-DMY_BINDING_PHRASE="<phrase>"`), first 6 bytes, bit0 cleared
- VTX not required for backpack OSD display
- Binding overwrites existing UID — scenarios 1 & 2 avoid this by reusing existing UID

## Architecture Boundaries

- `msp.h` — packet building only, no I/O
- `espnow_link.h` — ESP-NOW init/send/reinit + broadcast helper, no business logic
- `osd.h` — OSD commands via ESP-NOW, no layout knowledge
- `ble_service.h` — BLE GATT server, stages payloads + sets flags for main loop
- `bind.h` — ELRS bind protocol, stateless (broadcast via espnow_link)
- `lap_display.h` — lap formatting + OSD rendering
- `nvs_store.h` — UID persistence, namespace "hdzero"
- `stick_display.h` — M5StickS3 LCD status display, no business logic
- `main.cpp` — event loop; consumes staged BLE data under `g_ble_mux` and runs heavy work (NVS, ESP-NOW reinit) outside the BLE task

## Conventions

- Firmware: C++ headers in include/, single source in src/
- iOS: @MainActor + @Observable (not ObservableObject), @Environment for DI
- BLE callbacks stage data under `g_ble_mux` + set a flag; main loop processes (no heavy work in callbacks)
- NVS namespace: "hdzero", key: "uid"
- Unicast MAC invariant: `uid[0] & 0x01 == 0` at every assignment site

## Hardware

- Target / current: M5StickS3 (ESP32-S3, 1.14" LCD, 2 buttons, AXP2101 PMIC)
- Goggle: HDZero with ELRS backpack
