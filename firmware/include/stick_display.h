#pragma once
#include <M5Unified.h>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include "nvs_store.h"  // kDeviceNameMaxLen — m_deviceName buffer width

/// M5StickS3 LCD: editorial-lite redesign.
///
/// Layout (rotation 1, 240x135):
///   [0   .. 60)    UID band       — UID caption + BLE pill, then UID hero
///                                   printed as comma-separated decimals
///                                   (matches what HDZero goggles show).
///   [60  .. 61)    hairline rule
///   [64  .. 110)   Lap band       — caption row + lap number + time.
///                                   Hijacked by TEST / BIND verdicts.
///   [110 .. 111)   hairline rule
///   [113 .. 135)   Strip          — RADIO indicator (left) + sticky message
///                                   slot (right). Persists across redraws.
///
/// Each region's draw routine fills only its rectangle, so a lap update
/// never repaints the UID and the strip never repaints the lap band.
/// Not safe to call from BLE/ESP-NOW callbacks; main loop only.
class StickDisplay {
public:
    void begin() {
        auto cfg = M5.config();
        M5.begin(cfg);
        M5.Display.setRotation(1);
        m_w = M5.Display.width();
        m_h = M5.Display.height();
        M5.Display.fillScreen(TFT_BLACK);
        // M5GFX text datum is global state. Lock it to top_left here so
        // every draw routine in this class can rely on it without saving
        // and restoring around each print().
        M5.Display.setTextDatum(textdatum_t::top_left);
        // Build the palette. Done here rather than in-class because the
        // RGB565 conversion needs the live display object.
        m_colInk    = M5.Display.color565(0xFF, 0xFF, 0xFF);
        m_colSub    = M5.Display.color565(0x8C, 0x8C, 0x8C); // ~55% white
        m_colDim    = M5.Display.color565(0x52, 0x52, 0x52); // ~32%
        m_colHair   = M5.Display.color565(0x2E, 0x2E, 0x2E); // ~18%
        m_colAccent = M5.Display.color565(0xDB, 0x65, 0xA9);
        m_colOk     = M5.Display.color565(0x9B, 0xE3, 0x8A);
        m_colWarn   = M5.Display.color565(0xFF, 0xD8, 0x6B);
        m_colOrange = M5.Display.color565(0xFF, 0x9F, 0x4A);
        m_colErr    = M5.Display.color565(0xFF, 0x64, 0x64);
        m_colCyan   = M5.Display.color565(0x6B, 0xE1, 0xFF);
        drawHairlines();
    }

    void showStatus(const uint8_t uid[6], bool bleConnected, bool radioReady,
                    bool uidIsDefault = false) {
        memcpy(m_uid, uid, 6);
        m_bleConnected = bleConnected;
        m_radioReady = radioReady;
        m_uidIsDefault = uidIsDefault;
        clearTakeover();
        drawUidBand();
        drawLapBand();
        drawStrip();
    }

    /// Set the BLE-advertised device name shown in the UID band's
    /// caption row (top-left). Idempotent. Caller passes the same
    /// string used in `BLEDevice::init`, so a future rename only
    /// surfaces here after the post-rename reboot — which is fine,
    /// the LCD repaint runs in `setup()` before the user can read it.
    /// Empty string clears the slot (falls back to "UID" caption).
    void setDeviceName(const char* name) {
        if (!name) name = "";
        if (strncmp(m_deviceName, name, sizeof(m_deviceName)) == 0) return;
        strncpy(m_deviceName, name, sizeof(m_deviceName) - 1);
        m_deviceName[sizeof(m_deviceName) - 1] = 0;
        drawUidBand();
    }

    void showLap(uint8_t num, uint32_t ms) {
        m_haveLap = true;
        m_lapNum = num;
        m_lapMs = ms;
        m_lapFlashUntilMs = millis() + 1000;
        // Capture the UID-redraw need before clearTakeover wipes the
        // takeover kind — otherwise we can't tell the band still owes
        // a paint after a bind takeover was short-circuited by this lap.
        bool needsUidRedraw = (m_takeoverKind == TakeoverKind::Bind);
        clearTakeover();
        if (needsUidRedraw) drawUidBand();
        drawLapBand();
    }

