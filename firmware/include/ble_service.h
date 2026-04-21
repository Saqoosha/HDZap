#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>
#include "espnow_link.h"

#define BLE_SERVICE_UUID        "f47ac10b-58cc-4372-a567-0e02b2c3d479"
#define CHR_UID_CONFIG_UUID     "f47ac10b-58cc-4372-a567-0e02b2c3d481"
#define CHR_BIND_CMD_UUID       "f47ac10b-58cc-4372-a567-0e02b2c3d482"
#define CHR_LAP_TIME_UUID       "f47ac10b-58cc-4372-a567-0e02b2c3d483"
#define CHR_OSD_CONTROL_UUID    "f47ac10b-58cc-4372-a567-0e02b2c3d484"
#define CHR_STATUS_UUID         "f47ac10b-58cc-4372-a567-0e02b2c3d485"

// BLE callback context (Bluedroid's btc_task, typically core 0 under
// Arduino) writes these; Arduino main loop (typically core 1) reads.
// Flags signal edges; scratch fields carry the payload.
//
// Mux-guarded (portMUX; main loop never sees a torn pair):
//   g_staged_uid + g_uid_config_requested     (UID config staging)
//   g_lap_num + g_lap_time_ms + g_lap_count + g_lap_received  (lap frame)
//     — g_lap_count has a secondary role: read unlocked by
//       ble_update_status() for the status-notify payload. Single byte,
//       so the unlocked read is an atomic snapshot of the latest write.
//
// Bare-volatile single-flag — idempotent commands, rapid double-write
// collapses into one edge (which is fine, the action just means
// "do it once"):
//   g_bind_requested, g_osd_clear_requested, g_osd_reset_laps_requested
//
// Bare-volatile state snapshot — written by ServerCallbacks (BLE task),
// read for status-notify payload + main loop LCD update. Single byte, so
// atomic; readers always see the latest posted value:
//   g_ble_connected
inline volatile bool g_bind_requested = false;
inline volatile bool g_lap_received = false;
inline volatile bool g_osd_clear_requested = false;
inline volatile bool g_osd_reset_laps_requested = false;
inline volatile bool g_uid_config_requested = false;

// Lap data staged by LapTimeCallback.
inline volatile uint8_t g_lap_num = 0;
inline volatile uint32_t g_lap_time_ms = 0;

// UID staged by UIDConfigCallback. Applied (NVS save + ESP-NOW reinit) by main loop.
inline uint8_t g_staged_uid[6] = {};

inline portMUX_TYPE g_ble_mux = portMUX_INITIALIZER_UNLOCKED;

// Current UID — owned by main.cpp.
extern uint8_t g_uid[6];

// BLE server state
inline BLEServer *g_ble_server = nullptr;
inline BLECharacteristic *g_status_chr = nullptr;
inline volatile bool g_ble_connected = false;
inline volatile uint8_t g_lap_count = 0;

inline void ble_update_status() {
    if (!g_status_chr) return;
    uint8_t buf[8];
    buf[0] = g_ble_connected ? 1 : 0;
    memcpy(&buf[1], g_uid, 6);
    buf[7] = g_lap_count;
    g_status_chr->setValue(buf, 8);
    g_status_chr->notify();
}

class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer *s) override {
        g_ble_connected = true;
        ble_update_status();
    }
    void onDisconnect(BLEServer *s) override {
        g_ble_connected = false;
        ble_update_status();
        // ESP32 stops advertising on disconnect; re-enable so iPhone can reconnect.
        BLEDevice::startAdvertising();
    }
};

class UIDConfigCallback : public BLECharacteristicCallbacks {
    // Max bind phrase length must match MD5 input staging below AND the iOS
    // client's effective limit; diverging here silently produces different
    // UIDs on the two ends.
    static constexpr size_t kMaxBindPhrase = 63;

