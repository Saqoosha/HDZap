#include <Arduino.h>
#include "esp_sleep.h"
#include "stick_display.h"
#include "msp.h"
#include "espnow_link.h"
#include "osd.h"
#include "bind.h"
#include "osd_text_display.h"
#include "nvs_store.h"
#include "ble_service.h" // includes tx_sniff.h transitively
#include "espnow_recv.h"
#include "battery_monitor.h"
#include "power_log.h"

// Keep the two parallel definitions of the OSD-text wire format in
// lockstep. ble_service.h owns `OSD_TEXT_ROW_COUNT / OSD_TEXT_ROW_MAX`
// (sizing the global staging buffer and BLE callback validation);
// osd_text_display.h owns `ROW_COUNT / ROW_TEXT_MAX` (sizing the
// renderer's own row buffer plus the local stack array memcpy'd
// from the global). A silent drift would let `memcpy(rows,
// g_osd_text_rows, sizeof(rows))` truncate or read OOB depending
// on which side moved first.
static_assert(OSDTextDisplay::ROW_COUNT == OSD_TEXT_ROW_COUNT,
              "OSD text row count mismatch between ble_service.h and osd_text_display.h");
static_assert(OSDTextDisplay::ROW_TEXT_MAX == OSD_TEXT_ROW_MAX,
              "OSD text row max length mismatch between ble_service.h and osd_text_display.h");

uint8_t g_uid[6] = {};
// True only when the displayed UID came from the MAC fallback in
// setup() — i.e. `nvs_store::loadUid` reported no saved UID and we
// derived `g_uid` from `esp_read_mac` instead. Stays false on a
// previously-bound boot (NVS hit) and on every subsequent successful
// `applyStagedUid` (NVS write). Exists so the LCD can flag UNBOUND
// for the Web Flasher "Erase All" case: the MAC fallback is hardware-
// fixed per chip, so without this flag the post-erase UID is byte-
// for-byte identical to the pre-erase one and the wipe looks like
// it did nothing.
static bool g_uid_is_default = false;
static OSD osd;
static OSDTextDisplay osdTextDisplay;
static StickDisplay stickDisplay;
static BatteryMonitor batteryMonitor;
static PowerLog powerLog;
static bool last_ble_state = false;
static bool espnow_ready = false;
static uint32_t g_power_log_last_ms = 0;
static constexpr uint32_t POWER_LOG_INTERVAL_MS = 30000;

// --- Render retry state machine -------------------------------------------
// ESP-NOW unicast auto-retries at the 802.11 MAC layer, but the send
// callback is our only signal when those retries exhaust. The HDZero
// goggle sends no application-level ack, so MAC delivery is the deepest
// feedback we have.
//
// States: IDLE -> PENDING (dispatch scheduled) -> WAITING_ACK (callbacks
// pending) -> IDLE | PENDING (retry). Re-entering PENDING from
// WAITING_ACK is a retry; re-entering from IDLE is a fresh cycle.
//
// Retry granularity is the *whole render cycle*, not the individual
// failed packet: a mid-cycle failure (e.g. writeString #2 lands but
// writeString #3 drops) leaves the goggle OSD buffer with a partial
// frame. The renderer is idempotent against the staged dirty rows —
// a fresh re-render of the same dirty bits restores a known-good
// state regardless of which packet died. (No clear is involved — the
// goggle's overlay buffer keeps prior rows; we deliberately *don't*
// wipe it between cycles so untouched rows stay put.)
//
// Verify window sizing: a full cycle dispatches at most 4 dirty rows
// + 1 draw = 5 packets. ESP-NOW serializes unicast sends per peer at
// ~a few ms each plus MAC retry time (tens of ms worst case). 200 ms
// gives comfortable margin without making the user wait too long for
// the feedback strip to settle.
enum class RenderState : uint8_t { IDLE, PENDING, WAITING_ACK };
static RenderState g_render_state = RenderState::IDLE;
static uint32_t g_render_after_ms = 0;
static uint32_t g_render_verify_after_ms = 0;
static uint32_t g_render_fail_baseline = 0;
static uint8_t  g_render_retries_left = 0;
// Dirty bitmap snapshot taken at dispatch time. Verify-success /
// give-up paths use this to surgically clear only the bits we
// actually dispatched, leaving any bits that arrived from concurrent
// BLE writes during WAITING_ACK in place for the next cycle.
static uint8_t  g_render_dispatched_mask = 0;

static constexpr uint32_t RENDER_VERIFY_MS        = 200;
static constexpr uint32_t RENDER_RETRY_BACKOFF_MS = 50;
static constexpr uint8_t  MAX_RENDER_RETRIES      = 2;
/// Staging window before the first render dispatch. New dirty rows
/// that arrive within this window are batched into a single cycle
/// instead of each triggering a separate 200 ms verify pass. iOS now
/// fires the OSD-text writes back-to-back as `writeWithoutResponse`
/// (one or two connection events for all 4 rows) and pre-pends the
/// layout char in the same burst, so 40 ms is enough to coalesce a
/// full Ready / Result frame while halving the perceived render lag
/// versus the previous 80 ms window.
static constexpr uint32_t RENDER_STAGING_MS       = 40;

// --- Power saving (issue #5, phase 3 deep sleep) -------------------------
// After g_sleep_timeout_ms of no operator activity (same definition as
// the phase 1 LCD-off trigger), drop into esp_deep_sleep_start().
// Per the ESP32-S3 datasheet the *chip* draws ~10 µA in deep sleep with
// EXT1 wake; total board draw at the JST is higher because the LCD
// controller (still in panel-sleep mode), the M5PM1 PMIC, and the
// regulator rails stay live — measure once instrumented.
// BLE link drops on sleep entry. Wake fires a full reboot from
// BtnA/BtnB low and iOS CoreBluetooth reconnects automatically only
// if the app has a pending centralManager.connect() and is either in
// foreground or registered for state preservation; reconnect latency
// is variable (commonly 5-30 s after a cold sleep cycle).
//
// Timeout source: NVS-backed `slpmin` key (minutes), default 5 min via
// nvs_store::kSleepDefaultMin. `slpmin = 0` means "never deep-sleep" —
// useful for benchwork or troubleshooting. iOS writes the byte over
// the new sleep-config BLE characteristic; loop reapplies on
// g_sleep_minutes_changed without a reboot.
//
// Gates that defer sleep (caller-visible work in progress):
//   - charging — operator probably has the stick on the bench, USB is
//     just power, they want it responsive
//   - g_sniff_active or g_sniff_start_requested — sleep would silently
//     drop bind packets in flight (or lose the staged start request)
//   - telemetry_sniff::g_telemetry_sniff_active or _start_requested —
//     same reasoning: an iOS-driven backpack-telemetry debug session
//     would silently die mid-stream
//   - g_render_state != IDLE — mid-OSD-render, finish the cycle first
//   - g_sleep_minutes_changed — pending config update goes first; see
//     the consumer block immediately above the gate
static uint32_t g_sleep_timeout_ms = (uint32_t)nvs_store::kSleepDefaultMin * 60 * 1000;

