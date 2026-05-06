#pragma once

#include <cstdint>
#include <cstring>
#include <esp_now.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>

// Backpack telemetry debug sniffer.
//
// Sister module to tx_sniff.h. Where tx_sniff filters for the single
// MSP_ELRS_BIND function code and captures the source MAC, this module
// captures *every* incoming ESP-NOW packet into a small ring and ships
// per-packet records to iOS for the on-device debug view.
//
// Why a separate module instead of a flag in tx_sniff: the tx_sniff
// callback is a tight bind-only filter that bails on the first byte
// mismatch, hot-path-friendly. The telemetry debug callback is the
// opposite — it accepts everything and pays for a memcpy + ring update
// per packet. Splitting keeps the bind path free of any per-packet
// overhead when the debug screen isn't open.
//
// Mutual exclusion with tx_sniff: ESP-NOW has one global
// recv-callback slot (see tx_sniff.h docstring). Calling
// telemetry_sniff_start() while tx_sniff is active would silently
// overwrite tx_sniff's handler, so main.cpp enforces an explicit
// stop-other-first ordering before either start. The deep-sleep gate
// also reads `g_telemetry_sniff_active` so an iOS-driven debug session
// can't be torn down by an idle-timeout sleep.

namespace telemetry_sniff {

// 20-byte packet record, sized to fit a single BLE notify under the
// default 23-byte ATT MTU (3-byte ATT header + 20-byte payload). iOS
// decoder lives in BackpackTelemetryDebugView.swift; keep the layout
// in lockstep with that struct.
//
// Layout:
//   [0..5]   src MAC (6 bytes) — ELRS backpack uses its UID as MAC,
//            so this directly identifies the broadcaster (TX backpack,
//            goggle backpack, another peer)
//   [6..7]   MSP function code, little-endian uint16. 0xFFFF when the
//            packet doesn't look like MSPv1 or MSPv2 (no '$X<' / '$M<'
//            preamble) — e.g. raw ESP-NOW frames, encrypted payloads,
//            or short noise bursts
//   [8]      raw ESP-NOW packet length, capped at 255 (longer packets
//            still get captured but the length byte saturates)
//   [9]      flag bits: bit0 = MSPv2 ('$X<'), bit1 = MSPv1 ('$M<').
//            Mutually exclusive in well-formed packets; both clear
//            means non-MSP traffic
//   [10..19] first 10 bytes of the raw packet, for hex-dump display
constexpr size_t RECORD_SIZE = 20;

// Ring depth chosen to swallow a small burst (ELRS telemetry runs at
// roughly the CRSF rate — typically tens of packets/sec at 250 Hz
// link rate, much less in real-world telemetry) without the producer
// blocking the WiFi task. Main loop drains one record per iteration,
// so steady-state needs only ~1 slot; the rest is headroom for bursts
// when the iOS link is busy with an OSD render cycle.
constexpr size_t RING_CAPACITY = 32;

// Producer = ESP-NOW recv callback (WiFi task).
// Consumer = main loop (telemetry_pop).
// portMUX guards head/tail/dropped/total + the per-record memcpy so
// the consumer never sees a half-written record or a torn count.
inline portMUX_TYPE g_telemetry_mux = portMUX_INITIALIZER_UNLOCKED;
inline uint8_t  g_telemetry_ring[RING_CAPACITY][RECORD_SIZE] = {};
inline volatile uint8_t  g_telemetry_head    = 0;  // next free slot
inline volatile uint8_t  g_telemetry_tail    = 0;  // next slot to consume
inline volatile uint16_t g_telemetry_dropped = 0;  // ring-full overflow count
inline volatile uint32_t g_telemetry_total   = 0;  // total packets seen since start

// Edge flags from BLE callback (BLE task) → main loop. Same single-byte
// volatile pattern as g_sniff_start_requested / g_sniff_stop_requested.
inline volatile bool g_telemetry_start_requested = false;
inline volatile bool g_telemetry_stop_requested  = false;

// True while the recv callback is registered. Same role as
// tx_sniff.h::g_sniff_active — read by main.cpp's deep-sleep gate so
// a debug session isn't dropped by an idle-timeout sleep. Bare
// volatile (single-byte, single writer = main loop, single reader =
// also main loop in the gate).
inline volatile bool g_telemetry_sniff_active = false;

inline void _telemetry_recv_cb(const uint8_t *mac_addr, const uint8_t *data, int len) {
    portENTER_CRITICAL(&g_telemetry_mux);
    g_telemetry_total++;
    uint8_t next_head = (uint8_t)((g_telemetry_head + 1) % RING_CAPACITY);
    if (next_head == g_telemetry_tail) {
        // Ring full — drain rate < arrival rate. Count and bail; the
        // iOS view shows the dropped tally so a sustained overflow is
        // visible rather than silent.
        g_telemetry_dropped++;
        portEXIT_CRITICAL(&g_telemetry_mux);
        return;
    }
    uint8_t *rec = g_telemetry_ring[g_telemetry_head];
    memcpy(rec, mac_addr, 6);

    // MSP version + function code detection. MSPv2 is the modern format
    // ELRS uses; MSPv1 is recognized for completeness so legacy traffic
    // doesn't mislabel as "non-MSP".
    uint16_t fn = 0xFFFF;
    uint8_t flags = 0;
    if (len >= 8 && data[0] == '$' && data[1] == 'X' && data[2] == '<') {
        fn = (uint16_t)data[4] | ((uint16_t)data[5] << 8);
        flags |= 0x01;
    } else if (len >= 6 && data[0] == '$' && data[1] == 'M' && data[2] == '<') {
        fn = data[4];  // MSPv1 cmd byte
        flags |= 0x02;
    }
    rec[6] = (uint8_t)(fn & 0xFF);
    rec[7] = (uint8_t)(fn >> 8);
    rec[8] = (len > 255) ? 255 : (uint8_t)len;
    rec[9] = flags;

    // First 10 bytes for hex-dump preview. memset the tail when the
    // packet is shorter than 10 bytes so the iOS side doesn't render
    // stale ring contents from the prior occupant of this slot.
    int copy_len = (len < 10) ? len : 10;
    memcpy(&rec[10], data, copy_len);
    if (copy_len < 10) memset(&rec[10 + copy_len], 0, 10 - copy_len);

    g_telemetry_head = next_head;
    portEXIT_CRITICAL(&g_telemetry_mux);
}

// Returns false on IDF error (logs reason). Caller (main.cpp) MUST
// ensure tx_sniff is stopped first — registering here while tx_sniff's
// callback is live would silently overwrite it.
inline bool telemetry_sniff_start() {
    esp_err_t err = esp_now_register_recv_cb(_telemetry_recv_cb);
    if (err != ESP_OK) {
        Serial.printf("Telemetry sniff: register_recv_cb failed (%d)\n", err);
        return false;
    }
    // Reset counters/ring under the mux so the iOS view starts each
    // session from a clean slate (otherwise a stale "dropped" tally
    // from a previous session would appear instantly on the next start).
    portENTER_CRITICAL(&g_telemetry_mux);
    g_telemetry_head    = 0;
    g_telemetry_tail    = 0;
    g_telemetry_dropped = 0;
    g_telemetry_total   = 0;
    portEXIT_CRITICAL(&g_telemetry_mux);
    g_telemetry_sniff_active = true;
    return true;
}

inline bool telemetry_sniff_stop() {
    esp_err_t err = esp_now_unregister_recv_cb();
    if (err != ESP_OK && err != ESP_ERR_ESPNOW_NOT_INIT) {
        Serial.printf("Telemetry sniff: unregister_recv_cb failed (%d)\n", err);
        return false;
    }
    g_telemetry_sniff_active = false;
    return true;
}

// Pop the oldest pending record into `out` (RECORD_SIZE bytes) plus
// snapshot the current dropped/total counts. Returns false when the
// ring is empty. Counts are pulled under the same mux as the record
// pop so the iOS view sees a consistent (record, counts) pair.
inline bool telemetry_pop(uint8_t out[RECORD_SIZE],
                          uint16_t &dropped_out,
                          uint32_t &total_out) {
    portENTER_CRITICAL(&g_telemetry_mux);
    if (g_telemetry_head == g_telemetry_tail) {
        dropped_out = g_telemetry_dropped;
        total_out   = g_telemetry_total;
        portEXIT_CRITICAL(&g_telemetry_mux);
        return false;
    }
    memcpy(out, g_telemetry_ring[g_telemetry_tail], RECORD_SIZE);
    g_telemetry_tail = (uint8_t)((g_telemetry_tail + 1) % RING_CAPACITY);
    dropped_out = g_telemetry_dropped;
    total_out   = g_telemetry_total;
    portEXIT_CRITICAL(&g_telemetry_mux);
    return true;
}

}  // namespace telemetry_sniff
