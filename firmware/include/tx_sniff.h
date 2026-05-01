#pragma once

#include <cstdint>
#include <cstring>
#include <esp_now.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>
#include "msp.h"

// Flags written by BLE task (TXSniffCallback), consumed by main loop.
// Single-byte volatile is sufficient — one writer, one reader, no struct pair.
inline volatile bool g_sniff_start_requested = false;
inline volatile bool g_sniff_stop_requested  = false;

// Edge flag + payload. Written by ESP-NOW recv callback (WiFi task),
// read by main loop. Mux guards the 6-byte memcpy + flag pair so the
// main loop never sees a partially-written UID.
inline portMUX_TYPE  g_sniff_mux      = portMUX_INITIALIZER_UNLOCKED;
inline volatile bool g_sniff_captured = false;
inline uint8_t       g_sniff_uid[6]   = {};

// ESP-NOW recv callback — WiFi task context (not an ISR).
// Filters for ELRS bind packets: MSP header '$X' + function MSP_ELRS_BIND.
// src MAC equals the TX UID directly (ELRS backpack uses its UID as MAC).
inline void _espnow_recv_cb(const uint8_t *mac_addr, const uint8_t *data, int len) {
    // MSP_ELRS_BIND packet: at minimum header(3) + flags(1) + func(2) +
    // size(2) + uid_payload(6) + crc(1) = 15 bytes.
    if (len < 15) return;
    if (data[0] != '$' || data[1] != 'X') return;
    // Function code is little-endian at bytes [4:5]. MSP_ELRS_BIND = 0x0009.
    if (data[4] != (MSP_ELRS_BIND & 0xFF) || data[5] != (MSP_ELRS_BIND >> 8)) return;

    portENTER_CRITICAL(&g_sniff_mux);
    memcpy(g_sniff_uid, mac_addr, 6);
    g_sniff_captured = true;
    portEXIT_CRITICAL(&g_sniff_mux);
}

inline void sniff_start() {
    esp_now_register_recv_cb(_espnow_recv_cb);
}

inline void sniff_stop() {
    esp_now_unregister_recv_cb();
}
