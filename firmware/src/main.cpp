#include <Arduino.h>
#include "stick_display.h"
#include "msp.h"
#include "espnow_link.h"
#include "osd.h"
#include "bind.h"
#include "lap_display.h"
#include "nvs_store.h"
#include "ble_service.h"

uint8_t g_uid[6] = {};
static OSD osd;
static LapDisplay lapDisplay;
static StickDisplay stickDisplay;
static bool last_ble_state = false;
static bool espnow_ready = false;

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
// failed packet: a mid-cycle failure (e.g. clear + 3 writes land but
// writeString #4 drops) leaves the goggle OSD buffer in an inconsistent
// partial state. lapDisplay.render() is idempotent — it pulls from the
// authoritative lap history — so a fresh clear+writes+draw restores a
// known-good state regardless of which packet died.
//
// Verify window sizing: a full cycle is up to 10 packets; ESP-NOW
// serializes unicast sends per peer at ~a few ms each plus MAC retry
// time (tens of ms worst case). 200 ms gives comfortable margin without
// making the user wait too long for the feedback strip to settle.
enum class RenderState : uint8_t { IDLE, PENDING, WAITING_ACK };
static RenderState g_render_state = RenderState::IDLE;
static uint32_t g_render_after_ms = 0;
static uint32_t g_render_verify_after_ms = 0;
static uint32_t g_render_fail_baseline = 0;
static uint8_t  g_render_retries_left = 0;

static constexpr uint32_t RENDER_VERIFY_MS        = 200;
static constexpr uint32_t RENDER_RETRY_BACKOFF_MS = 50;
static constexpr uint8_t  MAX_RENDER_RETRIES      = 2;

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
        stickDisplay.showMessage("NVS SAVE FAIL", TFT_RED);
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
    stickDisplay.showStatus(g_uid, g_ble_connected);
    if (!radioOk) {
        stickDisplay.showMessage("ESPNOW FAIL", TFT_RED);
    } else {
        // Success here supersedes any prior "LAPS FULL" / "LAP RENDER
        // FAIL" / "ESPNOW FAIL" strip content; those conditions don't
        // apply to the freshly-committed UID.
        stickDisplay.clearMessage();
        if (wasRadioDown) Serial.println("ESP-NOW recovered");
    }
}

void setup() {
    stickDisplay.begin();
    Serial.begin(115200);
    delay(500); // Wait for USB CDC serial to enumerate before first println.
    Serial.println("\n=== HDZero OSD Lap Timer ===");

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
        stickDisplay.showMessage("ESPNOW FAIL (BLE only)", TFT_RED);
    } else {
        Serial.println("ESP-NOW initialized");
    }

    osd.begin(g_uid);
    lapDisplay.begin(&osd);

    ble_init("HDZeroOSD");
    Serial.println("BLE initialized, advertising...");

    stickDisplay.showStatus(g_uid, false);
}

