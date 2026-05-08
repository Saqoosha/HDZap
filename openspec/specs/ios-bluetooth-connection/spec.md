# ios-bluetooth-connection Specification

## Purpose

Manage the iOS-side BLE central lifecycle so the operator can pair, run, and recover from drops with predictable behavior — no silent state divergence between the app and the firmware, no ghost UIDs after a disconnect, no inscrutable failures during BT-state transitions.

## Requirements

### Requirement: Main-actor isolation / メインアクター隔離

`BluetoothManager` SHALL be `@MainActor` annotated. The `CBCentralManager` delegate dispatch queue MUST be the main queue (`queue: nil`). Functions that mutate observable state from BLE callbacks MUST runtime-assert main-actor isolation via `MainActor.assertIsolated()` (the @objc bridge from CoreBluetooth would otherwise let a future queue change silently break this).

`@MainActor` 配下のクラスでも、`CBCentralManagerDelegate` の `@objc` メソッドは Swift concurrency の隔離検査を経由しない。queue を変えると runtime まで検出されないため、ガードを runtime に置く。

#### Scenario: Recording an error from delegate
- Given a CB delegate callback running on main
- When `recordError(_:)` is called
- Then `MainActor.assertIsolated()` succeeds
- And `errorLog` is mutated safely

### Requirement: Scan state machine / スキャン状態機械

The central SHALL only scan when `state == .poweredOn`. Other states MUST surface an actionable user-facing error: `.poweredOff` → "Bluetooth is off. Enable it in Control Center.", `.unauthorized` → "Bluetooth permission denied. Open Settings → HDZero → Bluetooth.", `.unsupported` → "This device doesn't support Bluetooth LE." Other states MUST surface the raw state code so support reports remain useful.

Scan filtering MUST use `withServices: [serviceUUID]` (per `ble-gatt-protocol`). Discovered peripherals MUST be deduplicated by `identifier` to avoid double-listing the same device when it re-advertises during the scan window.

#### Scenario: Scan with BT off
- Given `centralManager.state == .poweredOff`
- When `startScan()` is called
- Then `lastError == "Bluetooth is off..."` and the central does NOT call `scanForPeripherals`

#### Scenario: Same device re-advertised
- Given `discoveredDevices` contains a peripheral with identifier X
- When the central reports the same X in another `didDiscover` callback
- Then `discoveredDevices` is unchanged (no duplicate entry)

### Requirement: Connect / disconnect / teardown distinction / 接続・切断・強制破棄の区別

The system SHALL distinguish three teardown sources with separate flags:

- **User Disconnect** — `userTappedDisconnect = true`, `suppressAutoReconnect = true`. iOS MUST NOT auto-reconnect on the upcoming `didDisconnectPeripheral`. State-change banner SHALL be suppressed (the user knows they tapped Disconnect).
- **App-initiated teardown** — `tearDownConnection(_:)` after a discovery / characteristic-discovery / wrong-service failure. `suppressAutoReconnect = true`, `userTappedDisconnect = false`. The teardown error banner stands but does not mask a concurrent BT-state change banner.
- **Unintended drop** — neither flag set. The system SHALL NOT surface a red error; instead it SHALL log the drop to console and call `centralManager.connect(peripheral)` to let iOS auto-reconnect indefinitely.

All three teardown paths MUST clear `previousUID`, `capturedTXUID`, `isTXSniffActive`, and `batteryPercent/isCharging/batteryAlarm` so a stale rollback target can't be applied to a different goggle on the next session.

`suppressAutoReconnect` の二重利用 (user tap + 内部 teardown) は意図的。両者とも「次の didDisconnect で auto-reconnect しない」結果が必要なため、フラグ 1 本で表現する。

#### Scenario: User Disconnect
- Given iOS is connected
- When the user taps Disconnect
- Then `disconnect()` runs, sets both flags, and calls `cancelPeripheralConnection`
- And `didDisconnectPeripheral` early-returns without auto-reconnect

#### Scenario: Wrong service
- Given the peripheral advertises only an unrelated service
- When `didDiscoverServices` runs
- Then `lastError` carries "ESP32 doesn't advertise expected service. Update firmware?"
- And `tearDownConnection` runs
- And the next session does NOT auto-apply the previous UID

#### Scenario: Auto-reconnect on drop
- Given iOS is connected and neither user-disconnect nor teardown is in flight
- When `didDisconnectPeripheral` fires with an error
- Then iOS prints a console log only (no red banner)
- And `centralManager.connect(peripheral)` queues an auto-reconnect

### Requirement: isReady gates writeable UI / 書き込み可能 UI は isReady に gating

`isReady` SHALL return true only when `isConnected == true` AND both `osdControlUUID` and `osdTextUUID` characteristics have been discovered. UI controls that require writing to the goggle (Lap, Reset, Apply UID) MUST gate on `isReady`, not `isConnected` alone.

`isConnected` は `didConnect` で立ち、`didDiscoverCharacteristics` まで write は失敗する。短い空白窓で write を許すと "Characteristic not ready" エラーがユーザに見える形で出る。

#### Scenario: Connect-just-completed window
- Given `didConnect` fired but characteristic discovery is in flight
- When `isReady` is read
- Then it returns `false` until characteristics are discovered

### Requirement: Error log with overflow + dedup / エラーログのオーバーフローと重複圧縮

