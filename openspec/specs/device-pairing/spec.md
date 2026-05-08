# device-pairing Specification

## Purpose

Match the M5StickS3 bridge to the pilot's HDZero goggle so ESP-NOW frames from the bridge are accepted as ELRS-bound traffic, with three on-ramps (existing UID reuse, bind phrase derivation, TX sniff capture) and one fail-safe (auto-rollback on failed pairing).

## Requirements

### Requirement: UID is 6 unicast bytes / UID は 6 バイトのユニキャスト

A UID SHALL be exactly 6 bytes. Bit 0 of byte 0 (the IEEE 802 multicast flag) MUST be cleared at every assignment site (BLE callback, NVS load, MAC fallback, MD5 derivation, TX sniff capture, manual entry). The firmware MUST NOT register a non-unicast UID as an ESP-NOW peer, and `esp_wifi_set_mac` rejects multicast addresses.

`uid[0] &= ~0x01` (or `&= 0xFE`) を全代入サイトで強制する。NVS の旧データや手入力で multicast bit が立った値が紛れ込む可能性があるため、load 後にも適用する。

#### Scenario: Manual UID entry with multicast bit
- Given the user enters `01:02:03:04:05:06` (bit0 of byte 0 set)
- When iOS calls `normalizeUID`
- Then the result is `00:02:03:04:05:06`
- And iOS displays the normalized result so the user sees the change

#### Scenario: Boot from NVS with corrupt UID
- Given NVS holds a UID with bit0 set (legacy or torn save)
- When `nvs_store::loadUid` returns
- Then `g_uid[0] &= ~0x01` runs in `setup()`
- And `espnow_init` registers the cleared UID as the peer

### Requirement: Bind phrase derivation matches ELRS / Bind phrase 派生は ELRS と一致

The bind phrase MUST be UTF-8 and at most 63 bytes. The derived UID SHALL be the first 6 bytes of `MD5("-DMY_BINDING_PHRASE=\"<phrase>\"")` with bit 0 of byte 0 cleared. The iOS app and the firmware MUST compute identical UIDs for the same input, including the byte cap.

iOS は `Insecure.MD5`、firmware は `MD5Builder`。プロンプト文字列のフォーマット (ダブルクォート込み) と長さ上限を両端で一致させないと、ペアリング後に goggle が応答しない原因になる。

#### Scenario: Standard bind phrase
- Given the user enters bind phrase "myracer"
- When either side derives the UID
- Then both sides produce the same 6 bytes with bit0 of byte 0 = 0

#### Scenario: Bind phrase exceeds 63 bytes
- Given the user enters a 64-byte bind phrase
- When iOS attempts to send via CHR_UID_CONFIG mode 0x01
- Then iOS surfaces "Bind phrase is 64 bytes; max is 63" and does not send
- And firmware similarly rejects an oversized payload with a serial log

### Requirement: UID sources / UID の入手経路

The system SHALL support three UID-acquisition modes, exposed via CHR_UID_CONFIG:

- Mode 0x01 (bind phrase) — payload `[0x01][phrase utf-8 ≤ 63]`. Firmware derives the UID via the MD5 formula.
- Mode 0x02 (explicit UID) — payload `[0x02][uid:6]`. Firmware accepts the bytes verbatim after applying the unicast invariant.
- Mode 0x03 (new pairing / station MAC) — payload `[0x03]`. Firmware derives the UID from `esp_read_mac(.., ESP_MAC_WIFI_STA)`. Used to provision a goggle that does not yet have a UID; subsequently the firmware broadcasts an ELRS bind packet so the goggle adopts this UID.

The firmware MUST log unrecognized modes and short payloads without staging a UID.

`mode 0x03` は「この M5Stick の MAC を新しい UID として採用する → bind broadcast で goggle に押し付ける」というシナリオで、空 UID の goggle に対する初回プロビジョニング用途。

#### Scenario: Bind phrase to UID
- Given iOS writes `[0x01]"myracer"` (8 bytes total) to CHR_UID_CONFIG
- When `UIDConfigCallback::onWrite` parses the payload
- Then `uid_from_bind_phrase("myracer", new_uid)` runs
- And `new_uid` is staged under `g_ble_mux` with `g_uid_config_requested = true`

