#pragma once
#include <M5Unified.h>

class StickDisplay {
public:
    void begin() {
        auto cfg = M5.config();
        M5.begin(cfg);
        M5.Display.setRotation(1);
        M5.Display.fillScreen(TFT_BLACK);
        M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
        M5.Display.setTextSize(2);
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
        M5.Display.fillRect(0, 24, M5.Display.width(), M5.Display.height() - 24, TFT_BLACK);
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
        int y = M5.Display.height() - 40;
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

    void showMessage(const char* msg, uint16_t color = TFT_CYAN) {
        int y = M5.Display.height() - 16;
        M5.Display.fillRect(0, y, M5.Display.width(), 16, TFT_BLACK);
        M5.Display.setCursor(4, y);
        M5.Display.setTextSize(1);
        M5.Display.setTextColor(color, TFT_BLACK);
        M5.Display.print(msg);
        M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
    }

    void update() { M5.update(); }
};
