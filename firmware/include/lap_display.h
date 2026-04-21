#pragma once

#include <cstdint>
#include <cstring>
#include <cstdio>
#include "osd.h"

class LapDisplay {
public:
    void begin(OSD *osd) {
        m_osd = osd;
        m_count = 0;
    }

    void addLap(uint8_t lapNum, uint32_t timeMs) {
        if (m_count >= MAX_LAPS) return;
        m_laps[m_count].num = lapNum;
        m_laps[m_count].timeMs = timeMs;
        m_count++;
    }

    void clear() {
        m_count = 0;
    }

    bool render() {
        if (!m_osd) return false;
        bool ok = m_osd->clear();

        if (m_count == 0) {
            ok = m_osd->writeString(0, 0, "NO LAPS") && ok;
            ok = m_osd->draw() && ok;
            if (!ok) Serial.println("lap_display: render incomplete");
            return ok;
        }

        // Lap rows: most recent first, max MAX_LAP_ROWS visible
        uint8_t visibleLaps = m_count < MAX_LAP_ROWS ? m_count : MAX_LAP_ROWS;
        uint8_t row = 0;
        for (int i = m_count - 1; i >= (int)(m_count - visibleLaps); i--) {
            char line[OSD_COLS + 1];
            char timeBuf[16];
            formatTime(m_laps[i].timeMs, timeBuf);
            snprintf(line, sizeof(line), "LAP %02d      %s", m_laps[i].num, timeBuf);
            ok = m_osd->writeString(row, 0, line) && ok;
            row++;
        }

        // Blank row between lap rows and best/total — no writeString, just
        // a row-index skip, so it costs zero ESP-NOW packets (keeps the
        // cycle inside the static_assert'd 10-packet budget).
        row++;

        uint8_t bestIdx = findBest();
        {
            char line[OSD_COLS + 1];
            char timeBuf[16];
            formatTime(m_laps[bestIdx].timeMs, timeBuf);
            snprintf(line, sizeof(line), "BEST  %02d    %s", m_laps[bestIdx].num, timeBuf);
            ok = m_osd->writeString(row, 0, line) && ok;
            row++;
        }

        {
            uint32_t total = 0;
            for (uint8_t i = 0; i < m_count; i++) {
                total += m_laps[i].timeMs;
            }
            char line[OSD_COLS + 1];
            char timeBuf[16];
            formatTime(total, timeBuf);
            snprintf(line, sizeof(line), "TOTAL       %s", timeBuf);
            ok = m_osd->writeString(row, 0, line) && ok;
        }

        ok = m_osd->draw() && ok;
        if (!ok) Serial.println("lap_display: render incomplete, OSD may be stale");
        return ok;
    }

private:
    // "%02d" formatting + u8 BLE wire format cap lap number at 99.
    static constexpr uint8_t MAX_LAPS = 99;
    // ESP-NOW: safe to send up to 10 packets per OSD cycle (REPORT.md).
    // render() cycle = clear + MAX_LAP_ROWS + best + total + draw = MAX_LAP_ROWS + 4.
    // 6 rows => 10 packets, the stable ceiling.
    static constexpr uint8_t MAX_LAP_ROWS = 6;
    static constexpr uint8_t ESPNOW_PACKET_BUDGET = 10;
    static_assert(MAX_LAP_ROWS + 4 <= ESPNOW_PACKET_BUDGET,
                  "LapDisplay render() must stay within ESP-NOW 10-packet budget");

    struct Lap {
        uint8_t num;
        uint32_t timeMs;
    };

    OSD *m_osd = nullptr;
    Lap m_laps[MAX_LAPS];
    uint8_t m_count = 0;

    /// Format milliseconds as "MM:SS.mmm"
    static void formatTime(uint32_t ms, char *buf) {
        uint32_t totalSec = ms / 1000;
        uint32_t millis = ms % 1000;
        uint32_t minutes = totalSec / 60;
        uint32_t seconds = totalSec % 60;
        snprintf(buf, 16, "%02lu:%02lu.%03lu",
                 (unsigned long)minutes,
                 (unsigned long)seconds,
                 (unsigned long)millis);
    }

    uint8_t findBest() const {
        uint8_t best = 0;
        for (uint8_t i = 1; i < m_count; i++) {
            if (m_laps[i].timeMs < m_laps[best].timeMs) {
                best = i;
            }
        }
        return best;
    }
};
