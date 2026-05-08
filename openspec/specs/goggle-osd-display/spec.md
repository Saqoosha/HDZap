# goggle-osd-display Specification

## Purpose

Render iOS-supplied 4-row OSD text on the HDZero goggle reliably, recovering from MAC-layer delivery failures, never overwriting fresh content with stale, and never wedging the operator on a frozen screen.

## Requirements

### Requirement: OSD grid and glyph mapping / OSD グリッドとグリフマッピング

The OSD grid SHALL be 50 columns by 18 rows (HDZero HD mode constants `OSD_COLS = 50`, `OSD_ROWS = 18`). The firmware SHALL auto-uppercase ASCII a–z to A–Z in `osd.h::writeString` because bytes 0x60–0x7F on the HDZero glyph set are FPV icons (battery, GPS, arrows), NOT ASCII lowercase. iOS senders MAY contain lowercase ASCII; bytes ≥ 0x60 outside the lowercase range MUST NOT appear in OSD strings.

`writeString` の OOB チェックは row >= OSD_ROWS / col >= OSD_COLS でフェイルセーフ (false 戻り)。max length は `col + len <= OSD_COLS` で truncate される。

#### Scenario: Lowercase letter received
- Given iOS sends "lap 5" (lowercase 'l')
- When the firmware writes the row via `writeString`
- Then the byte 'l' (0x6C) is converted to 'L' (0x4C) before being placed in the MSP payload

### Requirement: ESP-NOW packet budget / ESP-NOW パケット予算

A single OSD render cycle SHALL emit at most 10 ESP-NOW packets: 1 clear + up to 8 writeStrings + 1 draw. The default 4-row text-display path uses up to 5 packets per cycle (4 writeStrings for dirty rows + 1 draw); the Test OSD probe uses 3 packets (clear + writeString + draw); the Reset Laps path uses 2 packets (clear + draw).

このバジェットは ESP-NOW のシリアライズ送信タイミング (peer per ~ms, MAC retry 数十 ms 最悪) に対する verify window 200 ms の前提条件。10 packets 超過は verify window 内に収まらず、retry の判断が誤る可能性がある。

#### Scenario: Worst case 4-row dirty render
- Given all 4 OSD rows are marked dirty
- When the render dispatch runs
- Then 5 packets are queued: 4 writeString + 1 draw
- And the verify window (200 ms) is sufficient for MAC-layer ack callbacks

### Requirement: Per-row dirty bitmap / 行ごとのダーティビットマップ

The firmware SHALL maintain a 4-bit dirty bitmap (`m_dirty`) tracking which of the 4 rows have new content awaiting render. New content from iOS MUST OR-merge into the existing bitmap (`setDirtyRows(dirty, rows)`). The render path SHALL emit only the rows whose bit is set in the **dispatched mask**, NOT the live `m_dirty`, so a concurrent BLE write that lands between snapshot and packet emission stays for the next cycle instead of hitching a ride into the current one.

