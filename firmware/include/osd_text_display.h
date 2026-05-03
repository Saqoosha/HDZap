#pragma once

#include <cstdint>
#include <cstring>
#include "osd.h"

/// Renders the bottom 4 rows of the goggle OSD with iOS-supplied,
/// preformatted strings. iOS owns the layout and centering math;
/// firmware just writes whichever rows iOS marked dirty. The MSP
/// DisplayPort overlay buffer retains row content between writes,
/// so a single dirty row only costs writeString + draw (2 ESP-NOW
/// packets) — the TIME LEFT row can tick every second without
/// rerendering the lap/avg/diff rows below it.
///
/// iOS pads each row to a fixed width chosen for its row so a
/// shorter update cleanly overwrites a longer prior value at the
/// same centered position. There is no firmware-side clear-row
/// step; that responsibility lives in iOS via the padding.
class OSDTextDisplay {
public:
    static constexpr uint8_t ROW_COUNT = 4;
    static constexpr uint8_t ROW_TEXT_MAX = 19;

    void begin(OSD *osd) {
        m_osd = osd;
        clear();
    }

    /// Stage rows + dirty bitmap from the BLE staging buffer for the
    /// next render() call. Rows whose bit is clear in `dirty` are
    /// ignored and will not be re-sent — caller is responsible for
    /// not setting bits whose row content is unchanged.
    void setDirtyRows(uint8_t dirty,
                      const char rows[ROW_COUNT][ROW_TEXT_MAX + 1]) {
        m_dirty = dirty;
        for (uint8_t i = 0; i < ROW_COUNT; i++) {
            if (dirty & (uint8_t)(1 << i)) {
                strncpy(m_rows[i], rows[i], ROW_TEXT_MAX);
                m_rows[i][ROW_TEXT_MAX] = 0;
            }
        }
    }

    /// Drop staged rows. Used on race-reset to forget any pending
    /// content so a stale tick can't re-paint right after the
    /// operator just cleared the OSD.
    void clear() {
        for (uint8_t i = 0; i < ROW_COUNT; i++) {
            m_rows[i][0] = 0;
        }
        m_dirty = 0;
    }

    bool render() {
        if (!m_osd) return false;
        if (m_dirty == 0) return true; // nothing to do — caller bug, but cheap to no-op
        bool ok = true;
        for (uint8_t i = 0; i < ROW_COUNT; i++) {
            if (m_dirty & (uint8_t)(1 << i)) {
                ok = writeCentered(OSD_ROWS - ROW_COUNT + i, m_rows[i]) && ok;
            }
        }
        ok = m_osd->draw() && ok;
        if (!ok) Serial.println("osd_text_display: render incomplete, OSD may be stale");
        m_dirty = 0;
        return ok;
    }

private:
    OSD *m_osd = nullptr;
    char m_rows[ROW_COUNT][ROW_TEXT_MAX + 1] = {};
    uint8_t m_dirty = 0;

    bool writeCentered(uint8_t row, const char *line) {
        size_t len = strlen(line);
        uint8_t col = 0;
        if (len < OSD_COLS) {
            col = (OSD_COLS - len) / 2;
        }
        return m_osd->writeString(row, col, line);
    }
};
