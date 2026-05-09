#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_bt.h>          // esp_ble_tx_power_set, ESP_PWR_LVL_*
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>
#include "espnow_link.h"
#include "tx_sniff.h"
#include "telemetry_sniff.h"
#include "nvs_store.h"   // loadSleepMinutes() for the sleep-config char's read seed
#include "flight_battery_telemetry.h"

// Service UUID bumped ...d491 → ...d492 in lockstep with iOS to defeat
// CoreBluetooth's per-peripheral GATT cache. This bump adds
// CHR_FLIGHT_BATTERY (`…d48d`) while preserving CHR_TELEMETRY_DEBUG (`…d48c`)
// from the Backpack Telemetry Debug subview.
//
// History: d48c → d48d (CHR_OSD_LAYOUT WRITE_NR), d48d → d48e (CHR_DEVICE_NAME),
//          d48e → d490 (CHR_FW_VERSION), d490 → d491 (CHR_TELEMETRY_DEBUG),
//          d491 → d492 (CHR_FLIGHT_BATTERY).
#define BLE_SERVICE_UUID         "f47ac10b-58cc-4372-a567-0e02b2c3d492"
#define CHR_UID_CONFIG_UUID      "f47ac10b-58cc-4372-a567-0e02b2c3d481"
#define CHR_BIND_CMD_UUID        "f47ac10b-58cc-4372-a567-0e02b2c3d482"
#define CHR_OSD_CONTROL_UUID     "f47ac10b-58cc-4372-a567-0e02b2c3d484"
#define CHR_STATUS_UUID          "f47ac10b-58cc-4372-a567-0e02b2c3d485"
#define CHR_TX_SNIFF_UUID        "f47ac10b-58cc-4372-a567-0e02b2c3d486"
#define CHR_OSD_TEXT_UUID        "f47ac10b-58cc-4372-a567-0e02b2c3d487"
#define CHR_BATTERY_UUID         "f47ac10b-58cc-4372-a567-0e02b2c3d488"
#define CHR_DEVICE_NAME_UUID     "f47ac10b-58cc-4372-a567-0e02b2c3d489"
#define CHR_SLEEP_CONFIG_UUID    "f47ac10b-58cc-4372-a567-0e02b2c3d48a"
#define CHR_OSD_LAYOUT_UUID      "f47ac10b-58cc-4372-a567-0e02b2c3d48b"
#define CHR_FW_VERSION_UUID      "f47ac10b-58cc-4372-a567-0e02b2c3d48f"
#define CHR_TELEMETRY_DEBUG_UUID "f47ac10b-58cc-4372-a567-0e02b2c3d48c"
/// Flight pack CRSF Battery (0x08) from Backpack ESP-NOW telemetry.
#define CHR_FLIGHT_BATTERY_UUID "f47ac10b-58cc-4372-a567-0e02b2c3d48d"

#ifndef FIRMWARE_VERSION
#define FIRMWARE_VERSION "unknown"
#endif

// BLE callback context (Bluedroid's btc_task, typically core 0 under
// Arduino) writes these; Arduino main loop (typically core 1) reads.
// Flags signal edges; scratch fields carry the payload.
//
// Mux-guarded (portMUX; main loop never sees a torn pair):
//   g_staged_uid + g_uid_config_requested     (UID config staging)
//   g_osd_text_rows + g_osd_text_dirty        (iOS-owned goggle OSD text;
//       per-row staging with a dirty bitmask so iOS can refresh just one
//       row at a time. The goggle's MSP DisplayPort overlay buffer keeps
//       prior rows between writes, so a single dirty row only costs
//       writeString + draw (2 ESP-NOW packets) — TIME LEFT can tick
//       every second without rerendering the lap/avg/diff rows below)
//   g_uid                                     (6 bytes; main loop writes
//       under the mux in applyStagedUid, BLE task reads under the mux in
//       ble_update_status so the notify frame never carries a torn pair)
//
// Bare-volatile single-flag — idempotent commands, rapid double-write
// collapses into one edge (which is fine, the action just means
// "do it once"):
//   g_bind_requested, g_osd_clear_requested, g_osd_reset_laps_requested,
//   g_osd_test_requested,
//   g_sniff_start_requested, g_sniff_stop_requested  (defined in tx_sniff.h,
//       written by TXSniffCallback, consumed by main loop)
//
// Bare-volatile state snapshot — written by ServerCallbacks (BLE task),
// read for status-notify payload + main loop LCD update. Single byte, so
// atomic; readers always see the latest posted value:
//   g_ble_connected
inline volatile bool g_bind_requested = false;
inline volatile bool g_osd_clear_requested = false;
inline volatile bool g_osd_reset_laps_requested = false;
inline volatile bool g_osd_test_requested = false;
inline volatile bool g_uid_config_requested = false;

