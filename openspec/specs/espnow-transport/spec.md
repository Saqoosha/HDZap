# espnow-transport Specification

## Purpose

Move MSP / MSP-DisplayPort frames from the M5StickS3 to the HDZero goggle's ELRS backpack and back (for TX sniff) reliably enough to drive a sub-100 ms lap-timer feedback loop, with delivery feedback and a runtime-mutable peer.

## Requirements

### Requirement: Channel and protocol pinning / チャンネルとプロトコル固定

The firmware SHALL pin WiFi to channel 1 via `WiFi.begin("_", "_", 1)` and verify post-init using `esp_wifi_get_channel`. Channel drift after `WiFi.begin` MUST trigger an `esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE)` correction with a serial log. The peer entry SHALL use `peer.channel = 0` ("current channel").

Protocols SHALL be `WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N | WIFI_PROTOCOL_LR`. LR mode is ESP32-family-only; failure to enable it SHALL log a warning ("LR may be unavailable") but MUST NOT abort init.

ESP-NOW `peer.channel = 0` は「現在のチャンネル」を意味するので、WiFi.begin 後にチャンネルがずれると packet が goggle の listening channel に届かなくなる。固定 1 が大前提。

#### Scenario: Channel drift detected
- Given `WiFi.begin` for some reason lands on channel 6
- When `espnow_init` queries `esp_wifi_get_channel`
- Then it logs `WiFi on channel 6, forcing to 1`
- And calls `esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE)` before adding the peer

### Requirement: Idempotent init / 冪等な初期化

`espnow_init` SHALL be safe to call repeatedly. If `esp_now_init` returns `ESP_ERR_ESPNOW_INTERNAL` (typically caused by re-init on top of an already-initialized stack), the firmware SHALL `esp_now_deinit` (tolerating `ESP_ERR_ESPNOW_NOT_INIT`) and retry `esp_now_init` once. A peer-add returning `ESP_ERR_ESPNOW_EXIST` SHALL be treated as success with a log.

Send callback registration MUST happen BEFORE `esp_now_add_peer` so the EXIST early-return path still has delivery tracking wired. Callback registration failure SHALL log loudly ("delivery tracking disabled") but MUST NOT abort — transmission still works without the callback, but the render state machine sees no fail events and silently skips retries.

#### Scenario: Cold init
- Given fresh boot
- When `espnow_init(g_uid)` is called
- Then `esp_now_init` succeeds, send_cb is registered, the peer is added, and the function returns true

#### Scenario: Stale state from a prior init
- Given a prior `espnow_init` partially completed
- When `espnow_init` is called again
- Then `esp_now_init` returns `ESP_ERR_ESPNOW_INTERNAL`, deinit + retry recovers, and the function returns true

### Requirement: Peer table management on UID change / UID 変更時の peer テーブル管理

`espnow_reinit(new_uid)` SHALL:

1. Apply the unicast invariant (`new_uid[0] &= ~0x01`).
2. Snapshot every registered peer into a local array via `esp_now_fetch_peer` iteration.
3. Delete each snapshotted peer (tolerating `ESP_ERR_ESPNOW_NOT_FOUND` as success).
4. Update the station MAC via `esp_wifi_set_mac(WIFI_IF_STA, new_uid)`. Failure → return false (caller will fall back to `espnow_init`).
5. Add the new UID as a peer with `channel=0, encrypt=false, ifidx=WIFI_IF_STA`. EXIST → log + success.

Mutating the peer list while iterating with `esp_now_fetch_peer` is undocumented behavior; the snapshot-then-delete pattern is the only safe form.

`from_head=true` で fetch を始めて以降 `false` で続ける。`fetch_peer` は broadcast / multicast peer をスキップする可能性があるので「delete shifts the head」式の iteration は壊れやすい。

#### Scenario: UID change with one existing peer
- Given the peer table contains UID A
- When `espnow_reinit(UID B)` is called
- Then UID A is deleted, the station MAC becomes B, and B is added as the only peer

### Requirement: Send callback feedback / 送信コールバックフィードバック

The firmware SHALL register `_espnow_send_status_cb` via `esp_now_register_send_cb`. Successful deliveries SHALL increment `g_espnow_sent_ok`; failed deliveries (any non-`ESP_NOW_SEND_SUCCESS` status) SHALL increment `g_espnow_sent_fail`.

These counters are the only delivery feedback available (the HDZero goggle does not emit application-level acks). They MUST be `volatile uint32_t` aligned so single-word load/store is atomic on ESP32 — no mux required for the one-writer / one-reader pattern. Wraparound is safe via unsigned subtraction at read sites.

#### Scenario: Render verify uses the counters
- Given a render cycle dispatches 5 packets
- When the verify window elapses
- Then the main loop reads `g_espnow_sent_fail - g_render_fail_baseline` and treats >0 as a delivery failure

