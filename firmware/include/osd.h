#pragma once

#include <cstdint>
#include <cstring>
#include <Arduino.h>
#include "msp.h"
#include "espnow_link.h"

/// OSD controller — sends MSP OSD commands via ESP-NOW
class OSD {
public:
    /// Bind to the live UID storage. We hold a pointer rather than a
    /// copy so a subsequent UID change (applyStagedUid → espnow_reinit
    /// updates the peer table; osd would otherwise still send to the
    /// old MAC which is no longer a registered peer, and esp_now_send
    /// fails with ESP_ERR_ESPNOW_NOT_FOUND). Caller must keep the
    /// referenced storage alive for the OSD's lifetime — in our setup
    /// that's the file-scope `g_uid` in main.cpp, so the contract is
    /// trivially satisfied.
    void begin(const uint8_t *uid) {
        m_uid = uid;
    }

    /// Clear the OSD overlay buffer (not displayed until draw)
    bool clear() {
        uint8_t payload[] = {MSP_DP_CLEAR};
        return send_osd(payload, sizeof(payload));
    }

    /// Write text at (row, col). attr: bit0 = font page (0 or 1).
    bool writeString(uint8_t row, uint8_t col, const char *text, uint8_t attr = 0) {
        if (row >= OSD_ROWS || col >= OSD_COLS) {
            Serial.printf("osd: writeString OOB row=%u col=%u (grid %ux%u)\n",
                          row, col, OSD_ROWS, OSD_COLS);
            return false;
        }
        size_t maxLen = OSD_COLS - col;
        size_t textLen = strlen(text);
        if (textLen > maxLen) textLen = maxLen;

        uint8_t payload[4 + OSD_COLS];
        payload[0] = MSP_DP_WRITE_STRING;
        payload[1] = row;
        payload[2] = col;
        payload[3] = attr;
        for (size_t i = 0; i < textLen; i++) {
            char c = text[i];
            // BF/HDZero OSD font 0x60-0x7F = FPV glyphs (battery, GPS, arrows),
            // NOT ASCII lowercase. Promote a-z to A-Z to display Latin letters.
            if (c >= 'a' && c <= 'z') c -= 32;
            payload[4 + i] = c;
        }
        return send_osd(payload, 4 + textLen);
    }

    /// Draw — copy overlay to visible screen
    bool draw() {
        uint8_t payload[] = {MSP_DP_DRAW};
        return send_osd(payload, sizeof(payload));
    }

    /// Convenience: clear + write + draw in one call
    bool display(uint8_t row, uint8_t col, const char *text) {
        return clear() && writeString(row, col, text) && draw();
    }

private:
    const uint8_t *m_uid = nullptr;

    bool send_osd(const uint8_t *payload, size_t payload_size) {
        if (!m_uid) {
            Serial.println("osd: send before begin() — UID pointer not set");
            return false;
        }
        uint8_t buf[MSP_MAX_PACKET];
        size_t len = msp_build_packet(buf, MSP_SET_OSD_ELEM, payload, payload_size);
        bool ok = espnow_send(m_uid, buf, len);
        if (!ok) {
            // Include the DP subcommand and the UID we tried to send to,
            // so a "wrong peer / stale m_uid" failure mode is obvious in
            // the serial log instead of just "send failed".
            Serial.printf("osd: send failed (DP subcmd=0x%02X, dest %02X:%02X:%02X:%02X:%02X:%02X)\n",
                          payload[0],
                          m_uid[0], m_uid[1], m_uid[2],
                          m_uid[3], m_uid[4], m_uid[5]);
        }
        return ok;
    }
};