inline constexpr uint8_t OSD_TEXT_ROW_COUNT = 4;
inline constexpr uint8_t OSD_TEXT_ROW_MAX = 50;  // OSD_COLS — full grid width
inline char g_osd_text_rows[OSD_TEXT_ROW_COUNT][OSD_TEXT_ROW_MAX + 1] = {};
// Bitmask of rows that have new content waiting for the main loop to
// dispatch. Cleared after the loop snapshots and renders. Bit i = row i.
inline volatile uint8_t g_osd_text_dirty = 0;

// UID staged by UIDConfigCallback. Applied (NVS save + ESP-NOW reinit) by main loop.
inline uint8_t g_staged_uid[6] = {};

inline portMUX_TYPE g_ble_mux = portMUX_INITIALIZER_UNLOCKED;

// Current UID — owned by main.cpp.
extern uint8_t g_uid[6];

// BLE server state
inline BLEServer *g_ble_server = nullptr;
inline BLECharacteristic *g_status_chr = nullptr;
inline BLECharacteristic *g_tx_sniff_chr = nullptr;
inline BLECharacteristic *g_battery_chr = nullptr;
inline BLECharacteristic *g_telemetry_chr = nullptr;
inline BLECharacteristic *g_flight_battery_chr = nullptr;
inline volatile bool g_ble_connected = false;
// Last Test OSD outcome, surfaced via status notify so the iOS pairing
// flow can verify a fresh bind landed without asking the user to look at
// the goggle. Encodes: 0 = no test yet (or pending), 1 = OK (all packets
// MAC-acked), 2 = LOST (some delivery failed). Single-byte volatile is
// sufficient — written by the main loop after Test OSD completes, read
// (under g_ble_mux for atomicity with the rest of the status frame) by
// ble_update_status.
inline volatile uint8_t g_last_test_result = 0;

// Deep-sleep timeout config (issue #5 phase 3). 1 byte = minutes,
// 0 = disabled. iOS writes a single byte; main loop applies + persists
// on the rising edge of g_sleep_minutes_changed.
inline volatile bool g_sleep_minutes_changed = false;
inline volatile uint8_t g_sleep_minutes_pending = 0;

inline void ble_update_status() {
    if (!g_status_chr) return;
    uint8_t buf[8];
    // g_uid is mutated non-atomically by the main loop (applyStagedUid);
    // take the mux so the status-notify frame never carries a torn pair
    // of old/new bytes during a UID change. g_last_test_result is also
    // read here for atomicity with the rest of the frame.
    portENTER_CRITICAL(&g_ble_mux);
    buf[0] = g_ble_connected ? 1 : 0;
    memcpy(&buf[1], g_uid, 6);
    buf[7] = g_last_test_result;
    portEXIT_CRITICAL(&g_ble_mux);
    g_status_chr->setValue(buf, 8);
    g_status_chr->notify();
}

