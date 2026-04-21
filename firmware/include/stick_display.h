#pragma once
#include <M5Unified.h>
#include <cstring>

/// M5StickS3 LCD: fixed regions that don't overlap, so each drawing
/// function only touches its own strip:
///   [0 .. 20)              header (drawn once at begin())
///   [24 .. h-kMsgStripH)   status / lap card body
///   [h-kMsgStripH .. h)    message strip (sticky; persists across
///                          status and lap redraws until
///                          clearMessage() is called)
class StickDisplay {
public:
    void begin() {
        auto cfg = M5.config();
        M5.begin(cfg);
        M5.Display.setRotation(1);
        M5.Display.fillScreen(TFT_BLACK);
        M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
        M5.Display.setTextSize(2);
        m_msg[0] = 0;
        drawHeader();
    }

    void drawHeader() {
        M5.Display.fillRect(0, 0, M5.Display.width(), 20, TFT_BLUE);
        M5.Display.setCursor(4, 3);
        M5.Display.setTextColor(TFT_WHITE, TFT_BLUE);
        M5.Display.print("HDZero OSD");
        M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
    }

    void showStatus(const uint8_t uid[6], bool bleConnected) {
        int bodyHeight = M5.Display.height() - 24 - kMsgStripH;
        M5.Display.fillRect(0, 24, M5.Display.width(), bodyHeight, TFT_BLACK);
        M5.Display.setCursor(4, 28);
        M5.Display.setTextSize(1);
        M5.Display.printf("UID:\n %02X:%02X:%02X:%02X:%02X:%02X\n\n",
                          uid[0], uid[1], uid[2], uid[3], uid[4], uid[5]);
        M5.Display.setTextSize(2);
        M5.Display.setTextColor(bleConnected ? TFT_GREEN : TFT_RED, TFT_BLACK);
        M5.Display.printf("BLE: %s", bleConnected ? "OK" : "---");
        M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
    }

    void showLap(uint8_t num, uint32_t ms) {
        // Anchor the lap card above the message strip so a sticky error
        // stays visible across successive laps.
        int y = M5.Display.height() - 40 - kMsgStripH;
        M5.Display.fillRect(0, y, M5.Display.width(), 40, TFT_BLACK);
        M5.Display.setCursor(4, y);
        M5.Display.setTextSize(2);
        M5.Display.setTextColor(TFT_YELLOW, TFT_BLACK);
        uint32_t s = ms / 1000;
        uint32_t m = s / 60;
        s %= 60;
        uint32_t milli = ms % 1000;
        M5.Display.printf("Lap %02d\n%02lu:%02lu.%03lu", num,
                          (unsigned long)m, (unsigned long)s, (unsigned long)milli);
        M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
    }

    /// Set the sticky message strip. Stays on screen across showStatus /
    /// showLap redraws — crucial for surfacing radio / NVS failures that
    /// used to get wiped on the next BLE event.
    void showMessage(const char* msg, uint16_t color = TFT_CYAN) {
        strncpy(m_msg, msg, sizeof(m_msg) - 1);
        m_msg[sizeof(m_msg) - 1] = 0;
        m_msgColor = color;
        drawMessageStrip();
    }

    void clearMessage() {
        m_msg[0] = 0;
        drawMessageStrip();
    }

    void update() { M5.update(); }

private:
    static constexpr int kMsgStripH = 16;
    char m_msg[32] = {};
    uint16_t m_msgColor = TFT_CYAN;

    void drawMessageStrip() {
        int y = M5.Display.height() - kMsgStripH;
        M5.Display.fillRect(0, y, M5.Display.width(), kMsgStripH, TFT_BLACK);
        if (m_msg[0] == 0) return;
        M5.Display.setCursor(4, y);
        M5.Display.setTextSize(1);
        M5.Display.setTextColor(m_msgColor, TFT_BLACK);
        M5.Display.print(m_msg);
        M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
    }
};
