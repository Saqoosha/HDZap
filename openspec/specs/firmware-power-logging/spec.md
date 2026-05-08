# firmware-power-logging Specification

## Purpose

Capture VBAT and a few state bits to on-device flash every 30 s during multi-hour battery-only runs, so an operator can correlate firmware-side power optimizations with real device behavior without needing USB-attached serial during the run.

## Requirements

### Requirement: SPIFFS-backed CSV / SPIFFS による CSV 永続化

The firmware SHALL log to `/power.csv` on the SPIFFS partition. The partition is 128 KB. Mount SHALL happen in `setup()` via `SPIFFS.begin(true)` (auto-format on first run); failure SHALL set `m_ok = false` and log `power_log: SPIFFS mount failed (logging disabled)` without aborting boot.

USB を抜いてバッテリ単体で何時間も走らせる測定ワークフローでは Serial が使えない。フラッシュにログを残し、USB を挿し直したときに Serial に dump する設計。

#### Scenario: Mount succeeds
- Given a fresh SPIFFS partition
- When `powerLog.begin()` runs
- Then the partition is mounted, `m_ok = true`, header is written, and append is allowed

#### Scenario: Mount fails
- Given a corrupted SPIFFS partition that doesn't auto-format
- When `powerLog.begin()` runs
- Then `m_ok = false` and subsequent `appendSample` calls are no-ops
- And boot continues normally

### Requirement: Schema / スキーマ

The CSV header SHALL be exactly:

```text
millis,voltage_mv,percent,charging,panel_asleep,ble_connected
```

Each sample row SHALL be `millis,voltage_mv,percent,charging,panel_asleep,ble_connected\n` with the boolean fields encoded as `0` or `1`.

`voltage_mv` is logged instead of instantaneous current because M5Unified's `pmic_m5pm1` path does not implement `getBatteryCurrent()`. VBAT in mV is monotonic-ish under steady discharge, so `dV/dt` across a multi-minute window stands in for instantaneous current — good enough for before/after Phase 2 optimization deltas.

The caller SHALL sentinel-mark out-of-range readings as `-1` before passing in. main.cpp throttles to 30 s and applies the sentinel for VBAT outside `[2500, 4400]` mV.

#### Scenario: Append a normal row
- Given valid VBAT 3850 mV, percent 67, charging false, panel awake, BLE connected
- When `appendSample(millis(), 3850, 67, false, false, true)` is called
- Then the file gains a row matching `<millis>,3850,67,0,0,1`

#### Scenario: Append with out-of-range VBAT
- Given the PMIC returned 100 mV (transient I²C glitch)
- When the main loop's caller substitutes -1 sentinel before calling `appendSample`
- Then the row records `voltage_mv = -1`
- And the `dV/dt` analysis can filter on the sentinel

### Requirement: Schema-mismatch detection / スキーマ不一致検出

On boot, `begin()` SHALL read the existing file's first line and compare against the current header. If different (or empty / missing), the file SHALL be deleted and start fresh. Without this, a firmware update that changes the schema would append new-format rows under a stale header and break downstream parsing.

The header read MUST strip the trailing CR after `readBytesUntil('\n')` (because `println()` writes `"\r\n"`); without the strip, every boot falsely reports a schema mismatch and wipes the log.

If `SPIFFS.remove(kLogPath)` fails during the schema reset, logging SHALL be disabled (`m_ok = false`) — appending under a stale header would corrupt the file silently.

#### Scenario: Schema unchanged
- Given the existing file's header matches the current schema
- When `begin()` runs
- Then the file is preserved and append continues

#### Scenario: Schema changed
- Given a prior firmware wrote a 5-column file
- When the current 6-column firmware boots
- Then `begin()` detects the mismatch, removes the file, and re-creates with the new header

### Requirement: 30 s sampling cadence / 30 秒サンプリング頻度

main.cpp SHALL throttle `appendSample` calls to `POWER_LOG_INTERVAL_MS = 30000`. The interval arithmetic MUST be rollover-safe (`now - g_power_log_last_ms >= POWER_LOG_INTERVAL_MS` using unsigned subtraction). At 30 s, the 128 KB partition can hold roughly 21 hours of samples before rotation triggers.

