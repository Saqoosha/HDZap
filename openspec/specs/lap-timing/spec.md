# lap-timing Specification

## Purpose

Capture each lap of an FPV race the moment the operator taps LAP, with a precision and pause-resume model that matches how race timing is actually run in the field.

## Requirements

### Requirement: Manual lap recording / 手動ラップ記録

The lap timer SHALL record laps only on explicit user action (tap LAP). It MUST NOT detect lap completion via gates, sensors, or automatic triggers. The race operator SHALL be the sole decider of lap boundaries.

これは HDZap の設計上の選択。FPV レースで自動検出を導入すると false positive が体感を破壊するため、確定的な手動操作だけを採用する。

#### Scenario: Tap LAP during a running race
- Given a race is running with the timer at 12.345 s and 0 laps recorded
- When the user taps LAP
- Then a Lap is appended with `id = 1, time = 12.345`
- And the next lap starts accumulating from 12.345 s

### Requirement: Lap time is delta from previous boundary / ラップ時間は直前境界からの差分

Each Lap's `time` SHALL be `(elapsedTime at tap) - (cumulative time at previous tap)`, where the previous tap for the first lap is the race start. The implementation MUST snapshot `elapsedTime` at the moment of the tap (not the 60 Hz-sampled cached value) so consecutive taps have accurate boundaries.

`Date().timeIntervalSince(startDate)` を tap 時に再評価することで、UI 描画の 16 ms ジッタが lap 境界に乗らないようにする。

#### Scenario: Two consecutive taps
- Given the race timer just recorded lap 1 at 12.345 s (cumulative 12.345)
- When the user taps LAP at elapsedTime = 25.000 s
- Then lap 2 has `time = 25.000 - 12.345 = 12.655`

### Requirement: Lap IDs are stable and dense / ラップ ID は安定かつ連続

Lap `id` SHALL be assigned as `laps.count + 1` at the moment of recording. IDs MUST be unique within a race and dense (1, 2, 3, … with no gaps). Persisted records MUST preserve IDs verbatim; SwiftUI list diffing relies on uniqueness.

#### Scenario: Persisted race round-trips
- Given a race with 5 laps having ids [1,2,3,4,5]
- When the race is encoded to JSON and decoded back
- Then the decoded laps have ids [1,2,3,4,5] in order

### Requirement: Pause and resume preserves history / 一時停止・再開は履歴を保持

`stop()` SHALL freeze the timer and accumulate elapsed time. A subsequent `start()` SHALL resume from the accumulated time without resetting laps. `sessionStartedAt` SHALL be set on the first `start()` after a `reset()` and preserved across pause/resume. Only `reset()` clears laps, accumulated time, and `sessionStartedAt`.

これは「ピットイン → 再開」のような中断ワークフローを想定した動作。レース全体の開始時刻 (`sessionStartedAt`) は最初の START のままで保たれ、保存時のレース履歴が「いつ走り始めたか」を正しく示す。

#### Scenario: Stop, then start again
- Given a race ran for 30 s with 2 laps recorded, then stopped
- When the user taps START again 10 s later
- Then the timer resumes from 30 s (not 0)
- And the existing 2 laps remain
- And `sessionStartedAt` is still the original first-start timestamp

#### Scenario: Reset clears state
- Given a race in any state (running, paused, with laps)
- When `reset()` is called
- Then `elapsedTime = 0`, `laps = []`, `accumulatedTime = 0`, `sessionStartedAt = nil`
- And the timer is not running

### Requirement: Display refresh at 60 Hz / 60 Hz の表示更新

While running, the timer SHALL update `elapsedTime` at ~60 Hz (1/60 s) using a `Timer` registered on `RunLoop.main` in `.common` mode. The .common mode requirement is load-bearing: `.scheduledTimer` (default mode) pauses during scroll/tracking runloop modes, producing a visibly stuck timer.

タップ瞬間の時刻精度はこの 60 Hz 更新とは独立 (上の要件参照)。表示更新だけが 60 Hz で、lap boundary 自体は tap-time の `Date()` から算出する。

