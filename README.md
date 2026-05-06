# HDZap

iPhone manual lap timer that sends lap times to HDZero FPV goggles via ESP32 bridge.

> 📖 End-user manual: **[English](https://saqoosha.github.io/HDZap/)** ・ **[日本語](https://saqoosha.github.io/HDZap/ja/)**

```
┌──────────┐  BLE GATT  ┌──────────┐  ESP-NOW   ┌──────────┐
│  iPhone  │ ─────────→ │  ESP32   │ ─────────→ │ HDZero   │
│  App     │            │  Bridge  │            │ Goggle   │
│          │            │          │  MSPv2     │          │
│ SwiftUI  │ Lap times  │ BLE Svr  │  OSD cmds  │  OSD     │
│ Timer UI │ UID config │ ESP-NOW  │            │ Overlay  │
└──────────┘            └──────────┘            └──────────┘
```

## Components

### ESP32 Firmware (`firmware/`)

PlatformIO project for ESP32 devkit (target: M5StickS3).

- **BLE GATT Server** — receives commands from iPhone app
- **ESP-NOW** — sends MSPv2 OSD packets to HDZero goggle backpack
- **ELRS Bind** — binds with unbound goggles via MSP_ELRS_BIND broadcast
- **TX UID Capture** — sniffs ESP-NOW bind broadcasts from TX backpacks to capture their UID
- **NVS** — persists UID across reboots
- **Lap Display** — formats lap times for 50x18 OSD grid

### iPhone App (`app/`)

SwiftUI app (iOS 18+) with CoreBluetooth.

- **Timer** — stopwatch with large LAP button, lap history, best lap tracking
- **Connection** — BLE scan/connect, 3-mode UID setup, bind command, TX UID capture

## Goggle Pairing (3 Scenarios)

| Scenario | Input | Action |
|---|---|---|
| Goggle has bind phrase | Enter same phrase in app | MD5 → UID, no binding needed |
| Goggle bound to TX via manual bind | Tap "Start TX UID Capture", press Bind on TX | ESP32 sniffs bind broadcast, UID auto-filled |
| Goggle bound via bind mode | Read UID from goggle ELRS menu | Enter UID manually |
| Goggle not set up | Tap "New Pairing" in app | ESP32 sends bind packet (goggle must be in bind mode) |

TX UID capture is passive — the TX's existing goggle binding is unaffected. Scenarios 1–3 do not disrupt existing VTX connections.

## BLE Protocol

Service UUID: `f47ac10b-58cc-4372-a567-0e02b2c3d489`. The UUID is bumped on every GATT-shape change so iOS CoreBluetooth's per-peripheral cache reliably re-discovers added/removed characteristics without a phone reboot.

| Characteristic | UUID suffix | Direction | Format |
|---|---|---|---|
| UID Config | `...d481` | Write | `[mode:u8][data...]` |
| Bind Command | `...d482` | Write | `[0x01]` |
| OSD Control | `...d484` | Write | `[cmd:u8]` |
| Status | `...d485` | Read+Notify | `[conn:u8][uid:6][test:u8]` |
| TX Sniff | `...d486` | Write+Notify | Write: `[0x01]` start / `[0x00]` stop; Notify: `[uid:6]` |
| OSD Text | `...d487` | Write | `[row:u8][ascii:1-19B]`; rows 0..3 stage one bottom-anchored 4-row text frame |
| Battery | `...d488` | Read+Notify | `[percent:u8 (0xFF unknown)][flags:u8 (bit0 charging, bit1 LOW, bit2 CRITICAL, bit3 silenced; bits 4-7 reserved)]` |

UID Config modes: `0x01` bind phrase, `0x02` raw 6-byte UID, `0x03` new pairing (ESP32 MAC).
OSD commands: `0x01` clear, `0x02` reset laps, `0x03` test OSD.
TX Sniff: optional characteristic (older firmware omits it); iOS hides the section when absent.

## OSD Layout

```
LAP 03      01:23.456
LAP 02      01:21.789
LAP 01      01:22.123

BEST  02    01:21.789
TOTAL       04:07.368
```

50-column HD grid. Most recent lap at top. Best lap and total time at bottom.

## Install

### First-time install (Web Flasher)

Flash directly from the browser &mdash; no PlatformIO toolchain required:

**[saqoosha.github.io/HDZap/flash/](https://saqoosha.github.io/HDZap/flash/)**

Requirements: M5StickS3 + USB-C data cable + Chromium-based browser (Chrome, Edge, Brave, etc.) on macOS or Windows. To enter download mode, hold the small power button on the left side for 2 seconds &mdash; the green LED will flash. Safari, Firefox, and mobile browsers are not supported. To update later, revisit the same page and re-flash with the same steps.

## Build

### Firmware

```sh
cd firmware
pio run              # build
pio run -t upload    # flash to ESP32
pio device monitor   # serial monitor
```

### iPhone App

```sh
cd app
xcodegen generate    # generate .xcodeproj
open HDZap.xcodeproj
```

Build and run on device (BLE requires physical device, not simulator).

## Hardware

- **Current**: [M5StickS3](https://www.switch-science.com/products/10921) (ESP32-S3, 1.14" IPS LCD, BtnA/BtnB on GPIO11/12, AXP2101 PMIC, internal 250 mAh battery, USB-C, internal speaker)
- HDZero Goggle with ELRS backpack
- Buttons are multi-purpose: wake the LCD from idle sleep, silence the battery alarm, and wake from deep sleep (ext1 wake on GPIO11/12)
- **Other compatible boards**: see [docs/compatible-devices.md](docs/compatible-devices.md) for the full list of ESP32 chips and dev boards (battery-included and battery-external) that can run HDZap firmware.

## Technical Details

See [docs/REPORT.md](docs/REPORT.md) for MSPv2 protocol details, ESP-NOW configuration, and ELRS backpack binding protocol research.
