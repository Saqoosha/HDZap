#pragma once

#include <cstdint>
#include <cstring>
#include <Arduino.h>
#include "msp.h"
#include "espnow_link.h"

/// OSD controller — sends MSP OSD commands via ESP-NOW
class OSD {
public:
    void begin(uint8_t uid[6]) {
        memcpy(m_uid, uid, 6);
    }

    /// Clear the OSD overlay buffer (not displayed until draw)
    bool clear() {
        uint8_t payload[] = {MSP_DP_CLEAR};
        return send_osd(payload, sizeof(payload));
    }

    /// Write text at (row, col). attr: bit0 = font page (0 or 1).
    bool writeString(uint8_t row, uint8_t col, const char *text, uint8_t attr = 0) {
        if (row >= OSD_ROWS || col >= OSD_COLS) return false;
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
    uint8_t m_uid[6];

    bool send_osd(const uint8_t *payload, size_t payload_size) {
        uint8_t buf[MSP_MAX_PACKET];
        size_t len = msp_build_packet(buf, MSP_SET_OSD_ELEM, payload, payload_size);
        return espnow_send(m_uid, buf, len);
    }
};