#### Scenario: Scrolling does not freeze the clock
- Given the timer is running
- When the user scrolls the lap list
- Then the on-screen elapsed time continues advancing during the scroll gesture

### Requirement: Best-lap query / ベストラップの取得

The timer SHALL expose `bestLapIndex` returning the index of the smallest-time lap in the current race, or `nil` when no laps exist. Ties resolve to the earliest occurrence. The persisted `RaceRecord` SHALL apply the same rule.

#### Scenario: Single best lap
- Given laps with times [13.5, 12.1, 12.8]
- When `bestLapIndex` is queried
- Then it returns `1` (the 12.1 s lap)

#### Scenario: Tie picks earliest
- Given laps with times [12.1, 12.1, 13.0]
- When `bestLapIndex` is queried
- Then it returns `0`

### Requirement: Race metrics are derived, not stored / レースメトリクスは派生値

In-race metrics (`avgLapSec`, `paceLaps`, `diffSec`, `perLapSec`, `splitState`, `targetLapSec`, `remainingLaps`) SHALL be derived from `(laps, targetLapCount, sessionLimit)` via `RaceMetrics.init`. The constructor SHALL return `nil` for empty laps or zero total time so callers cannot show meaningless metrics.

`targetLapCount` is clamped to `[2, 99]`; `targetLapSec = sessionLimit / (targetLapCount - 1)`. `paceLaps` defaults to `lapCount + ceil(remainingSec / avgLapSec)` and accepts a `paceOverride` for tests.

`diffSec > 0` は遅れ (need to make up); `diffSec < 0` は貯金 (bank); `|diffSec| < 0.005 s` は on-target。`splitLabel` / `splitValue` の文字列はこの判定から決まる。

#### Scenario: Empty laps returns nil
- Given an empty laps array
- When `RaceMetrics.init(laps:, targetLapCount:, sessionLimit:)` is called
- Then it returns `nil`

#### Scenario: Pace calculation
- Given 3 laps averaging 12 s, sessionLimit = 60 s
- When metrics are computed without paceOverride
- Then `paceLaps = 3 + ceil((60 - 36) / 12) = 5`

### Requirement: OSD glyph compatibility / OSD グリフ互換性

The OSD payload generator SHALL avoid characters that misrender on the HDZero glyph set:

- `S` (uppercase) MUST NOT appear adjacent to digits in pace/timer rows because it renders as `5` on the goggle. `45S` would read as `455`.
- ASCII bytes 0x60–0x7F MUST NOT appear in OSD strings (those positions are FPV icons on the HDZero font, not lowercase ASCII). The firmware auto-uppercases lowercase ASCII via `osd.h::writeString`, so iOS-side strings MAY contain lowercase but MUST NOT contain bytes ≥ 0x60 outside the lowercase range.

`TIME LEFT 45S` の代わりに `TIME LEFT 45` を使う、`AVG 12.34s` を `AVG 12.34` にする、といった対応はこの要件に基づく。

#### Scenario: Time-left line excludes "S" suffix
- Given remaining seconds = 45
- When `RaceMetrics.timeLeftRaw(remainingSec: 45)` is called
- Then the result is `"TIME LEFT 45"` (no trailing `S`)

### Requirement: OSD rows are fixed-width / OSD 行は固定幅

The 4 semantic OSD rows (Time / Lap / Pace / Diff) MUST be padded to 50 bytes (`OSD_COLS`) before transmission so a shorter update cleanly overwrites the prior row at the same on-grid position. The same width MUST be applied to all four rows so they share a centered column.

このパディング規則は firmware 側 OSD バッファが直前の overlay 内容を保持する仕様 (clear なしで row 単位の write のみ) と組み合わさって機能する。可変幅にすると前 frame の長い行の末尾文字が残る。

#### Scenario: Short row padded
- Given a raw row "READY" (5 chars)
- When `RaceMetrics.padOSD("READY", width: 50, alignment: .center)` is called
- Then the result is a 50-character string with "READY" centered between spaces
