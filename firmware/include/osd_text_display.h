#pragma once

#include <cstdint>
#include <cstring>
#include "osd.h"

class OSDTextDisplay {
public:
    static constexpr uint8_t ROW_COUNT = 3;
    static constexpr uint8_t ROW_TEXT_MAX = 19;

    void begin(OSD *osd) {
        m_osd = osd;
        clear();
    }

    void setRows(const char rows[ROW_COUNT][ROW_TEXT_MAX + 1]) {
        for (uint8_t i = 0; i < ROW_COUNT; i++) {
            strncpy(m_rows[i], rows[i], ROW_TEXT_MAX);
            m_rows[i][ROW_TEXT_MAX] = 0;
        }
    }

    void clear() {
        for (uint8_t i = 0; i < ROW_COUNT; i++) {
            m_rows[i][0] = 0;
        }
    }

    bool render() {
        if (!m_osd) return false;

        bool ok = m_osd->clear();
        for (uint8_t i = 0; i < ROW_COUNT; i++) {
            ok = writeCentered(OSD_ROWS - ROW_COUNT + i, m_rows[i]) && ok;
        }
        ok = m_osd->draw() && ok;
        if (!ok) Serial.println("osd_text_display: render incomplete, OSD may be stale");
        return ok;
    }

private:
    OSD *m_osd = nullptr;
    char m_rows[ROW_COUNT][ROW_TEXT_MAX + 1] = {};

    bool writeCentered(uint8_t row, const char *line) {
        size_t len = strlen(line);
        uint8_t col = 0;
        if (len < OSD_COLS) {
            col = (OSD_COLS - len) / 2;
        }
        return m_osd->writeString(row, col, line);
    }
};
