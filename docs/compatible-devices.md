# Compatible ESP32 Devices for HDZap

HDZap firmware uses **BLE GATT** (iOS ↔ bridge) and **ESP-NOW** (bridge ↔ HDZero backpack).
Any candidate chip must support **both**.

## Chip eligibility

| Chip | Wi-Fi (ESP-NOW) | BLE | Verdict |
|---|---|---|---|
| ESP32 (classic) | ✅ | ✅ BT Classic + BLE 4.2 | ✅ usable |
| ESP32-S2 | ✅ | ❌ none | ❌ no BLE |
| ESP32-S3 | ✅ | ✅ BLE 5 | ✅ **current target (M5StickS3)** |
| ESP32-C2 (ESP8684) | ✅ | ✅ BLE 5 | ✅ usable |
| ESP32-C3 | ✅ | ✅ BLE 5 | ✅ usable |
| ESP32-C5 | ✅ Wi-Fi 6 dual-band | ✅ BLE 5 | ✅ usable (very new) |
| ESP32-C6 | ✅ Wi-Fi 6 | ✅ BLE 5 (+ 802.15.4) | ✅ usable |
| ESP32-H2 | ❌ no Wi-Fi | ✅ BLE 5 | ❌ no ESP-NOW |
| ESP32-P4 | ❌ no radio | ❌ none | ❌ no wireless |

ESP-NOW rides on the Wi-Fi MAC layer, so any chip without a Wi-Fi radio is automatically out.

---

## Battery-included devices (works out of the box)

These ship with a built-in LiPo, charging IC, case, and (usually) a display — no soldering required.

### ESP32-S3

| Device | Battery | UI / Notes |
|---|---|---|
| **M5StickS3** ⭐ current target | 120 mAh built-in | 1.14" LCD, 2 buttons, buzzer, AXP2101 PMIC |
| **M5Cardputer** | 120 mAh built-in | 1.14" LCD, QWERTY keyboard, speaker |
| **M5Dial** | 300 mAh built-in | 1.28" round touch LCD, rotary encoder, RTC, speaker |
| **M5StampFly** | 300 mAh (drone) | full quadcopter platform |
| **LilyGO T-Watch S3** | 470 mAh built-in | 1.54" touch LCD, accelerometer, vibration motor (smartwatch form factor) |
| **LilyGO T-Deck** | built-in | 2.8" LCD, QWERTY, trackball, speaker |
| **LilyGO T-Deck Plus** | built-in | T-Deck + GPS + LoRa |
| **LilyGO T-Embed** | 1300 mAh built-in | 1.9" LCD, rotary encoder, mic, speaker |
| **LilyGO T-Embed CC1101** | 1300 mAh built-in | T-Embed + Sub-GHz radio |
| **LilyGO T-Display S3 AMOLED Plus** | built-in | 1.9" AMOLED |

### ESP32 (classic)

| Device | Battery | UI / Notes |
|---|---|---|
| **M5StickC Plus2** ⚠️ **EOL** | 200 mAh built-in | 1.14" LCD — confirmed end-of-life on Switch Science 2026; in-stock only while inventory lasts. **Do not pick for new designs.** |
| **M5StickC Plus** ⚠️ EOL | 120 mAh built-in | 1.14" LCD |
| **TTGO T-Beam v1.2** | 18650 holder | 0.96" OLED, GPS, LoRa — bulky |
| **LilyGO T-Watch 2020** | built-in | superseded by T-Watch S3 |

### ESP32-C3 / C6

No fully integrated battery + case + display product currently ships in this category. C3/C6 ecosystem is still dominated by bare boards with solder pads (see next section).

---

## Battery-external devices (LiPo connector or solder pads)

Charging IC is on board — just plug or solder a LiPo. No case.

### ESP32-S3