void loop() {
    stickDisplay.update();

    if (g_ble_connected != last_ble_state) {
        last_ble_state = g_ble_connected;
        stickDisplay.showStatus(g_uid, g_ble_connected);
    }

    if (g_uid_config_requested) {
        applyStagedUid();
    }

    if (g_bind_requested) {
        g_bind_requested = false;
        Serial.println("Sending bind packet...");
        stickDisplay.showMessage("BINDING...", TFT_YELLOW);
        bool ok = send_bind_packet(g_uid);
        Serial.printf("Bind packet %s\n", ok ? "sent" : "FAILED");
        stickDisplay.showMessage(ok ? "BIND SENT" : "BIND FAIL",
                                 ok ? TFT_GREEN : TFT_RED);
    }

    if (g_lap_received) {
        uint8_t num;
        uint32_t ms;
        portENTER_CRITICAL(&g_ble_mux);
        num = g_lap_num;
        ms = g_lap_time_ms;
        g_lap_received = false;
        portEXIT_CRITICAL(&g_ble_mux);

        Serial.printf("Lap %d: %lu ms\n", num, (unsigned long)ms);
        bool stored = lapDisplay.addLap(num, ms);
        stickDisplay.showLap(num, ms);
        // Priority: radio dead > storage full > request a retryable
        // dispatch. ESPNOW DOWN matters most (nothing reaches the
        // goggle); LAPS FULL means storage is capped (lap lives on the
        // phone but not here); otherwise hand off to the render state
        // machine below, which handles dispatch, verify via send
        // callback, retry, and the final success/failure strip.
        if (!espnow_ready) {
            stickDisplay.showMessage("ESPNOW DOWN", TFT_RED);
        } else if (!stored) {
            stickDisplay.showMessage("LAPS FULL", TFT_ORANGE);
        } else {
            // Optimistic: a successful new lap should not keep a stale
            // "LAP RENDER FAIL" / "OSD LOST" visible. If the fresh
            // cycle fails, the state machine re-populates the strip.
            stickDisplay.clearMessage();
            requestRender();
        }
    }

    // --- Render dispatch -------------------------------------------------
    // Enter on PENDING once the scheduled dispatch time arrives. Snapshot
    // the failure counter as a baseline, fire the full cycle, and move to
    // WAITING_ACK so the verify block below can judge MAC-level delivery.
    if (g_render_state == RenderState::PENDING && millis() >= g_render_after_ms) {
        if (!espnow_ready) {
            // Radio died between request and dispatch — nothing to send.
            // Lap handler already surfaced ESPNOW DOWN when relevant;
            // just drop the cycle so we don't spin on PENDING.
            cancelRender();
        } else {
            g_render_fail_baseline = g_espnow_sent_fail;
            bool queued = lapDisplay.render();
            if (!queued) {
                // esp_now_send returned non-OK for at least one packet in
                // the cycle (queue-level failure — typically NO_MEM or
                // NOT_FOUND). Back off and retry; NEW-38 (esp_err_t
                // propagation) will later let us distinguish transient
                // from terminal errors here.
                if (g_render_retries_left > 0) {
                    g_render_retries_left--;
                    g_render_after_ms = millis() + RENDER_RETRY_BACKOFF_MS;
                    stickDisplay.showMessage("RETRY", TFT_ORANGE);
                } else {
                    cancelRender();
                    Serial.println("Render queue failed, retries exhausted");
                    stickDisplay.showMessage("OSD LOST", TFT_RED);
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
            // All packets delivered at the MAC layer. Strip was
            // optimistically cleared on dispatch; nothing to redraw.
            g_render_state = RenderState::IDLE;
        } else if (g_render_retries_left > 0) {
            g_render_retries_left--;
            g_render_state = RenderState::PENDING;
            g_render_after_ms = millis() + RENDER_RETRY_BACKOFF_MS;
            Serial.printf("ESP-NOW delivery: %u fail(s), retrying (%u left)\n",
                          (unsigned)newFails, g_render_retries_left);
            stickDisplay.showMessage("RETRY", TFT_ORANGE);
        } else {
            cancelRender();
            Serial.printf("ESP-NOW delivery gave up after %u retries (%u fail(s) last cycle)\n",
                          MAX_RENDER_RETRIES, (unsigned)newFails);
            stickDisplay.showMessage("OSD LOST", TFT_RED);
        }
    }

    if (g_osd_clear_requested) {
        g_osd_clear_requested = false;
        // Clearing the OSD and then letting a pending render repopulate
        // it would undo the user's intent, so cancel any in-flight cycle
        // first. The next lap will re-arm requestRender() naturally.
        cancelRender();
        if (!espnow_ready) {
            stickDisplay.showMessage("CLEAR: ESPNOW DOWN", TFT_ORANGE);
        } else if (!(osd.clear() && osd.draw())) {
            stickDisplay.showMessage("CLEAR FAIL", TFT_RED);
        } else {
            stickDisplay.showMessage("OSD CLEARED", TFT_CYAN);
        }
    }

    if (g_osd_test_requested) {
        g_osd_test_requested = false;
        // Debug button: one-shot "does ESP-NOW reach the goggle?" probe.
        // Bypass the lap state machine (test should not repopulate a lap
        // screen the user just cleared) and fire a single clear+write+draw
        // cycle with synchronous delivery verification.
        cancelRender();
        if (!espnow_ready) {
            stickDisplay.showMessage("TEST: ESPNOW DOWN", TFT_RED);
        } else {
            uint32_t failBefore = g_espnow_sent_fail;
            bool queued = osd.clear()
                       && osd.writeString(0, 0, "HDZERO TEST")
                       && osd.draw();
            if (!queued) {
                stickDisplay.showMessage("TEST QUEUE FAIL", TFT_RED);
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
                    stickDisplay.showMessage("TEST OK", TFT_GREEN);
                } else {
                    Serial.printf("Test OSD: %u packet(s) lost\n", (unsigned)newFails);
                    stickDisplay.showMessage("TEST LOST", TFT_RED);
                }
            }
        }
    }

    if (g_osd_reset_laps_requested) {
        g_osd_reset_laps_requested = false;
        // Reset invalidates the lap history; a pending render would try
        // to re-draw rows that no longer exist (or the "NO LAPS"
        // placeholder on top of a freshly-cleared OSD), so drop the
        // cycle before touching either side.
        cancelRender();
        lapDisplay.clear();
        if (!espnow_ready) {
            Serial.println("Laps reset (local only; ESP-NOW down)");
            stickDisplay.showMessage("RESET: ESPNOW DOWN", TFT_ORANGE);
        } else if (!(osd.clear() && osd.draw())) {
            Serial.println("Laps reset (OSD send failed)");
            stickDisplay.showMessage("RESET FAIL", TFT_RED);
        } else {
            Serial.println("Laps reset");
            stickDisplay.showStatus(g_uid, g_ble_connected);
            // Drop any stale "LAPS FULL" / "LAP RENDER FAIL" from the
            // sticky strip — a fresh reset is a clean slate.
            stickDisplay.clearMessage();
        }
    }

    delay(10);
}
