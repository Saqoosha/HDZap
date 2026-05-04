# Architecture

## System Overview

```
+-----------------+      BLE GATT       +-----------------+     ESP-NOW      +-----------------+
|   iPhone App    | -------------------> |   ESP32 Bridge  | --------------> |  HDZero Goggle  |
|                 |  OSD text rows       |                 | MSPv2 packets   |                 |
|  LapTimer       |  UID config          |  BLE Server     | (ESP-NOW ch1)   | ELRS Backpack   |
|  RaceMetrics    |  Bind commands       |    -> flags     | MAC spoofed     | receives MSP    |
|  Bluetooth      |  OSD control         |  Main Loop      | to match UID    | via ESP-NOW     |
|  SwiftUI Views  | <------------------- |  ESP-NOW + OSD  |                 | UART -> OSD     |
|                 |  Status notify       |  NVS (flash)    |                 | overlay         |
+-----------------+                      +-----------------+                 +-----------------+
```

## Data Flow

### Lap Recording / Goggle OSD

```
User taps LAP button
  → LapTimer.lap() records time (TimeInterval)
  → RaceMetrics calculates avg, pace, diff, and need/bank from iOS state
  → TimerView updates the iOS summary band
  → TimerView calls BluetoothManager.sendOSDText(lines:)
  → CoreBluetooth writes three OSD Text rows:
      [row=0]["LAP 4 22.345"]
      [row=1]["AVG 22.222 PACE 6L"]
      [row=2]["D+1.00 NEED -0.2/L"]
  → [BLE air gap]
  → ESP32 BLE callback: OSDTextCallback.onWrite()
  → Stages the row under g_ble_mux: copies into g_osd_text_rows[row]
    and OR-merges (1 << row) into g_osd_text_dirty.
  → Main loop snapshots dirty + rows under the mux, calls
    OSDTextDisplay.setDirtyRows(dirty, rows) which OR-merges the bits
    into m_dirty. State machine catch-up trigger fires when
    state == IDLE && espnow_ready && hasDirty():
      [PENDING] snapshot dispatched dirty mask + g_espnow_sent_fail
      [PENDING → dispatch] OSDTextDisplay.render():
          → osd.writeString()×N → MSPv2 [MSP_DP_WRITE]×N → ESP-NOW queue   (N = popcount(dirty))
          → osd.draw()          → MSPv2 [MSP_DP_DRAW]   → ESP-NOW queue
        m_dirty is left intact so MAC-layer retries re-emit the same bits.
      [WAITING_ACK] wait RENDER_VERIFY_MS for send-cb results
      [VERIFY] newFails = g_espnow_sent_fail - baseline
          newFails == 0          → clearDirtyBits(dispatched), IDLE (delivered)
          newFails > 0, retries  → PENDING after RENDER_RETRY_BACKOFF_MS
          retries exhausted      → clearDirtyBits(dispatched), IDLE + "OSD LOST" strip
  → Goggle backpack receives, forwards via UART to main SoC
  → MSP DisplayPort overlay buffer keeps prior rows between writeStrings
    (we never send DP_CLEAR mid-session); OSD overlay rendered on video feed
```

**Delivery tracking**: `esp_now_register_send_cb` populates `g_espnow_sent_ok` /
`g_espnow_sent_fail` from the WiFi task context. Single-word uint32_t is atomic
on ESP32; reader uses `volatile` without a mux. Retry granularity is the whole
render cycle (not individual packets) because mid-cycle failure leaves the
goggle OSD buffer with a partial frame — a fresh re-render of the same staged
dirty rows restores a known-good state regardless of which packet died.

**Cancellation**: `cancelRender()` drops the state machine when stale state
would be rendered: UID change (`applyStagedUid`), OSD clear, laps reset. Late
callbacks from an in-flight cycle are simply ignored. `osdTextDisplay.clear()`
in the laps-reset path also drops staged rows + the dirty mask so a 1Hz
TIME LEFT tick can't re-paint right after the operator wiped the OSD.

