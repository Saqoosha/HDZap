# firmware-battery-monitor Specification

## Purpose

Track the M5StickS3's battery state, alert the operator on low / critical thresholds via beep + LCD strip + iOS push, and let the operator silence an active alarm without losing visibility of subsequent tier transitions.

## Requirements

### Requirement: Polling cadence / ポーリング頻度

The battery monitor SHALL poll `M5.Power` every `kPollIntervalMs` (5000 ms) inside `tick(now, silenceRequested)`. The first call after construction MUST return `Outcome::StateChanged` (or `TierChanged`) so the caller pushes the initial value to the LCD + BLE.

`tick()` SHALL be actuator-free: no LCD writes, no BLE writes, no audio. The main loop owns those side effects so heavy work stays out of the monitor — mirroring the rest of the firmware's "callbacks stage flags, loop owns I/O" split. Two narrow `Serial.printf` paths are allowed: edge-triggered PMIC validity transitions and operator-press-but-already-silenced (the support-report trace).

#### Scenario: First tick after boot
- Given a fresh `BatteryMonitor` and `now = 100`
- When `tick(100, false)` is called
- Then the monitor polls `M5.Power`, primes its state, and returns `Outcome::StateChanged`
- And the main loop pushes the initial battery payload to LCD + BLE

#### Scenario: Throttled tick
- Given `tick(0, false)` ran 1 second ago
- When `tick(1000, false)` is called
- Then `Outcome::Throttled` is returned (no poll, no observable change)

### Requirement: Tier state machine with hysteresis / ヒステリシス付きティア状態機械

The monitor SHALL track three tiers: `None`, `Low (≤ 20%)`, `Critical (≤ 10%)`. Tier transitions use hysteresis to prevent jitter:

| From | Threshold | To |
|---|---|---|
| None | pct ≤ 10 | Critical |
| None | pct ≤ 20 | Low |
| Low | pct ≤ 10 | Critical |
| Low | pct ≥ 25 (`kLowRecover`) | None |
| Critical | pct ≥ 25 (`kLowRecover`) | None |
| Critical | pct ≥ 13 (`kCriticalRecover`) | Low |

Charging or `pct < 0` (PMIC unknown) SHALL force `tier = None` regardless of percent. `M5.Power.isCharging()` MUST be compared against the explicit `is_charging` enumerator (NOT `> 0`) because `charge_unknown` would otherwise be misread as "USB plugged in" and silence a real low-battery condition.

Critical 復帰を `kLowRecover` (25%) に通すのは「9% で silence した運転者が 12% に戻った」シナリオを想定。Low → None のヒステリシスを Critical → None にも対称適用する。

#### Scenario: Sag from 11% to 9%
- Given current tier = None, pct = 11
- When the next poll reads pct = 9
- Then tier transitions to Critical

#### Scenario: Recovery oscillation
- Given current tier = Low, pct = 19 (got there from None at 20)
- When the next poll reads pct = 21
- Then tier remains Low (21 < kLowRecover = 25)
- And the operator does not see alarm clear until pct >= 25

#### Scenario: Charge unknown does not silence
- Given pct = 8 and `M5.Power.isCharging() == charge_unknown`
- When tick polls
- Then tier becomes Critical (charge_unknown is NOT treated as charging)

### Requirement: Silence latch / Silence ラッチ