    /// Lap-band takeover for the TEST OSD probe verdict. Auto-clears after
    /// the takeover window back to the most recent lap.
    void showTestResult(bool ok) {
        startTakeover(TakeoverKind::Test, ok);
    }

    /// Lap-band takeover for the BIND verdict. Holds the UID band yellow
    /// for the whole takeover window so the operator sees the BINDING
    /// state — caller does not need a paired clear.
    void showBindResult(bool ok) {
        m_bindActive = true;
        drawUidBand();
        startTakeover(TakeoverKind::Bind, ok);
    }

    /// Battery readout shown in the UID band's top row, anchored to the
    /// left of the BLE pill. Idempotent: a setBattery call with the same
    /// values is a cheap cache compare, no redraw. Updates only the
    /// current widget slot — the rest of the UID band is untouched.
    /// Correctness across BLE pill width changes (BLE → BLE OFF) relies
    /// on `drawUidBand()` repainting the full band whenever BLE state
    /// flips, so a stale wider widget can't leave ghost pixels behind.
    void setBattery(int8_t percent, bool charging) {
        if (percent < -1) percent = -1;
        if (percent > 100) percent = 100;
        if (percent == m_battPct && charging == m_battCharging) return;
        m_battPct = percent;
        m_battCharging = charging;
        drawBatteryWidget();
    }

    /// Sticky message strip — persists across UID / lap redraws until
    /// clearMessage() is called. Surfaces radio / NVS failures across
    /// BLE events.
    void showMessage(const char* msg, uint16_t color = 0) {
        size_t len = strlen(msg);
        if (len >= sizeof(m_msg)) {
            Serial.printf("stick_display: showMessage truncated (%u -> %u)\n",
                          (unsigned)len, (unsigned)(sizeof(m_msg) - 1));
        }
        strncpy(m_msg, msg, sizeof(m_msg) - 1);
        m_msg[sizeof(m_msg) - 1] = 0;
        // 0 → ink color.
        m_msgColor = (color == 0) ? m_colInk : color;
        drawStrip();
    }

    void clearMessage() {
        m_msg[0] = 0;
        drawStrip();
    }

    /// Read-only access to the current sticky message text. Empty string
    /// when nothing is shown. Callers use this to scope a `clearMessage()`
    /// to "only if my own message is still up" — without this, e.g. a
    /// battery-recovery clear would silently drop an unrelated `RADIO
    /// DOWN` / `OSD LOST` that arrived in the meantime.
    const char* currentMessage() const { return m_msg; }

    void update() {
        M5.update();
        // While asleep, skip update()'s own time-driven repaints
        // (lap-flash and takeover expiry). External show*() callers
        // still write to GRAM behind the dark panel; wakePanel() does
        // a full repaint so those are eventually overdrawn.
        if (m_panelAsleep) return;
        uint32_t now = millis();

        if (m_lapFlashUntilMs && now >= m_lapFlashUntilMs) {
            m_lapFlashUntilMs = 0;
            drawLapBand();
        }

        if (m_takeoverUntilMs && now >= m_takeoverUntilMs) {
            // clearTakeover drops m_bindActive when wasBind, so the
            // UID band needs a redraw alongside the lap-band repaint.
            bool needsUidRedraw = (m_takeoverKind == TakeoverKind::Bind);
            clearTakeover();
            if (needsUidRedraw) drawUidBand();
            drawLapBand();
        }
    }

    /// Power-saving panel-off state (issue #5 phase 1). Idempotent.
    /// `M5.Display.sleep()` internally issues `_panel->setBrightness(0)`
    /// without touching LGFX's `_brightness` cache, so `wakeup()` later
    /// restores the original brightness on its own — no need to capture
    /// or re-apply it here. The full repaint on wake covers any external
    /// `show*()` calls that wrote to GRAM behind the dark panel.
    void sleepPanel() {
        if (m_panelAsleep) return;
        m_panelAsleep = true;
        M5.Display.sleep();
    }

