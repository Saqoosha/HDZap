# firmware-status-display Specification

## Purpose

Tell the operator at a glance — without picking up the phone — what UID is on the goggle, whether BLE and ESP-NOW are alive, what the battery is doing, the most recent lap time, and any sticky failure that needs attention.

## Requirements

### Requirement: Three-band layout / 3 バンドレイアウト

The 240×135 LCD SHALL be divided into 3 bands separated by 1 px hairlines:

| Y range | Band | Content |
|---|---|---|
| 0..60 | UID band | UID caption + BLE pill + battery widget; UID hero printed as comma-separated decimals |
| 64..110 | Lap band | LAST LAP / TIME captions + lap number (size 3) + lap time (size 2); hijacked by TEST/BIND verdicts |
| 113..135 | Strip | RADIO indicator (left) + sticky message slot (right) |

Each region's draw routine SHALL fill only its rectangle so a lap update never repaints the UID band and the strip never repaints the lap band. The display methods SHALL NOT be called from BLE/ESP-NOW callbacks — main loop only.

UID は HDZero goggle が表示する `%u,%u,%u,%u,%u,%u` の十進カンマ区切り形式と一致させる。M5Stick の小さい LCD でユーザが「ゴーグル側と同じ数字か?」を目視確認できる UX。

#### Scenario: Lap update preserves UID band
- Given the LCD shows status with UID + BLE pill + battery + lap
- When `showLap(5, 12345)` is called
- Then the lap band is repainted with lap=05 / time=00:12.345
- And the UID band is unchanged

### Requirement: BLE pill / BLE ピル

The UID band SHALL display a BLE indicator: a colored dot + label `BLE` (green) when connected, `BLE OFF` (red) when not. The label width changes with state, so the pill anchor moves; the battery widget MUST recompute its anchor each draw to avoid ghost pixels from the prior wider label.

#### Scenario: BLE drops
- Given LCD shows green `BLE` pill at 47%
- When `showStatus(uid, false, espnow_ready)` is called (BLE disconnect)
- Then the UID band repaints with red `BLE OFF` pill
- And the battery widget moves left to its new anchor

### Requirement: Battery widget / バッテリウィジェット

`setBattery(percent, charging)` SHALL be idempotent: a call with the same values SHALL be a cheap cache compare (no redraw). On change, only the battery widget slot SHALL be repainted (not the full UID band). Color rules:

| Condition | Color |
|---|---|
| pct < 0 (unknown) | dim grey |
| charging | cyan |
| pct < 20 | red |
| pct < 40 | warn (yellow) |
| pct >= 40 | ok (green) |

Drawn elements: 12×6 px battery icon body + 2×2 px tip + interior fill proportional to pct + ` 87%` text.

`drawUidBand()` SHALL repaint the full band whenever BLE state flips, so a stale wider label never leaves ghost pixels around the battery widget.

#### Scenario: Idle 47% → 47%
- Given battery widget shows 47%
- When `setBattery(47, false)` is called again
- Then the cache compare returns equal and no draw happens

#### Scenario: Cross 40% threshold
- Given battery widget shows 41% (green)
- When `setBattery(39, false)` is called
- Then the widget repaints in warn (yellow)

### Requirement: Lap band content / Lap バンドの内容

The lap band SHALL show:

- Caption row: `LAST LAP` (left) + `TIME` (right).
- Number row: lap number as 2-digit `%02u` (size 3), time as `%02u:%02u.%03lu` (size 2).

When no lap has been recorded yet, both fields SHALL show `--` / `--:--.---`. Color rules:

| Condition | Color |
|---|---|
| `!m_haveLap` | dim |
| flashing window (1 s after `showLap`) | accent |
| `!linksUp` (BLE down OR radio down) | dim |
| else | ink (white) |

The dim treatment when links are down communicates "you can't trust this to be reaching the goggle right now" while preserving the historical lap value.

#### Scenario: Lap recorded with both links up
- Given BLE connected, ESP-NOW ready
- When `showLap(7, 12345)` is called
- Then the lap band shows `07` (accent during 1 s flash) and `00:12.345` (white)
- And after 1 s the lap number returns to white (or stays accent until the next state change)

### Requirement: Takeover for TEST / BIND verdicts / TEST / BIND 結果のテイクオーバー

The lap band SHALL be takeover-able for ~3 s (`kTakeoverMs = 3000`) by either:

