# firmware-power-management Specification

## Purpose

Stretch the M5StickS3's small battery across a full race day by trimming static draw (CPU, BLE/WiFi TX power), turning the LCD off when idle, and dropping into deep sleep after extended inactivity — without disrupting an active race.

## Requirements

### Requirement: CPU clock at 80 MHz / CPU クロック 80 MHz

The firmware SHALL set CPU frequency to 80 MHz at the very start of `setup()` via `setCpuFrequencyMhz(80)`. Bluedroid's documented minimum is 80 MHz; below that BLE becomes unstable. The firmware SHALL verify the actual frequency post-call via `getCpuFrequencyMhz()` and log a warning if it isn't 80.

CPU の dynamic-power 部分は周波数に線形比例するので 240 MHz → 80 MHz は数 mA の節約になる。Apply タイミングは Serial.begin との順序によらず動作する (UART divisor は APB-derived で APB は 80 MHz 固定)。

#### Scenario: Boot at 80 MHz
- Given a fresh boot
- When `setup()` runs
- Then `setCpuFrequencyMhz(80)` is called before any peripheral init
- And `getCpuFrequencyMhz() == 80`
- And serial logs `CPU: 80 MHz`

### Requirement: Idle-timeout LCD sleep / アイドル時 LCD スリープ

After `IDLE_TIMEOUT_MS` (30 s) of no operator activity, the firmware SHALL call `stickDisplay.sleepPanel()`. Activity is intentionally narrow: hardware button presses (BtnA, BtnB) and OSD-text dirty rows arriving from BLE. BLE-only events (UID change, bind, OSD test, etc.) do NOT count — they're triggered from the phone, the phone has its own visual feedback, and a stick on the table doesn't need to light up because configuration is happening remotely.

`markActivity()` SHALL update `g_last_activity_ms` to `millis()` and call `wakePanel()` if asleep. Race-active pacing is automatic: every lap pushes the timer forward via the OSD-text dirty-rows trigger, so the LCD stays lit through a normal race and only sleeps once the operator stops.

The sleep gate SHALL be re-checked at the end of every loop iteration and SHALL be idempotent (`sleepPanel` is a cheap no-op when already asleep).

#### Scenario: Operator presses BtnA after 60 s idle
- Given the LCD has been asleep for 30 s after a 30 s idle window
- When the operator taps BtnA
- Then `markActivity()` runs, the LCD wakes (full repaint), and `g_last_activity_ms` resets

#### Scenario: BLE-only configuration does not wake LCD
- Given the LCD is asleep
- When iOS sends a UID config change
- Then `applyStagedUid` runs but the LCD remains asleep
- And the goggle gets the new UID without the M5Stick lighting up

### Requirement: Panel sleep API / パネルスリープ API

`stickDisplay.sleepPanel()` and `wakePanel()` SHALL be the only entry points for panel power state. `sleepPanel` SHALL call `M5.Display.sleep()` only — it MUST NOT prepend `setBrightness(0)` because that corrupts LGFX's `_brightness` cache and `wakeup()` then restores brightness=0 (visibly black panel after wake).

`wakePanel` SHALL call `M5.Display.wakeup()`, then wait 5 ms (`delay(5)`) per the ST7789 SLPOUT timing requirement, then full-repaint via `fillScreen(TFT_BLACK)` + `drawHairlines` + `drawUidBand` + `drawLapBand` + `drawStrip`. Without the 5 ms wait, the first draw bytes after wakeup can be dropped and the panel stays blank until the next render edge.

LGFX の brightness cache が 0 になる事故は実装中に踏んだ落とし穴。setBrightness(0) を sleep に追加した PR を revert した経緯がある。

#### Scenario: Wake after sleep
- Given `m_panelAsleep == true`
- When `wakePanel()` is called
- Then `M5.Display.wakeup()` runs, the firmware delays 5 ms, the panel is fully repainted
- And `m_panelAsleep == false`

### Requirement: Deep sleep gate / ディープスリープゲート

After `g_sleep_timeout_ms` (computed from NVS-backed `slpmin` × 60 × 1000) of inactivity AND all defer conditions clear, the firmware SHALL enter ESP32 deep sleep via `esp_deep_sleep_start()`. Defer conditions:

- `g_sleep_timeout_ms == 0` (user disabled deep sleep).
- `batteryMonitor.charging() == true` (USB plugged in; operator is at the bench).
- `g_sniff_active || g_sniff_start_requested` (BLE-staged sniff would be lost).
- `g_render_state != IDLE` (mid-OSD-render, finish first).

