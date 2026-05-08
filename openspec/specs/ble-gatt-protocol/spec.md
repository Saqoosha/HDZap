# ble-gatt-protocol Specification

## Purpose

Define the BLE GATT contract between the iOS app and the M5StickS3 firmware so each side can be developed and updated independently while remaining interoperable.

## Requirements

### Requirement: Single primary service / 単一のプライマリサービス

The firmware SHALL advertise exactly one primary BLE service. The current Service UUID is `f47ac10b-58cc-4372-a567-0e02b2c3d48d` (revision byte `d`). On every breaking GATT-shape change (added/removed characteristic, property change, payload schema change), the trailing revision byte SHALL be bumped, and the iOS app SHALL be released in lockstep with the new value.

The iOS app SHALL filter scans by the current Service UUID, MUST NOT discover the device by local name alone, and MUST NOT operate against any other service on the peripheral. The base prefix `f47ac10b-58cc-4372-a567-0e02b2c3d48` (15 bytes) is reserved for HDZap; only the trailing revision byte may change across firmware/app versions.

サービス UUID の末尾バイトは iOS CoreBluetooth の GATT 形状キャッシュ無効化に使われる。iOS は peripheral ごとに characteristic / property 構成をキャッシュするため、UUID を据え置いたまま GATT 形状を変えると古い iOS ビルドはステイル形状で動き続ける。リリースパスの責任分界: spec を更新する change が UUID をバンプし、firmware と iOS の両方を同 change で揃える。

#### Scenario: iOS scans for the device
- Given the iOS app has Bluetooth enabled and a paired or new M5StickS3 nearby
- When the user taps Scan
- Then the central scans with `withServices: [serviceUUID]` only
- And only peripherals advertising that service appear in the discovered list

#### Scenario: Firmware advertises the service
- Given the firmware has booted
- When `ble_init` finishes
- Then `BLEDevice::startAdvertising` runs with `addServiceUUID(BLE_SERVICE_UUID)` and `setScanResponse(true)`

### Requirement: Characteristic shape / Characteristic 形状

The service SHALL expose exactly the following characteristics, with the listed UUID, properties, and payload semantics. Changing any of these (UUID, properties, or payload schema) is a breaking GATT-shape change and MUST be paired with a Service UUID revision-byte bump per the Single primary service requirement above.

| Characteristic | UUID suffix | Properties | Payload |
|---|---|---|---|
| UID config | `…d481` | WRITE | `[mode:1] [arg…]` (mode 0x01 = bind phrase up to 63 bytes; 0x02 = explicit 6-byte UID; 0x03 = derive from station MAC, no arg) |
| Bind command | `…d482` | WRITE | `[0x01]` to broadcast an ELRS bind packet |
| OSD control | `…d484` | WRITE | `[cmd:1]` (0x01 clear OSD; 0x02 reset laps; 0x03 fire Test OSD probe) |
| Status | `…d485` | READ + NOTIFY | `[connected:1][uid:6][test_result:1]` (test_result: 0 none / 1 OK / 2 LOST) |
| TX sniff | `…d486` | WRITE + NOTIFY | WRITE `[0x01]` start / `[0x00]` stop; NOTIFY = captured 6-byte TX UID |
| OSD text | `…d487` | WRITE + WRITE_NR | `[row:1][text…]` (row 0–3, text up to 50 bytes) |
| Battery | `…d488` | READ + NOTIFY | `[percent:1][flags:1]` (percent: 0–100 or 0xFF unknown; flags bit0 charging, bit1 LOW, bit2 CRITICAL, bit3 silenced) |
| Sleep config | `…d48a` | READ + WRITE | `[minutes:1]` (deep-sleep idle timeout; 0 = disabled) |
| OSD layout | `…d48b` | READ + WRITE + WRITE_NR | `[y_offset:i8]` (signed; rows to shift the 4-row text block up from the bottom) |

The firmware SHALL allocate `numHandles >= 1 + 2*characteristic_count + descriptor_count` (currently 32) when calling `BLEServer::createService`. The iOS app SHALL treat absence of TX sniff or Battery as non-fatal (older firmware) but SHALL surface absence of UID config / Bind / OSD control / Status / OSD text as a firmware/app version mismatch error and tear down the connection.