- TEST OSD verdict via `showTestResult(ok)` — caption `TEST OSD`, verdict `DELIVERED` (green) or `LOST` (red).
- BIND packet verdict via `showBindResult(ok)` — caption `BIND PACKET`, verdict `SENT` (warn yellow) or `FAIL` (red); also tints the UID band yellow for the takeover window.

After the takeover expires, the lap band SHALL revert to the most recent lap (or the placeholder if no lap has been recorded). A Bind takeover that overlaps a lap arrival or another takeover starting on top SHALL drop `m_bindActive` and repaint the UID band white before transitioning, so the band can never be stranded yellow.

iOS の自動ペアリングフローは bind → 2.5 s settle → test という連続動作なので、3 s 内に kind が切り替わるシナリオを設計に組み込む必要がある。

#### Scenario: BIND followed by TEST within 3 s
- Given `showBindResult(true)` was just called (UID band yellow, lap band shows `BIND PACKET / SENT`)
- When `showTestResult(true)` is called 2 s later
- Then `m_bindActive` is dropped and the UID band repaints white
- And the lap band switches to `TEST OSD / DELIVERED` (green) for a fresh ~3 s window

#### Scenario: Lap arrives during BIND takeover
- Given a BIND takeover is on screen
- When `showLap(...)` is called within the takeover window
- Then the lap band repaints to the lap (preempts the takeover)
- And the UID band repaints white (m_bindActive cleared)

### Requirement: Sticky strip message / スティッキー strip メッセージ

The strip SHALL persist a single sticky message across UID/lap redraws until `clearMessage()` is called. The strip layout:

- Left: RADIO indicator dot + label `RADIO` (green) or `RADIO DOWN` (red).
- Right: optional sticky message in `m_msgColor`.

`showMessage(msg, color)` SHALL truncate to `sizeof(m_msg) - 1` (31 chars) with a serial log on truncation. Color 0 falls through to ink (white).

A long message MAY be clipped left of the RADIO label width; the firmware SHALL log `stick_display: strip clipped (msg=... overruns RADIO label)` so a future too-long message is diagnosable.

`currentMessage()` SHALL expose the current message text so callers can scope a `clearMessage()` to "only if my own message is still up" — without this, a battery-recovery clear would silently drop an unrelated `RADIO DOWN` / `OSD LOST` that arrived in between.

#### Scenario: Battery low message
- Given the strip is empty
- When `showMessage("BATTERY LOW", colorWarn())` is called
- Then the strip shows `RADIO` (green) on the left and `BATTERY LOW` (yellow) on the right

#### Scenario: Battery recovery scoped clear
- Given the strip currently shows `BATTERY CRITICAL`
- When the battery transitions to None and the main loop calls `clearMessage()` only if `currentMessage()` matches
- Then the strip clears (current matches)

#### Scenario: Battery recovery does NOT clobber unrelated message
- Given the strip currently shows `OSD LOST`
- When the battery transitions to None
- Then the main loop's scoped check finds `currentMessage() != "BATTERY LOW"/"BATTERY CRITICAL"` and skips clear
- And `OSD LOST` stays visible

### Requirement: Update tick handles flash and takeover expiry / Update tick で flash と takeover 終了処理

`update()` SHALL be called every loop iteration. It SHALL call `M5.update()` (refreshes button state) and, while not asleep, expire the lap-flash window (after 1 s) and the takeover window (after 3 s). Both expiries SHALL trigger an appropriate band repaint.

While asleep (`m_panelAsleep`), `update()` SHALL skip its time-driven repaints. External `show*()` callers still write to GRAM behind the dark panel; `wakePanel()` does a full repaint so those are eventually overdrawn.

#### Scenario: Flash expires
- Given `showLap(...)` was called 1.1 s ago
- When `update()` is called
- Then `m_lapFlashUntilMs = 0` and `drawLapBand()` runs (lap number returns from accent to its non-flashing color)

#### Scenario: Update while asleep
- Given `m_panelAsleep == true`
- When `update()` is called
- Then `M5.update()` runs but no draw happens
- And `m_lapFlashUntilMs` and `m_takeoverUntilMs` are not consumed

### Requirement: M5GFX text datum is locked / M5GFX のテキスト基準点は固定

`begin()` SHALL set `M5.Display.setTextDatum(textdatum_t::top_left)` once and the rest of the class SHALL rely on this. Each draw routine MUST NOT save and restore around its `print()` calls because the datum is global state already locked.

#### Scenario: After begin
- Given `begin()` has run
- When any internal draw routine sets the cursor and prints
- Then text positions calculate as if drawn from the top-left of the cursor without per-call datum changes