    void wakePanel() {
        if (!m_panelAsleep) return;
        m_panelAsleep = false;
        M5.Display.wakeup();
        // ST7789 SLPOUT requires ~5 ms before the next command per the
        // datasheet; M5GFX's setSleep() doesn't insert it. Without this
        // wait, the first draw bytes after wakeup can be dropped and the
        // panel comes back blank until the next render edge.
        delay(5);
        M5.Display.fillScreen(TFT_BLACK);
        drawHairlines();
        drawUidBand();
        drawLapBand();
        drawStrip();
    }

    bool isPanelAsleep() const { return m_panelAsleep; }

    // Palette accessors — main.cpp uses these to pass strip colors to
    // showMessage() without depending on TFT_* names.
    uint16_t colorOk()     const { return m_colOk; }
    uint16_t colorWarn()   const { return m_colWarn; }
    uint16_t colorOrange() const { return m_colOrange; }
    uint16_t colorErr()    const { return m_colErr; }
    uint16_t colorAccent() const { return m_colAccent; }
    uint16_t colorCyan()   const { return m_colCyan; }
    uint16_t colorInk()    const { return m_colInk; }
    uint16_t colorSub()    const { return m_colSub; }

private:
    enum class TakeoverKind : uint8_t { None, Test, Bind };

    static constexpr int kUidBandY    = 0;
    static constexpr int kUidBandH    = 60;
    static constexpr int kHair1Y      = 60;
    static constexpr int kLapBandY    = 64;
    static constexpr int kLapBandH    = 46;
    static constexpr int kHair2Y      = 110;
    static constexpr int kStripY      = 113;
    static constexpr int kStripH      = 22;
    static constexpr uint32_t kTakeoverMs = 3000;

    int m_w = 240, m_h = 135;

    uint8_t m_uid[6] = {};
    bool m_bleConnected = false;
    bool m_radioReady = false;
    bool m_bindActive = false;

    // True when the UID on display came from the MAC-derived fallback in
    // setup(), not from an NVS load or a runtime BLE bind. Surfaces a
    // small "UNBOUND" tag in the UID band caption so a Web Flasher
    // "Erase All" run is visibly distinct from a previously-bound
    // device — without this, the MAC fallback is byte-for-byte the
    // same value across erase + reflash and looks like the wipe was a
    // no-op. main.cpp owns the source-of-truth flag and passes it on
    // every showStatus call.
    bool m_uidIsDefault = false;

    // BLE-advertised device name shown in the UID band caption row.
    // Width is symbolically tied to nvs_store::kDeviceNameMaxLen (+1
    // for null) so a future cap change can't silently truncate this
    // mirror buffer. Caption row truncates with an ellipsis if the
    // available width is smaller than the rendered string —
    // primarily an issue when UNBOUND is also showing, which eats
    // ~50 px on top of the right-side battery + BLE widgets.
    char m_deviceName[nvs_store::kDeviceNameMaxLen + 1] = {};

    bool m_haveLap = false;
    uint8_t m_lapNum = 0;
    uint32_t m_lapMs = 0;
    uint32_t m_lapFlashUntilMs = 0;

    TakeoverKind m_takeoverKind = TakeoverKind::None;
    bool m_takeoverOk = false;
    uint32_t m_takeoverUntilMs = 0;

    char m_msg[32] = {};
    uint16_t m_msgColor = 0;

    // -1 = unknown (not polled yet, or PMIC reported -1). 0..100 valid.
    int8_t m_battPct = -1;
    bool m_battCharging = false;
    bool m_panelAsleep = false;

    // Palette is filled by begin(); zero-init keeps pre-begin reads safe
    // (everything renders as black until begin() runs).
    uint16_t m_colInk = 0, m_colSub = 0, m_colDim = 0, m_colHair = 0;
    uint16_t m_colAccent = 0, m_colOk = 0, m_colWarn = 0;
    uint16_t m_colOrange = 0, m_colErr = 0, m_colCyan = 0;