class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer *s, esp_ble_gatts_cb_param_t *param) override {
        g_ble_connected = true;
        memset(&g_flight_battery_last_sent, 0xFF, sizeof(g_flight_battery_last_sent));
        ble_update_status();
        // Issue #5 phase 2 redux: ask iOS for low-power conn params.
        // 30-50 ms interval, latency 4 -> peripheral wakes 1/5 events
        // when idle (effective ~250 ms), 4 s supervision timeout fits
        // Apple Accessory Design Guidelines and survives the 30 s+ idle
        // windows we see when the operator isn't pushing laps.
        // updateConnParams takes 1.25 ms units for intervals and
        // 10 ms units for the timeout.
        s->updateConnParams(param->connect.remote_bda,
                            24,   // min interval = 30 ms (24 * 1.25)
                            40,   // max interval = 50 ms (40 * 1.25)
                            4,    // slave latency = skip up to 4 events
                            400); // supervision timeout = 4 s (400 * 10 ms)
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

class TXSniffCallback : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChr) override {
        std::string val = pChr->getValue();
        if (val.length() < 1) return;
        uint8_t cmd = (uint8_t)val[0];
        if (cmd == 0x01) g_sniff_start_requested = true;
        else if (cmd == 0x00) g_sniff_stop_requested = true;
    }
};

class TelemetryDebugCallback : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChr) override {
        std::string val = pChr->getValue();
        if (val.length() < 1) return;
        uint8_t cmd = (uint8_t)val[0];
        // Same start/stop wire format as TX sniff: 0x01=start, 0x00=stop.
        // Mutual exclusion with TX sniff (they share the one ESP-NOW
        // recv-callback slot) is enforced in main.cpp's flag handler,
        // not here — keeping the callback identical across the two
        // sniff modes makes the wire protocol uniform and the start
        // ordering decision explicit at the consumer site.
        if (cmd == 0x01) telemetry_sniff::g_telemetry_start_requested = true;
        else if (cmd == 0x00) telemetry_sniff::g_telemetry_stop_requested = true;
    }
};

inline void ble_notify_tx_uid(const uint8_t uid[6]) {
    if (!g_tx_sniff_chr) return;
    g_tx_sniff_chr->setValue(const_cast<uint8_t *>(uid), 6);
    g_tx_sniff_chr->notify();
}

/// Push a single telemetry packet record (RECORD_SIZE bytes, layout
/// documented in telemetry_sniff.h) to iOS. Caller (main.cpp) owns
/// the throttle decision — this helper just mirrors bytes onto the
/// notify channel, mirroring the ble_update_battery / ble_notify_tx_uid
/// pattern. Same null-guard behavior as ble_update_battery: a missing
/// characteristic (createCharacteristic returned nullptr at boot due to
/// numHandles overflow) logs once and silently drops, so the main loop
/// keeps running.
inline void ble_notify_telemetry_packet(const uint8_t record[telemetry_sniff::RECORD_SIZE]) {
    if (!g_telemetry_chr) {
        static bool warned = false;
        if (!warned) {
            Serial.println("ble_notify_telemetry_packet: g_telemetry_chr is null (GATT setup failed?)");
            warned = true;
        }
        return;
    }
    g_telemetry_chr->setValue(const_cast<uint8_t *>(record), telemetry_sniff::RECORD_SIZE);
    g_telemetry_chr->notify();
}

/// Push the latest battery payload to the iOS app. Caller (main.cpp) is
/// responsible for the change-gate; this helper just mirrors the bytes
/// to the BLE notify channel. The 2-byte payload format is documented in
/// `battery_monitor.h::payload`.
inline void ble_update_battery(const uint8_t payload[2]) {
    if (!g_battery_chr) {
        // Reachable if `createCharacteristic` returned nullptr at boot
        // (numHandles overflow regression — see `ble_init` for the trap
        // we already hit once). Logging once-per-boot surfaces a future
        // GATT setup regression that would otherwise silently drop every
        // battery push; matches the project's "fail loud" convention.
        static bool warned = false;
        if (!warned) {
            Serial.println("ble_update_battery: g_battery_chr is null (GATT setup failed?)");
            warned = true;
        }
        return;
    }
    g_battery_chr->setValue(const_cast<uint8_t *>(payload), 2);
    g_battery_chr->notify();
}

