#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Preferences.h>
#include "espnow_link.h"

#define BLE_SERVICE_UUID        "f47ac10b-58cc-4372-a567-0e02b2c3d479"
#define CHR_UID_CONFIG_UUID     "f47ac10b-58cc-4372-a567-0e02b2c3d481"
#define CHR_BIND_CMD_UUID       "f47ac10b-58cc-4372-a567-0e02b2c3d482"
#define CHR_LAP_TIME_UUID       "f47ac10b-58cc-4372-a567-0e02b2c3d483"
#define CHR_OSD_CONTROL_UUID    "f47ac10b-58cc-4372-a567-0e02b2c3d484"
#define CHR_STATUS_UUID         "f47ac10b-58cc-4372-a567-0e02b2c3d485"

// Global volatile flags for BLE callback -> main loop communication
volatile bool g_bind_requested = false;
volatile bool g_lap_received = false;
volatile bool g_osd_clear_requested = false;
volatile bool g_osd_reset_laps_requested = false;

// Lap data from BLE
volatile uint8_t g_lap_num = 0;
volatile uint32_t g_lap_time_ms = 0;

// Current UID (shared with main)
extern uint8_t g_uid[6];

// Extern declarations for functions provided by other agents
extern void send_elrs_bind_packet();

// NVS persistence
static Preferences nvs_prefs;

inline bool nvs_save_uid(const uint8_t uid[6]) {
    nvs_prefs.begin("hdzero", false);
    size_t written = nvs_prefs.putBytes("uid", uid, 6);
    nvs_prefs.end();
    return written == 6;
}

inline bool nvs_load_uid(uint8_t uid[6]) {
    nvs_prefs.begin("hdzero", true);
    size_t read = nvs_prefs.getBytes("uid", uid, 6);
    nvs_prefs.end();
    return read == 6;
}

// BLE state
static BLEServer *pServer = nullptr;
static BLECharacteristic *pStatusChr = nullptr;
static volatile bool g_ble_connected = false;
static volatile uint8_t g_lap_count = 0;

class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer *s) override {
        g_ble_connected = true;
        update_status();
    }
    void onDisconnect(BLEServer *s) override {
        g_ble_connected = false;
        update_status();
        BLEDevice::startAdvertising();
    }
    void update_status() {
        if (!pStatusChr) return;
        uint8_t buf[8];
        buf[0] = g_ble_connected ? 1 : 0;
        memcpy(&buf[1], g_uid, 6);
        buf[7] = g_lap_count;
        pStatusChr->setValue(buf, 8);
        pStatusChr->notify();
    }
};

class UIDConfigCallback : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChr) override {
        std::string val = pChr->getValue();
        if (val.length() < 1) return;
        uint8_t mode = (uint8_t)val[0];
        uint8_t new_uid[6];

        if (mode == 0x01 && val.length() > 1) {
            // Bind phrase mode
            char phrase[64] = {};
            size_t len = val.length() - 1;
            if (len > 63) len = 63;
            memcpy(phrase, val.data() + 1, len);
            uid_from_bind_phrase(phrase, new_uid);
        } else if (mode == 0x02 && val.length() >= 7) {
            // Manual UID
            memcpy(new_uid, val.data() + 1, 6);
        } else if (mode == 0x03) {
            // Use ESP32's own MAC
            esp_read_mac(new_uid, ESP_MAC_WIFI_STA);
            new_uid[0] &= ~0x01;
        } else {
            return;
        }

        memcpy(g_uid, new_uid, 6);
        nvs_save_uid(g_uid);
        espnow_reinit(g_uid);
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
        if (val.length() < 5) return;
        const uint8_t *d = (const uint8_t *)val.data();
        g_lap_num = d[0];
        g_lap_time_ms = d[1] | (d[2] << 8) | (d[3] << 16) | (d[4] << 24);
        g_lap_count++;
        g_lap_received = true;
    }
};

class OSDControlCallback : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChr) override {
        std::string val = pChr->getValue();
        if (val.length() < 1) return;
        if ((uint8_t)val[0] == 0x01) g_osd_clear_requested = true;
        if ((uint8_t)val[0] == 0x02) {
            g_osd_reset_laps_requested = true;
            g_lap_count = 0;
        }
    }
};

inline void ble_init(const char *device_name = "HDZeroOSD") {
    BLEDevice::init(device_name);
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new ServerCallbacks());

    BLEService *pService = pServer->createService(BLE_SERVICE_UUID);

    // UID Config
    BLECharacteristic *pUID = pService->createCharacteristic(
        CHR_UID_CONFIG_UUID, BLECharacteristic::PROPERTY_WRITE);
    pUID->setCallbacks(new UIDConfigCallback());

    // Bind Command
    BLECharacteristic *pBind = pService->createCharacteristic(
        CHR_BIND_CMD_UUID, BLECharacteristic::PROPERTY_WRITE);
    pBind->setCallbacks(new BindCmdCallback());

    // Lap Time
    BLECharacteristic *pLap = pService->createCharacteristic(
        CHR_LAP_TIME_UUID, BLECharacteristic::PROPERTY_WRITE);
    pLap->setCallbacks(new LapTimeCallback());

    // OSD Control
    BLECharacteristic *pOSD = pService->createCharacteristic(
        CHR_OSD_CONTROL_UUID, BLECharacteristic::PROPERTY_WRITE);
    pOSD->setCallbacks(new OSDControlCallback());

    // Status (read + notify)
    pStatusChr = pService->createCharacteristic(
        CHR_STATUS_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    pStatusChr->addDescriptor(new BLE2902());

    pService->start();

    BLEAdvertising *pAdv = BLEDevice::getAdvertising();
    pAdv->addServiceUUID(BLE_SERVICE_UUID);
    pAdv->setScanResponse(true);
    BLEDevice::startAdvertising();
}