    void startTakeover(TakeoverKind kind, bool ok) {
        // Hand-off: a different-kind takeover starting on top of an
        // in-flight Bind takeover would otherwise overwrite m_takeoverKind
        // and leave m_bindActive stranded — the iOS auto-pairing flow
        // hits this (bind → 2.5 s settle → test) within the 3 s window.
        if (m_takeoverKind == TakeoverKind::Bind && kind != TakeoverKind::Bind && m_bindActive) {
            m_bindActive = false;
            drawUidBand();
        }
        m_takeoverKind = kind;
        m_takeoverOk = ok;
        m_takeoverUntilMs = millis() + kTakeoverMs;
        drawLapBand();
    }

    void clearTakeover() {
        // m_bindActive is owned by the bind takeover lifecycle. Dropping
        // it here means showStatus / showLap / update() expiry all
        // reliably repaint the UID band white on the next draw —
        // otherwise an interrupted bind (lap arrives mid-takeover, BLE
        // reconnects mid-takeover) could strand the band yellow forever.
        if (m_takeoverKind == TakeoverKind::Bind) m_bindActive = false;
        m_takeoverKind = TakeoverKind::None;
        m_takeoverOk = false;
        m_takeoverUntilMs = 0;
    }

    void drawHairlines() {
        M5.Display.fillRect(0, kHair1Y, m_w, 1, m_colHair);
        M5.Display.fillRect(0, kHair2Y, m_w, 1, m_colHair);
    }