### Requirement: No delay() between packets / パケット間に delay() なし

The firmware MUST NOT call `delay()` between consecutive `esp_now_send` calls in a single MSP cycle. `delay()` yields to FreeRTOS, breaking ESP-NOW packet timing — observed symptom is the goggle dropping every packet after the first. `delayMicroseconds` is a busy-wait that does NOT yield and MAY be used (e.g. the 5 ms gap between bind broadcasts).

After all packets in a cycle are queued, calling `delay()` to wait for send-callback timing (e.g. the Test OSD probe's 200 ms verify wait) is allowed because the ESP-NOW MAC-layer TX runs on the WiFi task and is not blocked by main-loop `delay()`.

CLAUDE.md にも明記されているプロジェクト最重要不変条件の一つ。再発防止の観点で spec として固定する。

#### Scenario: Bind broadcast gap
- Given `espnow_send_broadcast(data, len, repeat=3)`
- When the second and third sends are emitted
- Then `delayMicroseconds(5000)` runs between them (busy-wait, no yield)
- And NEVER `delay(5)` (millis-based, yields to FreeRTOS)

### Requirement: Broadcast send for bind / Bind 用ブロードキャスト送信

`espnow_send_broadcast(data, len, repeat)` SHALL:

1. Add the broadcast peer (`FF:FF:FF:FF:FF:FF`) with `channel=0, ifidx=WIFI_IF_STA, encrypt=false`. `ESP_ERR_ESPNOW_EXIST` → log + continue.
2. Send `repeat` times, with `delayMicroseconds(5000)` between consecutive sends.
3. Remove the broadcast peer (tolerating `ESP_ERR_ESPNOW_NOT_FOUND`).

The function SHALL return `true` only if every send returned `ESP_OK`.

ELRS backpack は 3 連続 broadcast を 5 ms 間隔で受信できる前提で書かれている。間隔を 0 にすると最初の packet 以外を取りこぼす実機挙動が観測されている。

#### Scenario: Three-broadcast bind
- Given `send_bind_packet(uid)` is called
- When `espnow_send_broadcast(buf, len, 3)` runs
- Then 3 broadcasts are sent with 5 ms gaps and the broadcast peer is removed afterward

### Requirement: TX sniff recv callback / TX sniff 受信コールバック

`sniff_start()` SHALL register `_espnow_recv_cb` via `esp_now_register_recv_cb`. The callback SHALL filter for MSP `MSP_ELRS_BIND` packets:

- Length >= 15 bytes (header + flags + func + size + uid_payload + crc).
- Header bytes `$X<` at indices [0..2].
- Function code `MSP_ELRS_BIND = 0x0009` at indices [4..5] (little-endian).

A matching frame's `src_mac` (the ELRS backpack's UID) SHALL be copied into `g_sniff_uid` under `g_sniff_mux`, with bit 0 of byte 0 cleared (unicast invariant), and `g_sniff_captured` set true.

`sniff_stop()` SHALL `esp_now_unregister_recv_cb` (tolerating `ESP_ERR_ESPNOW_NOT_INIT`) and clear `g_sniff_active`.

ESP-NOW の recv callback スロットはグローバルに 1 つ。プロジェクト内で他の recv_cb は使わないため、`sniff_start/stop` がグローバルなオン/オフを表す。

#### Scenario: Bind packet captured
- Given a sniff session is active and a goggle nearby fires its TX bind
- When the recv callback receives a 15+ byte frame with header `$X<` and func 0x0009
- Then `g_sniff_uid` is set to `mac_addr` (with bit0 cleared)
- And `g_sniff_captured = true`

### Requirement: TX power and current trim / TX パワー・電流トリム

The firmware SHALL set WiFi maximum TX power to ~+7 dBm via `esp_wifi_set_max_tx_power(28)` (unit = 0.25 dBm). Failure SHALL log but MUST NOT abort init.

The firmware SHALL drop BLE TX power from the +9 dBm Arduino default to 0 dBm via `esp_ble_tx_power_set(ESP_PWR_LVL_N0)` for `DEFAULT`, `ADV`, and `SCAN` types. `CONN_HDL0` MUST NOT be set in `ble_init` because the per-connection-handle override is only valid AFTER the connection completes; `ESP_BLE_PWR_TYPE_DEFAULT` covers the connected case.

iPhone がオペレータの卓上 (1-2 m) にある運用条件下で +7 dBm でリンクマージンは十分。TX 電流節約は idle 時の合計電流に効く。

#### Scenario: TX power applied at boot
- Given a fresh boot
- When `espnow_init` and `ble_init` complete
- Then WiFi TX is at ~+7 dBm (28 in 0.25 dBm units)
- And BLE DEFAULT/ADV/SCAN TX power is N0 (0 dBm)
- And serial log surfaces the actual values via the getter