    void onWrite(BLECharacteristic *pChr) override {
        std::string val = pChr->getValue();
        if (val.length() < 1) {
            Serial.println("UIDConfig: empty write");
            return;
        }
        uint8_t mode = (uint8_t)val[0];
        uint8_t new_uid[6];

        if (mode == 0x01 && val.length() > 1) {
            size_t len = val.length() - 1;
            // Reject oversized phrases instead of truncating — a truncated
            // MD5 input would produce a UID the iOS side never derives.
            if (len > kMaxBindPhrase) {
                Serial.printf("UIDConfig: bind phrase too long (%u bytes, max %u)\n",
                              (unsigned)len, (unsigned)kMaxBindPhrase);
                return;
            }
            char phrase[kMaxBindPhrase + 1] = {};
            memcpy(phrase, val.data() + 1, len);
            uid_from_bind_phrase(phrase, new_uid);
        } else if (mode == 0x02 && val.length() >= 7) {
            memcpy(new_uid, val.data() + 1, 6);
        } else if (mode == 0x03) {
            esp_read_mac(new_uid, ESP_MAC_WIFI_STA);
        } else {
            // Either an unrecognized mode or a known mode with a short
            // payload (mode 0x01 needs >= 2 bytes, mode 0x02 needs >= 7).
            // Log both fields so iOS protocol skew is diagnosable.
            Serial.printf("UIDConfig: unexpected mode=0x%02X len=%u\n",
                          mode, (unsigned)val.length());
            return;
        }

        new_uid[0] &= ~0x01; // unicast MAC invariant

        portENTER_CRITICAL(&g_ble_mux);
        memcpy(g_staged_uid, new_uid, 6);
        g_uid_config_requested = true;
        portEXIT_CRITICAL(&g_ble_mux);
    }
};

class BindCmdCallback : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChr) override {
        std::string val = pChr->getValue();
        if (val.length() >= 1 && (uint8_t)val[0] == 0x01) {
            g_bind_requested = true;
        }
    }
};

class LapTimeCallback : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChr) override {
        std::string val = pChr->getValue();
        if (val.length() < 5) {
            Serial.printf("LapTime: short payload (%u bytes, need 5)\n",
                          (unsigned)val.length());
            return;
        }
        const uint8_t *d = (const uint8_t *)val.data();

        portENTER_CRITICAL(&g_ble_mux);
        g_lap_num = d[0];
        // Explicit uint32 casts avoid signed-int promotion UB when bit 31 is set.
        g_lap_time_ms = (uint32_t)d[1]
                      | ((uint32_t)d[2] << 8)
                      | ((uint32_t)d[3] << 16)
                      | ((uint32_t)d[4] << 24);
        g_lap_count++;
        g_lap_received = true;
        portEXIT_CRITICAL(&g_ble_mux);
    }
};

class OSDControlCallback : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChr) override {
        std::string val = pChr->getValue();
        if (val.length() < 1) {
            Serial.println("OSDControl: empty write");
            return;
        }
        uint8_t cmd = (uint8_t)val[0];
        if (cmd == 0x01) {
            g_osd_clear_requested = true;
        } else if (cmd == 0x02) {
            g_osd_reset_laps_requested = true;
            // Reset under the mux for symmetry with LapTimeCallback's
            // increment — otherwise concurrent BLE writes could tear.
            portENTER_CRITICAL(&g_ble_mux);
            g_lap_count = 0;
            portEXIT_CRITICAL(&g_ble_mux);
        } else {
            Serial.printf("OSDControl: unknown command 0x%02X\n", cmd);
        }
    }
};

inline void ble_init(const char *device_name = "HDZeroOSD") {
    BLEDevice::init(device_name);
    g_ble_server = BLEDevice::createServer();
    g_ble_server->setCallbacks(new ServerCallbacks());

    BLEService *pService = g_ble_server->createService(BLE_SERVICE_UUID);

    BLECharacteristic *pUID = pService->createCharacteristic(
        CHR_UID_CONFIG_UUID, BLECharacteristic::PROPERTY_WRITE);
    pUID->setCallbacks(new UIDConfigCallback());

    BLECharacteristic *pBind = pService->createCharacteristic(
        CHR_BIND_CMD_UUID, BLECharacteristic::PROPERTY_WRITE);
    pBind->setCallbacks(new BindCmdCallback());

    BLECharacteristic *pLap = pService->createCharacteristic(
        CHR_LAP_TIME_UUID, BLECharacteristic::PROPERTY_WRITE);
    pLap->setCallbacks(new LapTimeCallback());

    BLECharacteristic *pOSD = pService->createCharacteristic(
        CHR_OSD_CONTROL_UUID, BLECharacteristic::PROPERTY_WRITE);
    pOSD->setCallbacks(new OSDControlCallback());

    g_status_chr = pService->createCharacteristic(
        CHR_STATUS_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    g_status_chr->addDescriptor(new BLE2902());

    pService->start();

    BLEAdvertising *pAdv = BLEDevice::getAdvertising();
    pAdv->addServiceUUID(BLE_SERVICE_UUID);
    pAdv->setScanResponse(true);
    BLEDevice::startAdvertising();
}