The sleep-config consumer (CHR_SLEEP_CONFIG → `g_sleep_minutes_changed`) MUST run BEFORE the deep-sleep gate so an iOS write that lands at the idle threshold is never lost. A `mins=0` write that arrives just at the threshold would otherwise be silently dropped: the gate fires first and `esp_deep_sleep_start` wipes RAM before the consumer can apply the new value.

`g_last_activity_ms` SHALL be reset to `millis()` whenever `g_sleep_minutes_changed` is consumed so a config change while idle doesn't immediately drop into sleep before the operator can react.

deep sleep 後はチップ ~10 µA だが、LCD コントローラ・PMIC・レギュレータレールが live で残るため JST 端での合計はもっと高い。実測は instrumented で別途。

#### Scenario: Sleep timeout reached on battery
- Given `g_sleep_timeout_ms = 5*60*1000`, no charging, no sniff, render IDLE, 5+ min of inactivity
- When the gate runs
- Then `Serial.flush() + delay(50)` (best-effort drain) and `esp_sleep_enable_ext1_wakeup` succeed
- And `esp_deep_sleep_start()` is called (does not return)
- And the next boot starts from `setup()`

#### Scenario: Sleep deferred by sniff
- Given the same idle timeout reached but `g_sniff_active == true`
- When the gate runs
- Then deep sleep does NOT execute; the loop continues

#### Scenario: ext1 wake setup fails
- Given `esp_sleep_enable_ext1_wakeup` returns non-OK
- When the gate runs
- Then `Serial.printf("Deep sleep ABORTED: ext1 wake setup failed (...)")` logs
- And `g_last_activity_ms = millis()` resets so the next attempt is one full window away
- And `esp_deep_sleep_start()` is NOT called (would sleep with no wake source)

### Requirement: Wake source / ウェイクソース

The firmware SHALL configure `esp_sleep_enable_ext1_wakeup(WAKE_GPIO_MASK, ESP_EXT1_WAKEUP_ANY_LOW)` with `WAKE_GPIO_MASK = BIT64(11) | BIT64(12)` (BtnA = GPIO11, BtnB = GPIO12 per the M5Unified board table for M5StickS3). Both pins are in the ESP32-S3 RTC GPIO range; M5StickS3 has external pull-ups, so no `rtc_gpio_pullup_en` is needed.

After wake, `setup()` MUST NOT re-use any state from before sleep (RAM is wiped). The firmware MAY call `esp_sleep_get_wakeup_cause()` purely for logging; the rest of setup runs identically regardless of wake reason.

#### Scenario: BtnA wakes the device
- Given the M5Stick is in deep sleep
- When the operator presses BtnA
- Then the device boots through `setup()`
- And serial logs `Wake from deep sleep: ext1 GPIO mask=0x800`

### Requirement: Sleep-config wire format / Sleep config wire フォーマット

CHR_SLEEP_CONFIG SHALL carry a single unsigned byte: minutes of idle before deep sleep, with 0 meaning "disabled". The characteristic SHALL be both READ and WRITE. The READ value SHALL be seeded with the current persisted value at `ble_init` time so a fresh iOS read sees the actual setting, not 0.

Writes SHALL stage `g_sleep_minutes_pending` and set `g_sleep_minutes_changed` under `g_ble_mux`. The main loop SHALL apply, persist via `nvs_store::saveSleepMinutes`, log the new state, and reset `g_last_activity_ms`.

#### Scenario: User sets 10 min sleep
- Given iOS writes `[0x0A]` to CHR_SLEEP_CONFIG
- When the main loop consumer runs
- Then `g_sleep_timeout_ms == 600000` (10*60*1000)
- And NVS persists 10
- And `g_last_activity_ms` resets

### Requirement: Bluedroid connection params / Bluedroid 接続パラメータ

On BLE connect, the firmware SHALL request 30-50 ms interval (24-40 in 1.25 ms units), slave latency 4, supervision timeout 4 s (400 in 10 ms units) via `updateConnParams`. Slave latency 4 means the peripheral wakes 1 in 5 events when idle (effective ~250 ms idle wake), trimming current draw during the 30 s+ idle windows seen when the operator isn't pushing laps.

iOS MAY reject and pick its own params; the firmware SHALL log the LL status without retrying. Phase-2-redux savings silently revert in that case.

`CONN_HDL0` per-handle override is NOT applied here because the docs require it post-connection; `ESP_BLE_PWR_TYPE_DEFAULT` covers the connected case.

#### Scenario: Successful negotiation
- Given iOS connects
- When `updateConnParams(24, 40, 4, 400)` runs from `onConnect`
- Then GAP `UPDATE_CONN_PARAMS` event reports `status == 0`
- And the link runs at the requested params