NOTIFY 対応の characteristic (Status / TX sniff / Battery) は CCCD (BLE2902) を必ず追加する。`numHandles` のデフォルト 15 では characteristic がサイレントに切り捨てられ、過去 iOS 側で 8 個中 5 個しか見えない事故があった。

#### Scenario: Discovery enumerates known characteristics
- Given iOS has connected to the peripheral
- When `peripheral.discoverCharacteristics([known UUIDs], for: service)` returns
- Then the iOS app records each discovered characteristic under its UUID
- And subscribes to NOTIFY on Status, TX sniff, and Battery if present
- And issues a one-shot READ on Battery to seed the initial value

#### Scenario: Required characteristic missing
- Given a firmware build that omits one of UID config / Bind / OSD control / Status / OSD text
- When iOS finishes characteristic discovery
- Then iOS surfaces "Firmware missing characteristics: <names>. Update firmware?"
- And iOS calls `cancelPeripheralConnection` and sets `suppressAutoReconnect = true`

### Requirement: Connection parameters / 接続パラメータ

On connect, the firmware SHALL request connection parameters tuned for low-power idle: 30–50 ms interval (24–40 in 1.25 ms units), slave latency 4, supervision timeout 4 s (400 in 10 ms units). The iOS central MAY accept or reject; the firmware MUST tolerate rejection and log the LL status without retrying.

iOS が独自パラメータを採用した場合、phase 2 redux のアイドル時電流節約は失われるが機能は維持される。観測のみ。

#### Scenario: Successful negotiation
- Given a fresh BLE connection
- When firmware calls `updateConnParams(24, 40, 4, 400)` from `onConnect`
- Then the GAP `UPDATE_CONN_PARAMS` event reports `status == 0`
- And the link runs with the requested interval / latency

#### Scenario: Central rejects negotiation
- Given a fresh BLE connection
- When `updateConnParams` is called and the central rejects
- Then the GAP event reports `status != 0`
- And the firmware logs `BLE conn params REJECTED: status=<n>`
- And the connection remains usable with the central's parameters

### Requirement: Write semantics / Write の意味論

The iOS app MUST use `writeWithoutResponse` for OSD text writes (CHR_OSD_TEXT, `…d487`), and SHOULD use `writeWithoutResponse` for non-urgent OSD layout writes (slider drags). State-transition layout writes (Ready ↔ Running ↔ Result, reconnect replay) MUST use `writeWithResponse` so the new offset cannot be silently dropped from a saturated outbound queue. All other writes (UID config, Bind, OSD control, TX sniff, Sleep config) MUST use `writeWithResponse`.

WRITE_NR を使うには characteristic 側で `PROPERTY_WRITE_NR` を立てる必要があり、iOS は characteristic ごとの property bitmap をキャッシュする。property を後から WRITE_NR 付きに変えた場合、Service UUID をバンプして iOS のキャッシュを無効化しないと iOS は writeWithoutResponse をサイレントに drop する。

#### Scenario: Bulk OSD row write
- Given iOS needs to push 4 OSD rows
- When iOS issues 4 back-to-back `writeWithoutResponse` writes to CHR_OSD_TEXT
- Then all 4 land at the firmware within one or two BLE connection events
- And the firmware coalesces them into one ESP-NOW render cycle

#### Scenario: State-transition OSD layout
- Given the race transitions Ready → Running
- When iOS calls `sendOSDLayout(yOffset:, urgent: true)`
- Then iOS uses `writeWithResponse` (CBCharacteristicWriteType.withResponse)
- And iOS waits for ATT acknowledgement before sending the new content rows

### Requirement: BLE callback discipline / BLE コールバック規律

The firmware BLE callbacks (`UIDConfigCallback`, `OSDTextCallback`, `SleepConfigCallback`, `OSDLayoutCallback`, `OSDControlCallback`, `BindCmdCallback`, `TXSniffCallback`, `ServerCallbacks`) MUST stage state and set flags only. They MUST NOT call NVS, ESP-NOW send/init, or any other blocking I/O. Heavy work runs in the main loop, gated by the staged flags.