/// CRSF Battery (0x08) mirrored to iOS. v1 LE layout:
/// `[ver:1][flags:1][volt_dv:2][curr_da:2][mah:3][rem:1]`.
inline void ble_maybe_notify_flight_battery(const FlightBatterySampleRaw &s) {
    if (!g_flight_battery_chr) {
        static bool warned = false;
        if (!warned) {
            Serial.println("ble_maybe_notify_flight_battery: g_flight_battery_chr null (GATT overflow?)");
            warned = true;
        }
        return;
    }
    if (!g_ble_connected) {
        return;
    }
    if (s.voltage_dv == g_flight_battery_last_sent.voltage_dv &&
        s.current_da == g_flight_battery_last_sent.current_da &&
        s.consumed_mah == g_flight_battery_last_sent.consumed_mah &&
        s.remaining_pct == g_flight_battery_last_sent.remaining_pct) {
        return;
    }
    g_flight_battery_last_sent = s;
    uint8_t buf[10];
    buf[0] = 1; // schema version
    buf[1] = 0; // flags
    uint16_t v = static_cast<uint16_t>(s.voltage_dv);
    uint16_t c = static_cast<uint16_t>(s.current_da);
    uint32_t mah = static_cast<uint32_t>(s.consumed_mah) & 0x00FFFFFFu;
    buf[2] = static_cast<uint8_t>(v);
    buf[3] = static_cast<uint8_t>(v >> 8);
    buf[4] = static_cast<uint8_t>(c);
    buf[5] = static_cast<uint8_t>(c >> 8);
    buf[6] = static_cast<uint8_t>(mah);
    buf[7] = static_cast<uint8_t>(mah >> 8);
    buf[8] = static_cast<uint8_t>(mah >> 16);
    buf[9] = static_cast<uint8_t>(s.remaining_pct);
    g_flight_battery_chr->setValue(buf, sizeof(buf));
    g_flight_battery_chr->notify();
}

class SleepConfigCallback : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChr) override {
        std::string val = pChr->getValue();
        if (val.length() < 1) {
            Serial.println("SleepConfig: empty write");
            return;
        }
        uint8_t mins = (uint8_t)val[0];
        // Stage under the mux so a second BLE write between the loop's
        // flag-test and value-read can't be silently dropped (matches
        // the OSD-text per-row staging pattern). uint8_t reads are
        // atomic on ESP32-S3 so the byte itself isn't tearable; the
        // mux is for the flag+payload pair, not the byte.
        portENTER_CRITICAL(&g_ble_mux);
        g_sleep_minutes_pending = mins;
        g_sleep_minutes_changed = true;
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
        } else if (cmd == 0x03) {
            g_osd_test_requested = true;
        } else {
            Serial.printf("OSDControl: unknown command 0x%02X\n", cmd);
        }
    }
};

class OSDTextCallback : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChr) override {
        std::string val = pChr->getValue();
        // Reject row-only writes. iOS always pads each row to a fixed
        // width before sending, so an empty-text payload only reaches
        // here through a buggy caller — rather than silently staging
        // an empty string and emitting a 2-packet "do nothing" cycle
        // that doesn't visibly clear the prior row, fail loud.
        if (val.length() < 2) {
            Serial.printf("OSDText: short payload (%u bytes, need row + text)\n",
                          (unsigned)val.length());
            return;
        }

        uint8_t row = (uint8_t)val[0];
        if (row >= OSD_TEXT_ROW_COUNT) {
            Serial.printf("OSDText: row out of range (%u)\n", row);
            return;
        }

        size_t len = val.length() - 1;
        if (len > OSD_TEXT_ROW_MAX) {
            Serial.printf("OSDText: row %u too long (%u bytes, max %u)\n",
                          row, (unsigned)len, OSD_TEXT_ROW_MAX);
            return;
        }

