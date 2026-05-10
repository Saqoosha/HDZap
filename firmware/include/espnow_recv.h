#pragma once

#include <cstring>

#include <esp_now.h>
#include <esp_wifi.h>
#include <freertos/portmacro.h>

#include "flight_battery_telemetry.h"
#include "msp.h"
#include "telemetry_sniff.h"
#include "tx_sniff.h"

inline constexpr int kPromiscMspCandidateMaxLen = 384;
inline portMUX_TYPE g_promisc_msp_mux = portMUX_INITIALIZER_UNLOCKED;
inline volatile bool g_promisc_msp_staged = false;
inline int g_promisc_msp_len = 0;
inline uint8_t g_promisc_msp_buf[kPromiscMspCandidateMaxLen] = {};
// Counts staged-overwrite events on the promiscuous-MSP single-slot
// buffer (producer = Wi-Fi promisc cb, consumer = main loop). Mirrors
// `g_flight_battery_dropped` so a sustained burst arriving faster than
// the main-loop drain is visible at the serial console rather than
// silent. main.cpp logs on each new dropped edge.
inline volatile uint32_t g_promisc_msp_dropped = 0;

inline bool hdzap_telemetry_source_matches(const uint8_t sender[6]) {
    if (!sender) return false;
    portENTER_CRITICAL(&g_sniff_mux);
    bool match = g_telemetry_source_configured &&
                 memcmp(g_telemetry_source_uid, sender, 6) == 0;
    portEXIT_CRITICAL(&g_sniff_mux);
    return match;
}

/// For management/data MPDUs, addr2 is the transmitter address. ESP-NOW uses
/// vendor-specific action frames, so this is the sender we bind telemetry to.
inline bool hdzap_extract_80211_sender(const uint8_t *frame, int len, uint8_t out[6]) {
    constexpr int kAddr2Offset = 10;
    if (!frame || !out || len < kAddr2Offset + 6) return false;
    memcpy(out, frame + kAddr2Offset, 6);
    return true;
}

/// Same cheap prefilter as the bench sniffer: Backpack telemetry is an MSP
/// packet (`$M`/`$X`) somewhere inside the raw MPDU.
inline bool hdzap_find_msp_offset(const uint8_t *p, size_t len, size_t *out_offset) {
    for (size_t i = 0; i + 2 < len; i++) {
        if (p[i] != '$') continue;
        uint8_t b = p[i + 1];
        if (b == 'M' || b == 'm' || b == 'X' || b == 'x') {
            if (out_offset) *out_offset = i;
            return true;
        }
    }
    return false;
}

inline bool hdzap_consume_promisc_msp_candidate(uint8_t *out, int out_cap, int *out_len) {
    if (!g_promisc_msp_staged || !out || !out_len || out_cap <= 0) return false;
    portENTER_CRITICAL(&g_promisc_msp_mux);
    bool had = g_promisc_msp_staged;
    if (had) {
        int n = g_promisc_msp_len;
        if (n > out_cap) n = out_cap;
        memcpy(out, g_promisc_msp_buf, n);
        *out_len = n;
        g_promisc_msp_staged = false;
    }
    portEXIT_CRITICAL(&g_promisc_msp_mux);
    return had;
}

inline void hdzap_try_capture_bind_uid(const uint8_t *mac_addr, const uint8_t *data, int len) {
    if (!g_sniff_active)
        return;
    if (!mac_addr)
        return;
    if (!data)
        return;
    if (len < 15)
        return;
    if (data[0] != '$' || data[1] != 'X' || data[2] != '<')
        return;
    if (data[4] != (MSP_ELRS_BIND & 0xFF) || data[5] != (MSP_ELRS_BIND >> 8))
        return;
    portENTER_CRITICAL(&g_sniff_mux);
    memcpy(g_sniff_uid, mac_addr, 6);
    memcpy(g_telemetry_source_uid, mac_addr, 6);
    // Unicast MAC invariant — applied at every assignment site (per
    // CLAUDE.md). Both UIDs feed downstream filters that compare
    // bit-by-bit, so silently letting the multicast bit through here
    // would also persist via nvs_store::saveTelemetrySourceUid (which
    // independently rejects non-unicast and would drop the save).
    g_sniff_uid[0] &= ~0x01;
    g_telemetry_source_uid[0] &= ~0x01;
    g_telemetry_source_configured = true;
    g_telemetry_source_captured = true;
    g_sniff_captured = true;
    portEXIT_CRITICAL(&g_sniff_mux);
}

