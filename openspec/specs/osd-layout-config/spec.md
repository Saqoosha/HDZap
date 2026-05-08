# osd-layout-config Specification

## Purpose

Let the operator position the 4-row OSD text block on the goggle (vertical position), pick a horizontal alignment, and hide rows that aren't useful — without the firmware needing to know about layout decisions.

## Requirements

### Requirement: Four semantic rows / 4 つのセマンティックロー

The OSD layout SHALL fix the row count at 4. Each row has a stable semantic role across race states:

| Index | Role | In-race content |
|---|---|---|
| 0 | Time | TIME LEFT (1 Hz tick) |
| 1 | Lap | Latest lap number + time |
| 2 | Pace | AVG + PACE projection |
| 3 | Diff | DIFF / NEED / BANK + per-lap split |

Pre-race the rows show READY / RACE limit / N LAPS @ pace / blank. Post-race they show DONE / lap count + total / AVG + BEST / blank.

セマンティック単位で固定することで、設定 UI が "Time row" "Lap row" のような意味のあるラベルを表示できる。

#### Scenario: Pre-race Ready frame
- Given a 60 s race, 7 target laps
- When the operator opens the Ready frame
- Then OSD shows `READY`, `RACE 60`, `7LAPS @ 10.00`, blank

### Requirement: Position by first visible row / 先頭表示行による位置指定

The user-visible position knob SHALL be `firstVisibleRow` — the 0-indexed top row of the **visible** block on the 18-row goggle grid. Hidden rows do NOT reserve grid space — visible rows are packed, so a 4-row block with one hidden row occupies 3 contiguous grid rows starting at `firstVisibleRow`.

The slider range SHALL be `[0, osdGridRows - visibleCount] = [0, 18 - visibleCount]`.

Earlier schema versions (`v1`, `v2`) used a different position semantic ("top of the 4-row buffer", including hidden slots) and SHALL NOT be auto-migrated to v3. Both v1 and v2 only shipped on draft / TestFlight builds; auto-migrating would silently move the pilot's OSD position.

非表示行を含む 4 行ブロックを動かす旧モデルは「3 行表示なのに何故か空白も含めた 4 行分が動く」という UX を生み、ユーザに分かりにくかった。「見えている行の頂点」を直接動かす v3 に変更。

#### Scenario: All-visible default
- Given a fresh install (visibleCount = 4)
- When the snapshot is read
- Then `firstVisibleRow = 14` (osdGridRows - rowCount = 18 - 4)
- And the block occupies rows 14..17 (bottom-anchored)

#### Scenario: Hide one row
- Given `rows[2].visible = false` (Pace hidden); slider at default
- When the snapshot is read
- Then `visibleCount = 3`
- And `firstVisibleRow` is re-clamped to `[0, 15]`

### Requirement: Persistence keys / 永続化キー

The settings store SHALL persist via UserDefaults under versioned keys:

- `osdLayout.firstVisibleRow.v3`
- `osdLayout.alignment.v3`
- `osdLayout.rows.v3` (JSON-encoded `[OSDRowConfig]`)

The firmware SHALL NOT persist any layout state. The iOS app SHALL replay `firmwareYOffset` to the M5Stick on every connect (state-transition write, urgent) so the goggle position is restored after the M5Stick reboots.

ファーム側で持たない理由: 設定は iOS 側で UI を持って編集されるため、source of truth を片側に集約する。

#### Scenario: First launch with no persisted keys
- Given UserDefaults has none of the v3 keys
- When `OSDLayoutSettings.init` runs
- Then `firstVisibleRow = 14`, `alignment = .center`, `rows = 4 visible defaults`

#### Scenario: Reconnect after firmware reboot
- Given iOS had `firstVisibleRow = 7` last session
- When iOS reconnects to the freshly-booted M5Stick
- Then iOS issues a state-transition CHR_OSD_LAYOUT write with `urgent: true`
- And the M5Stick applies the new offset before the next OSD frame is rendered

### Requirement: Alignment / アライメント

The horizontal alignment SHALL be a single value (left / center / right) shared by all 4 rows. Per-row alignment was tried and removed — lap timer rows always read as a single block, so per-row variation adds UI without payoff.

`alignment` SHALL be applied via `RaceMetrics.padOSD(line, width: 50, alignment:)` when iOS builds the 50-byte row payloads.

#### Scenario: Right-aligned race
- Given alignment = .right
- When iOS sends the lap row "LAP 5 12.345"
- Then the BLE payload pads with leading spaces so the text ends at column 50

