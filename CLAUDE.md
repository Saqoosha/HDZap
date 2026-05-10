# HDZero OSD Lap Timer

## Project Overview

iPhone manual lap timer → BLE → ESP32 bridge → ESP-NOW → HDZero goggle OSD.
FPV drone racing use case: operator taps LAP on phone, lap time appears on pilot's goggle.

## Repository Structure

```
firmware/                 ESP32 PlatformIO project (Arduino framework)
app/                      iOS SwiftUI app (iOS 18+, xcodegen)
docs/                     Architecture, research, TestFlight setup (only docs/manual/ + docs/flash/ ship to Pages)
docs/manual/              End-user manual (en + ja); served on GitHub Pages
docs/flash/               Browser firmware flasher (esptool-js, M5StickS3); served on GitHub Pages
scripts/                  build / upload-testflight / release helpers
.github/workflows/        CI: builds firmware for both branches, composes Pages artefact, deploys
.claude/skills/release/   Release skill (auto-triggers on "release" / "ship it" / etc.)
```

## Branching & Deployment

- `develop` (default) → CI deploys staging at `/dev/`, `/dev/flash/`, `/dev/ja/`.
- `main` (PR-only, branch-protected) → CI deploys production at `/`, `/flash/`, `/ja/`.
- Pages is one site per repo, so the workflow checks out **both** branches on every push, builds firmware for each, and composes a single `_site/` (main at root, develop mirrored under `/dev/`). Pushing to either branch refreshes its slice without disturbing the other.
- Releases promote develop → main via a release PR driven by [`scripts/release.sh`](scripts/release.sh) / the [`release`](.claude/skills/release/SKILL.md) skill. Direct push to `main` is rejected by branch protection.
- `manifest.json` is stamped per side as `<branch>-<short sha>` so the live page identifies which build it is.

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
- Service UUID: `f47ac10b-58cc-4372-a567-0e02b2c3d490` (bumped from `…d48e` to ship CHR_FW_VERSION `…d48f`, a READ-only string seeded from `git describe --tags --dirty --always` via the PlatformIO pre-script `firmware/scripts/inject_version.py`; iOS reads it on connect and warns when the leading major-version component disagrees with the app's `CFBundleShortVersionString`. The prior `…d48d → …d48e` bump shipped CHR_DEVICE_NAME `…d489`, the renameable BLE-advertised name char; iOS writes the new UTF-8 name, firmware persists to NVS namespace `hdzero` key `btname` (default `HDZeroOSD`) and `ESP.restart()`s so `BLEDevice::init(name)` re-runs with the new value, and bonded iOS auto-reconnects after the ~3 s reboot. The earlier `…d48c → …d48d` bump shipped CHR_OSD_LAYOUT `…d48b` with `PROPERTY_WRITE_NR` for `writeWithoutResponse` slider drags; iOS caches each char's property bitmap and silently drops `writeWithoutResponse` on a char whose cached bitmap doesn't advertise the WRITE_NR bit, so a property change is a GATT shape change for cache-invalidation purposes.) Adding a characteristic — or changing its properties — without a service bump is safe ONLY when no existing iOS build attempts to read or write it; bump in the same change that ships an iOS build using the new char/property.
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
- `espnow_recv.h` — owns the unified ESP-NOW recv callback registration (and the promiscuous-mode RX hook for backpack telemetry that doesn't address us directly). `espnow_recv_attach_cb()` is called from `setup()` and after every ESP-NOW reinit; the callback fans out to bind capture (gated on `g_sniff_active`), flight-battery decode (gated on `hdzap_telemetry_source_matches`), and telemetry-debug capture (gated on `g_telemetry_sniff_active`). No module other than this one calls `esp_now_register_recv_cb` — adding a new caller would silently overwrite the unified handler.
- `tx_sniff.h` — flag-only TX UID bind capture. `sniff_start/sniff_stop` toggle `g_sniff_active`; the actual capture happens inside the unified callback in `espnow_recv.h`. `g_sniff_uid` + `g_sniff_captured` guarded by `g_sniff_mux`. `g_sniff_active` is read by main.cpp's deep-sleep gate so a deep sleep can't drop a staged sniff session.
- `telemetry_sniff.h` — flag-only Backpack telemetry debug sniffer. `telemetry_sniff_start/stop` toggle `g_telemetry_sniff_active`; the unified callback in `espnow_recv.h` calls `telemetry_sniff::capture_if_active(...)` to copy 20-byte records into a portMUX-guarded ring drained one-per-loop in main.cpp. `g_telemetry_sniff_active` also feeds the deep-sleep gate. Coexists with `tx_sniff` — both ride the same callback, no preempt logic needed.
- `flight_battery_telemetry.h` — staged flight-pack CRSF Battery sample. `flight_battery_on_espnow_payload()` calls `crsfp_try_battery_from_any_msp_payload` (in `crsf_battery_telemetry.h`), and on success stages `g_flight_battery_staged_sample` for main loop consumption via `flight_battery_consume_if_staged`. `g_flight_battery_dropped` counts staged-overwrite events; main.cpp logs on edge changes. The CRSF parser tracks per-reason rejection counters (`g_crsf_rej_*` / `g_crsf_accepts`) so "no telemetry decoded" failure modes can be diagnosed from serial — main.cpp emits a 30 s reject-reason summary while `g_telemetry_source_configured` is set but no decode has happened.
- `osd_text_display.h` — iOS-owned 4-row goggle OSD text. Per-row dirty bitmap; `render()` writeStrings just the dirty rows + draw (no clear), and the goggle's overlay buffer keeps prior content between writes. `m_dirty` survives across retries so the state machine can re-emit the same bits; `clearDirtyBits(mask)` is the surgical drop, called from main.cpp on verify-success / give-up.
- `battery_monitor.h` — PMIC poll + alarm tier (None/Low/Critical with hysteresis) + silence latch. Single `tick(now, silenceRequested) → Outcome` (Throttled/StateChanged/TierChanged) replaces the prior `poll()` + `silence()` + `consumeSilencedDirty()` trio; silence-dirty edges fold into `StateChanged`, and `TierChanged` is returned *instead of* `StateChanged` on a tier transition (callers test `!= Throttled` for the BLE+LCD push and `== TierChanged` for the sticky strip message). Actuator-free — `main.cpp` owns LCD/BLE/speaker dispatch (edge-triggered `Serial.printf` for PMIC validity / silence no-op diagnostics only). Beep cadence is a separate destructive-read channel: `consumeBeepDue(now)` burns the slot on a `true` return; pair with `scheduleBeepRetry(now)` from main.cpp on a `M5.Speaker.tone()` failure so the next ~1 s retries instead of waiting out the 15-30 s cadence.
- `nvs_store.h` — UID persistence (sentinel-protected) + deep-sleep timeout (`slpmin`, single-byte putUChar — no sentinel, one NVS entry can't tear). Namespace "hdzero".
- `power_log.h` — SPIFFS-backed CSV append at `/power.csv` for issue #5 phase 2/3 measurement runs. Schema = `millis,voltage_mv,percent,charging,panel_asleep,ble_connected`; main.cpp throttles to 30 s and sentinel-marks out-of-range VBAT readings as -1. Schema-mismatch detection on boot wipes incompatible old logs (with CR strip); stale `/power.csv.tmp` from interrupted rotate is cleaned up at boot. Auto-rotates at ~110 KB to keep the most recent ~80 KB; rotate write failures preserve the original. `dumpToSerial()` runs in `setup()`.
- `stick_display.h` — M5StickS3 LCD status display, no business logic. `sleepPanel()` / `wakePanel()` / `isPanelAsleep()` own the panel power state for issue #5 phase 1; `sleepPanel()` calls `M5.Display.sleep()` only — do NOT prepend `setBrightness(0)` or it corrupts LGFX's `_brightness` cache and `wakeup()` restores brightness=0. `wakePanel()` waits 5 ms after `wakeup()` (ST7789 SLPOUT settling) then forces a full repaint.
- `main.cpp` — event loop; consumes staged BLE data under `g_ble_mux`, runs heavy work (NVS, ESP-NOW reinit) outside the BLE task, and hosts the render-retry state machine (`IDLE` → `PENDING` → `WAITING_ACK`). Snapshots the dispatched dirty mask at render time so verify-success can clear *only* the bits we sent (BLE writes during WAITING_ACK survive). OSD delivery uses MAC-layer feedback from `esp_now_register_send_cb` (counters in `espnow_link.h`) — if any packet in a cycle fails to deliver, `render()` is re-dispatched up to `MAX_RENDER_RETRIES` times. The `IDLE && hasDirty → requestRender` catch-up trigger picks up bits that arrived during a verify window or while ESP-NOW was down. `cancelRender()` drops the cycle when stale state would be rendered (UID change, OSD clear, laps reset). Owns issue #5 power-saving glue: phase-1 LCD-off (30 s idle, `markActivity()` resets on button or OSD-text dirty), phase-2-redux runtime tuning (`setCpuFrequencyMhz(80)`, BLE/WiFi TX power), phase-3 deep sleep (`g_sleep_timeout_ms` from NVS-backed `slpmin`, ext1 wake on BtnA/BtnB; gate also guards on `g_sniff_active` and pending `g_sleep_minutes_changed`), and the per-30-s power-log append. Sleep-config consumer block runs BEFORE the sleep gate so an iOS write at the idle threshold is never lost.

## Conventions

- Firmware: C++ headers in include/, single source in src/
- iOS: @MainActor + @Observable (not ObservableObject), @Environment for DI
- BLE callbacks stage paired state under `g_ble_mux` (UID staging, lap frame); idempotent single-flag commands use bare `volatile`. See `ble_service.h` shared-state docstring. Heavy work (NVS, ESP-NOW reinit) runs in main loop, not in callbacks.
- `CBCentralManager` delegate queue MUST be main (`queue: nil`). `BluetoothManager` is `@MainActor`; `recordError` runtime-asserts main-actor isolation.
- NVS namespace: "hdzero"; keys: `"uid"` (6 bytes) + `"init"` (sentinel for torn-save detection). Save order is remove sentinel → write uid → write sentinel; loadUid warns but still returns a present uid when the sentinel is absent (fail-soft — dropping a valid UID on every torn save would be worse than a log line).
- Unicast MAC invariant: `uid[0] & 0x01 == 0` at every assignment site
- `M5.BtnA/B.wasPressed()` is non-consuming (pure read of a latched edge), so multiple consumers can observe the same press in one tick — current pattern: `markActivity()` (LCD wake) reads the edge, and the same `wasPressed()` derives a `silenceReq` flag passed into `batteryMonitor.tick(now, silenceReq)` (alarm silence; `tick()` no-ops the silence when tier==None or already silenced). Don't add a "consume" wrapper — the multi-observer model is the design.

## Hardware

- Target / current: M5StickS3 (ESP32-S3, 1.14" LCD, 2 buttons, AXP2101 PMIC)
- Goggle: HDZero with ELRS backpack
