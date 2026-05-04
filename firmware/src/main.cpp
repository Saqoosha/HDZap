#include <Arduino.h>
#include "stick_display.h"
#include "msp.h"
#include "espnow_link.h"
#include "osd.h"
#include "bind.h"
#include "osd_text_display.h"
#include "nvs_store.h"
#include "ble_service.h" // includes tx_sniff.h transitively
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
    stickDisplay.showStatus(g_uid, g_ble_connected, espnow_ready);
    if (!radioOk) {
        stickDisplay.showMessage("ESPNOW FAIL", stickDisplay.colorErr());
    } else {
        // Success here supersedes any prior "LAPS FULL" / "LAP RENDER
        // FAIL" / "ESPNOW FAIL" strip content; those conditions don't
        // apply to the freshly-committed UID.
        stickDisplay.clearMessage();
        if (wasRadioDown) Serial.println("ESP-NOW recovered");
    }
    // Push the new UID to iOS over BLE notify. Without this, the iOS
    // status frame is only refreshed on connect/disconnect, so a UID
    // change (especially the auto-rollback path triggered by a failed
    // pairing test) leaves the app showing the stale UID — exactly
    // the state we just left behind on the firmware side.
    ble_update_status();
}

void setup() {
    // Issue #5 phase 2 redux: drop CPU clock from the 240 MHz default
    // to 80 MHz. Bluedroid's documented minimum is 80 MHz; below that
    // BLE becomes unstable. CPU dynamic power scales ~linearly with
    // frequency so this is a clean ~15-25 mA win without touching the
    // BLE/ESP-NOW radios. Must run BEFORE Serial.begin() so the UART
    // divisor lands on the right base clock.
    setCpuFrequencyMhz(80);

    stickDisplay.begin();
    batteryMonitor.begin();
    Serial.begin(115200);
    delay(500); // Wait for USB CDC serial to enumerate before first println.
    Serial.println("\n=== HDZero OSD Lap Timer ===");
    Serial.printf("CPU: %u MHz\n", (unsigned)getCpuFrequencyMhz());

    // Mount the on-device power log and dump anything from the previous
    // (presumably battery-only) session before we start writing to it.
    // Operator workflow: unplug → run on battery for hours → plug back in
    // → boot prints the trail before continuing the next session.
    powerLog.begin();
    powerLog.dumpToSerial();

    if (!nvs_store::loadUid(g_uid)) {
        esp_read_mac(g_uid, ESP_MAC_WIFI_STA);
        Serial.println("No saved UID, using MAC");
    }
    // Enforce unicast MAC invariant after both the MAC fallback and NVS load —
    // legacy or corrupted NVS values could arrive with bit0 set.
    g_uid[0] &= ~0x01;

    Serial.printf("UID: %02X:%02X:%02X:%02X:%02X:%02X\n",
                  g_uid[0], g_uid[1], g_uid[2], g_uid[3], g_uid[4], g_uid[5]);

    espnow_ready = espnow_init(g_uid);
    if (!espnow_ready) {
        // Keep running so the user can still reconfigure UID over BLE.
        Serial.println("ESP-NOW init FAILED — BLE only, reconfigure UID to retry");
        stickDisplay.showMessage("ESPNOW FAIL (BLE only)", stickDisplay.colorErr());
    } else {
        Serial.println("ESP-NOW initialized");
    }

    osd.begin(g_uid);
    osdTextDisplay.begin(&osd);

    ble_init("HDZeroOSD");
    Serial.println("BLE initialized, advertising...");

    stickDisplay.showStatus(g_uid, false, espnow_ready);

    // Boot counts as activity; without this the panel could sleep before
    // the operator has had a chance to interact at all.
    g_last_activity_ms = millis();
}

void loop() {
    stickDisplay.update();

    // stickDisplay.update() polled M5.update() above, so the wasPressed
    // edges for this tick are fresh. Either button wakes the panel and
    // resets the idle timer. wasPressed() is non-consuming, so the
    // battery-monitor block below still observes the same edge — short
    // press = wake AND silence (silence() no-ops when tier==None, so
    // the two effects don't fight).
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
        // Poll before reacting to button input: a press that happens to
        // fall in the same loop iteration as a tier transition should
        // silence the *new* tier the operator can see on the LCD, not
        // the stale (typically None) tier from the previous poll.
        BatteryMonitor::PollResult bres = batteryMonitor.poll(bnow);
        if (M5.BtnA.wasPressed() || M5.BtnB.wasPressed()) {
            batteryMonitor.silence();
        }
        bool silenceDirty = batteryMonitor.consumeSilencedDirty();
        if (bres.stateChanged || silenceDirty) {
            stickDisplay.setBattery(batteryMonitor.percent(), batteryMonitor.charging());
            uint8_t buf[2];
            batteryMonitor.payload(buf);
            ble_update_battery(buf);
        }
        if (bres.tierChanged) {
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
            }
        }
    }

    if (g_ble_connected != last_ble_state) {
        last_ble_state = g_ble_connected;
        stickDisplay.showStatus(g_uid, g_ble_connected, espnow_ready);
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
    if (g_render_state == RenderState::IDLE && espnow_ready && osdTextDisplay.hasDirty()) {
        requestRender();
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
        portENTER_CRITICAL(&g_sniff_mux);
        memcpy(uid, g_sniff_uid, 6);
        g_sniff_captured = false;
        portEXIT_CRITICAL(&g_sniff_mux);
        Serial.printf("TX UID captured: %02X:%02X:%02X:%02X:%02X:%02X\n",
                      uid[0], uid[1], uid[2], uid[3], uid[4], uid[5]);
        ble_notify_tx_uid(uid);
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
            stickDisplay.showStatus(g_uid, g_ble_connected, espnow_ready);
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

    // --- Power log append ------------------------------------------------
    // Snapshot VBAT + state every 30 s (rollover-safe interval arithmetic).
    // M5.Power.getBatteryVoltage() returns mV; dV/dt across a multi-minute
    // window stands in for instantaneous current draw, which the M5StickS3
    // (pmic_m5pm1, no INA chip) doesn't expose through the M5Unified API.
    // Per-loop is too noisy and would burn the SPIFFS partition; 30 s
    // captures the trend that matters for before/after power deltas.
    {
        uint32_t now = millis();
        if (now - g_power_log_last_ms >= POWER_LOG_INTERVAL_MS) {
            g_power_log_last_ms = now;
            int16_t voltage_mv = M5.Power.getBatteryVoltage();
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