        portENTER_CRITICAL(&g_ble_mux);
        memcpy(g_osd_text_rows[row], val.data() + 1, len);
        g_osd_text_rows[row][len] = 0;
        g_osd_text_dirty |= (uint8_t)(1 << row);
        portEXIT_CRITICAL(&g_ble_mux);
    }
};

// Diagnostic GAP handler — surfaces conn-param negotiation outcome
// (iOS may reject our request and pick its own) and advertising-start
// failures so an "I can't see the device" complaint has a serial
// breadcrumb. Status != 0 on UPDATE_CONN_PARAMS means the LL rejected
// our request; in that case phase 2 redux's interval/latency savings
// silently revert to whatever the central chose.
inline void _ble_gap_diag_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param) {
    if (event == ESP_GAP_BLE_UPDATE_CONN_PARAMS_EVT) {
        const auto& u = param->update_conn_params;
        if (u.status != 0) {
            Serial.printf("BLE conn params REJECTED: status=%d (central picked its own params)\n",
                          (int)u.status);
        }
        Serial.printf("BLE conn params: interval=%u (%.2f ms) latency=%u timeout=%u (%u ms)\n",
                      (unsigned)u.conn_int,
                      u.conn_int * 1.25,
                      (unsigned)u.latency,
                      (unsigned)u.timeout,
                      (unsigned)u.timeout * 10);
    } else if (event == ESP_GAP_BLE_ADV_START_COMPLETE_EVT) {
        if (param->adv_start_cmpl.status != ESP_BT_STATUS_SUCCESS) {
            Serial.printf("BLE adv start FAILED: status=%d (peripheral invisible)\n",
                          (int)param->adv_start_cmpl.status);
        }
    }
}

