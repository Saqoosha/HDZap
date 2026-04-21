#include <Arduino.h>
#include "stick_display.h"
#include "msp.h"
#include "espnow_link.h"
#include "osd.h"
#include "bind.h"
#include "lap_display.h"
#include "ble_service.h"

uint8_t g_uid[6] = {};
static OSD osd;
static LapDisplay lapDisplay;
static StickDisplay stickDisplay;
static bool last_ble_state = false;

void send_elrs_bind_packet() {
    send_bind_packet(g_uid);
}

void setup() {
    stickDisplay.begin();
    Serial.begin(115200);
    delay(500);
    Serial.println("\n=== HDZero OSD Lap Timer ===");

    if (!nvs_load_uid(g_uid)) {
        esp_read_mac(g_uid, ESP_MAC_WIFI_STA);
        g_uid[0] &= ~0x01;
        Serial.println("No saved UID, using MAC");
    }

    Serial.printf("UID: %02X:%02X:%02X:%02X:%02X:%02X\n",
                  g_uid[0], g_uid[1], g_uid[2], g_uid[3], g_uid[4], g_uid[5]);

    if (!espnow_init(g_uid)) {
        Serial.println("ESP-NOW init FAILED!");
        stickDisplay.showMessage("ESP-NOW FAIL", TFT_RED);
        while (true) delay(1000);
    }
    Serial.println("ESP-NOW initialized");

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

    if (g_bind_requested) {
        g_bind_requested = false;
        Serial.println("Sending bind packet...");
        stickDisplay.showMessage("BINDING...", TFT_YELLOW);
        send_elrs_bind_packet();
        Serial.println("Bind packet sent");
        stickDisplay.showMessage("BIND SENT", TFT_GREEN);
    }

    if (g_lap_received) {
        g_lap_received = false;
        uint8_t num = g_lap_num;
        uint32_t ms = g_lap_time_ms;
        Serial.printf("Lap %d: %lu ms\n", num, (unsigned long)ms);
        lapDisplay.addLap(num, ms);
        lapDisplay.render();
        stickDisplay.showLap(num, ms);
    }

    if (g_osd_clear_requested) {
        g_osd_clear_requested = false;
        osd.clear();
        osd.draw();
        stickDisplay.showMessage("OSD CLEARED", TFT_CYAN);
    }

    if (g_osd_reset_laps_requested) {
        g_osd_reset_laps_requested = false;
        lapDisplay.clear();
        osd.clear();
        osd.draw();
        Serial.println("Laps reset");
        stickDisplay.showStatus(g_uid, g_ble_connected);
    }

    delay(10);
}