The operator MAY silence an active alarm via a button press; the monitor SHALL latch `m_silenced = true` when called with `silenceRequested = true` AND `tier != None` AND not already silenced. Silence presses with `tier == None` SHALL be no-ops (the operator's wake-LCD button on a healthy battery is high-frequency). Already-silenced presses SHALL log to serial as the support-report trace.

Every tier transition (escalate, de-escalate, recover) SHALL clear `m_silenced` — the operator's "I know" acknowledgment was for the prior tier, not the new one. The asymmetry is deliberate: a Critical → Low de-escalation re-arms beeps, which can surprise an operator who silenced at 9% and saw the cell sag back to 12%. The trade-off vs. silence lingering across an unrelated tier change is judged acceptable.

The wire-level invariant is `silenced ⇒ tier != None`. The `payload()` byte MUST defensively zero the silenced bit when `tier == None`, even though `tick()`'s clear-on-tier-transition already enforces this — a future regression would otherwise leak a wire-illegal byte to iOS.

#### Scenario: Silence at Critical
- Given tier = Critical, silenced = false
- When `tick(now, silenceRequested = true)` runs
- Then `m_silenced = true`
- And `Outcome::StateChanged` is returned (silence dirty edge folded in)

#### Scenario: Tier transition clears silence
- Given tier = Critical, silenced = true, pct = 9
- When the next poll reads pct = 14 (transitions to Low)
- Then `m_silenced` is cleared
- And `Outcome::TierChanged` is returned
- And the BLE payload bytes 1 = `0b0010` (LOW set, silenced cleared)

### Requirement: Beep cadence / ビープ周期

`consumeBeepDue(now)` SHALL return true when a beep should fire and burn the cadence slot on a true return. Beep is suppressed when `tier == None || silenced`. Period: Low = 30000 ms, Critical = 15000 ms. Entering a tier (`m_lastBeepMs = 0` reset on transition) SHALL beep immediately; subsequent beeps follow the period.

Caller MUST pair `tick()` with `consumeBeepDue()`. If the downstream `M5.Speaker.tone()` returns false (queue full / unsupported channel), caller MUST call `scheduleBeepRetry(now)` so the alarm retries ~1 s later (`kBeepRetryMs = 1000`) instead of waiting out the full 15-30 s cadence.

`scheduleBeepRetry` rewinds `m_lastBeepMs` to `now - (period - kBeepRetryMs)` so a persistent speaker-queue-full doesn't busy-loop the main loop on retries. Resetting `m_lastBeepMs = 0` directly would do that.

`m_lastBeepMs == 0` を sentinel として使うため、リワインド時に 0 着地を避けるガード (`(target == 0) ? 1 : target`) を入れる。

#### Scenario: Critical beep period
- Given tier = Critical, silenced = false, last beep at t=0
- When `consumeBeepDue(15000)` is called
- Then it returns true and burns the slot
- And `consumeBeepDue(20000)` returns false (5 s into the next 15 s window)

#### Scenario: Speaker queue full
- Given a beep is due and `M5.Speaker.tone(...)` returns false
- When the main loop calls `scheduleBeepRetry(now)`
- Then the next beep is due at `now + kBeepRetryMs (≈1 s)`
- And the main loop does NOT busy-loop on retry attempts

### Requirement: Outcome enum / Outcome 列挙

`tick` SHALL return one of three Outcome values:

- `Throttled (0b00)` — poll skipped, no observable change → main loop noop.
- `StateChanged (0b01)` — percent / charging / silenced edge → push BLE + LCD update.
- `TierChanged (0b11)` — tier transition (StateChanged-superset) → push + sticky strip message.

Bit pattern encodes `TierChanged ⇒ StateChanged` structurally (`0b11 == 0b01 | 0b10`). Callers test `!= Throttled` for "anything changed" and `== TierChanged` for "tier transition specifically". A future caller asking via `& StateChanged` would correctly include TierChanged via the bit superset.

Silence-dirty edges SHALL fold into `StateChanged` (NOT a separate `silenceDirty` channel). This removes the bug class where a caller forgets to surface silence transitions because they're a side channel.

#### Scenario: Tier change forwards as TierChanged
- Given a poll causes tier transition None → Low
- When `tick` returns
- Then it returns `Outcome::TierChanged`
- And the main loop does both the BLE+LCD push (StateChanged superset) AND the sticky `BATTERY LOW` strip message

### Requirement: BLE wire payload / BLE wire ペイロード

`payload(out[2])` SHALL produce 2 bytes:

- `out[0]` — percent 0-100, or 0xFF when unknown (`m_pct < 0`).
- `out[1]` — flags: bit0 charging, bit1 LOW alarm, bit2 CRITICAL alarm, bit3 silenced. Higher bits are reserved.

`silenced` MUST only be set when `tier != None`. Charging policy enforces `tier == None` when charging is true.

The `out` parameter MUST be a reference to a 2-byte array (`uint8_t (&out)[2]`) so a single-byte buffer can't compile.

#### Scenario: Critical with silenced
- Given pct = 8, charging = false, tier = Critical, silenced = true
- When `payload(buf)` is called
- Then `buf[0] == 0x08` and `buf[1] == 0b00001100` (CRITICAL bit + silenced bit)

#### Scenario: Charging at low pct
- Given pct = 5, charging = true (so tier was forced to None)
- When `payload(buf)` is called
- Then `buf[0] == 0x05` and `buf[1] == 0x01` (charging bit only; tier and silenced are zero)

### Requirement: Beep tone parameters / ビープ音パラメータ

The monitor SHALL expose `beepFrequency(tier)` and `beepDurationMs(tier)`:

| Tier | Frequency | Duration |
|---|---|---|
| Low | 1000 Hz | 200 ms |
| Critical | 1500 Hz | 100 ms |

These are the parameters the main loop passes to `M5.Speaker.tone(...)`. `kSpeakerVolume = 64` (~25%, audible indoors) is set once in `begin()`.

#### Scenario: Critical beep parameters
- Given tier = Critical
- When the main loop reads `beepFrequency(Critical)` and `beepDurationMs(Critical)`
- Then the values are 1500 Hz and 100 ms
- And `M5.Speaker.tone(1500, 100)` is the dispatch

### Requirement: Charge current is not modified / 充電電流は変更しない

The firmware SHALL NOT call `M5.Power.setChargeCurrent(...)`. The M5StickS3's `pmic_m5pm1` PMIC has no case in `Power_Class::setChargeCurrent`, so the default ~100 mA from the hardware is what the device gets. With BLE + ESP-NOW + LCD all active the device draws roughly that much; a USB-tethered stick floats at ~50% indefinitely. The fix is to cut consumption (LCD brightness, BLE/WiFi TX power), not to push the PMIC harder.

#### Scenario: USB plugged in for an hour
- Given the device is on USB at 50% with all radios active
- When an hour elapses
- Then the battery percent stays approximately constant (within polling jitter)
- And the firmware does NOT attempt to raise charge current