The error log SHALL hold at most 5 entries (newest at index 0). Inserting a duplicate of the head MUST collapse into a single entry while incrementing `droppedErrorCount`. Inserting past capacity MUST trim the oldest while incrementing `droppedErrorCount`. `clearError()` (single-tap dismissal) SHALL pop the head only and preserve `droppedErrorCount`. `clearAllErrors()` SHALL zero the log and the dropped counter.

エラー嵐の中で 5 件しかログを残さないと「あといくつ消えたか」が見えなくなる。`droppedErrorCount` を sticky にすることで、ユーザが 1 件ずつ tap して消化したあとも本当の量が分かる。

#### Scenario: Storm of identical errors
- Given the head error is "Characteristic not ready"
- When 10 more "Characteristic not ready" errors are recorded
- Then `errorLog.count == 1` and `droppedErrorCount == 10`

#### Scenario: Different errors past capacity
- Given the log is full with 5 distinct errors
- When a 6th distinct error is recorded
- Then `errorLog.count == 5` (newest at 0, oldest dropped)
- And `droppedErrorCount += 1`

### Requirement: Battery state lifecycle / バッテリ状態のライフサイクル

iOS SHALL clear `batteryPercent`, `isCharging`, `batteryAlarm` on every disconnect, teardown, and notify error. A stale "47%" lingering after the link drops would mislead the operator about the device's current state.

iOS SHALL issue a one-shot READ on the Battery characteristic during characteristic discovery so the first frame fills before the CCCD-triggered notify pipeline establishes. Without this, the connect-edge notify can race the CCCD write and the first frame is silently dropped.

iOS SHALL surface a forward-compat warning if the battery flags byte has any of bits 4–7 set ("Battery wire format has unknown bits 0x..."), and a wire-invariant warning if `silenced=1 && tier=None` (firmware regression).

#### Scenario: Disconnect mid-frame
- Given the most recent battery frame was 47% / not charging
- When the link drops (any source)
- Then `batteryPercent`, `isCharging`, `batteryAlarm` all reset

#### Scenario: Forward-compat warning
- Given the firmware sends a battery payload with bit 5 set
- When iOS decodes the frame
- Then `lastError` carries the unknown-bits warning with the masked hex
- And the warning collapses to one entry on repeats (consecutive-duplicate dedup)

### Requirement: Status frame length discrimination / Status フレーム長による分岐

iOS SHALL parse CHR_STATUS frames using length-discrimination per `ble-gatt-protocol`: 8 bytes places `test_result` at index 7; 9 bytes places `test_result` at index 8 with index 7 being the deprecated `lap_count`. iOS MUST NOT pin index 7 unconditionally because that misreads a legacy `lap_count == 2` as `test_result == LOST` and rolls back a successful pairing.

iOS SHALL bump `testResultRevision` on every parsed status frame, regardless of value, so observers can ignore stale frames from before their own pairing attempt.

iOS SHALL surface a "Status frame unexpected size (NB, expected ≥8). Firmware/app version mismatch?" error if the payload is shorter than 8 bytes, AND invalidate `currentUID` so the UI does not keep showing a UID that no longer reflects firmware state.

#### Scenario: Legacy 9-byte status frame
- Given an older firmware build emitting a 9-byte frame with `lap_count = 2, test_result = 0`
- When iOS parses
- Then `lastTestResult == .none` (read from byte 8)
- And NOT `.lost` (which it would be if byte 7 were used)

### Requirement: previousUID rollback target lifecycle / previousUID ロールバック対象のライフサイクル

`previousUID` SHALL be set when `recordPreviousUID` is called on a known-current UID before applying a new one. It MUST be cleared on:

- User Disconnect (next session is likely a different M5Stick).
- `tearDownConnection` (same reason).
- `didFailToConnect` (the connection never came up; rollback target is meaningless).
- Successful auto-rollback (the rollback BLE write actually queued).

It MUST persist across the Settings sheet being dismissed so the operator can re-open Settings later and tap Restore even after a successful pairing — "go back to my old goggle" is a real workflow.

#### Scenario: Pairing fails, auto-rollback
- Given iOS just applied UID B with previousUID = A
- When the firmware reports test_result == LOST
- Then iOS dispatches `[0x02][A]` to CHR_UID_CONFIG
- And `previousUID` is cleared if the dispatch returned true

#### Scenario: Manual Restore later
- Given a successful Apply with previousUID still recorded
- When the user taps Restore in Settings
- Then iOS dispatches the rollback write and clears `previousUID`

### Requirement: TX sniff state / TX sniff 状態

`isTXSniffActive` SHALL be a local view of whether iOS has asked the firmware to listen. The firmware emits no state echo, so iOS MUST track the toggle locally.

`isTXSniffActive` MUST be preserved across auto-reconnects (the firmware recv callback survives BLE drops), and MUST be cleared on user-initiated Disconnect and any `tearDownConnection` (firmware state is also discarded in those cases).

`capturedTXUID` MUST be cleared on every disconnect so a stale capture from a prior session can't be applied to the next M5Stick.

#### Scenario: Auto-reconnect during sniff
- Given `isTXSniffActive == true` and the link drops
- When iOS auto-reconnects
- Then `isTXSniffActive` is still `true` (not reset by the drop)
- And iOS SHALL NOT re-issue the start command on every reconnect (firmware state survived)