#### Scenario: Manual UID write
- Given iOS writes `[0x02][0xAA,0xBB,0xCC,0xDD,0xEE,0xFF]` to CHR_UID_CONFIG
- When the callback parses
- Then `new_uid = AA:BB:CC:DD:EE:FF` is staged with bit0 cleared (resulting in AA:BB:CC:DD:EE:FE)

### Requirement: ELRS bind broadcast / ELRS bind ブロードキャスト

When CHR_BIND_CMD receives `[0x01]`, the firmware SHALL broadcast an MSP `MSP_ELRS_BIND` packet over ESP-NOW carrying the current UID as the payload, repeated 3 times. The 3 broadcasts MUST be separated by ~5 ms gaps using `delayMicroseconds(5000)` (busy-wait, NOT `delay()`), because the ELRS backpack drops back-to-back broadcasts arriving faster than it can process them.

The firmware MUST add the broadcast peer (`FF:FF:FF:FF:FF:FF`) before transmitting and remove it after, treating `ESP_ERR_ESPNOW_EXIST` on add as a stale-state log-and-continue.

`delay()` を 3 broadcast 間に挟むと FreeRTOS が yield して ESP-NOW タイミングが崩れる (CLAUDE.md「NEVER use delay() between ESP-NOW packets」)。`delayMicroseconds` は busy-wait で yield しないため許容される。

#### Scenario: Bind from a paired session
- Given the firmware has a UID and ESP-NOW is initialized
- When iOS writes `[0x01]` to CHR_BIND_CMD
- Then `g_bind_requested` becomes true
- And the next main-loop iteration calls `send_bind_packet(g_uid)` and clears the flag
- And the LCD shows `BIND PACKET SENT/FAIL` for ~3 s via `showBindResult(ok)`

### Requirement: TX sniff capture / TX sniff キャプチャ

When CHR_TX_SNIFF receives `[0x01]`, the firmware SHALL register an ESP-NOW recv callback that filters for MSP `MSP_ELRS_BIND` packets and treats the source MAC of any matching frame as a captured TX UID. The captured 6 bytes (after the unicast-invariant clear) MUST be sent to iOS via a CHR_TX_SNIFF notify. Writing `[0x00]` to CHR_TX_SNIFF SHALL unregister the callback.

The recv-callback registration state SHALL survive BLE drops; only an explicit stop request clears it. While a sniff session is active, the deep-sleep gate MUST defer sleep so a captured frame is not lost between recv and notify.

ELRS backpack は自身の UID をそのまま MAC アドレスとして送信するため、bind 帯のブロードキャストを受信して `mac_addr` を読むだけで UID が抽出できる。15 バイト未満のフレーム、`$X<` 以外の header、`MSP_ELRS_BIND` 以外の function は捨てる。

#### Scenario: Capture during pilot bind
- Given iOS has activated TX sniff and the pilot triggers their TX bind on a goggle nearby
- When the recv callback sees a matching MSP_ELRS_BIND frame
- Then `g_sniff_uid = mac_addr` (with bit0 cleared) and `g_sniff_captured = true`
- And the main loop dispatches `ble_notify_tx_uid(uid)`
- And iOS updates `capturedTXUID`

#### Scenario: Stop sniff explicitly
- Given a sniff session is active
- When iOS writes `[0x00]` to CHR_TX_SNIFF
- Then `sniff_stop()` runs and `g_sniff_active = false`

### Requirement: Apply UID atomically / UID の原子的適用

When `g_uid_config_requested` is set, the main loop SHALL:

1. Snapshot `g_staged_uid` under the mux and clear the flag.
2. Cancel any in-flight render (UID change invalidates packets aimed at the old peer).
3. Persist the new UID via `nvs_store::saveUid`. If save fails, abort without mutating `g_uid` and surface `NVS SAVE FAIL` on the LCD.
4. Publish the new UID to `g_uid` under the mux.
5. Re-initialize ESP-NOW with the new UID via `espnow_reinit` (or `espnow_init` if the radio is currently down).
6. Update LCD status and clear any superseded sticky message.
7. Push a CHR_STATUS notify so iOS sees the new UID immediately.