Paired state (UID + flag, OSD text rows + dirty bitmap, sleep minutes + changed flag, OSD layout y_offset + changed flag) MUST be staged under `g_ble_mux` (FreeRTOS portMUX) so the main loop never observes a torn pair. Idempotent single-flag commands (bind, OSD clear, OSD reset laps, OSD test, sniff start/stop) MAY use a bare `volatile bool`.

BLE コールバックは Bluedroid の btc_task で実行され、長くブロックすると BLE スタックの応答性が落ちる。NVS save (~ms 単位) や ESP-NOW reinit (~ms~数十 ms) はメインループ側で実行する。

#### Scenario: Concurrent BLE write during NVS save
- Given the main loop is partway through `applyStagedUid` (NVS save in flight)
- When iOS issues a second UID config write
- Then `UIDConfigCallback::onWrite` stages the new UID under `g_ble_mux` and sets `g_uid_config_requested = true`
- And the callback returns immediately
- And the next main-loop iteration picks up the new staged UID after the in-flight save completes

#### Scenario: Empty or malformed write rejected
- Given iOS sends a CHR_OSD_TEXT payload of length < 2
- When `OSDTextCallback::onWrite` runs
- Then the callback logs `OSDText: short payload (<n> bytes, need row + text)`
- And no row is staged
- And `g_osd_text_dirty` is not modified

### Requirement: Status notify content / Status 通知の中身

The firmware SHALL push a CHR_STATUS notify on every state edge: BLE connect, BLE disconnect, UID change, and Test OSD result update. The 8-byte payload SHALL be `[connected:u8][uid[6]:bytes][test_result:u8]`, atomically read under `g_ble_mux` so iOS never sees a torn UID during a UID change.

iOS SHALL parse the frame with length-discrimination: 8 bytes uses `byte[7]` as test_result; legacy 9-byte frames (older firmware) use `byte[8]` and `byte[7]` is the deprecated lap_count. iOS SHALL NOT pin `byte[7]` unconditionally because that misreads a legacy lap_count of 2 as `test_result == LOST` and rolls back a successful pairing.

#### Scenario: UID change notify
- Given iOS is connected and has cached the current UID
- When the firmware finishes `applyStagedUid`
- Then the firmware calls `ble_update_status`
- And iOS receives an 8-byte notify with the new UID at bytes 1..6
- And iOS updates `currentUID` and bumps `testResultRevision`

### Requirement: Battery wire format / バッテリ wire フォーマット

The firmware SHALL push a CHR_BATTERY notify whenever any of `{percent, charging, alarm tier, silenced}` changes (subject to the battery monitor's 5 s poll throttle). The 2-byte payload SHALL be `[percent:u8 (0–100, or 0xFF unknown)][flags:u8]`. Flag bits: bit0 charging, bit1 LOW alarm, bit2 CRITICAL alarm, bit3 silenced. Higher bits are reserved.

When `tier == None`, the silenced bit MUST be 0 (silence is meaningless without an active alarm). When charging is true, the firmware policy enforces `tier == None`. iOS SHALL log a wire-format violation if it ever sees `silenced == 1 && tier == None`, and SHALL surface a warning if any of bits 4–7 are set (forward-compat watchdog).

#### Scenario: Battery polled while idle
- Given the firmware is running on battery at 47%
- When `BatteryMonitor::tick` returns `Outcome::StateChanged` (percent edge)
- Then `ble_update_battery([0x2F, 0x00])` is called
- And iOS updates `batteryPercent = 47`, `isCharging = false`, `batteryAlarm = .none`

#### Scenario: Critical alarm with silenced
- Given the cell is at 8% and the operator has pressed the silence button
- When the firmware pushes the next battery frame
- Then the payload is `[0x08, 0x0C]` (CRITICAL bit + silenced bit)
- And iOS decodes `BatteryAlarm.critical(silenced: true)`