// BtnA = GPIO11, BtnB = GPIO12 (M5Unified board table for M5StickS3).
// Both fall in the ESP32-S3 RTC GPIO range (0-21), so ext1 wake on
// active-low directly catches a press without needing a timer poll.
// Active-low works without rtc_gpio_pullup_en() because M5StickS3 has
// external pull-ups on both button lines; on a board without external
// pulls, call rtc_gpio_pullup_en(GPIO_NUM_11/12) before sleep to avoid
// spurious wake.
static constexpr uint64_t WAKE_GPIO_MASK = BIT64(11) | BIT64(12);

// --- Power saving (issue #5, phase 1) -------------------------------------
// LCD-only: drop the panel to sleep after IDLE_TIMEOUT_MS of no operator
// activity. "Activity" is intentionally narrow per the issue spec — only
// hardware button presses and lap arrivals reset the timer / wake the
// panel. BLE-driven config events (UID change, bind, OSD test, etc.) do
// NOT count: they're triggered from the phone, the phone already has
// visual feedback, and a stick sitting on a table doesn't need to light
// up just because configuration is happening remotely.
//
// Race-active heuristic falls out for free: every lap pushes the timer
// forward, so a 30 s idle window keeps the LCD lit through a normal race
// pace and only sleeps once the operator stops.
//
// Phase 1 is panel-only — no MCU sleep, no BLE/ESP-NOW radio changes.
// Estimated savings: ~25 mA off the always-on baseline (per issue #5;
// not yet measured at the JST connector).
static constexpr uint32_t IDLE_TIMEOUT_MS = 30000;
static uint32_t g_last_activity_ms = 0;

// File-scope rather than function-static because `telemetry_sniff_start()`
// zeroes `g_telemetry_dropped` for the new session, so a lingering
// function-local last-logged value would emit a misleading
// "ring overflow (dropped=0 total=...)" line on the first drain after
// every restart. The start handler in `loop()` resets this in lockstep
// with the dropped counter.
static uint16_t g_last_telemetry_dropped_logged = 0;

static void markActivity() {
    g_last_activity_ms = millis();
    if (stickDisplay.isPanelAsleep()) {
        Serial.println("LCD wake");
        stickDisplay.wakePanel();
    }
}

static void requestRender(uint32_t delay_ms = 0) {
    g_render_state = RenderState::PENDING;
    g_render_after_ms = millis() + delay_ms;
    g_render_retries_left = MAX_RENDER_RETRIES;
}

static void cancelRender() {
    // Call when the pending render would draw stale state (UID change,
    // OSD clear, laps reset). An in-flight WAITING_ACK naturally winds
    // down as its callbacks arrive; we simply stop reacting to them.
    g_render_state = RenderState::IDLE;
}

static void applyStagedUid() {
    uint8_t new_uid[6];
    portENTER_CRITICAL(&g_ble_mux);
    memcpy(new_uid, (const void *)g_staged_uid, 6);
    g_uid_config_requested = false;
    portEXIT_CRITICAL(&g_ble_mux);

    // UID change invalidates any in-flight render: packets were aimed at
    // the old peer, and the lap history post-change belongs to a new
    // session from the goggle's perspective. Drop the state machine so
    // late callbacks from the old cycle can't trigger a retry on the
    // new peer.
    cancelRender();

    // Persist before publishing. If NVS save fails g_uid is untouched —
    // no rollback window, no chance for ble_update_status to leak an
    // uncommitted value to iOS between the publish and the commit.
    if (!nvs_store::saveUid(new_uid)) {
        Serial.println("NVS save failed — UID unchanged");
        stickDisplay.showMessage("NVS SAVE FAIL", stickDisplay.colorErr());
        return;
    }
    // Publish the committed value under the mux so ble_update_status
    // never sees a torn old/new byte pair during the memcpy.
    portENTER_CRITICAL(&g_ble_mux);
    memcpy(g_uid, new_uid, 6);
    portEXIT_CRITICAL(&g_ble_mux);
    // The UID is now backed by an NVS save, not the MAC fallback —
    // drop the UNBOUND flag so the LCD stops flagging the band.
    g_uid_is_default = false;

    bool wasRadioDown = !espnow_ready;
    bool radioOk;
    if (espnow_ready) {
        radioOk = espnow_reinit(g_uid);
        if (!radioOk) {
            espnow_ready = false;
            Serial.println("ESP-NOW reinit failed");
        }
    } else {
        // espnow_ready is false — espnow_init recovers from a partial prior
        // init (see its docstring), so a fresh attempt with the new UID is
        // the right move.
        espnow_ready = espnow_init(g_uid);
        radioOk = espnow_ready;
        if (!radioOk) {
            Serial.println("ESP-NOW init still failing after UID change");
        }
    }
    stickDisplay.showStatus(g_uid, g_ble_connected, espnow_ready, g_uid_is_default);
    if (!radioOk) {
        stickDisplay.showMessage("ESPNOW FAIL", stickDisplay.colorErr());
    } else {
        // Success here supersedes any prior "LAPS FULL" / "LAP RENDER
        // FAIL" / "ESPNOW FAIL" strip content; those conditions don't
        // apply to the freshly-committed UID.
        stickDisplay.clearMessage();
        if (wasRadioDown) Serial.println("ESP-NOW recovered");
        espnow_recv_attach_cb();
    }
    // Push the new UID to iOS over BLE notify. Without this, the iOS
    // status frame is only refreshed on connect/disconnect, so a UID
    // change (especially the auto-rollback path triggered by a failed
    // pairing test) leaves the app showing the stale UID — exactly
    // the state we just left behind on the firmware side.
    ble_update_status();
}

