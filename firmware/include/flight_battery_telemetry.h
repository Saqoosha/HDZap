#pragma once

#include <cstdint>

#include <freertos/portmacro.h>

#include "crsf_battery_telemetry.h"

/// Staged telemetry from ESP-NOW recv (Wi-Fi task); consumed in Arduino main loop.
/// Same pattern as `ble_update_battery`: callback stays light — no BLE I/O here.

struct FlightBatterySampleRaw {
    int16_t voltage_dv{};
    int16_t current_da{};
    int32_t consumed_mah{};
    int8_t remaining_pct{-1};
};

inline volatile bool g_flight_battery_staged = false;
inline FlightBatterySampleRaw g_flight_battery_staged_sample{};
inline portMUX_TYPE g_flight_battery_mux = portMUX_INITIALIZER_UNLOCKED;

/// Last NOTIFY payload mirrored for change detection (avoid spamming BLE).
inline FlightBatterySampleRaw g_flight_battery_last_sent{};

inline void flight_battery_on_espnow_payload(const uint8_t *data, int len) {
    CrsfFlightBatteryDecoded dec{};
    bool got = crsfp_try_battery_from_any_msp_payload(data, len, &dec);
    if (!got)
        return;
    portENTER_CRITICAL(&g_flight_battery_mux);
    g_flight_battery_staged_sample.voltage_dv = dec.voltage_dv;
    g_flight_battery_staged_sample.current_da = dec.current_da;
    g_flight_battery_staged_sample.consumed_mah = dec.consumed_mah;
    g_flight_battery_staged_sample.remaining_pct = dec.remaining_pct;
    g_flight_battery_staged = true;
    portEXIT_CRITICAL(&g_flight_battery_mux);
}

inline bool flight_battery_consume_if_staged(FlightBatterySampleRaw *out) {
    if (!g_flight_battery_staged || !out)
        return false;
    portENTER_CRITICAL(&g_flight_battery_mux);
    bool had = g_flight_battery_staged;
    if (had) {
        *out = g_flight_battery_staged_sample;
        g_flight_battery_staged = false;
    }
    portEXIT_CRITICAL(&g_flight_battery_mux);
    return had;
}
