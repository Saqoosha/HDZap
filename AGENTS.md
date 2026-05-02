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
- `tx_sniff.h` — ESP-NOW recv callback for TX UID capture; sniff_start/stop register/unregister the global recv_cb slot; g_sniff_uid + g_sniff_captured guarded by g_sniff_mux
- `lap_display.h` — lap formatting + OSD rendering. `render()` is idempotent (pulls from in-memory lap history) so retries are safe.
- `nvs_store.h` — UID persistence, namespace "hdzero"
- `stick_display.h` — M5StickS3 LCD status display, no business logic
- `main.cpp` — event loop; consumes staged BLE data under `g_ble_mux`, runs heavy work (NVS, ESP-NOW reinit) outside the BLE task, and hosts the render-retry state machine (`IDLE` → `PENDING` → `WAITING_ACK`). Lap delivery uses MAC-layer feedback from `esp_now_register_send_cb` (counters in `espnow_link.h`) — if any packet in a cycle fails to deliver, `render()` is re-dispatched up to `MAX_RENDER_RETRIES` times (granularity = whole cycle, because mid-cycle failure leaves the OSD buffer partially written). `cancelRender()` drops the cycle when stale state would be rendered (UID change, OSD clear, laps reset).

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


<claude-mem-context>
# Memory Context

# [HDZeroOSD] recent context, 2026-05-02 11:08am GMT+9

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (15,498t read) | 232,612t work | 93% savings

### May 2, 2026
511 10:17a 🔵 HDZero OSD Grid Is 50 Columns × 18 Rows
512 10:18a 🔵 Firmware Build Uses PlatformIO; Test Scripts Are Python-Based
513 " ⚖️ iOS Owns All OSD Text Generation — M5Stick Acts as Pure BLE→ESP-NOW Bridge
514 10:20a 🔵 No Settings or Target Lap Configuration Model Exists in iOS App
515 10:23a ⚖️ Target Lap Seconds Derived from Target Lap Count: targetLapSec = 90 / (targetLapCount - 1)
516 10:24a ⚖️ iOS TimerView Will Mirror OSD Diff/Need Info In-App
517 10:26a 🔵 Design Specs Live in docs/superpowers/specs/ with Date-Prefixed Filenames
518 10:27a 🔵 TimerView Already Has summaryBand with Pace/Avg — New Diff Line Inserts Here
519 10:28a 🟣 Implementation Spec Written: iOS-Owned Goggle OSD with BLE Text-Frame Protocol
520 10:32a ✅ OSD Lap Time Format Corrected: No Unit Suffix — "LAP 4 22.345" Not "LAP 4 22.345S"
521 10:34a ⚖️ Implementation Phase Started: 5-Step Execution Plan for OSD Bottom-Center Feature
522 10:35a 🔵 iOS App Uses XcodeGen (project.yml), iOS 18 Target, and summaryBand Has 3 SummaryColumn Widgets
523 10:36a 🔵 requestRender() Has Single Call Site at main.cpp:213 — Firmware OSD Text Path Adds a Second
524 " 🔵 BluetoothManager.lapCount Is Firmware's Count, Not iOS's — RaceMetrics Uses LapTimer.laps.count
525 10:37a 🟣 RaceMetrics.swift Created — iOS Race Metrics Model with OSD Text Generation
526 " ✅ RaceMetrics.splitLabel for .onTarget Changed from "Target" to "Split"
527 10:38a 🟣 TimerView.swift Wired to RaceMetrics — summaryBand Expanded with Target/Pace/Diff/Need Columns
528 " ✅ TimerView summaryBand Trimmed to 5 Columns; recordLap Dead Code Removed
529 " ✅ SummaryColumn Scaled Down to Fit 5 Columns — Font 18→14pt, Padding 12→8pt, Flexible Width
530 10:39a 🟣 BluetoothManager.swift Gains sendOSDText() and osdTextUUID Characteristic Discovery
531 " 🔴 osdASCIIData Non-ASCII Fallback Fixed: UInt8(ascii: "?") → 63
532 " 🟣 ConnectionView Gains "Race Target" Section with Stepper for Target Lap Count
533 " 🟣 firmware/include/osd_text_display.h Created — Firmware OSD Bottom-Center Text Renderer
534 10:40a 🟣 firmware/include/ble_service.h: OSDTextCallback and CHR_OSD_TEXT_UUID Added
535 " 🔵 main.cpp Patch Failed — Context Lines Don't Match Current File State
536 " 🟣 firmware/src/main.cpp: OSDTextDisplay Integrated into Render State Machine
537 " 🟣 firmware/src/main.cpp: g_osd_text_received Handler and Render Dispatch Switch Applied
538 " ✅ firmware: osdTextDisplay.clear() Added to Reset Handler Alongside lapDisplay.clear()
539 10:41a 🔵 Cross-Codebase Verification: All Feature Symbols Correctly Placed, sendLapTime Now Orphaned
540 " 🔴 OSDTextCallback: g_osd_text_received Trigger Fixed — Removed Premature row-2-only Guard
541 " ✅ XcodeGen Regenerated Xcode Project After Adding RaceMetrics.swift
542 10:42a 🔵 ARCHITECTURE.md Needs Updates: OSD Text Characteristic Missing from GATT Table, Lap Flow Outdated
543 " ✅ ARCHITECTURE.md Updated: Lap Recording Section Rewritten for iOS-Owned OSD Text Flow
544 " 🔴 ARCHITECTURE.md Module Graph and Concurrency Model Still Missing OSD Text Entries
545 " ✅ ARCHITECTURE.md: Module Graph, Concurrency Table, and iOS Module Graph Updated
546 " ✅ ARCHITECTURE.md BLE GATT Table Updated: OSD Text Characteristic d487 Added
547 " ✅ Implementation Complete: Spec Status Updated to "Implemented — pending build/hardware verification"
548 " 🟣 iOS-Owned Goggle OSD Feature Fully Implemented — 11 Files Changed, 908 Insertions
549 10:43a ✅ ARCHITECTURE.md System Overview Diagram Fixed: Garbled Unicode Replaced with Clean ASCII Art
550 " 🔵 Final Verification: RaceMetrics.swift Registered in Xcode, sendOSDText Called at 2 Sites
551 10:44a ✅ All 5 Implementation Plan Steps Completed — Build and Hardware Verification Intentionally Deferred
552 11:06a 🔵 HDZeroOSD project has both firmware and iOS build targets
553 " 🔵 HDZeroOSD local build environment confirmed
554 " 🔵 HDZeroOSD current working changes before local test
555 " 🔵 HDZeroOSD firmware build succeeds locally — linking stage reached
556 " 🔵 HDZeroOSD firmware build succeeded — flash 75.3% used
557 " 🔴 iOS build fails — TimerView.swift missing return in opaque return type function
558 11:07a 🔴 TimerView.swift summaryBand fixed — added explicit return before HStack
559 " 🟣 HDZap iOS app builds successfully for iOS Simulator (Debug)
560 " 🟣 HDZeroOSD iOS-owned goggle OSD feature — full changeset summary

Access 233k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>