    void drawUidBand() {
        M5.Display.fillRect(0, kUidBandY, m_w, kUidBandH, TFT_BLACK);

        // Caption row: device name (or "UID" fallback) on the left, UNBOUND
        // tag right after, battery + BLE widgets on the right. The right
        // edge of the caption text must stay clear of the battery widget
        // — drawBatteryWidget anchors to the BLE pill, so the worst-case
        // left edge is ~m_w - 100 (BLE OFF + battery widget). Reserve a
        // safety margin and elide the caption with an ellipsis if it
        // wouldn't fit otherwise.
        M5.Display.setFont(&fonts::Font0);
        M5.Display.setTextSize(1);
        M5.Display.setTextColor(m_bindActive ? m_colWarn : m_colSub, TFT_BLACK);
        constexpr int kCaptionPxPerChar = 6;
        // Right-side reserve covers the worst-case battery widget + BLE
        // pill placement so the caption (incl. UNBOUND tag) cannot reach
        // pixels owned by the widget. Worst case is BLE OFF: BLE label
        // 42 px + 14 px gap = 56 px on the far right, and the battery
        // widget (kIconTotalW=14 + kGap=4 + kTextW=24 = 42 px) anchored
        // 8 px left of the BLE dot, so battery xLeft = m_w - 14 - 42 -
        // 8 - 42 = 134. With the previous 100-px reserve, a 14-char
        // name + UNBOUND extended to x=138 — 4 px into the battery
        // widget. 110 leaves the caption ending at x≤130 with a
        // safety margin.
        constexpr int kCaptionRightReserve = 110;
        const char* caption = (m_deviceName[0] != 0) ? m_deviceName : "UID";
        constexpr int kUnboundPad = 6;             // px gap before UNBOUND tag
        const int unboundW = (m_uidIsDefault && !m_bindActive)
                                 ? (int)strlen("UNBOUND") * kCaptionPxPerChar + kUnboundPad
                                 : 0;
        const int captionAvailPx = m_w - 6 - unboundW - kCaptionRightReserve;
        // Mirror m_deviceName's storage so the worst case (20-byte name +
        // null) fits exactly. The "UID" fallback is also well within this.
        char captionBuf[sizeof(m_deviceName)] = {};
        strncpy(captionBuf, caption, sizeof(captionBuf) - 1);
        const int maxCaptionChars = captionAvailPx / kCaptionPxPerChar;
        if (maxCaptionChars > 0 && (int)strlen(captionBuf) > maxCaptionChars) {
            // Replace the last visible character with an ellipsis so the
            // truncation is unambiguous instead of looking like a different
            // (shorter) name. Truncation lands at exactly maxCaptionChars
            // total: (maxCaptionChars - 1) real chars + '~', so the user
            // sees one more byte of the original name than truncating
            // before the overwrite would yield.
            captionBuf[maxCaptionChars] = 0;
            captionBuf[maxCaptionChars - 1] = '~';
        } else if (maxCaptionChars <= 0) {
            captionBuf[0] = 0;
        }
        M5.Display.setCursor(6, 6);
        M5.Display.print(captionBuf);
        // UNBOUND tag: in warn-yellow so it reads as "needs attention"
        // without escalating to error-red. Suppressed during a bind
        // takeover (m_bindActive) so the band is visually clean — that
        // takeover is itself the "binding now" affordance.
        if (m_uidIsDefault && !m_bindActive) {
            const int captionPx = (int)strlen(captionBuf) * kCaptionPxPerChar;
            M5.Display.setTextColor(m_colWarn, TFT_BLACK);
            M5.Display.setCursor(6 + captionPx + kUnboundPad, 6);
            M5.Display.print("UNBOUND");
            M5.Display.setTextColor(m_colSub, TFT_BLACK);
        }

        const char* bleLabel = m_bleConnected ? "BLE" : "BLE OFF";
        uint16_t bleCol = m_bleConnected ? m_colOk : m_colErr;
        int labelW = (int)strlen(bleLabel) * 6;
        int x = m_w - 6 - labelW;
        M5.Display.fillCircle(x - 6, 9, 2, bleCol);
        M5.Display.setTextColor(bleCol, TFT_BLACK);
        M5.Display.setCursor(x, 6);
        M5.Display.print(bleLabel);

        char uidStr[32];
        snprintf(uidStr, sizeof(uidStr), "%u,%u,%u,%u,%u,%u",
                 m_uid[0], m_uid[1], m_uid[2], m_uid[3], m_uid[4], m_uid[5]);

        uint16_t heroCol;
        if (m_bindActive)        heroCol = m_colWarn;
        else if (!m_radioReady)  heroCol = m_colDim;
        else                     heroCol = m_colInk;
        M5.Display.setTextColor(heroCol, TFT_BLACK);

        // Pick the largest fitting font; smallest is the fallback. Disable
        // wrap so a worst-case overflow clips at the edge instead of
        // rolling onto a second line that crosses the hairline.
        const lgfx::IFont* fontChain[] = {
            &fonts::FreeMonoBold18pt7b,
            &fonts::FreeMonoBold12pt7b,
            &fonts::FreeMonoBold9pt7b,
        };
        const int avail = m_w - 12;
        const lgfx::IFont* chosen = fontChain[2];
        for (auto* f : fontChain) {
            M5.Display.setFont(f);
            if (M5.Display.textWidth(uidStr) <= avail) { chosen = f; break; }
        }
        M5.Display.setFont(chosen);
        M5.Display.setTextSize(1);
        M5.Display.setTextWrap(false);

        int textW = M5.Display.textWidth(uidStr);
        int xHero = (m_w - textW) / 2;
        if (xHero < 4) xHero = 4;
        int slotTop = kUidBandY + 18;
        int slotH   = kUidBandH - 18;
        int fontH   = M5.Display.fontHeight();
        int yHero   = slotTop + (slotH - fontH) / 2;
        if (yHero < slotTop) yHero = slotTop;
        M5.Display.setCursor(xHero, yHero);
        M5.Display.print(uidStr);

        M5.Display.setFont(&fonts::Font0);
        M5.Display.setTextSize(1);
        M5.Display.setTextWrap(true);
        M5.Display.setTextColor(m_colInk, TFT_BLACK);

        drawBatteryWidget();
    }