void setup() {
    // USB-CDC consoles must enumerate before bursts of println — keep this
    // ahead of BLE/WiFi spam so boot traces are capturable during LCD issues.
    Serial.begin(115200);
    delay(700);

    Serial.println("\n=== HDZero OSD Lap Timer ===");
    Serial.printf("[boot] CPU MHz before LCD = %u\n", (unsigned)getCpuFrequencyMhz());

    stickDisplay.begin();
    batteryMonitor.begin();
    // Wake-cause check needs to land before the splash hold so a
    // deep-sleep wake (operator pressing BtnA/BtnB to resume mid-race)
    // can skip the splash window entirely and bring the UI up
    // instantly. On a cold boot we want the full splash hold so the
    // version is readable; on a wake it's noise.
    esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
    bool fromDeepSleep = (cause != ESP_SLEEP_WAKEUP_UNDEFINED);
    // Boot splash: centered "HDZap" + "FW <git-describe>" so the
    // operator can confirm which firmware is running before the
    // UID/lap UI takes over. Skip the splash entirely on a deep-sleep
    // wake so a button press resumes operation without a 1.2 s freeze.
    if (!fromDeepSleep) {
        stickDisplay.showSplash(FIRMWARE_VERSION);
    }
    Serial.printf("Firmware: %s\n", FIRMWARE_VERSION);

    // Surface the wake cause so an operator can tell a power-on-reset
    // from a button-wake on serial. The cause was already read above
    // for the splash gate; print the breadcrumb here where the rest
    // of the boot diagnostics live.
    if (cause == ESP_SLEEP_WAKEUP_EXT1) {
        uint64_t mask = esp_sleep_get_ext1_wakeup_status();
        Serial.printf("Wake from deep sleep: ext1 GPIO mask=0x%llx (BtnA=GPIO11, BtnB=GPIO12)\n",
                      (unsigned long long)mask);
    } else if (cause != ESP_SLEEP_WAKEUP_UNDEFINED) {
        Serial.printf("Wake from deep sleep: cause=%d\n", (int)cause);
    }

    // Mount the on-device power log and dump anything from the previous
    // (presumably battery-only) session before we start writing to it.
    // Operator workflow: unplug → run on battery for hours → plug back in
    // → boot prints the trail before continuing the next session.
    // `/power.csv` mounts here; dumping is deferred until the tail of setup()
    // so an idle USB CDC link can't block forever before BLE + ESP-NOW +
    // the first LCD paint.
    powerLog.begin();

    if (!nvs_store::loadUid(g_uid)) {
        esp_read_mac(g_uid, ESP_MAC_WIFI_STA);
        g_uid_is_default = true;
        Serial.println("No saved UID, using MAC");
    }

    {
        uint8_t telemetrySource[6];
        if (nvs_store::loadTelemetrySourceUid(telemetrySource)) {
            portENTER_CRITICAL(&g_sniff_mux);
            memcpy(g_telemetry_source_uid, telemetrySource, sizeof(g_telemetry_source_uid));
            g_telemetry_source_configured = true;
            g_telemetry_source_captured = false;
            portEXIT_CRITICAL(&g_sniff_mux);
        }
    }

    {
        uint8_t mins = nvs_store::loadSleepMinutes();
        g_sleep_timeout_ms = (uint32_t)mins * 60 * 1000;
        Serial.printf("Deep sleep: %s (slpmin=%u)\n",
                      mins == 0 ? "disabled" : "enabled",
                      (unsigned)mins);
    }
    // Enforce unicast MAC invariant after both the MAC fallback and NVS load —
    // legacy or corrupted NVS values could arrive with bit0 set.
    g_uid[0] &= ~0x01;

    Serial.printf("UID: %02X:%02X:%02X:%02X:%02X:%02X\n",
                  g_uid[0], g_uid[1], g_uid[2], g_uid[3], g_uid[4], g_uid[5]);
    if (g_telemetry_source_configured) {
        Serial.printf("Telemetry source: %02X:%02X:%02X:%02X:%02X:%02X\n",
                      g_telemetry_source_uid[0], g_telemetry_source_uid[1],
                      g_telemetry_source_uid[2], g_telemetry_source_uid[3],
                      g_telemetry_source_uid[4], g_telemetry_source_uid[5]);
    } else {
        Serial.println("Telemetry source: not configured");
    }

    espnow_ready = espnow_init(g_uid);
    if (!espnow_ready) {
        // Keep running so the user can still reconfigure UID over BLE.
        Serial.println("ESP-NOW init FAILED — BLE only, reconfigure UID to retry");
        stickDisplay.showMessage("ESPNOW FAIL (BLE only)", stickDisplay.colorErr());
    } else {
        Serial.println("ESP-NOW initialized");
        espnow_recv_attach_cb();
    }

    osd.begin(g_uid);
    osdTextDisplay.begin(&osd);

    char deviceName[nvs_store::kDeviceNameMaxLen + 1] = {};
    nvs_store::loadDeviceName(deviceName, sizeof(deviceName));
    Serial.printf("BLE name: %s\n", deviceName);
    ble_init(deviceName);
    stickDisplay.setDeviceName(deviceName);
    Serial.println("BLE initialized, advertising...");

    stickDisplay.showStatus(g_uid, false, espnow_ready, g_uid_is_default);

    // Boot counts as activity; without this the panel could sleep before
    // the operator has had a chance to interact at all.
    g_last_activity_ms = millis();

    bool cpuOk = setCpuFrequencyMhz(80);
    unsigned hzAfter = (unsigned)getCpuFrequencyMhz();
    if (!cpuOk || hzAfter != 80) {
        Serial.printf("CPU: setCpuFrequencyMhz(80) FAILED — running at %u MHz\n", hzAfter);
    } else {
        Serial.printf("[boot] CPU scaled to %u MHz for BLE/idle savings\n", hzAfter);
    }
#if defined(M5STICKS3)
    delay(5);
#endif
    stickDisplay.showStatus(g_uid, false, espnow_ready, g_uid_is_default);
    Serial.println("[boot] setup complete");

    // After LCD + radios: safe to blast historical CSV — if USB TX backs up,
    // the operator still sees a usable stick.
    powerLog.dumpToSerial();
}