The renderer SHALL leave `m_dirty` untouched after `render()` — the caller (main.cpp's render state machine) is responsible for clearing the dispatched bits via `clearDirtyBits(mask)` only after MAC-layer delivery is confirmed.

これは「verify window 中に新着 BLE 書き込みが m_dirty に OR されたとき、verify 成功で全 dirty bits がクリアされて新着内容が消失する」を防ぐための設計。dispatch 時の snapshot を保存し、verify 成功時にその snapshot のみクリアする。

#### Scenario: Two writes during one cycle
- Given iOS writes rows 0 and 1, then 40 ms later writes row 2 while the first cycle is in WAITING_ACK
- When the first cycle's verify succeeds
- Then `clearDirtyBits(0b0011)` runs (only the dispatched bits)
- And `m_dirty == 0b0100` (row 2 still pending)
- And the IDLE catch-up trigger picks up row 2 in the next cycle

### Requirement: Render state machine / レンダ状態機械

The render flow SHALL be a 3-state machine:

- **IDLE** — no render in flight. If `hasDirty()` and `espnow_ready`, the catch-up trigger queues a PENDING with `RENDER_STAGING_MS` (40 ms) delay so back-to-back BLE writes coalesce into one cycle.
- **PENDING** — dispatch scheduled at `g_render_after_ms`. On dispatch: snapshot `g_espnow_sent_fail` as `g_render_fail_baseline`; snapshot `m_dirty` as `g_render_dispatched_mask`; call `render(mask)`. If queue-level send fails (esp_now_send returns non-OK), retry up to `MAX_RENDER_RETRIES` (2) with `RENDER_RETRY_BACKOFF_MS` (50 ms) backoff. If queue succeeds, transition to WAITING_ACK with verify deadline `now + RENDER_VERIFY_MS` (200 ms).
- **WAITING_ACK** — at the verify deadline, compare `g_espnow_sent_fail - g_render_fail_baseline`. If 0, all packets MAC-acked → clear dispatched bits → IDLE. If > 0 and retries remain, decrement retry counter → PENDING with backoff. If > 0 and retries exhausted → clear dispatched bits → cancelRender → show `OSD LOST`.

`cancelRender()` SHALL be called whenever the in-flight cycle would render stale state: UID change, OSD clear, OSD reset laps, base-row change. Late callbacks from the canceled cycle MUST NOT trigger a retry.

ESP-NOW unicast は MAC レイヤで自動 retry するが、最後の retry が失敗した時の通知が send callback 経由でしか得られない。HDZero goggle は application-level ack を出さないので、これが取れる最深のフィードバック。

#### Scenario: All packets delivered
- Given a 5-packet cycle at baseline `g_espnow_sent_fail = 100`
- When the verify window elapses with `g_espnow_sent_fail` still 100
- Then dispatched bits are cleared and the state machine returns to IDLE

#### Scenario: One packet lost, retries available
- Given a 5-packet cycle, baseline 100, retries-left = 2
- When verify shows `g_espnow_sent_fail == 101` (1 fail)
- Then retries-left becomes 1
- And the state transitions to PENDING with a 50 ms backoff
- And the LCD shows `RETRY` (orange)

#### Scenario: Retries exhausted
- Given retries-left = 0 and verify shows fails > 0
- When the verify window elapses
- Then dispatched bits are cleared (so IDLE catch-up doesn't immediately re-fire)
- And the LCD shows `OSD LOST` (red)
- And the state machine returns to IDLE

### Requirement: Render is idempotent against the buffer / レンダはバッファに対して冪等

A re-render of the same dispatched mask SHALL produce the same on-goggle state. The goggle's MSP DisplayPort overlay buffer retains row content between writes — the renderer deliberately does NOT issue a clear before each cycle so untouched rows stay put. Mid-cycle failures (e.g. writeString #2 lands but writeString #3 drops) leave the goggle with a partial frame; a re-render of the same dirty mask restores a known-good state regardless of which packet died.

`OSDTextDisplay::render(mask)` writes only the rows in the mask plus a single `draw()`. No clear, no per-row blank.

#### Scenario: Mid-cycle failure recovers via retry
- Given a 5-packet cycle where writeString #2 succeeds but #3 drops
- When the retry fires
- Then the same 4 writeStrings + draw are sent again
- And the goggle's overlay buffer is overwritten by the successful 4 rows + draw

### Requirement: Base-row positioning and clear / ベース行の位置と clear

The 4-row text block SHALL be positioned via `setBaseRow(uint8_t baseRow)` where `baseRow` is the top row of the 4-row block on the 18-row grid. Range MUST be `[0, MAX_BASE_ROW = 18 - 4 = 14]`. Setting a new base row SHALL OR-merge all 4 dirty bits so the next render repaints the block at the new position.

`setBaseRow` MUST NOT issue an OSD clear itself — firing an ESP-NOW packet from a setter mixes I/O with state mutation. The main loop SHALL call `osd.clear()` after `setBaseRow` (when the value changed AND `espnow_ready`) so old text at the prior base row is wiped before the next render. Without the clear, ghost text remains visible alongside the new rows.

The main loop's CHR_OSD_LAYOUT consumer MUST cancel any in-flight render BEFORE calling `setBaseRow` so a pending verify-success doesn't clear the freshly-set dirty bits via `clearDirtyBits(g_render_dispatched_mask)`. Without that guard, a slider tick that lands inside the 200 ms verify window of a prior text update silently loses its layout change.

#### Scenario: Layout change during a render cycle
- Given the state machine is in WAITING_ACK with dispatched_mask = 0b1111
- When iOS writes a new y_offset via CHR_OSD_LAYOUT
- Then the main loop calls `cancelRender()` first, then `setBaseRow(newBase)` and `osd.clear()`
- And the IDLE catch-up trigger queues a fresh render at the new base row
- And the prior verify-success path can no longer clear the freshly-set dirty bits (cancelled)

### Requirement: Render-cycle batching / レンダサイクルバッチング

The IDLE → PENDING transition SHALL apply a `RENDER_STAGING_MS` (40 ms) delay so back-to-back BLE writes that arrive within the window coalesce into a single render cycle. iOS fires OSD-text writes as `writeWithoutResponse`, often delivering all 4 rows within one or two BLE connection events; without staging, each row would trigger its own 200 ms verify window and the user would see line-by-line rendering.

`RENDER_STAGING_MS` was chosen to pair with `writeWithoutResponse` characteristics: long enough to coalesce a full Ready/Result frame, short enough to halve the perceived render latency vs. the previous 80 ms window.

#### Scenario: Coalesced 4-row Ready frame
- Given iOS issues 4 writeWithoutResponse OSD-text writes in ~5 ms
- When the staging window elapses
- Then a single render cycle dispatches all 4 dirty rows + 1 draw
- And the user sees the Ready frame appear atomically

### Requirement: Goggle does not echo / Goggle は応答を返さない

The HDZero goggle SHALL NOT be assumed to emit any application-level acknowledgement. The deepest delivery feedback available is the ESP-NOW MAC-layer send-status callback (`esp_now_register_send_cb`), which counts successes and failures via `g_espnow_sent_ok` / `g_espnow_sent_fail`. The render state machine MUST use these counters and SHALL NOT depend on goggle-side responses.

`uint32_t` のロード/ストアは 32-bit aligned で atomic なので、`volatile` のみで mux なしで ok。wraparound は unsigned subtraction で安全。

#### Scenario: All ESP-NOW packets reported success
- Given baseline `g_espnow_sent_ok = 1000, g_espnow_sent_fail = 5`, dispatch 5 packets
- When verify fires
- Then `g_espnow_sent_fail == 5` (no new fails)
- And the state machine treats this as success

### Requirement: Test OSD probe / Test OSD プローブ

When CHR_OSD_CONTROL receives `0x03`, the firmware SHALL bypass the OSD-text state machine and fire a single `clear → writeString(0,0,"HDZERO TEST") → draw` cycle synchronously. After queueing, the firmware SHALL `delay(RENDER_VERIFY_MS = 200 ms)` (this `delay()` is OK because it's after all packets are queued, not between them) and check `g_espnow_sent_fail` delta.

The result SHALL be encoded into the CHR_STATUS notify's last byte: 1 = OK (delta 0), 2 = LOST (delta > 0). LCD SHALL show `TEST OSD DELIVERED/LOST` for ~3 s via `showTestResult(ok)`.

The Test path SHALL `cancelRender()` so the probe doesn't repopulate a screen the user just cleared.

「`delay()` 禁止ルール」は ESP-NOW packet 間に挟む `delay()` のこと。すべての packet を queue 済の状態で待機する `delay()` は WiFi task の callback を阻害しないため許容される。

#### Scenario: Test OSD success
- Given `espnow_ready == true`
- When iOS writes 0x03 to CHR_OSD_CONTROL
- Then 3 ESP-NOW packets are queued, the firmware delays 200 ms, and finds 0 new fails
- And `g_last_test_result = 1` is set under `g_ble_mux`
- And `ble_update_status()` notifies iOS with byte[7] = 1

### Requirement: OSD clear and reset / OSD クリアとリセット

When CHR_OSD_CONTROL receives `0x01` (clear), the firmware SHALL `cancelRender()` first, then issue `osd.clear() + osd.draw()`. When it receives `0x02` (reset laps), the firmware SHALL `cancelRender()`, drop staged OSD-text rows via `osdTextDisplay.clear()`, and issue `osd.clear() + osd.draw()`.

Both paths SHALL surface failure modes on the LCD: `CLEAR FAIL` / `RESET FAIL` (red) on send failure, `CLEAR: ESPNOW DOWN` / `RESET: ESPNOW DOWN` (orange) when the radio is down.

#### Scenario: Reset wipes staged text
- Given `m_dirty != 0` with content for rows 0..3
- When iOS writes 0x02 to CHR_OSD_CONTROL
- Then `osdTextDisplay.clear()` zeroes `m_rows` and `m_dirty`
- And the goggle screen is cleared via `osd.clear() + osd.draw()`
- And the next BLE OSD-text write re-arms the state machine cleanly