### Requirement: Per-row visibility / 行ごとの表示・非表示

Each of the 4 rows SHALL have an independent `visible: Bool`. Hidden rows MUST be sent as 50 spaces over BLE so the goggle's overlay buffer (which retains prior content between writes) is cleanly cleared at that row instead of leaving stale text behind.

Visible rows are packed: the visible block has height = `visibleCount`. Hidden rows do NOT occupy a position in the buffer — the firmware buffer slot mapping (`bufferLayout()`) skips them.

下の `bufferLayout()` の正しさは subscript 範囲外を含む edge case の積み重ねなので、`visibleCount > 0` を保証する `bufferTopRow` の clamp に依存する。

#### Scenario: Hidden Pace row
- Given `rows[2].visible = false` (Pace hidden), all others visible
- When `renderBuffer(["TIME", "LAP", "PACE", "DIFF"])` is called
- Then the buffer is `["TIME ...", "LAP ...", "DIFF ...", blank]` (Pace dropped, DIFF moves up)

#### Scenario: All hidden
- Given all `rows[i].visible = false`
- When the snapshot is read
- Then `firmwareYOffset = 0` (no shift; goggle position doesn't matter for an all-blank frame)
- And the firmware sees 4 blank-row writes

### Requirement: Firmware Y offset wire format / ファームの Y オフセット wire フォーマット

The CHR_OSD_LAYOUT characteristic SHALL carry a single signed byte: rows to shift the 4-row block up from the firmware's default bottom-anchored position (DEFAULT_BASE_ROW = 18 - 4 = 14). The firmware SHALL clamp the resulting `base_row` to `[0, MAX_BASE_ROW = 14]`.

`firmwareYOffset = bufferTopRow - (osdGridRows - rowCount)`. iOS computes this from `firstVisibleRow + visibleCount - rowCount` (clamped to grid). When all rows are hidden, iOS SHALL send `0` so the goggle doesn't drift away from its boot default on a replay.

#### Scenario: Top-anchored layout
- Given `firstVisibleRow = 0`, `visibleCount = 4`
- When iOS computes `firmwareYOffset`
- Then it is `0 - 14 = -14`
- And the BLE byte is `0xF2` (signed -14)

### Requirement: Always-visible Ready and Result frames / Ready / Result フレームは常に全表示

The pre-race Ready frame and the post-race Result frame SHALL be rendered with `OSDLayoutConfig.allVisible` (all 4 rows visible). Pilots must not miss DONE / target / total / best lap because they hid a row to clean up the in-race display. The user's hide/show preferences resume in the running race state.

#### Scenario: Pace hidden in-race, Result still 4 rows
- Given the user hid the Pace row for the running race
- When the race ends and the Result frame is generated
- Then all 4 rows are sent (DONE / lap count + total / AVG + BEST / blank) via `allVisible`

### Requirement: Buffer slot routing for partial updates / 部分更新のためのバッファスロットルーティング

The system SHALL provide `bufferSlot(forSemanticIndex:)` returning the firmware buffer slot (0..3) currently holding a given semantic row, or `nil` if the row is hidden. Partial updates (TIME LEFT 1 Hz tick, lap event) SHALL use this to address only the slot that changed instead of rebuilding the full buffer.

部分更新のメリット: 行 1 つだけの更新なら BLE write は CHR_OSD_TEXT に対する 1 row で済み、ESP-NOW cycle が writeString + draw の 2 packets で完結する (その他 3 行は goggle overlay に保持された前 frame のまま)。

#### Scenario: TIME LEFT tick on a layout with Pace hidden
- Given Pace hidden (rows visible: Time, Lap, Diff)
- When the 1 Hz TIME LEFT tick fires
- Then `bufferSlot(forSemanticIndex: 0)` returns the slot index for Time
- And iOS issues a single CHR_OSD_TEXT write to that slot

### Requirement: Editor preview state / エディタプレビュー状態

The settings store SHALL expose `previewEditorActive: Bool` (in-memory only, not persisted). TimerView SHALL watch the false transition so it can repaint the live race frame the moment the editor pops, instead of waiting for the whole Settings sheet to close — which can be much later than the editor's Done tap, leaving the goggle on dummy preview content.

#### Scenario: Editor close repaints
- Given the layout editor is on screen (`previewEditorActive == true`) pushing dummy rows to the goggle
- When the user taps Done
- Then `previewEditorActive` flips to `false`
- And TimerView immediately re-pushes the live race frame