void loop() {
    stickDisplay.update();

    // stickDisplay.update() polled M5.update() above, so the wasPressed
    // edges for this tick are fresh. Either button wakes the panel and
    // resets the idle timer. wasPressed() is non-consuming, so the
    // battery-monitor block below sees the same edge via its silenceReq
    // argument — short press = wake AND silence intent (tick() no-ops
    // the silence when tier==None or already silenced, so the two
    // effects don't fight).
    if (M5.BtnA.wasPressed() || M5.BtnB.wasPressed()) {
        markActivity();
    }

    // --- Battery monitor -------------------------------------------------
    // Throttled internally to ~5 s; button state is fresh from M5.update()
    // inside stickDisplay.update(). The monitor itself is side-effect free
    // (no LCD writes, no BLE writes, no audio); we drive all three from here
    // so heavy work stays in the main loop, mirroring the rest of the
    // firmware's "callbacks stage flags, loop owns I/O" split.
    {
        uint32_t bnow = millis();
        bool silenceReq = M5.BtnA.wasPressed() || M5.BtnB.wasPressed();
        BatteryMonitor::Outcome bout = batteryMonitor.tick(bnow, silenceReq);
        if (bout != BatteryMonitor::Outcome::Throttled) {
            stickDisplay.setBattery(batteryMonitor.percent(), batteryMonitor.charging());
            uint8_t buf[2];
            batteryMonitor.payload(buf);
            ble_update_battery(buf);
        }
        if (bout == BatteryMonitor::Outcome::TierChanged) {
            switch (batteryMonitor.tier()) {
                case BatteryMonitor::Tier::None: {
                    // Recovery (charging plug-in or rise above hysteresis)
                    // clears the alarm sticky — but only when the battery
                    // message is still the one on screen. A radio / render
                    // failure may have overwritten our message in between,
                    // and those systems don't always re-raise on their next
                    // tick (e.g. NVS_SAVE_FAIL is one-shot), so blindly
                    // clearing here would silently lose unrelated state.
                    const char* cur = stickDisplay.currentMessage();
                    if (cur[0] && (strcmp(cur, "BATTERY LOW") == 0 ||
                                   strcmp(cur, "BATTERY CRITICAL") == 0)) {
                        stickDisplay.clearMessage();
                    }
                    break;
                }
                case BatteryMonitor::Tier::Low:
                    stickDisplay.showMessage("BATTERY LOW", stickDisplay.colorWarn());
                    break;
                case BatteryMonitor::Tier::Critical:
                    stickDisplay.showMessage("BATTERY CRITICAL", stickDisplay.colorErr());
                    break;
            }
        }
        if (batteryMonitor.consumeBeepDue(bnow)) {
            BatteryMonitor::Tier t = batteryMonitor.tier();
            // M5Unified Speaker_Class::tone returns false on a queue-full /
            // unsupported channel. consumeBeepDue already burned the cadence
            // slot, so a missed tone goes silent for the next full period
            // unless we surface it.
            bool ok = M5.Speaker.tone(BatteryMonitor::beepFrequency(t),
                                      BatteryMonitor::beepDurationMs(t));
            if (!ok) {
                Serial.println("Battery alarm tone FAILED (speaker queue full or unavailable)");
                // consumeBeepDue() above already burned the cadence
                // slot; without this the alarm would go silent for
                // 15-30 s on a transient queue-full. Schedule the
                // retry ~1 s out (not 0) so a persistent speaker
                // failure doesn't busy-loop the main loop.
                batteryMonitor.scheduleBeepRetry(bnow);
            }
        }
    }

    if (g_ble_connected != last_ble_state) {
        last_ble_state = g_ble_connected;
        stickDisplay.showStatus(g_uid, g_ble_connected, espnow_ready, g_uid_is_default);
        // Push the current battery snapshot on every connect edge so a
        // newly-paired iOS gets a value immediately, not on the next poll
        // delta. Without this the first 5 s after connect leave the iOS
        // row stuck on "—" because notify only fires on state change.
        if (g_ble_connected) {
            uint8_t buf[2];
            batteryMonitor.payload(buf);
            ble_update_battery(buf);
        }
    }

    if (g_uid_config_requested) {
        applyStagedUid();
    }

    if (g_bind_requested) {
        g_bind_requested = false;
        Serial.println("Sending bind packet...");
        // send_bind_packet is synchronous (~ms); a "BINDING in flight"
        // visual would never reach the eye. showBindResult both paints
        // the verdict on the lap band and tints the UID band yellow for
        // the takeover window — that's the visible BINDING state.
        bool ok = send_bind_packet(g_uid);
        Serial.printf("Bind packet %s\n", ok ? "sent" : "FAILED");
        stickDisplay.showBindResult(ok);
    }

    // --- OSD layout (Y offset) update from BLE --------------------------
    // Apply BEFORE the OSD-text dirty drain so a coincident layout-change
    // + content-update settles in one render cycle: setBaseRow re-marks
    // every row dirty so the IDLE catch-up trigger below picks them up.
    // Wipe the goggle overlay buffer before the next render, otherwise
    // text from the prior base row stays visible alongside the new rows.
    if (g_osd_layout_changed) {
        int8_t y;
        portENTER_CRITICAL(&g_ble_mux);
        y = g_osd_layout_y_offset_pending;
        g_osd_layout_changed = false;
        portEXIT_CRITICAL(&g_ble_mux);
        // Clamp y_offset to [-(MAX_BASE_ROW), 0]: 0 = bottom-anchored
        // default, -MAX_BASE_ROW puts the block at the top of the grid.
        // Any positive value (which would push the block off the bottom)
        // collapses to 0; out-of-range negatives clamp to -MAX_BASE_ROW.
        int newBase = (int)OSDTextDisplay::DEFAULT_BASE_ROW + (int)y;
        if (newBase < 0) newBase = 0;
        if (newBase > (int)OSDTextDisplay::MAX_BASE_ROW) {
            newBase = OSDTextDisplay::MAX_BASE_ROW;
        }
        uint8_t prevBase = osdTextDisplay.baseRow();
        // Cancel any in-flight render BEFORE re-marking rows dirty so a
        // pending verify success doesn't clear the freshly-set dirty
        // bits via `clearDirtyBits(g_render_dispatched_mask)` — the
        // dispatched mask was for the prior (now stale) base row, and
        // clearing it would also drop the bits setBaseRow just turned
        // on, leaving the next render cycle with nothing to draw.
        // Symptom without this guard: a slider tick that lands inside
        // the 200 ms verify window of a prior text update silently
        // loses its layout change — the OSD stays at prevBase until
        // the next BLE write retriggers requestRender().
        if (g_render_state != RenderState::IDLE) {
            cancelRender();
        }
        osdTextDisplay.setBaseRow((uint8_t)newBase);
        if (espnow_ready && (uint8_t)newBase != prevBase) {
            // Best-effort: if the clear packet drops, the next render
            // overwrites the new rows but the old ones at prevBase will
            // linger until the operator hits Clear OSD. Logging that
            // case so a "ghost text" report is diagnosable.
            if (!osd.clear()) {
                Serial.println("OSD layout: clear after base-row change failed");
            }
        }
        Serial.printf("OSD layout: y_offset=%d base_row=%u\n",
                      (int)y, (unsigned)newBase);
    }

    {
        // Re-check the dirty bitmap *inside* the mux. The bare-volatile
        // read outside is a fast path so the loop doesn't grab the
        // spinlock every tick; a concurrent BLE write between that read
        // and the critical section would otherwise leave the dirty bits
        // half-cleared and we'd render whichever bits we happened to
        // capture. Snapshot under the mux, dispatch outside.
        char rows[OSDTextDisplay::ROW_COUNT][OSDTextDisplay::ROW_TEXT_MAX + 1];
        uint8_t dirty = 0;
        if (g_osd_text_dirty) {
            portENTER_CRITICAL(&g_ble_mux);
            dirty = g_osd_text_dirty;
            if (dirty) {
                memcpy(rows, g_osd_text_rows, sizeof(rows));
                g_osd_text_dirty = 0;
            }
            portEXIT_CRITICAL(&g_ble_mux);
        }

        if (dirty) {
            // OR-merge the staged rows into the display's dirty mask.
            // We never overwrite — a BLE write that lands during a
            // WAITING_ACK window would otherwise lose its bit when the
            // pending verify finally clears m_dirty on success.
            osdTextDisplay.setDirtyRows(dirty, rows);
            if (!espnow_ready) {
                stickDisplay.showMessage("ESPNOW DOWN", stickDisplay.colorErr());
            } else {
                stickDisplay.clearMessage();
            }
            // OSD text dirty rows are the new "lap arrived from iOS"
            // signal after PR #13 collapsed the firmware lap pipeline
            // into iOS-driven OSD text. Treat them as operator activity
            // for the same reason we'd wake on the old g_lap_received
            // edge: the operator is actively running a session.
            markActivity();
        }
    }

    // --- Dispatch new content while idle --------------------------------
    // Catch-up trigger: if the state machine is IDLE and the display
    // has dirty rows that haven't been delivered yet, request a render.
    // This unifies three previously separate edges:
    //   - a fresh BLE write just merged dirty bits
    //   - ESP-NOW was down at dispatch and just came back up
    //   - a previous WAITING_ACK cycle finished and a new BLE write
    //     arrived in the meantime
    // Without this, a row written during WAITING_ACK would sit in
    // m_dirty unrendered until the next BLE edge.
    // RENDER_STAGING_MS delay batches BLE writes that arrive back-to-back
    // into a single cycle — 4-row Ready/Results displays appear atomically
    // instead of line-by-line across multiple 200 ms verify passes.
    if (g_render_state == RenderState::IDLE && espnow_ready && osdTextDisplay.hasDirty()) {
        requestRender(RENDER_STAGING_MS);
    }

    // --- Render dispatch -------------------------------------------------
    // Enter on PENDING once the scheduled dispatch time arrives. Snapshot
    // the failure counter as a baseline, fire the full cycle, and move to
    // WAITING_ACK so the verify block below can judge MAC-level delivery.
    if (g_render_state == RenderState::PENDING && millis() >= g_render_after_ms) {
        if (!espnow_ready) {
            // Radio died between request and dispatch — nothing to send.
            // The producer already surfaced ESPNOW DOWN when relevant;
            // just drop the cycle so we don't spin on PENDING.
            cancelRender();
        } else {
            g_render_fail_baseline = g_espnow_sent_fail;
            // Snapshot the bits we're about to dispatch and pass them
            // explicitly to render(). A concurrent BLE write that
            // OR-merges new bits into m_dirty between this snapshot
            // and the actual MSP packet writes would otherwise hitch
            // a ride and be sent here too — those bits stay live in
            // m_dirty and the next IDLE catch-up picks them up cleanly.
            // Single-byte volatile read is atomic on ESP32, so the
            // snapshot itself doesn't need the BLE mux.
            g_render_dispatched_mask = osdTextDisplay.dirty();
            bool queued = osdTextDisplay.render(g_render_dispatched_mask);
            if (!queued) {
                // esp_now_send returned non-OK for at least one packet in
                // the cycle (queue-level failure — typically NO_MEM or
                // NOT_FOUND). Back off and retry; NEW-38 (esp_err_t
                // propagation) will later let us distinguish transient
                // from terminal errors here.
                if (g_render_retries_left > 0) {
                    g_render_retries_left--;
                    g_render_after_ms = millis() + RENDER_RETRY_BACKOFF_MS;
                    stickDisplay.showMessage("RETRY", stickDisplay.colorOrange());
                } else {
                    // Give up on this cycle. Drop the dispatched bits —
                    // otherwise the IDLE catch-up trigger would
                    // immediately re-fire and we'd loop forever. Bits
                    // that arrived after dispatch survive for the next
                    // cycle.
                    osdTextDisplay.clearDirtyBits(g_render_dispatched_mask);
                    cancelRender();
                    Serial.println("Render queue failed, retries exhausted");
                    stickDisplay.showMessage("OSD LOST", stickDisplay.colorErr());
                }
            } else {
                g_render_state = RenderState::WAITING_ACK;
                g_render_verify_after_ms = millis() + RENDER_VERIFY_MS;
            }
        }
    }

    // --- Render verify ---------------------------------------------------
    // After the verify window, compare the failure counter against the
    // baseline. Any delta means MAC-layer delivery failed on at least one
    // packet in the cycle; retry (re-entering PENDING) or give up.
    //
    // Spurious retries are acceptable: if a straggler callback from an
    // earlier cycle counts against the current baseline, we re-render,
    // which is idempotent. The cost is a visible "RETRY" strip flash.
    if (g_render_state == RenderState::WAITING_ACK && millis() >= g_render_verify_after_ms) {
        uint32_t newFails = g_espnow_sent_fail - g_render_fail_baseline;
        if (newFails == 0) {
            // All dispatched packets delivered at the MAC layer. Clear
            // *only* the bits we dispatched — bits that arrived from
            // BLE writes during the verify window need to survive so
            // the IDLE catch-up trigger picks them up next iteration.
            osdTextDisplay.clearDirtyBits(g_render_dispatched_mask);
            g_render_state = RenderState::IDLE;
        } else if (g_render_retries_left > 0) {
            g_render_retries_left--;
            g_render_state = RenderState::PENDING;
            g_render_after_ms = millis() + RENDER_RETRY_BACKOFF_MS;
            Serial.printf("ESP-NOW delivery: %u fail(s), retrying (%u left)\n",
                          (unsigned)newFails, g_render_retries_left);
            stickDisplay.showMessage("RETRY", stickDisplay.colorOrange());
        } else {
            // Give up on the dispatched bits so we don't wedge in an
            // infinite IDLE→PENDING→fail loop with the same stale rows;
            // any new bits accumulated during the verify window survive
            // and start a fresh cycle next iteration.
            osdTextDisplay.clearDirtyBits(g_render_dispatched_mask);
            cancelRender();
            Serial.printf("ESP-NOW delivery gave up after %u retries (%u fail(s) last cycle)\n",
                          MAX_RENDER_RETRIES, (unsigned)newFails);
            stickDisplay.showMessage("OSD LOST", stickDisplay.colorErr());
        }
    }

    if (g_osd_clear_requested) {
        g_osd_clear_requested = false;
        // Clearing the OSD and then letting a pending render repopulate
        // it would undo the user's intent, so cancel any in-flight cycle
        // first. The next OSD-text frame will re-arm requestRender()
        // naturally.
        cancelRender();
        if (!espnow_ready) {
            stickDisplay.showMessage("CLEAR: ESPNOW DOWN", stickDisplay.colorOrange());
        } else if (!(osd.clear() && osd.draw())) {
            stickDisplay.showMessage("CLEAR FAIL", stickDisplay.colorErr());
        } else {
            stickDisplay.showMessage("OSD CLEARED", stickDisplay.colorCyan());
        }
    }

    if (g_osd_test_requested) {
        g_osd_test_requested = false;
        // Debug button: one-shot "does ESP-NOW reach the goggle?" probe.
        // Bypass the OSD-text state machine (test should not repopulate
        // a screen the user just cleared) and fire a single
        // clear+write+draw cycle with synchronous delivery verification.
        cancelRender();
        // Result is also pushed back to iOS via the status notify so the
        // pairing flow can auto-rollback on failure without asking the
        // user to look at the goggle. Encoding matches g_last_test_result
        // doc above (1 = OK, 2 = LOST). We always overwrite — the iOS
        // side reads the value as "result of the most recent test" and
        // is responsible for ignoring stale values it has already acted on.
        uint8_t result = 2;
        if (!espnow_ready) {
            stickDisplay.showMessage("TEST: ESPNOW DOWN", stickDisplay.colorErr());
        } else {
            uint32_t failBefore = g_espnow_sent_fail;
            bool queued = osd.clear()
                       && osd.writeString(0, 0, "HDZERO TEST")
                       && osd.draw();
            if (!queued) {
                stickDisplay.showMessage("TEST QUEUE FAIL", stickDisplay.colorErr());
            } else {
                // Packets are already in the ESP-NOW queue; MAC-layer TX
                // and send callbacks fire from the WiFi task, which is
                // NOT blocked by a main-loop delay. 200 ms is the same
                // verify window the render state machine uses.
                //
                // The "no delay between ESP-NOW packets" rule is about
                // inserting delays *between* clear/write/draw — those
                // break delivery. Delaying *after* all three are queued
                // only waits for the callbacks we care about.
                delay(RENDER_VERIFY_MS);
                uint32_t newFails = g_espnow_sent_fail - failBefore;
                if (newFails == 0) {
                    Serial.println("Test OSD: delivered");
                    stickDisplay.showTestResult(true);
                    result = 1;
                } else {
                    Serial.printf("Test OSD: %u packet(s) lost\n", (unsigned)newFails);
                    stickDisplay.showTestResult(false);
                }
            }
        }
        portENTER_CRITICAL(&g_ble_mux);
        g_last_test_result = result;
        portEXIT_CRITICAL(&g_ble_mux);
        ble_update_status();
    }

    // --- TX sniff handling -------------------------------------------
    // Start/stop driven by iOS; capture relayed to iOS via BLE notify so
    // the operator can apply the caught UID as the new goggle target.
    // tx_sniff and telemetry_sniff coexist on the unified ESP-NOW recv
    // callback (espnow_recv.h) — both can run concurrently without
    // fighting for the recv-callback slot.
    if (g_sniff_start_requested) {
        g_sniff_start_requested = false;
        if (sniff_start()) {
            Serial.println("TX sniff: started");
        }
    }

    if (g_sniff_stop_requested) {
        g_sniff_stop_requested = false;
        if (sniff_stop()) {
            Serial.println("TX sniff: stopped");
        }
    }

    if (g_sniff_captured) {
        uint8_t uid[6];
        uint8_t telemetrySource[6];
        bool telemetrySourceCaptured = false;
        portENTER_CRITICAL(&g_sniff_mux);
        memcpy(uid, g_sniff_uid, 6);
        memcpy(telemetrySource, g_telemetry_source_uid, 6);
        telemetrySourceCaptured = g_telemetry_source_captured;
        g_telemetry_source_captured = false;
        g_sniff_captured = false;
        portEXIT_CRITICAL(&g_sniff_mux);
        Serial.printf("TX UID captured: %02X:%02X:%02X:%02X:%02X:%02X\n",
                      uid[0], uid[1], uid[2], uid[3], uid[4], uid[5]);
        if (telemetrySourceCaptured) {
            if (nvs_store::saveTelemetrySourceUid(telemetrySource)) {
                Serial.printf("Telemetry source captured: %02X:%02X:%02X:%02X:%02X:%02X\n",
                              telemetrySource[0], telemetrySource[1], telemetrySource[2],
                              telemetrySource[3], telemetrySource[4], telemetrySource[5]);
            } else {
                Serial.println("Telemetry source save failed");
            }
        }
        ble_notify_tx_uid(uid);
    }

    // --- Telemetry debug sniff handling ------------------------------
    // Start/stop driven by iOS Backpack Telemetry Debug subview. Each
    // captured ESP-NOW packet is shipped to iOS as a 20-byte record
    // (telemetry_sniff::RECORD_SIZE / layout in telemetry_sniff.h).
    // Coexists with TX sniff on the unified recv callback — no preempt
    // needed.
    if (telemetry_sniff::g_telemetry_start_requested) {
        telemetry_sniff::g_telemetry_start_requested = false;
        if (telemetry_sniff::telemetry_sniff_start()) {
            // telemetry_sniff_start zeroes g_telemetry_dropped for the
            // new session — keep our last-logged mirror in sync so the
            // first drain doesn't log a phantom "dropped=0" against a
            // stale prior session's high-water mark.
            g_last_telemetry_dropped_logged = 0;
            Serial.println("Telemetry sniff: started");
        }
    }

    if (telemetry_sniff::g_telemetry_stop_requested) {
        telemetry_sniff::g_telemetry_stop_requested = false;
        if (telemetry_sniff::telemetry_sniff_stop()) {
            Serial.println("Telemetry sniff: stopped");
        }
    }

    // Drain one telemetry record per loop iteration. With the main loop
    // delay(10) below this caps notify rate at ~100 packets/sec — well
    // under what BLE can sustain at our 30-50 ms negotiated connection
    // interval, but enough headroom for the ELRS telemetry rate (CRSF
    // telemetry typically ≤ 50 Hz). Sustained ring overflow is logged
    // here on each transition to a higher dropped count so the operator
    // sees evidence in serial even though iOS doesn't surface it yet.
    if (telemetry_sniff::g_telemetry_sniff_active) {
        uint8_t record[telemetry_sniff::RECORD_SIZE];
        uint16_t dropped = 0;
        uint32_t total = 0;
        if (telemetry_sniff::telemetry_pop(record, dropped, total)) {
            ble_notify_telemetry_packet(record);
        }
        if (dropped != g_last_telemetry_dropped_logged) {
            Serial.printf("Telemetry sniff: ring overflow (dropped=%u total=%u)\n",
                          (unsigned)dropped, (unsigned)total);
            g_last_telemetry_dropped_logged = dropped;
        }
    }

    // Flight-pack CRSF Battery (MSP 0x0011 wrapped by Backpack). Promiscuous
    // RX only stages candidate bytes; parsing + BLE notification stays here.
    {
        uint8_t promiscCandidate[kPromiscMspCandidateMaxLen];
        int promiscCandidateLen = 0;
        if (hdzap_consume_promisc_msp_candidate(promiscCandidate,
                                                sizeof(promiscCandidate),
                                                &promiscCandidateLen)) {
            flight_battery_on_espnow_payload(promiscCandidate, promiscCandidateLen);
        }

        FlightBatterySampleRaw fb{};
        if (flight_battery_consume_if_staged(&fb)) {
            ble_maybe_notify_flight_battery(fb);
        }
        // Surface flight-battery staging overwrites so a sustained
        // burst rate isn't silent.
        static uint32_t last_fb_dropped_logged = 0;
        uint32_t fb_dropped = g_flight_battery_dropped;
        if (fb_dropped != last_fb_dropped_logged) {
            Serial.printf("Flight battery: staged sample overwrite (dropped=%u)\n",
                          (unsigned)fb_dropped);
            last_fb_dropped_logged = fb_dropped;
        }

        // Same edge-log discipline for the upstream promiscuous-MSP
        // candidate buffer — bursts there are upstream of the
        // flight-battery staging, so they wouldn't show in
        // `g_flight_battery_dropped`.
        static uint32_t last_promisc_dropped_logged = 0;
        uint32_t promisc_dropped = g_promisc_msp_dropped;
        if (promisc_dropped != last_promisc_dropped_logged) {
            Serial.printf("Promisc MSP: candidate overwrite (dropped=%u)\n",
                          (unsigned)promisc_dropped);
            last_promisc_dropped_logged = promisc_dropped;
        }

        // CRSF parser diagnostics. Print a reject-reason summary every
        // 30 s when a telemetry source is configured but no battery
        // frame has decoded since the last summary — turns "no flight
        // telemetry" from a silent failure into a clue at the serial
        // console (bad CRC vs wrong frame type vs none-of-the-above).
        static uint32_t last_crsf_summary_ms = 0;
        static uint32_t last_crsf_accepts_seen = 0;
        constexpr uint32_t kCrsfSummaryEveryMs = 30 * 1000;
        if (g_telemetry_source_configured &&
            millis() - last_crsf_summary_ms >= kCrsfSummaryEveryMs) {
            uint32_t accepts_now = g_crsf_accepts;
            if (accepts_now == last_crsf_accepts_seen) {
                Serial.printf(
                    "CRSF parser: no decode in %us — rejects: null=%u short_msp=%u no_msp=%u "
                    "msp_len=%u msp_crc=%u short_crsf=%u no_addr=%u type=%u len=%u crsf_crc=%u range=%u\n",
                    (unsigned)(kCrsfSummaryEveryMs / 1000),
                    (unsigned)g_crsf_rej_null_arg,
                    (unsigned)g_crsf_rej_short_msp,
                    (unsigned)g_crsf_rej_no_msp_marker,
                    (unsigned)g_crsf_rej_msp_frame_len,
                    (unsigned)g_crsf_rej_msp_crc,
                    (unsigned)g_crsf_rej_short_crsf,
                    (unsigned)g_crsf_rej_no_crsf_candidate,
                    (unsigned)g_crsf_rej_frame_type,
                    (unsigned)g_crsf_rej_frame_len,
                    (unsigned)g_crsf_rej_crsf_crc,
                    (unsigned)g_crsf_rej_range);
            }
            last_crsf_accepts_seen = accepts_now;
            last_crsf_summary_ms = millis();
        }
    }

    if (g_osd_reset_laps_requested) {
        g_osd_reset_laps_requested = false;
        // Reset invalidates the staged OSD text; a pending render would
        // re-draw rows on top of a freshly-cleared OSD, so drop the
        // cycle before clearing.
        cancelRender();
        osdTextDisplay.clear();
        if (!espnow_ready) {
            Serial.println("Laps reset (local only; ESP-NOW down)");
            stickDisplay.showMessage("RESET: ESPNOW DOWN", stickDisplay.colorOrange());
        } else if (!(osd.clear() && osd.draw())) {
            Serial.println("Laps reset (OSD send failed)");
            stickDisplay.showMessage("RESET FAIL", stickDisplay.colorErr());
        } else {
            Serial.println("Laps reset");
            stickDisplay.showStatus(g_uid, g_ble_connected, espnow_ready, g_uid_is_default);
            // Drop any stale "LAPS FULL" / "LAP RENDER FAIL" from the
            // sticky strip — a fresh reset is a clean slate.
            stickDisplay.clearMessage();
        }
    }

    // --- Idle-timeout LCD sleep ------------------------------------------
    // End-of-tick check so any markActivity() earlier in this iteration
    // already updated g_last_activity_ms. Sleep is one-shot (sleepPanel
    // is idempotent), so checking every tick is cheap.
    if (!stickDisplay.isPanelAsleep() &&
        millis() - g_last_activity_ms >= IDLE_TIMEOUT_MS) {
        Serial.println("LCD sleep (idle)");
        stickDisplay.sleepPanel();
    }

    // --- Device-name rename from BLE -------------------------------------
    // iOS write → persist → reboot. BLEDevice::init(name) is one-shot, so
    // there's no clean live path: tearing the BLE stack down at runtime
    // would invalidate every BLECharacteristic* + callback object the
    // server has handed out. A 2-3 s reboot window is cheap and bonded
    // iOS auto-reconnects without user action.
    //
    // Like the sleep-config consumer below, this block must precede the
    // deep-sleep gate — a rename write landing at the idle threshold
    // would otherwise be wiped by `esp_deep_sleep_start()` before the
    // NVS persist runs, and the user's tap would silently no-op until
    // the next button press wakes the device.
    if (g_device_name_changed) {
        char pending[nvs_store::kDeviceNameMaxLen + 1] = {};
        portENTER_CRITICAL(&g_ble_mux);
        memcpy(pending, (const void*)g_device_name_pending, sizeof(pending));
        g_device_name_changed = false;
        portEXIT_CRITICAL(&g_ble_mux);
        if (nvs_store::saveDeviceName(pending)) {
            Serial.printf("Device name: saved '%s' — restarting in 200 ms\n", pending);
            // Brief pause so the BLE write's ATT response (write-with-
            // response from iOS) actually leaves the radio before the
            // restart drops the link; without this iOS's write would
            // surface as a transient error in the rename UI. Stalling
            // the loop for 200 ms is acceptable here because the next
            // line is `ESP.restart()` — every other loop responsibility
            // (battery monitor, OSD retry, LCD sleep) is about to be
            // re-entered from `setup()` anyway. The CLAUDE.md rule
            // against `delay()` between ESP-NOW packets does not apply:
            // no ESP-NOW traffic is in flight at this point in the loop.
            delay(200);
            ESP.restart();
        } else {
            Serial.printf("Device name: NVS save failed for '%s' — keeping current\n", pending);
        }
    }

    // --- Deep-sleep config update from BLE -------------------------------
    // Must run BEFORE the deep-sleep gate below — otherwise an iOS write
    // (especially mins=0 = "disable") that lands at the idle threshold
    // would be silently dropped: the gate fires first and esp_deep_sleep_start
    // wipes RAM before the consumer can apply the new value.
    if (g_sleep_minutes_changed) {
        uint8_t mins;
        portENTER_CRITICAL(&g_ble_mux);
        mins = g_sleep_minutes_pending;
        g_sleep_minutes_changed = false;
        portEXIT_CRITICAL(&g_ble_mux);
        g_sleep_timeout_ms = (uint32_t)mins * 60 * 1000;
        if (!nvs_store::saveSleepMinutes(mins)) {
            Serial.println("Sleep config: NVS save failed (in-memory only)");
        }
        Serial.printf("Sleep config: timeout=%u min (%s)\n",
                      (unsigned)mins,
                      mins == 0 ? "disabled" : "enabled");
        // Reset activity timer so a config change while idle doesn't
        // immediately drop us into sleep before the operator can react.
        g_last_activity_ms = millis();
    }

    // --- Deep-sleep gate (issue #5 phase 3) ------------------------------
    // Same activity timestamp as the phase-1 LCD-off check above, just a
    // longer threshold and harder action. Gates: no charge plug, no sniff
    // capture or pending sniff start (sleep would lose the BLE-staged
    // start request), no in-flight render. After sleep this branch never
    // returns; wake is a full reboot through setup(). On the iOS side,
    // CoreBluetooth needs a pending centralManager.connect() to pick the
    // peripheral back up — typical reconnect after a cold sleep cycle is
    // 5-30 s depending on whether the app is foreground or in background
    // state preservation.
    if (g_sleep_timeout_ms > 0 &&
        millis() - g_last_activity_ms >= g_sleep_timeout_ms &&
        !batteryMonitor.charging() &&
        !g_sniff_active &&
        !g_sniff_start_requested &&
        !telemetry_sniff::g_telemetry_sniff_active &&
        !telemetry_sniff::g_telemetry_start_requested &&
        g_render_state == RenderState::IDLE) {
        Serial.println("Deep sleep — wake on BtnA/BtnB press");
        // USB CDC Serial.flush() only drains the FreeRTOS-side queue, not
        // the host buffer; the wake-cause printout in setup() (which IS
        // delivered after wake) is the source of truth for "did we sleep
        // and wake correctly?". The pre-sleep line is best-effort.
        Serial.flush();
        delay(50);
        esp_err_t we = esp_sleep_enable_ext1_wakeup(WAKE_GPIO_MASK,
                                                    ESP_EXT1_WAKEUP_ANY_LOW);
        if (we != ESP_OK) {
            // Worst-case silent failure: deep-sleep with no wake source
            // means only a hardware reset recovers. Abort the sleep and
            // bump the activity timer so the next attempt is one full
            // window away — gives the operator (and us) a chance to see
            // the failure on serial without spinning into immediate retry.
            Serial.printf("Deep sleep ABORTED: ext1 wake setup failed (%d)\n", we);
            g_last_activity_ms = millis();
        } else {
            esp_deep_sleep_start();
            // unreachable
        }
    }

    // --- Power log append ------------------------------------------------
    // Snapshot VBAT + state every 30 s (rollover-safe interval arithmetic).
    // M5.Power.getBatteryVoltage() returns mV; dV/dt across a multi-minute
    // window stands in for instantaneous current draw — M5Unified's
    // pmic_m5pm1 path does not implement getBatteryCurrent() (the switch
    // falls through to the default 0 return; M5PM1 may expose current via
    // its own registers in a future release).
    // Per-loop is too noisy and would burn the SPIFFS partition; 30 s
    // captures the trend that matters for before/after power deltas.
    {
        uint32_t now = millis();
        if (now - g_power_log_last_ms >= POWER_LOG_INTERVAL_MS) {
            g_power_log_last_ms = now;
            int16_t voltage_mv = M5.Power.getBatteryVoltage();
            // PMIC can return 0/-1 during boot transient or on I²C glitch.
            // Sentinel-mark instead of writing a phantom 0 mV row that
            // would corrupt downstream dV/dt analysis. -1 matches the
            // battery_monitor.h convention for "unknown".
            if (voltage_mv < 2500 || voltage_mv > 4400) {
                static bool warnedVbat = false;
                if (!warnedVbat) {
                    Serial.printf("power_log: VBAT out of range (%d mV) — logging as -1\n",
                                  (int)voltage_mv);
                    warnedVbat = true;
                }
                voltage_mv = -1;
            }
            powerLog.appendSample(now,
                                  voltage_mv,
                                  batteryMonitor.percent(),
                                  batteryMonitor.charging(),
                                  stickDisplay.isPanelAsleep(),
                                  g_ble_connected);
        }
    }

    delay(10);
}