| Device | Charge IC | Connector | Notes |
|---|---|---|---|
| **Seeed XIAO ESP32-S3** | built-in | rear pads | 21 × 17.5 mm, ultra small |
| **Seeed XIAO ESP32-S3 Sense** | built-in | rear pads | XIAO + camera + mic |
| **Adafruit QT Py ESP32-S3** | built-in | JST PH | XIAO-class footprint |
| **Adafruit Feather ESP32-S3** | built-in | JST PH 2 mm | Feather form factor |
| **Unexpected Maker FeatherS3** | built-in | JST PH | high build quality |
| **Unexpected Maker TinyS3** | built-in | pads | small |
| **Unexpected Maker ProS3** | built-in | JST PH | more pins |
| **Unexpected Maker NanoS3** | built-in | pads | Nano-size |
| **LilyGO T-Display S3** | built-in | JST | 1.9" LCD on board |
| **LilyGO T-Dongle S3** | built-in | connector | USB dongle + TFT |
| **M5StampS3** | external HAT | pads | needs M5 battery HAT |
| **M5AtomS3 / AtomS3R** | external Base | connector | needs AtomBase w/ battery |
| **Heltec Wireless Stick Lite V3** | built-in | JST PH 1.25 | 0.96" OLED |
| **Heltec Wireless Paper** | built-in | JST | E-Ink display |

### ESP32-C3

| Device | Charge IC | Connector | Notes |
|---|---|---|---|
| **Seeed XIAO ESP32-C3** | built-in | rear pads | smallest, ~$5 |
| **Adafruit QT Py ESP32-C3** | built-in | JST PH | XIAO-class footprint |
| **LilyGO T-OI Plus** | built-in | 14500 holder onboard | unique form factor |
| **DFRobot Beetle ESP32-C3** | built-in | connector | small |
| **M5StampC3 / C3U** | external HAT | pads | needs M5 battery HAT |

### ESP32-C6

| Device | Charge IC | Connector | Notes |
|---|---|---|---|
| **Seeed XIAO ESP32-C6** | built-in | rear pads | smallest C6 option |
| **Adafruit Feather ESP32-C6** | built-in | JST PH | Feather standard |
| **Adafruit QT Py ESP32-C6** | built-in | JST PH | QT Py footprint |
| **M5NanoC6** | external | pads | needs separate battery wiring |
| **Waveshare ESP32-C6 Zero** | external | none | bare; cheapest |

### ESP32-C2 (ESP8684)

Mostly used as embedded modules — few hobbyist-grade dev boards with on-board charging exist.

### ESP32-C5

| Device | Charge IC | Connector | Notes |
|---|---|---|---|
| **Espressif ESP32-C5-DevKitC-1** | none | none | evaluation board only |

---

## Recommendations

| Use case | Pick |
|---|---|
| **HDZap as-is, with LCD** | **M5StickS3** (current target — keep it) |
| **Smallest, OK with soldering** | **Seeed XIAO ESP32-S3** + LiPo |
| **Adafruit ecosystem** | **Adafruit Feather ESP32-S3** |
| **Future-proof (Thread/Zigbee option)** | **Adafruit Feather ESP32-C6** or **XIAO ESP32-C6** |
| **Need on-device keyboard** | **M5Cardputer** |
| **Wearable** | **LilyGO T-Watch S3** |

---

## Notes

- ⚠️ **M5StickC Plus2 is EOL** (confirmed on Switch Science 2026; M5 recommends **M5StickS3** as the successor). Do not select for new builds.
- ❌ **ESP32-S2, ESP32-H2, ESP32-P4** cannot satisfy BLE + ESP-NOW simultaneously.
- This list is curated from the maintainer's working knowledge; verify stock, price, and current revision on each vendor's site (Switch Science, M5Stack, LilyGO, Seeed, Adafruit, Unexpected Maker, DFRobot, Heltec, Waveshare) before ordering.
- Porting effort beyond M5StickS3: pin map, LCD/buttons/PMIC presence, and battery monitoring will need adaptation. Core BLE + ESP-NOW + MSP/OSD logic is chip-portable.
