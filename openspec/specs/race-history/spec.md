# race-history Specification

## Purpose

Persist completed races so the operator can review past sessions, see best-lap and pace trends, and share a single race as an image, without losing data to schema drift, crash-mid-write, or storage outages.

## Requirements

### Requirement: Race record schema and invariants / レース記録のスキーマと不変条件

A `RaceRecord` SHALL contain:

- `id: UUID` — stable identifier for SwiftUI list diffing.
- `startedAt: Date`, `endedAt: Date` — `endedAt >= startedAt` MUST hold.
- `sessionLimit: TimeInterval` — finite, non-negative.
- `targetLapCount: Int` — non-negative.
- `accentHue: Double` — finite, normalized to `0..<360` after construction.
- `laps: [LapEntry]` — non-empty, each `time` finite and `>= 0`, `id`s unique within the array.

All construction paths (`snapshot(...)`, decoding) MUST validate these invariants. A snapshot violating any invariant MUST return `nil`. A decoded JSON violating any invariant MUST throw `DecodingError.dataCorruptedError` keyed at the offending field.

ハンド編集や旧スキーマの混入を放置すると、UI で render できないレコードが store に乗って書き戻され、整合性が崩れる。validate を build/decode の単一経路に集約する。

#### Scenario: Snapshot with empty laps
- Given `laps == []` and otherwise valid inputs
- When `RaceRecord.snapshot(...)` is called
- Then it returns `nil`

#### Scenario: Decode malformed JSON
- Given a JSON file with `endedAt < startedAt`
- When `JSONDecoder.decode([RaceRecord].self, from:)` runs
- Then it throws `DecodingError` with the offending key path

### Requirement: Newest-first ordering / 新しい順の整列

The store SHALL keep `records` sorted by `endedAt` descending. Inserts (`add`) MUST maintain the order via ordered insertion using `firstIndex(where: { $0.endedAt < record.endedAt })`. Inserts of a record with an existing `id` SHALL replace the prior entry (no duplicates).

順序を `add` のたびに sort で取り直す API ではなく、ordered insert にすることで履歴が常に dense / unique である invariant をコードレベルで強制する。

#### Scenario: Out-of-order insert
- Given the store contains records ending at 10:00 and 12:00 (newest first: 12:00, 10:00)
- When a record ending at 11:00 is added
- Then the resulting order is 12:00, 11:00, 10:00

#### Scenario: Duplicate-id insert
- Given the store contains a record with id X
- When `add` is called with another record sharing id X
- Then the prior record is replaced and only one entry with id X exists

### Requirement: On-disk persistence at Application Support / Application Support に永続化

The store SHALL persist to `Library/Application Support/HDZap/race-history.json` (resolved via `FileManager.url(for: .applicationSupportDirectory, ...)`). Writes MUST use `Data.write(to:options: [.atomic])` so a crash mid-write cannot truncate the file. The directory MUST be created on demand if missing.

`temporaryDirectory` への fallback は禁止。iOS が tmp を reap するため、サイレントに履歴が消える事故が以前発生していた。Application Support の解決失敗は `setupError` で UI に表面化する。

#### Scenario: Application Support unavailable at init
- Given `FileManager.url(for: .applicationSupportDirectory)` throws
- When `RaceHistoryStore.init` runs
- Then `fileURL == nil`
- And `setupError` carries a localized message
- And subsequent `add` produces a `lastPersistError` indicating storage isn't available
- And `records` mutates only with rollback semantics (see commit/rollback requirement)

### Requirement: Mutate-then-persist with rollback / 楽観更新+ロールバック

The store SHALL apply a mutation in memory, attempt `persist()`, and on failure MUST roll back the in-memory state to the prior snapshot. `lastPersistError` SHALL surface a user-facing localized message; the next successful mutation clears it. Errors recognized: `noStorage`, `NSFileWriteOutOfSpaceError`, `NSFileWriteVolumeReadOnlyError`, `NSFileWriteNoPermissionError`, fallthrough generic.

過去の挙動は in-memory を更新したまま persist 失敗をサイレント化していたため、起動時に「保存したはずのレースがなくなった」UX となっていた。失敗時は表示も巻き戻し、明示的に通知する。

#### Scenario: Out-of-space
- Given the store has 3 records and the disk is full
- When `add(record)` runs
- Then `records` momentarily contains 4 records, persist fails, and `records` is restored to the prior 3
- And `lastPersistError == "Couldn't save race: device is out of storage."`

### Requirement: Corrupt-file quarantine / 壊れたファイルの隔離

If decoding the on-disk file fails at launch, the store SHALL move the original to `race-history.corrupt-<unix-ts>-<6-char-uuid>.json` so a future debugging session can inspect it. If the rename itself fails (collision, out-of-space), the original SHALL be deleted to prevent the next atomic write from silently overwriting the corrupt file under its original name.

#### Scenario: Corrupt JSON at launch
- Given `race-history.json` contains malformed JSON
- When the store loads asynchronously
- Then the file is moved to `race-history.corrupt-1715000000-abc123.json`
- And `records` remains empty
- And the next `add` writes a fresh `race-history.json`

### Requirement: Asynchronous load on startup / 起動時の非同期ロード

The store SHALL read the on-disk file on a background `Task.detached(priority: .utility)` so app launch is not blocked by file I/O. The decoded array SHALL hop back to `MainActor` before being assigned to `records`.

#### Scenario: Cold start
- Given a 200 KB history file
- When the app launches
- Then SwiftUI renders the first frame without waiting for the file read
- And `records` populates a few hundred ms later via the main-actor assignment

### Requirement: Persisted accent hue is normalized / 保存される accent hue は正規化済み

`accentHue` SHALL be normalized to `0..<360` via `truncatingRemainder(dividingBy: 360)` before storage. NaN/Inf MUST be rejected at validation. The OKLCH-based theme uses the raw degrees, so an out-of-range hue silently shifts to a wrong color.

#### Scenario: Negative hue normalized
- Given `accentHue = -45`
- When `RaceRecord.snapshot` constructs the record
- Then the persisted `accentHue` is `315.0`

### Requirement: Delete and clear-all / 削除と全消去

The store SHALL expose `delete(id: UUID)` (single record) and `deleteAll()` (entire history). Both operations SHALL go through the commit path with rollback semantics. `clearLastPersistError()` SHALL allow the UI to dismiss the error banner without touching records.

#### Scenario: Delete one
- Given the store has records [A, B, C]
- When `delete(id: B.id)` is called
- Then `records == [A, C]` (or rolled back if persist fails)

### Requirement: Race summary metrics / レースサマリのメトリクス

`RaceRecord` SHALL expose derived metrics: `lapCount`, `totalTime`, `bestLapIndex`, `bestLapTime`, `worstLapTime`, `avgLapTime`. `bestLapIndex` ties resolve to earliest occurrence. `avgLapTime` returns 0 for empty laps (validation prevents the empty case at construction).

#### Scenario: Average across 3 laps
- Given laps with times [12.0, 12.5, 11.5]
- When `record.avgLapTime` is read
- Then the result is `12.0`

### Requirement: Share card export / シェアカード出力

The race-history capability SHALL provide a shareable visual summary (race date, total time, lap count, best lap, lap-by-lap chart) renderable to a `UIImage` for the iOS share sheet. The card MUST use the record's persisted `accentHue` so each race is visually distinct in shared images.

実装はビュー層 (`RaceShareCard`) が担当するが、shareable な出力点は spec として担保する。