Per-loop sampling is too noisy for the trend analysis the data feeds and would burn the SPIFFS partition; 30 s captures the trend that matters for Phase 2 optimization deltas without saturating the storage budget.

#### Scenario: First sample after boot
- Given `g_power_log_last_ms = 0` and `millis() = 30000`
- When the loop's append block runs
- Then `appendSample(30000, ...)` is called and `g_power_log_last_ms = 30000`

#### Scenario: Throttled call
- Given `g_power_log_last_ms = 30000` and `millis() = 50000`
- When the loop's append block runs
- Then `appendSample` is NOT called (only 20 s elapsed)

### Requirement: Rotation policy / ローテーションポリシー

When the file size reaches `kRotateThresholdBytes = 110 KB`, `appendSample` SHALL trigger `rotate()`. Rotation copies the most recent ~80 KB (`kRotateRetainBytes`) into a tmp file `/power.csv.tmp`, then renames over the original.

The rotation SHALL skip leading bytes to the next newline so the rotated file does not begin mid-row. If the retain window contains no newline (one giant row, or earlier corruption), rotation SHALL abort and keep the original — better to keep stale data than to wipe it.

The tmp file SHALL re-emit the header at the top so a downstream parser sees the column names.

If any write to the tmp file fails (read error or short write), the tmp SHALL be removed and the original preserved. Replacing the original with a half-rotated tmp would lose user data.

A stale tmp file from an interrupted prior rotation SHALL be cleaned up at boot in `begin()` so the next rotate's tmp write doesn't fail with "file exists".

長時間ランの粒度ではトレンドが見えれば十分で、何時間も前のノイズを保持し続ける必要はない。容量逼迫で append が黙って失敗する方が悪いシナリオなので積極的に rotate する。

#### Scenario: Rotation triggered
- Given the file has grown to 111 KB
- When the next `appendSample` runs
- Then `rotate()` runs first, retaining the most recent ~80 KB
- And the new sample is appended after rotation

#### Scenario: Stale tmp at boot
- Given a power loss interrupted a prior rotate after `dst.close()` but before the rename
- When `begin()` runs
- Then `/power.csv.tmp` is removed
- And the next rotate's tmp creation succeeds

### Requirement: Append failure handling / 追記失敗のハンドリング

If `f.printf(...)` returns `<= 0` (SPIFFS-full despite rotation, write error mid-format), `appendSample` SHALL log the failure throttled to one line per minute (`60000 ms`). A sustained fault during a multi-hour run MUST NOT spam Serial.

#### Scenario: Persistent SPIFFS-full
- Given rotate failed silently and SPIFFS is full
- When `appendSample` runs and `printf` returns 0
- Then a single warning line logs once
- And subsequent failures within 60 s are silenced

### Requirement: Serial dump on plug-in / USB 再接続時の Serial dump

`dumpToSerial()` SHALL stream the entire log to Serial. main.cpp SHALL call `powerLog.dumpToSerial()` once in `setup()` after `powerLog.begin()` so an operator who unplugged → ran on battery → plugged USB back in immediately sees the trail.

The dump SHALL read in 256-byte chunks (faster than per-byte) and SHALL bail with `--- power_log: read error mid-dump ---` if a chunk read returns negative — a single-byte read returning -1 cast to 0xFF would silently corrupt the dump.

The dump SHALL be the only readout path. No BLE GATT download is offered, deliberately, to keep the surface tiny.

#### Scenario: Operator plugs USB back in
- Given a battery-only run produced 5 KB of samples
- When USB is reconnected and the device boots
- Then `powerLog.begin()` mounts the partition
- And `powerLog.dumpToSerial()` streams `--- power_log dump start ---` ... 5 KB ... `--- power_log dump end ---`
- And the operator can copy/paste the trail for analysis

### Requirement: Manual clear / 手動クリア

`clear()` SHALL drop all logged samples (keeping the header line) by removing the file and re-creating it with just the header. Used after `dumpToSerial()` to start a fresh measurement run without hand-cleaning the partition.

#### Scenario: Clear after dump
- Given the log has 5 KB of samples and `dumpToSerial()` has run
- When the operator (via Serial debug command, future) calls `powerLog.clear()`
- Then `/power.csv` exists with just the header line
- And the next `appendSample` writes the first row of a fresh run
