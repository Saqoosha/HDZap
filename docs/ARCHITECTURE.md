# Architecture

## System Overview

```
┌─────────────────┐      BLE GATT       ┌─────────────────┐     ESP-NOW      ┌─────────────────┐
│   iPhone App    │ ──────────────────→  │   ESP32 Bridge  │ ─────────────→   │  HDZero Goggle  │
│                 │                      │                 │                  │                 │
│  ┌───────────┐  │  Lap times           │  ┌───────────┐  │  MSPv2 packets   │  ELRS Backpack  │
│  │ LapTimer  │  │  UID config          │  │BLE Server │  │  (ESP-NOW ch1)   │  (built-in ESP32│
│  │           │  │  Bind commands       │  │           │  │                  │   running ELRS  │
│  │ Stopwatch │  │  OSD control         │  │  ↓ flags  │  │  MAC spoofed     │   backpack FW)  │
│  └───────────┘  │                      │  │           │  │  to match UID    │                 │
│  ┌───────────┐  │                      │  │ Main Loop │  │                  │  Receives MSP   │
│  │ Bluetooth │  │  Status notify       │  │  ↓        │  │                  │  via ESP-NOW    │
│  │ Manager   │◄─│──────────────────── │  │ ESP-NOW   │  │                  │       ↓         │
│  └───────────┘  │  [conn][uid][laps]   │  │ + OSD     │  │                  │  UART to main   │
│  ┌───���───────┐  │                      │  └───────────┘  │                  │  SoC → OSD      │
│  │ SwiftUI   │  │                      │  ┌───────────┐  │                  │  overlay on     │
│  │ Views     │  │                      │  │NVS (flash)│  │                  │  video feed     │
│  └───────────┘  │                      │  └─────��─────┘  │                  │                 │
└──���──────────────┘                      └─────────────────┘                  └─────────────────┘
```

## Data Flow

### Lap Recording

```
User taps LAP button
  → LapTimer.lap() records time (TimeInterval)
  → TimerView calls BluetoothManager.sendLapTime(lapNum, timeMs)
  → CoreBluetooth writes to Lap Time characteristic
  → [BLE air gap]
  → ESP32 BLE callback: LapTimeCallback.onWrite()
  → Sets g_lap_received=true, g_lap_num, g_lap_time_ms (volatile)
  → Main loop detects flag
  → LapDisplay.addLap(num, ms) stores in array
  → LapDisplay.render():
      → osd.clear()         → MSPv2 [MSP_DP_CLEAR]    → ESP-NOW
      → osd.writeString()×N → MSPv2 [MSP_DP_WRITE]×N  → ESP-NOW
      → osd.draw()          → MSPv2 [MSP_DP_DRAW]      → ESP-NOW
  → Goggle backpack receives, forwards via UART to main SoC
  → OSD overlay rendered on video feed
```

### UID Configuration

```
User selects mode in ConnectionView:

Mode 1 — Bind Phrase:
  iPhone: uidFromBindPhrase(phrase)     ← MD5("-DMY_BINDING_PHRASE=\"phrase\"")
  iPhone: sendUIDConfig(.bindPhrase)    ← [0x01][phrase bytes]
  ESP32:  UIDConfigCallback receives
  ESP32:  uid_from_bind_phrase(phrase)   ← same MD5, same UID
  ESP32:  nvs_save_uid(), espnow_reinit()

Mode 2 — Manual UID:
  iPhone: parseUID("60:D2:53:8A:B2:9E")
  iPhone: sendUIDConfig(.manualUID)     ← [0x02][6 bytes]
  ESP32:  memcpy, nvs_save_uid(), espnow_reinit()

Mode 3 — New Pairing:
  iPhone: sendUIDConfig(.newPairing)    ← [0x03]
  ESP32:  esp_read_mac() → use own MAC as UID
  ESP32:  nvs_save_uid(), espnow_reinit()
  User:   puts goggle in bind mode
  iPhone: sendBindCommand()             ← [0x01]
  ESP32:  send_bind_packet() → MSPv2 MSP_ELRS_BIND to FF:FF:FF:FF:FF:FF (3x)
  Goggle: saves UID to EEPROM, reboots
```

## ESP32 Firmware Architecture

### Module Dependency Graph

```
main.cpp
  ├── ble_service.h ──→ nvs_store.h (staged data only; main.cpp applies)
  ├── bind.h ──→ msp.h (MSP_ELRS_BIND)
  │             └→ espnow_link.h (broadcast helper)
  ├── lap_display.h ──→ osd.h ──→ msp.h (MSP_SET_OSD_ELEM)
  │                               └→ espnow_link.h (send)
  ├── nvs_store.h ──→ Preferences (namespace "hdzero")
  └── stick_display.h ──→ M5Unified (LCD status display only)
```

### Concurrency Model

