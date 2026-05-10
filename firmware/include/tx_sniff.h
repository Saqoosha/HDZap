#pragma once

#include <cstdint>
#include <cstring>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>

// Flags written by TXSniffCallback (ble_service.h, BLE task context),
// consumed by main loop. Single-byte volatile is sufficient — one writer,
// one reader, no struct pair.
inline volatile bool g_sniff_start_requested = false;
inline volatile bool g_sniff_stop_requested  = false;

// True while iOS asks for TX UID sniff packets. Written by main-loop only
// (sniff_start/sniff_stop are called from main.cpp's BLE-flag handlers),
// read by main-loop's deep-sleep gate (issue #5 phase 3) — same task,
// no mux needed. Bare volatile keeps the compiler from caching the read
// across the gate's other condition checks.
inline volatile bool g_sniff_active = false;

// Edge flag + payload. Written by ESP-NOW recv callback (WiFi task),
// read by main loop. Mux guards the 6-byte memcpy + flag pair so the
// main loop never sees a partially-written UID.
inline portMUX_TYPE  g_sniff_mux      = portMUX_INITIALIZER_UNLOCKED;
inline volatile bool g_sniff_captured = false;
inline uint8_t       g_sniff_uid[6]   = {};

// Flight-pack telemetry is sniffed in promiscuous mode, so it must be
// filtered explicitly. Bind sniff captures the TX's ESP-NOW sender MAC and
// persists it separately from the OSD target UID.
inline volatile bool g_telemetry_source_configured = false;
inline volatile bool g_telemetry_source_captured = false;
inline uint8_t       g_telemetry_source_uid[6] = {};

// TX UID sniff relies on ESP-NOW recv callbacks. The unified handler lives in
// `espnow_recv.h` and stays registered whenever ESP-NOW is up — otherwise
// flight battery telemetry is never delivered. sniff_start/sniff_stop only
// toggle g_sniff_active so bind capture is gated without unregistering recv.

inline bool sniff_start() {
    g_sniff_active = true;
    return true;
}

inline bool sniff_stop() {
    g_sniff_active = false;
    return true;
}