iOS owns the entire goggle OSD layout. Firmware no longer formats laps —
the legacy `LapDisplay` path and the Lap Time characteristic (`...d483`)
were both retired when the OSD Text per-row path landed.

### TX UID Capture

```
Operator taps "Start TX UID Capture" in SettingsView
  → BluetoothManager.startTXSniff()
  → CoreBluetooth writes [0x01] to TX Sniff characteristic
  → [BLE air gap]
  → TXSniffCallback.onWrite() sets g_sniff_start_requested = true
  → Main loop: sniff_start() → esp_now_register_recv_cb(_espnow_recv_cb)

Pilot presses Bind on TX Backpack
  → TX Backpack broadcasts ESP-NOW MSP_ELRS_BIND packet (dst: FF:FF:FF:FF:FF:FF)
    (src MAC = TX UID; payload = MSPv2 with function 0x0009)
  → _espnow_recv_cb fires (WiFi task context):
      filter: data[0]='$', data[1]='X', data[2]='<', data[4..5]=0x0009
      portENTER_CRITICAL → memcpy src_mac → g_sniff_uid, bit0 cleared, g_sniff_captured=true
  → Main loop detects g_sniff_captured:
      reads g_sniff_uid under g_sniff_mux
      ble_notify_tx_uid(uid) → BLE notify [uid:6B]
  → [BLE air gap]
  → BluetoothManager.didUpdateValueFor(txSniffUUID):
      capturedTXUID = Array(data)
  → SettingsView shows captured UID + Apply button

Operator taps "Apply"
  → bluetooth.recordPreviousUID(currentUID)   ← enables Restore if Apply fails
  → bluetooth.sendUIDConfig(.manualUID(uid))  ← routes through existing UID config flow
  → bluetooth.stopTXSniff()                   ← [0x00] to TX Sniff characteristic
```

**Key invariants**: TX binding state is unaffected (TX only broadcasts; nothing is written
to it). The recv callback occupies the single global ESP-NOW recv slot — no other code in
this project uses `esp_now_register_recv_cb`. `isTXSniffActive` on iOS is local state
(no firmware echo); it survives BLE auto-reconnects intentionally because the firmware
recv callback also survives them.

### UID Configuration

```
User selects mode in SettingsView:

Mode 1 — Bind Phrase:
  iPhone: uidFromBindPhrase(phrase)           ← MD5("-DMY_BINDING_PHRASE=\"phrase\"")
  iPhone: sendUIDConfig(.bindPhrase)          ← [0x01][phrase bytes, ≤63]
  ESP32:  UIDConfigCallback stages new_uid    ← same MD5, same UID
  ESP32 (main loop) applyStagedUid():
        → nvs_store::saveUid (returns early on failure; g_uid untouched)
        → commit g_uid under g_ble_mux
        → espnow_reinit or espnow_init

Mode 2 — Manual UID:
  iPhone: parseUID → normalizeUID("60:D2:53:8A:B2:9E")
  iPhone: sendUIDConfig(.manualUID)           ← [0x02][6 bytes]
  ESP32:  UIDConfigCallback stages → main loop applies (as above)

Mode 3 — New Pairing:
  iPhone: sendUIDConfig(.newPairing)          ← [0x03]
  ESP32:  esp_read_mac() → stage own MAC as UID
  ESP32 (main loop) applyStagedUid() as above
  User:   puts goggle in bind mode
  iPhone: sendBindCommand()                   ← [0x01]
  ESP32:  send_bind_packet() → MSPv2 MSP_ELRS_BIND to FF:FF:FF:FF:FF:FF (3x)
  Goggle: saves UID to EEPROM, reboots
```

## ESP32 Firmware Architecture

### Module Dependency Graph