```
BLE Callback Thread              Main Loop (Arduino loop())
─────────────────                ───────────────────────────
UIDConfigCallback.onWrite()  →   g_staged_uid + g_uid_config_requested
                                 → main loop: nvs_store::saveUid + espnow_reinit

BindCmdCallback.onWrite()    →   g_bind_requested                  → send_bind_packet

LapTimeCallback.onWrite()    →   g_lap_num + g_lap_time_ms + g_lap_received
                                 → main loop: addLap + render

OSDControlCallback.onWrite() →   g_osd_clear_requested / reset_laps → main loop
```

All multi-field producers (UID staging, lap pair) are guarded by `portENTER_CRITICAL(&g_ble_mux)`
on both the BLE task and main loop sides, so main loop never observes a torn pair. Single-bool
flags rely on `volatile` ordering alone. No heavy work runs inside BLE callbacks.

## iPhone App Architecture

### Module Graph

```
HDZeroLapTimerApp
  ├── @State bluetoothManager: BluetoothManager
  ├── @State lapTimer: LapTimer
  └── ContentView (TabView)
        ├── TimerView
        │     ├── reads: LapTimer (elapsed, laps, isRunning)
        │     ├── reads: BluetoothManager (isConnected)
        │     ├── actions: lapTimer.start/stop/lap/reset
        │     ├── actions: bluetooth.sendLapTime/sendOSDControl
        │     └── embeds: LapListView
        └── ConnectionView
              ├── reads: BluetoothManager (isConnected, discoveredDevices, currentUID)
              ├── actions: bluetooth.startScan/connect/disconnect
              ├── actions: bluetooth.sendUIDConfig/sendBindCommand
              └── uses: UIDUtils (uidFromBindPhrase, formatUID, parseUID)
```

### State Management

- `@Observable` macro (iOS 17+) on BluetoothManager and LapTimer
- Injected via `.environment()` from app root
- Views access via `@Environment(Type.self)`
- No Combine, no ObservableObject — pure Observation framework

### BLE State Machine

```
                    ┌──────────┐
          ┌────────→│  Idle    │←─────────┐
          │         └────┬─────┘          │
          │              │ startScan()    │ disconnect()
          │              ▼                │
          │         ┌──────────┐          │
          │         │ Scanning │          │
          │         └────┬─────┘          │
          │              │ didDiscover    │
          │              │ connect()      │
          │              ▼                │
          │         ┌──────────┐          │
          │         │Connecting│          │
          │         └────┬─────┘          │
          │              │ didConnect     │
          │              ▼                │
          │         ┌──────────┐          │
          │         │Connected │──────────┘
          │         └────┬─────┘  (user disconnect)
          │              │ didDisconnect (unexpected)
          │              ▼
          │         ┌──────────┐
          └─────────│Reconnect │ (auto)
                    └──────────┘
```

## Protocol Specifications

### BLE GATT

| Characteristic | UUID | Properties | Payload |
|---|---|---|---|
| UID Config | `f47ac10b-...-0e02b2c3d481` | Write | `[mode:u8][data:0-63B]` |
| Bind Command | `f47ac10b-...-0e02b2c3d482` | Write | `[0x01]` |
| Lap Time | `f47ac10b-...-0e02b2c3d483` | Write | `[lap:u8][ms:u32 LE]` = 5B |
| OSD Control | `f47ac10b-...-0e02b2c3d484` | Write | `[cmd:u8]` |
| Status | `f47ac10b-...-0e02b2c3d485` | Read+Notify | `[conn:u8][uid:6B][laps:u8]` = 8B |

### MSPv2 Packet Format

```
Byte:  0    1    2    3      4-5       6-7        8..N-1    N
       $    X    <    flags  func(LE)  size(LE)   payload   CRC8
       0x24 0x58 0x3C 0x00   ....      ....       ....      ....
```

CRC8-DVB-S2 calculated over bytes 3 through N-1 (flags through end of payload).

### MSP Function Codes Used

| Code | Name | Payload | Purpose |
|---|---|---|---|
| `0x00B6` | MSP_SET_OSD_ELEM | DisplayPort sub-cmd + data | OSD overlay control |
| `0x0009` | MSP_ELRS_BIND | UID (6 bytes) | Backpack binding |

### MSP DisplayPort Sub-commands (payload byte 0)

| Code | Name | Additional payload |
|---|---|---|
| `0x02` | MSP_DP_CLEAR | none |
| `0x03` | MSP_DP_WRITE_STRING | `[row][col][attr][text...]` |
| `0x04` | MSP_DP_DRAW | none |

### ESP-NOW Configuration

```
WiFi mode:    STA
Channel:      1
Protocols:    11B | 11G | 11N | LR
TX Power:     19.5 dBm
Encryption:   none
MAC address:  spoofed to UID (both sender and peer)
```

## Future: M5StickS3 Migration

Target hardware changes:
- Board: `m5stack-atoms3` or custom M5StickS3 board def in platformio.ini
- ESP32-S3 (BLE 5.0, same ESP-NOW API)
- 1.14" IPS display (135x240) — show connection status, current UID
- Button A: cycle display pages
- Button B: emergency manual lap (backup if BLE disconnects)
- Battery: 250mAh, USB-C charging
