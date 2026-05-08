#pragma once

#include <cstdint>
#include <cstring>
#include "osd.h"

/// Renders 4 contiguous rows of the goggle OSD with iOS-supplied,
/// preformatted strings. iOS owns the layout (centering, alignment,
/// per-row visibility); firmware just writes whichever rows iOS
/// marked dirty at whatever base row iOS configured. The MSP
/// DisplayPort overlay buffer retains row content between writes,
/// so a single dirty row only costs writeString + draw (2 ESP-NOW
/// packets) — the TIME LEFT row can tick every second without
/// rerendering the lap/avg/diff rows below it.
///
/// Base row defaults to OSD_ROWS - ROW_COUNT (bottom of the grid)
/// and can be moved up via setBaseRow() so the user can position
/// the OSD block away from the goggle's bottom edge. Caller (main.cpp)
/// is responsible for clearing the goggle overlay after a base-row
/// change, since old text at the prior base would otherwise remain
/// visible alongside the new rows at the new base.
///
/// iOS pads each row to a fixed width so a shorter update cleanly
/// overwrites a longer prior value at the same position. There is
/// no firmware-side clear-row step; that responsibility lives in
/// iOS via the padding.
class OSDTextDisplay {
public:
    static constexpr uint8_t ROW_COUNT = 4;
    static constexpr uint8_t ROW_TEXT_MAX = 50;  // OSD_COLS — full grid width
    static constexpr uint8_t DEFAULT_BASE_ROW = OSD_ROWS - ROW_COUNT;
    static constexpr uint8_t MAX_BASE_ROW = OSD_ROWS - ROW_COUNT;

    void begin(OSD *osd) {
        m_osd = osd;
        clear();
    }

    /// Move the 4-row block to a new top row. Caller (main.cpp) is
    /// expected to issue an OSD clear after this so leftover text at
    /// the prior base row doesn't sit alongside the new render. We
    /// don't clear here ourselves because firing an ESP-NOW packet
    /// from a setter mixes I/O into a state mutation; the main loop
    /// owns the radio so it owns the clear.
    /// All four row dirty bits are OR-merged so the next render
    /// repaints the block at the new position.
    void setBaseRow(uint8_t baseRow) {
        if (baseRow > MAX_BASE_ROW) baseRow = MAX_BASE_ROW;
        if (baseRow == m_baseRow) return;
        m_baseRow = baseRow;
        m_dirty |= (uint8_t)((1u << ROW_COUNT) - 1u);
    }

    uint8_t baseRow() const { return m_baseRow; }

    /// Stage rows + dirty bitmap from the BLE staging buffer. Bits
    /// OR-merge into the pending mask so dirty rows from earlier
    /// snapshots that haven't been rendered yet (e.g. ESP-NOW was
    /// down at dispatch, or a retry is still in flight) keep their
    /// place rather than being clobbered when a new row arrives.
    /// Caller (main loop) clears the merged mask via clearDirty()
    /// once the render-retry state machine confirms successful
    /// MAC delivery.
    void setDirtyRows(uint8_t dirty,
                      const char rows[ROW_COUNT][ROW_TEXT_MAX + 1]) {
        m_dirty |= dirty;
        for (uint8_t i = 0; i < ROW_COUNT; i++) {
            if (dirty & (uint8_t)(1 << i)) {
                strncpy(m_rows[i], rows[i], ROW_TEXT_MAX);
                m_rows[i][ROW_TEXT_MAX] = 0;
            }
        }
    }

    /// Drop staged rows. Used on race-reset / OSD clear to forget
    /// any pending content so a stale tick can't re-paint right
    /// after the operator just cleared the OSD.
    void clear() {
        for (uint8_t i = 0; i < ROW_COUNT; i++) {
            m_rows[i][0] = 0;
        }
        m_dirty = 0;
    }

    /// Snapshot the current dirty mask. Caller (the render state
    /// machine) saves this at dispatch time so verify-success can
    /// clear *only* the bits we just dispatched, leaving any bits
    /// that arrived from concurrent BLE writes during WAITING_ACK
    /// in place for the next cycle.
    uint8_t dirty() const { return m_dirty; }

    /// Clear specific dirty bits without touching others. The render
    /// state machine calls this from verify-success / give-up paths
    /// with the mask it dispatched so a row that was BLE-staged
    /// during the verify window survives until the next dispatch.
    void clearDirtyBits(uint8_t mask) {
        m_dirty &= (uint8_t)~mask;
    }

    /// True when at least one row has been staged but not yet rendered
    /// successfully. Drives the main loop's `IDLE && hasDirty →
    /// requestRender` catch-up path: BLE writes that arrive during a
    /// WAITING_ACK window accumulate here (setDirtyRows OR-merges)
    /// and the loop dispatches a fresh cycle the next time the state
    /// machine returns to IDLE.
    bool hasDirty() const { return m_dirty != 0; }

    /// Emit only the rows in `mask`. Caller passes the dispatched
    /// snapshot so a concurrent BLE write that OR-merges new bits into
    /// `m_dirty` between dispatch and the actual MSP packet writes
    /// doesn't get sent here too — those bits live on in `m_dirty` and
    /// the next IDLE catch-up trigger picks them up cleanly. Callers
    /// that have no specific mask in mind can pass `dirty()`.
    bool render(uint8_t mask) {
        if (!m_osd) return false;
        // No-op when there's nothing to send. Defensive — shouldn't
        // happen under the normal `request render only when dirty`
        // policy, but a stray retry path or a future caller bug would
        // otherwise emit a draw on top of a stale buffer.
        if (mask == 0) return true;
        bool ok = true;
        for (uint8_t i = 0; i < ROW_COUNT; i++) {
            if (mask & (uint8_t)(1 << i)) {
                ok = writeCentered(m_baseRow + i, m_rows[i]) && ok;
            }
        }
        ok = m_osd->draw() && ok;
        if (!ok) Serial.println("osd_text_display: render incomplete, OSD may be stale");
        // Intentionally leave `m_dirty` set: the render-retry state
        // machine in main.cpp may re-enter with the same dispatched
        // mask if MAC-layer delivery failed. Caller clears bits via
        // clearDirtyBits(mask) once verify confirms success, or via
        // clear() on an explicit OSD reset.
        return ok;
    }

private:
    OSD *m_osd = nullptr;
    char m_rows[ROW_COUNT][ROW_TEXT_MAX + 1] = {};
    uint8_t m_dirty = 0;
    uint8_t m_baseRow = DEFAULT_BASE_ROW;

    bool writeCentered(uint8_t row, const char *line) {
        size_t len = strlen(line);
        uint8_t col = 0;
        if (len < OSD_COLS) {
            col = (OSD_COLS - len) / 2;
        }
        return m_osd->writeString(row, col, line);
    }
};