inline void ble_init(const char *device_name = "HDZeroOSD") {
    BLEDevice::init(device_name);
    BLEDevice::setCustomGapHandler(_ble_gap_diag_handler);

    // Issue #5 phase 2 redux: drop BLE TX power from the +9 dBm Arduino
    // default to 0 dBm. The phone is on the operator's table, ~1-2 m
    // away — high TX is wasted and the radio current scales with power.
    // Apply to ADV and SCAN; CONN_HDL0 is intentionally NOT set here
    // because per the ESP-IDF docs the per-connection-handle override
    // is only valid AFTER the connection completes. ESP_BLE_PWR_TYPE_DEFAULT
    // covers the connected case. A loud per-call check makes a future
    // controller-state regression surface in serial instead of silently
    // running at the +9 dBm default.
    auto setBleTxOrLog = [](esp_ble_power_type_t t, esp_power_level_t lvl, const char* name) {
        esp_err_t e = esp_ble_tx_power_set(t, lvl);
        if (e != ESP_OK) {
            Serial.printf("BLE TX power: %s set failed (%d)\n", name, (int)e);
        }
    };
    setBleTxOrLog(ESP_BLE_PWR_TYPE_DEFAULT, ESP_PWR_LVL_N0, "DEFAULT");
    setBleTxOrLog(ESP_BLE_PWR_TYPE_ADV,     ESP_PWR_LVL_N0, "ADV");
    setBleTxOrLog(ESP_BLE_PWR_TYPE_SCAN,    ESP_PWR_LVL_N0, "SCAN");

    // Verify the controller accepted the requested levels — getter
    // reflects the runtime state, not the request.
    Serial.printf("BLE TX power: DEFAULT=%d ADV=%d SCAN=%d (0=N0/0dBm, 11=P9/+9dBm)\n",
                  esp_ble_tx_power_get(ESP_BLE_PWR_TYPE_DEFAULT),
                  esp_ble_tx_power_get(ESP_BLE_PWR_TYPE_ADV),
                  esp_ble_tx_power_get(ESP_BLE_PWR_TYPE_SCAN));

    g_ble_server = BLEDevice::createServer();
    g_ble_server->setCallbacks(new ServerCallbacks());

    // numHandles must cover `1 (service decl) + 2 per characteristic +
    // 1 per BLE2902 descriptor`. createService() defaults to 15 and then
    // silently drops overflow characteristics — last visible symptom was
    // iOS only seeing 5 of 8 chars after we added battery / TX sniff.
    // 40 leaves comfortable headroom; recompute and bump if a future GATT
    // addition pushes the count past ~36.
    BLEService *pService = g_ble_server->createService(BLEUUID(BLE_SERVICE_UUID), 40, 0);

    BLECharacteristic *pUID = pService->createCharacteristic(
        CHR_UID_CONFIG_UUID, BLECharacteristic::PROPERTY_WRITE);
    pUID->setCallbacks(new UIDConfigCallback());

    BLECharacteristic *pBind = pService->createCharacteristic(
        CHR_BIND_CMD_UUID, BLECharacteristic::PROPERTY_WRITE);
    pBind->setCallbacks(new BindCmdCallback());

    BLECharacteristic *pOSD = pService->createCharacteristic(
        CHR_OSD_CONTROL_UUID, BLECharacteristic::PROPERTY_WRITE);
    pOSD->setCallbacks(new OSDControlCallback());

    BLECharacteristic *pOSDText = pService->createCharacteristic(
        CHR_OSD_TEXT_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    pOSDText->setCallbacks(new OSDTextCallback());

    g_status_chr = pService->createCharacteristic(
        CHR_STATUS_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    g_status_chr->addDescriptor(new BLE2902());

    g_tx_sniff_chr = pService->createCharacteristic(
        CHR_TX_SNIFF_UUID,
        BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY);
    g_tx_sniff_chr->addDescriptor(new BLE2902());
    g_tx_sniff_chr->setCallbacks(new TXSniffCallback());

    g_battery_chr = pService->createCharacteristic(
        CHR_BATTERY_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    g_battery_chr->addDescriptor(new BLE2902());

    g_flight_battery_chr = pService->createCharacteristic(
        CHR_FLIGHT_BATTERY_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    g_flight_battery_chr->addDescriptor(new BLE2902());

    // Firmware version string for iOS-side compatibility check. READ-only
    // (compile-time constant for the running build), no callback, no
    // notify — iOS reads once after characteristic discovery and parses
    // the major-version component. Match the existing fail-loud pattern
    // (see g_battery_chr null check below) so a future numHandles
    // regression surfaces in serial instead of crashing on the first
    // setValue.
    BLECharacteristic *pFwVersion = pService->createCharacteristic(
        CHR_FW_VERSION_UUID, BLECharacteristic::PROPERTY_READ);
    if (!pFwVersion) {
        Serial.println("ble_init: CHR_FW_VERSION createCharacteristic failed (numHandles overflow?)");
    } else {
        const char *v = FIRMWARE_VERSION;
        pFwVersion->setValue((uint8_t *)v, strlen(v));
    }

    BLECharacteristic *pSleep = pService->createCharacteristic(
        CHR_SLEEP_CONFIG_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
    pSleep->setCallbacks(new SleepConfigCallback());
    {
        // Seed the read value with the persisted minutes so a fresh iOS
        // read sees the actual current setting, not 0.
        uint8_t cur = nvs_store::loadSleepMinutes();
        pSleep->setValue(&cur, 1);
    }

    g_telemetry_chr = pService->createCharacteristic(
        CHR_TELEMETRY_DEBUG_UUID,
        BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY);
    g_telemetry_chr->addDescriptor(new BLE2902());
    g_telemetry_chr->setCallbacks(new TelemetryDebugCallback());

    pService->start();

    BLEAdvertising *pAdv = BLEDevice::getAdvertising();
    pAdv->addServiceUUID(BLE_SERVICE_UUID);
    pAdv->setScanResponse(true);
    BLEDevice::startAdvertising();
}