```
main.cpp ──→ nvs_store.h (load/save UID) ──→ Preferences
  ├── ble_service.h (stages data + flags only; main.cpp applies)
  │     ├── tx_sniff.h (recv_cb registration + sniff state)
  │     │     └→ msp.h (MSP_ELRS_BIND filter constant)
  │     └── espnow_link.h (uid_from_bind_phrase helper)
  ├── bind.h ──→ msp.h (MSP_ELRS_BIND)
  │             └→ espnow_link.h (broadcast helper)
  ├── osd_text_display.h ──→ osd.h ──→ msp.h (MSP_SET_OSD_ELEM)
  │                                    └→ espnow_link.h (send)
  └── stick_display.h ──→ M5Unified (LCD status display only)
```

### Concurrency Model

```
BLE Callback Thread              Main Loop (Arduino loop())
─────────────────                ───────────────────────────
UIDConfigCallback.onWrite()  →   g_staged_uid + g_uid_config_requested
                                 → main loop: nvs_store::saveUid + espnow_reinit

BindCmdCallback.onWrite()    →   g_bind_requested                  → send_bind_packet

OSDTextCallback.onWrite()    →   per-row staging: copies into
                                 g_osd_text_rows[row]; OR-merges
                                 (1<<row) into g_osd_text_dirty
                                 → main loop snapshot under mux,
                                 OSDTextDisplay.setDirtyRows (OR-merge),
                                 IDLE catch-up trigger → state machine

OSDControlCallback.onWrite() →   g_osd_clear_requested / reset_laps → main loop
                                 → cancelRender + osd.clear/reset

TXSniffCallback.onWrite()    →   g_sniff_start_requested / g_sniff_stop_requested
                                 → main loop: sniff_start/stop (register/unregister recv_cb)

WiFi task (ESP-NOW send cb)  →   g_espnow_sent_ok / g_espnow_sent_fail
                                 → main loop verify step reads delta

WiFi task (ESP-NOW recv cb)  →   g_sniff_uid[6] + g_sniff_captured (guarded by g_sniff_mux)
                                 → main loop: ble_notify_tx_uid → iOS
```

All multi-field producers (UID staging, lap pair, OSD text rows) are guarded by `portENTER_CRITICAL(&g_ble_mux)`
on both the BLE task and main loop sides, so main loop never observes a torn pair. Single-bool
flags rely on `volatile` ordering alone. The ESP-NOW send-callback counters are `volatile uint32_t`
without a mux — single-word load/store is atomic on ESP32, and the reader only needs the delta
across a verify window. No heavy work runs inside BLE callbacks or the ESP-NOW send callback.

## iPhone App Architecture

### Module Graph

```
HDZeroLapTimerApp
  ├── @State bluetoothManager: BluetoothManager
  ├── @State lapTimer: LapTimer
  └── ContentView (TabView)
        ├── TimerView
        │     ├── reads: LapTimer (elapsed, laps, isRunning)
        │     ├── reads: RaceMetrics (target, avg, pace, diff, need/bank)
        │     ├── reads: BluetoothManager (isConnected)
        │     ├── actions: lapTimer.start/stop/lap/reset
        │     ├── actions: bluetooth.sendOSDText/sendOSDControl
        │     └── embeds: LapListView
        └── SettingsView
              ├── reads: BluetoothManager (isConnected, discoveredDevices,
              │          connectedIdentifier, currentUID, capturedTXUID,
              │          isTXSniffActive)
              ├── owns: targetLapCount, raceSessionLimit, accentHue
              │         @AppStorage settings
              ├── actions: bluetooth.startScan/connect/disconnect
              ├── actions: bluetooth.sendUIDConfig/sendBindCommand
              ├── actions: bluetooth.sendOSDText/sendOSDControl (Send/Clear test)
              ├── actions: bluetooth.startTXSniff/stopTXSniff/clearCapturedTXUID
              └── uses: UIDUtils (uidFromBindPhrase, formatUID,
                        formatUIDDecimal, parseUID, normalizeUID)
```