The firmware MUST NOT publish a UID it failed to persist (no rollback window where iOS could read an uncommitted value).

`espnow_reinit` は登録済 peer の snapshot → delete → MAC 変更 → 新 peer 追加の順で動く。`esp_now_fetch_peer` の iteration 中の peer mutation はドキュメント外なので一旦コピーしてから消す。

#### Scenario: Successful UID change while connected
- Given iOS is connected and the firmware has UID A
- When iOS sends a CHR_UID_CONFIG write resulting in staged UID B
- Then NVS save succeeds → `g_uid = B` → ESP-NOW reinitializes with B → CHR_STATUS notify fires with B in bytes 1..6
- And iOS observes `currentUID == B`

#### Scenario: NVS save fails
- Given a transient NVS partition error
- When the main loop tries `nvs_store::saveUid(B)` and it returns false
- Then `g_uid` remains A
- And the LCD shows `NVS SAVE FAIL` (red)
- And iOS continues to read UID A in the next status frame

### Requirement: Auto-rollback on failed pairing / ペアリング失敗時の自動ロールバック

The iOS pairing flow SHALL record the previous UID before applying a new one (via `recordPreviousUID`). After a successful Apply + bind, iOS SHALL trigger a Test OSD probe (CHR_OSD_CONTROL `0x03`). If the firmware reports `test_result == 2 (LOST)` within the pairing flow's window, iOS SHALL auto-roll back by re-sending the previous UID via mode 0x02. The rollback target persists across Settings sheet open/close so the user can manually Restore later, but is cleared on user-initiated Disconnect or any teardown that drops the session intent.

iOS は `testResultRevision` を bump 比較して、自分の Apply 以前の古い test result を誤って受け取らないようにする。複数 Apply 連打にも対応する。

#### Scenario: Test reports LOST
- Given iOS just applied UID B and bound the goggle
- When the firmware completes Test OSD and reports `test_result = 2`
- Then iOS dispatches a CHR_UID_CONFIG mode-0x02 write with the previous UID A
- And `previousUID` is cleared because the rollback dispatch was queued

#### Scenario: Manual Restore later in the session
- Given a successful Apply (test_result == OK) on UID B, with previousUID == A still recorded
- When the user taps Restore in the Settings sheet
- Then iOS dispatches mode-0x02 with UID A
- And `previousUID` is cleared

### Requirement: Bind-phrase byte cap is shared / Bind phrase バイト上限の共有

`maxBindPhraseBytes` MUST be 63 on both sides. iOS validates pre-send (`sendUIDConfig` rejects oversized phrases with a user-visible error). Firmware validates post-receive (oversized phrases produce a serial log without staging). A drift in this constant produces UIDs that disagree across sides and breaks pairing without an obvious symptom.

#### Scenario: Constant drift detected by review
- Given a PR raises iOS's `maxBindPhraseBytes` without changing the firmware's `kMaxBindPhrase`
- When the spec is consulted
- Then the reviewer flags the divergence as a breaking change requiring a coordinated bump

### Requirement: Status carries Test OSD verdict / Status に Test OSD 結果を載せる

The firmware SHALL encode the most recent Test OSD outcome into the CHR_STATUS frame's last byte: 0 = no test yet, 1 = OK (all packets MAC-acked), 2 = LOST. The byte SHALL be updated under `g_ble_mux` in lockstep with the rest of the status frame. iOS SHALL read this byte (with length-discrimination per `ble-gatt-protocol`) and bump `testResultRevision` on every received frame, regardless of value, so observers can ignore stale frames from before their own pairing attempt.

#### Scenario: Test OSD success path
- Given iOS triggers Test OSD via CHR_OSD_CONTROL `0x03`
- When the firmware completes the probe with all packets MAC-acked
- Then `g_last_test_result = 1` under the mux
- And `ble_update_status` notifies with byte[7] = 1
- And iOS observes `lastTestResult == .ok` and `testResultRevision` increments