    void drawBatteryWidget() {
        // Anchor the right edge of the widget 8 px left of the BLE pill's
        // dot. The BLE label width changes (BLE → BLE OFF), so the widget
        // slides too — the widget's own wipe rect is sized to the worst
        // case so a prior wider label can't leave ghost pixels behind.
        const char* bleLabel = m_bleConnected ? "BLE" : "BLE OFF";
        int labelW = (int)strlen(bleLabel) * 6;
        int blePillLeftPx = m_w - 14 - labelW;  // leftmost pixel of the BLE dot
        int xRight = blePillLeftPx - 8;

        constexpr int kIconBodyW = 12;
        constexpr int kIconTipW  = 2;
        constexpr int kIconTotalW = kIconBodyW + kIconTipW;
        constexpr int kIconH     = 6;
        constexpr int kIconY     = 7;          // visually centered with the 8 px Font0 row at y=6
        constexpr int kIconInnerMaxW = kIconBodyW - 2;
        constexpr int kIconInnerH    = kIconH - 2;
        constexpr int kGap       = 4;
        constexpr int kTextChars = 4;          // " 87%" / "100%" / " --%"
        constexpr int kTextW     = kTextChars * 6;
        constexpr int kWidgetW   = kIconTotalW + kGap + kTextW;
        constexpr int kWipeH     = 14;         // strictly above the UID hero slot at y=18

        int xLeft = xRight - kWidgetW;
        // Widest BLE-label position is "BLE OFF"; using the actual current
        // xLeft is fine because every drawUidBand wipes the full band first
        // and every standalone setBattery call uses the same xLeft until
        // the BLE state changes (which forces a full drawUidBand redraw).
        M5.Display.fillRect(xLeft, kUidBandY, kWidgetW, kWipeH, TFT_BLACK);

        uint16_t color;
        if (m_battPct < 0)            color = m_colDim;
        else if (m_battCharging)      color = m_colCyan;
        else if (m_battPct < 20)      color = m_colErr;
        else if (m_battPct < 40)      color = m_colWarn;
        else                          color = m_colOk;

        int xIcon = xLeft;
        M5.Display.drawRect(xIcon, kIconY, kIconBodyW, kIconH, color);
        M5.Display.fillRect(xIcon + kIconBodyW, kIconY + 2, kIconTipW, 2, color);
        if (m_battPct >= 0) {
            int fillW = (m_battPct * kIconInnerMaxW + 50) / 100;
            if (fillW < 0) fillW = 0;
            if (fillW > kIconInnerMaxW) fillW = kIconInnerMaxW;
            if (fillW > 0) {
                M5.Display.fillRect(xIcon + 1, kIconY + 1, fillW, kIconInnerH, color);
            }
        }

        M5.Display.setFont(&fonts::Font0);
        M5.Display.setTextSize(1);
        M5.Display.setTextColor(color, TFT_BLACK);
        M5.Display.setCursor(xIcon + kIconTotalW + kGap, 6);
        char buf[8];
        if (m_battPct < 0) snprintf(buf, sizeof(buf), " --%%");
        else               snprintf(buf, sizeof(buf), "%3d%%", (int)m_battPct);
        M5.Display.print(buf);
        M5.Display.setTextColor(m_colInk, TFT_BLACK);
    }

    void drawLapBand() {
        M5.Display.fillRect(0, kLapBandY, m_w, kLapBandH, TFT_BLACK);

        if (m_takeoverUntilMs && millis() < m_takeoverUntilMs) {
            drawTakeover();
            return;
        }

        M5.Display.setTextSize(1);
        M5.Display.setTextColor(m_colSub, TFT_BLACK);
        M5.Display.setCursor(6, kLapBandY + 4);
        M5.Display.print("LAST LAP");
        int timeLabelW = M5.Display.textWidth("TIME");
        M5.Display.setCursor(m_w - 6 - timeLabelW, kLapBandY + 4);
        M5.Display.print("TIME");

        // Lap number and time share the same dim/ink rule: dim if no lap
        // yet OR either link is down. The lap *value* survived as past
        // data either way; the dim treatment communicates "you can't
        // trust this to be reaching the goggle right now."
        bool flashing = m_haveLap && m_lapFlashUntilMs && millis() < m_lapFlashUntilMs;
        bool linksUp = m_bleConnected && m_radioReady;
        uint16_t lapCol;
        if (!m_haveLap)     lapCol = m_colDim;
        else if (flashing)  lapCol = m_colAccent;
        else if (!linksUp)  lapCol = m_colDim;
        else                lapCol = m_colInk;

        M5.Display.setTextColor(lapCol, TFT_BLACK);
        M5.Display.setTextSize(3); // 18×24
        char numBuf[8];
        if (m_haveLap) snprintf(numBuf, sizeof(numBuf), "%02u", m_lapNum);
        else           snprintf(numBuf, sizeof(numBuf), "--");
        M5.Display.setCursor(6, kLapBandY + 16);
        M5.Display.print(numBuf);

        uint16_t timeCol = (m_haveLap && linksUp) ? m_colInk : m_colDim;
        M5.Display.setTextColor(timeCol, TFT_BLACK);
        M5.Display.setTextSize(2); // 12×16
        char timeBuf[16];
        if (m_haveLap) {
            uint32_t s = m_lapMs / 1000;
            uint32_t m = s / 60;
            s %= 60;
            uint32_t milli = m_lapMs % 1000;
            snprintf(timeBuf, sizeof(timeBuf), "%02lu:%02lu.%03lu",
                     (unsigned long)m, (unsigned long)s, (unsigned long)milli);
        } else {
            snprintf(timeBuf, sizeof(timeBuf), "--:--.---");
        }
        int timeW = M5.Display.textWidth(timeBuf);
        M5.Display.setCursor(m_w - 6 - timeW, kLapBandY + 20);
        M5.Display.print(timeBuf);

        M5.Display.setTextSize(1);
        M5.Display.setTextColor(m_colInk, TFT_BLACK);
    }