### State Management

- `@MainActor @Observable` on BluetoothManager and LapTimer (iOS 18+)
- Injected via `.environment()` from app root
- Views access via `@Environment(Type.self)`
- No Combine, no ObservableObject — pure Observation framework

### BLE State

BluetoothManager owns three coupled values:

- `isConnected: Bool`
- `connectedPeripheral: CBPeripheral?`
- `characteristics: [CBUUID: CBCharacteristic]`

Three paths leave the connected state:

1. **User-initiated or internal teardown** — `disconnect()` and
   `tearDownConnection(_:)` both set `suppressAutoReconnect`; the
   upcoming `didDisconnectPeripheral` then takes the early-return branch.
   `tearDownConnection(_:)` is the shared cleanup called from discovery
   error paths (missing service, missing characteristics, discovery
   failure) so the UI never ends up in `isConnected = true` with an
   empty characteristics map.
2. **Unexpected drop** — `didDisconnectPeripheral` without the flag
   calls `centralManager.connect(peripheral)` again. iOS retries in the
   background until either `didConnect` fires or the user reconnects.
3. **Bluetooth-stack state change** — `centralManagerDidUpdateState` sees
   `.poweredOff` / `.unauthorized` / `.resetting` / `.unsupported` while
   `isConnected`. The session is torn down via `tearDownConnection(_:)`
   (which also sets `suppressAutoReconnect`) and `lastError` explains
   which state caused it. A subsequent `.poweredOn` requires the user to
   re-tap Scan — transient `.resetting` is treated the same way for
   simplicity.

## Protocol Specifications

### BLE GATT

Service UUID: `f47ac10b-58cc-4372-a567-0e02b2c3d489`. Bumped on every GATT-shape change so iOS CoreBluetooth's per-peripheral cache reliably re-discovers added/removed characteristics without a phone reboot.

| Characteristic | UUID | Properties | Payload |
|---|---|---|---|
| UID Config | `f47ac10b-...-0e02b2c3d481` | Write | `[mode:u8][data:0-63B]` |
| Bind Command | `f47ac10b-...-0e02b2c3d482` | Write | `[0x01]` |
| OSD Control | `f47ac10b-...-0e02b2c3d484` | Write | `[cmd:u8]` |
| Status | `f47ac10b-...-0e02b2c3d485` | Read+Notify | `[conn:u8][uid:6B][test:u8]` = 8B |
| TX Sniff | `f47ac10b-...-0e02b2c3d486` | Write+Notify | Write: `[0x01]` start / `[0x00]` stop; Notify: `[uid:6B]` on capture |
| OSD Text | `f47ac10b-...-0e02b2c3d487` | Write | `[row:u8][ascii:1-19B]`; rows `0..3` stage one bottom-anchored 4-row text frame, dirty bits OR-merged on each write |
| Battery | `f47ac10b-...-0e02b2c3d488` | Read+Notify | `[percent:u8 (0xFF unknown)][flags:u8 (bit0 charging, bit1 LOW, bit2 CRITICAL, bit3 silenced; bits 4-7 reserved → iOS surfaces unknown bits via `lastError`)]` |

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

## Hardware Target

Currently deployed on M5StickS3 (ESP32-S3, 1.14" IPS 135x240 LCD, BtnA/BtnB on GPIO11/GPIO12, AXP2101 PMIC, internal 250 mAh battery, USB-C charging, internal speaker for the battery alarm). Buttons are multi-purpose: wake the LCD from phase-1 idle sleep, silence the battery alarm, and wake the device from phase-3 deep sleep via ext1. The `stick_display.h` module owns the LCD layout (UID band + status pill + battery widget); `battery_monitor.h` owns the alarm tier + speaker cadence; `main.cpp` orchestrates power phases (LCD-off → runtime tuning → deep sleep) and consumes the monitors' outputs.