inline void hdzap_espnow_recv_cb(const uint8_t *mac_addr, const uint8_t *data, int len) {
    hdzap_try_capture_bind_uid(mac_addr, data, len);
    // Flight-battery decode happens in the promiscuous-RX path only
    // (see `hdzap_promiscuous_rx_cb` below). Backpack telemetry can
    // arrive as a broadcast frame too — that fires both the ESP-NOW
    // recv callback AND the promiscuous capture, so decoding here as
    // well would double-stage the same sample and inflate
    // `g_flight_battery_dropped`. The stick is generally not the
    // backpack's ESP-NOW peer, so the recv callback rarely sees these
    // anyway.
    // Telemetry debug ride-along: cheap one-byte gate inside when the
    // iOS Backpack Telemetry Debug subview isn't open, so the bind /
    // flight-battery hot path stays untaxed in the common case.
    telemetry_sniff::capture_if_active(mac_addr, data, len);
}

inline void hdzap_promiscuous_rx_cb(void *buf, wifi_promiscuous_pkt_type_t type) {
    if (type != WIFI_PKT_MGMT && type != WIFI_PKT_DATA) return;
    auto *pkt = static_cast<wifi_promiscuous_pkt_t *>(buf);
    if (!pkt) return;
    const uint8_t *payload = pkt->payload;
    const int len = pkt->rx_ctrl.sig_len;
    if (!payload || len <= 0) return;
    uint8_t sender[6];
    if (!hdzap_extract_80211_sender(payload, len, sender)) return;
    if (!hdzap_telemetry_source_matches(sender)) return;
    size_t msp_off = 0;
    if (!hdzap_find_msp_offset(payload, static_cast<size_t>(len), &msp_off)) return;
    int copy_len = len - static_cast<int>(msp_off);
    if (copy_len <= 0) return;
    if (copy_len > kPromiscMspCandidateMaxLen) copy_len = kPromiscMspCandidateMaxLen;
    portENTER_CRITICAL(&g_promisc_msp_mux);
    if (g_promisc_msp_staged) {
        // Producer arrived again before the main loop drained the
        // previous candidate. Bump the counter so a sustained burst
        // shows up at the serial console.
        g_promisc_msp_dropped++;
    }
    memcpy(g_promisc_msp_buf, payload + msp_off, copy_len);
    g_promisc_msp_len = copy_len;
    g_promisc_msp_staged = true;
    portEXIT_CRITICAL(&g_promisc_msp_mux);
}

/// Registers the unified recv path; safe to call after every ESP-NOW init/reinit success.
inline void espnow_recv_attach_cb() {
    esp_err_t err = esp_now_register_recv_cb(hdzap_espnow_recv_cb);
    if (err != ESP_OK) {
        Serial.printf("esp_now_register_recv_cb failed (%d)\n", (int)err);
    }
    // Bench telemetry capture worked because it used promiscuous mode:
    // Backpack CRSF telemetry is visible on-air but is not necessarily
    // addressed to this M5Stick's ESP-NOW MAC, so the normal recv callback
    // can stay silent while TX/goggle paths still see packets.
    esp_err_t cb_err = esp_wifi_set_promiscuous_rx_cb(hdzap_promiscuous_rx_cb);
    if (cb_err != ESP_OK) {
        Serial.printf("esp_wifi_set_promiscuous_rx_cb failed (%d)\n", (int)cb_err);
    }
    esp_err_t promisc_err = esp_wifi_set_promiscuous(true);
    if (promisc_err != ESP_OK) {
        Serial.printf("esp_wifi_set_promiscuous(true) failed (%d)\n", (int)promisc_err);
    }
}
