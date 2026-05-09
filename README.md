# HDZap

iPhone manual lap timer that sends lap times to HDZero FPV goggles via ESP32 bridge.

> 📖 **End-user manual:** **[English](https://saqoosha.github.io/HDZap/)** ・ **[日本語](https://saqoosha.github.io/HDZap/ja/)**
>
> 🚧 **Status:** Beta — iOS app distributed via [TestFlight](https://testflight.apple.com/join/gjjbKFp3); App Store release coming soon.

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

## Repository Layout

```
firmware/                  ESP32 PlatformIO project (Arduino framework)
app/                       iOS SwiftUI app (iOS 18+, xcodegen)
docs/manual/               End-user manual (en + ja); served on GitHub Pages
docs/flash/                Browser firmware flasher (esptool-js); served on GitHub Pages
docs/                      Architecture, research, and TestFlight setup docs
scripts/                   build / upload-testflight / release helpers
.github/workflows/         CI: builds firmware, composes Pages artefact, deploys
.claude/skills/release/    Claude Code skill for cutting a release end-to-end
```

## Branching & deployment

Two-branch model — open all PRs against `develop`.

| Branch | Default? | Protection | Pages deploys to |
|---|---|---|---|
| `develop` | ✅ | None — push freely | <https://saqoosha.github.io/HDZap/dev/> (`/dev/flash/`, `/dev/ja/`) |
| `main` | | PR-only merge, no force push, no delete | <https://saqoosha.github.io/HDZap/> (`/flash/`, `/ja/`) |

CI ([`.github/workflows/flasher.yml`](.github/workflows/flasher.yml)) checks out **both** branches on every push, builds firmware for each, and composes a single Pages artefact with `main` at the canonical paths and `develop` mirrored under `/dev/`. So pushing to `develop` updates the staging URLs without touching production, and merging to `main` promotes the whole bundle (firmware + manual) at once.

The Web Flasher's `manifest.json` is stamped with `<branch>-<sha>` at build time so you can confirm which build is live:

```sh
curl -s https://saqoosha.github.io/HDZap/flash/manifest.json      # production: main-<sha>
curl -s https://saqoosha.github.io/HDZap/dev/flash/manifest.json  # staging:    develop-<sha>
```

Hotfixes still go through `develop` → `main` PRs. Direct push to `main` is blocked.

## BLE Protocol

Service UUID: `f47ac10b-58cc-4372-a567-0e02b2c3d48e`. The UUID is bumped on every GATT-shape change — including characteristic property-bitmap changes — so iOS CoreBluetooth's per-peripheral cache reliably re-discovers the new shape without a phone reboot.

| Characteristic | UUID suffix | Direction | Format |
|---|---|---|---|
| UID Config | `...d481` | Write | `[mode:u8][data...]` |
| Bind Command | `...d482` | Write | `[0x01]` |
| OSD Control | `...d484` | Write | `[cmd:u8]` |
| Status | `...d485` | Read+Notify | `[conn:u8][uid:6][test:u8]` |
| TX Sniff | `...d486` | Write+Notify | Write: `[0x01]` start / `[0x00]` stop; Notify: `[uid:6]` |
| OSD Text | `...d487` | Write | `[row:u8][ascii:1-19B]`; rows 0..3 stage one bottom-anchored 4-row text frame |
| Battery | `...d488` | Read+Notify | `[percent:u8 (0xFF unknown)][flags:u8 (bit0 charging, bit1 LOW, bit2 CRITICAL, bit3 silenced; bits 4-7 reserved)]` |
| Device Name | `...d489` | Read+Write | UTF-8, ≤20 bytes; write triggers NVS persist + reboot so the new name lands in `BLEDevice::init` |

UID Config modes: `0x01` bind phrase, `0x02` raw 6-byte UID, `0x03` new pairing (ESP32 MAC).
OSD commands: `0x01` clear, `0x02` reset laps, `0x03` test OSD.
TX Sniff: optional characteristic (older firmware omits it); iOS hides the section when absent.

## Goggle Pairing (4 Scenarios)

| Scenario | Input | Action |
|---|---|---|
| Goggle has bind phrase | Enter same phrase in app | MD5 → UID, no binding needed |
| Goggle bound to TX via manual bind | Tap "Start TX UID Capture", press Bind on TX | ESP32 sniffs bind broadcast, UID auto-filled |
| Goggle bound via bind mode | Read UID from goggle ELRS menu | Enter UID manually |
| Goggle not set up | Tap "New Pairing" in app | ESP32 sends bind packet (goggle must be in bind mode) |

TX UID capture is passive — the TX's existing goggle binding is unaffected. Scenarios 1–3 do not disrupt existing VTX connections.

## OSD Layout

50-column HD grid. The iOS app composes a **bottom-anchored 4-row text frame** and writes it row-by-row over BLE; the firmware relays each row as an MSPv2 `MSP_DP_WRITE` packet over ESP-NOW and finishes the cycle with `MSP_DP_DRAW`. The goggle keeps prior overlay content between writes, so only the rows that change get re-emitted (per-row dirty bits in `osd_text_display.h`).

The iOS app emits three distinct frame types; row 0 (TIME LEFT) ticks down independently while rows 1-3 update on each lap:

**Pre-race (Ready)**
```
                     READY
                    RACE 90
                7LAPS @ 12.86
```

**Mid-race (TIME LEFT row + lap row + metrics row + split row)**
```
                  TIME LEFT 45
                  LAP 4 22.345
              AVG 22.222 PACE 6L
              D+1.00 NEED -0.2/L
```

**Post-race (Done)**
```
                     DONE
                7LAPS 03:14.56
              AVG 22.84 BEST 21.78
```

Row composition lives in [`app/HDZap/Models/RaceMetrics.swift`](app/HDZap/Models/RaceMetrics.swift) (`timeLeftRow`, `readyOSDRows`, `osdMetricRows`, `resultOSDRows`). All rows are space-padded to 50 cols so a shorter update cleanly overwrites a longer prior value without leftover chars. ASCII `s` is dropped from numeric strings — the HDZero glyph set renders `S` as `5`.

## Install (end users)

1. **iPhone app:** Join the [TestFlight beta](https://testflight.apple.com/join/gjjbKFp3) on your iPhone, install the TestFlight app from the App Store if you don't have it, then tap **Install** for HDZap.
2. **Firmware:** Open the [Web Flasher](https://saqoosha.github.io/HDZap/flash/) in Chrome (Edge / Brave also work — Web Serial required, so Safari and Firefox don't), connect an M5StickS3 over USB-C, hold the small power button for 2 s to enter download mode, then click **Connect** → **Write**.

The full step-by-step is in the [end-user manual](https://saqoosha.github.io/HDZap/).

## Build (developers)

### Firmware

```sh
cd firmware
pio run              # build
pio run -t upload    # flash to ESP32
pio device monitor   # serial monitor (115200)
```

### iPhone App

```sh
cd app
xcodegen generate    # generate .xcodeproj
open HDZap.xcodeproj
```

Build and run on a physical device (BLE doesn't work in the simulator).

### Local Web Flasher preview

The CI build is the source of truth, but you can preview locally:

```sh
cd firmware && pio run -e m5stick-s3
cp .pio/build/m5stick-s3/{bootloader,partitions,firmware}.bin ../docs/flash/firmware/
mv ../docs/flash/firmware/firmware.bin ../docs/flash/firmware/hdzap.bin
python3 -m http.server 8765 --directory docs --bind 127.0.0.1
# open http://127.0.0.1:8765/flash/ in Chrome (Web Serial requires HTTPS or localhost)
```

## Hardware

- **Current**: [M5StickS3](https://www.switch-science.com/products/10921) (ESP32-S3, 1.14" IPS LCD, BtnA/BtnB on GPIO11/12, AXP2101 PMIC, internal 250 mAh battery, USB-C, internal speaker)
- HDZero Goggle with ELRS backpack
- Buttons are multi-purpose: wake the LCD from idle sleep, silence the battery alarm, and wake from deep sleep (ext1 wake on GPIO11/12)
- **Other ESP32 boards**: not currently supported. The firmware target in [`firmware/platformio.ini`](firmware/platformio.ini) is M5StickS3 only. [docs/compatible-devices.md](docs/compatible-devices.md) catalogues the chips and devkits that could *technically* run HDZap (BLE + ESP-NOW capable) — that's a future-support plan, not shipped functionality.

## Technical Details

- [docs/architecture.md](docs/architecture.md) — data flow, state machines, layered boundaries.
- [docs/report.md](docs/report.md) — MSPv2 protocol details, ESP-NOW configuration, ELRS backpack binding research.
- [docs/testflight-setup.md](docs/testflight-setup.md) — TestFlight team setup and release credentials.
- [AGENTS.md](AGENTS.md) — knowledge base for AI coding agents (architecture invariants, gotchas, conventions).
- [CLAUDE.md](CLAUDE.md) — Claude Code specific notes (firmware constraints, BLE invariants, hardware notes).

## License

[MIT](LICENSE) © Saqoosha