    void drawTakeover() {
        const char* caption = "";
        const char* verdict = "";
        uint16_t color = m_colInk;
        switch (m_takeoverKind) {
            case TakeoverKind::Test:
                caption = "TEST OSD";
                verdict = m_takeoverOk ? "DELIVERED" : "LOST";
                color   = m_takeoverOk ? m_colOk : m_colErr;
                break;
            case TakeoverKind::Bind:
                caption = "BIND PACKET";
                verdict = m_takeoverOk ? "SENT" : "FAIL";
                color   = m_takeoverOk ? m_colWarn : m_colErr;
                break;
            case TakeoverKind::None:
                return;
        }

        M5.Display.setTextSize(1);
        M5.Display.setTextColor(color, TFT_BLACK);
        int capW = M5.Display.textWidth(caption);
        M5.Display.setCursor((m_w - capW) / 2, kLapBandY + 4);
        M5.Display.print(caption);

        M5.Display.setTextSize(3);
        int verW = M5.Display.textWidth(verdict);
        if (verW > m_w - 8) {
            M5.Display.setTextSize(2);
            verW = M5.Display.textWidth(verdict);
        }
        M5.Display.setCursor((m_w - verW) / 2, kLapBandY + 18);
        M5.Display.print(verdict);

        M5.Display.setTextSize(1);
        M5.Display.setTextColor(m_colInk, TFT_BLACK);
    }

    void drawStrip() {
        M5.Display.fillRect(0, kStripY, m_w, kStripH, TFT_BLACK);

        const char* radioLabel = m_radioReady ? "RADIO" : "RADIO DOWN";
        uint16_t radioCol = m_radioReady ? m_colOk : m_colErr;
        M5.Display.fillCircle(8, kStripY + 9, 2, radioCol);
        M5.Display.setTextSize(1);
        M5.Display.setTextColor(radioCol, TFT_BLACK);
        M5.Display.setCursor(16, kStripY + 6);
        M5.Display.print(radioLabel);

        if (m_msg[0]) {
            int msgW = M5.Display.textWidth(m_msg);
            int msgX = m_w - 6 - msgW;
            // Floor the start position so a long message can't run over
            // the RADIO label. Visible width used by the label = 16 (icon
            // gutter) + textWidth(label) + 6 (separator).
            int radioRight = 16 + M5.Display.textWidth(radioLabel) + 6;
            if (msgX < radioRight) {
                Serial.printf("stick_display: strip clipped (msg=\"%s\" overruns RADIO label)\n", m_msg);
                msgX = radioRight;
            }
            M5.Display.setTextColor(m_msgColor, TFT_BLACK);
            M5.Display.setCursor(msgX, kStripY + 6);
            M5.Display.print(m_msg);
        }

        M5.Display.setTextColor(m_colInk, TFT_BLACK);
    }
};
