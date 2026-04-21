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

static void applyStagedUid() {
    uint8_t new_uid[6];
    portENTER_CRITICAL(&g_ble_mux);
    memcpy(new_uid, (const void *)g_staged_uid, 6);
    g_uid_config_requested = false;
    portEXIT_CRITICAL(&g_ble_mux);

    // Persist first, then reconfigure the radio. If NVS save fails we roll
    // g_uid back so runtime and persistent state stay in sync — otherwise a
    // reboot would silently revert to the old UID and the goggle stops
    // receiving for no user-visible reason.
    uint8_t prev_uid[6];
    memcpy(prev_uid, g_uid, 6);
    memcpy(g_uid, new_uid, 6);
    if (!nvs_store::saveUid(g_uid)) {
        memcpy(g_uid, prev_uid, 6);
        Serial.println("NVS save failed — UID change reverted");
        stickDisplay.showMessage("NVS SAVE FAIL\nUID reverted", TFT_RED);
        return;
    }

    if (espnow_ready) {
        if (!espnow_reinit(g_uid)) {
            espnow_ready = false;
            Serial.println("ESP-NOW reinit failed");
            stickDisplay.showMessage("ESPNOW FAIL", TFT_RED);
        }
    } else {
        // espnow_ready is false — espnow_init recovers from a partial prior
        // init (see its docstring), so a fresh attempt with the new UID is
        // the right move.
        espnow_ready = espnow_init(g_uid);
        if (!espnow_ready) {
            Serial.println("ESP-NOW init still failing after UID change");
            stickDisplay.showMessage("ESPNOW FAIL", TFT_RED);
        }
    }
    stickDisplay.showStatus(g_uid, g_ble_connected);
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
        stickDisplay.showMessage("ESPNOW FAIL\nBLE only", TFT_RED);
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
        lapDisplay.addLap(num, ms);
        if (espnow_ready) lapDisplay.render();
        stickDisplay.showLap(num, ms);
    }

    if (g_osd_clear_requested) {
        g_osd_clear_requested = false;
        if (!espnow_ready) {
            stickDisplay.showMessage("CLEAR: ESPNOW DOWN", TFT_ORANGE);
        } else if (!(osd.clear() && osd.draw())) {
            stickDisplay.showMessage("CLEAR FAIL", TFT_RED);
        } else {
            stickDisplay.showMessage("OSD CLEARED", TFT_CYAN);
        }
    }

    if (g_osd_reset_laps_requested) {
        g_osd_reset_laps_requested = false;
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
        }
    }

    delay(10);
}
