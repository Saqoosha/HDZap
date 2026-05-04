#pragma once

#include <cstdint>
#include <cstring>
#include <esp_now.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>
#include "msp.h"

// Flags written by TXSniffCallback (ble_service.h, BLE task context),
// consumed by main loop. Single-byte volatile is sufficient — one writer,
// one reader, no struct pair.
inline volatile bool g_sniff_start_requested = false;
inline volatile bool g_sniff_stop_requested  = false;

// Edge flag + payload. Written by ESP-NOW recv callback (WiFi task),
// read by main loop. Mux guards the 6-byte memcpy + flag pair so the
// main loop never sees a partially-written UID.
inline portMUX_TYPE  g_sniff_mux      = portMUX_INITIALIZER_UNLOCKED;
inline volatile bool g_sniff_captured = false;
inline uint8_t       g_sniff_uid[6]   = {};

// ESP-NOW recv callback — WiFi task context (not an ISR).
// Filters for ELRS bind packets: MSP header '$X<' + function MSP_ELRS_BIND.
// src MAC equals the TX UID directly (ELRS backpack uses its UID as MAC).
inline void _espnow_recv_cb(const uint8_t *mac_addr, const uint8_t *data, int len) {
    // 15-byte guard filters noise: header(3)+flags(1)+func(2)+size(2)+
    // uid_payload(6)+crc(1)=15. We only read up to data[5]; the extra
    // bytes ensure this is a structurally plausible bind packet rather
    // than a short frame that coincidentally starts with '$X'. UID is
    // taken from mac_addr, not the payload bytes.
    if (len < 15) return;
    if (data[0] != '$' || data[1] != 'X' || data[2] != '<') return;
    // Function code is little-endian at bytes [4:5]. MSP_ELRS_BIND = 0x0009.
    if (data[4] != (MSP_ELRS_BIND & 0xFF) || data[5] != (MSP_ELRS_BIND >> 8)) return;

    portENTER_CRITICAL(&g_sniff_mux);
    memcpy(g_sniff_uid, mac_addr, 6);
    g_sniff_uid[0] &= ~0x01; // unicast MAC invariant — enforce at every assignment site
    g_sniff_captured = true;
    portEXIT_CRITICAL(&g_sniff_mux);
}

// ESP-NOW has one global recv callback slot. sniff_start registers our
// handler; sniff_stop removes it. No other recv_cb is used in this project.
// Returns false on IDF error (logs reason); main loop surfaces this to iOS.
// True while the recv callback is registered. Read by main.cpp's deep
// sleep path — sleep would cut WiFi RF and silently drop bind packets.
// Set/cleared on the success path of start/stop so a register failure
// doesn't leave it asserted.
inline volatile bool g_sniff_active = false;

inline bool sniff_start() {
    esp_err_t err = esp_now_register_recv_cb(_espnow_recv_cb);
    if (err != ESP_OK) {
        Serial.printf("TX sniff: register_recv_cb failed (%d)\n", err);
        return false;
    }
    g_sniff_active = true;
    return true;
}

inline bool sniff_stop() {
    esp_err_t err = esp_now_unregister_recv_cb();
    if (err != ESP_OK && err != ESP_ERR_ESPNOW_NOT_INIT) {
        Serial.printf("TX sniff: unregister_recv_cb failed (%d)\n", err);
        return false;
    }
    g_sniff_active = false;
    return true;
}
