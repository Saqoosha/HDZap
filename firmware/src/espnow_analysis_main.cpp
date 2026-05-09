/**
 * ESP-NOW / Wi-Fi bench sniffer — separate PlatformIO environment
 * `m5stick-s3-espnow-analysis` (see platformio.ini).
 *
 * From boot: Wi-Fi promiscuous mode on a fixed channel logs *all* 802.11
 * frames the radio reports (mgmt/data/control), not just ESP-NOW unicasts
 * to this MAC. Use this to see whether ELRS backpack traffic appears on
 * air at all and at which RSSI.
 *
 * Output:
 *   - Serial @ 921600:
 *       • `EN,millis,rssi,ch,len,wtype,hex` for ESP-NOW OUI-confirmed raw MPDUs.
 *       • `MS,millis,rssi,ch,len,wtype,hex` for MSP-looking raw MPDU candidates (`$M`/`$X`).
 *       • comment status every 2 s: `# pkts=... en=... ms=... dropQ=...`
 *   - SPIFFS is disabled by default; serial capture avoids small-flash limits and slow writes.
 *
 * Promiscuous callback runs in the WiFi task — we only enqueue caps; loop()
 * formats and writes (matches IDF guidance, avoids blocking the RX path).
 */

#include <Arduino.h>
#include <M5Unified.h>
#include <SPIFFS.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#ifndef ANALYSIS_WIFI_CHANNEL
#define ANALYSIS_WIFI_CHANNEL 1
#endif

#ifndef ANALYSIS_MAX_CAP_BYTES
// Hex dump length per line (payload truncated; full 802.11 frame can be larger).
#define ANALYSIS_MAX_CAP_BYTES 384
#endif

#ifndef ANALYSIS_LOG_MAX_BYTES
#define ANALYSIS_LOG_MAX_BYTES (96 * 1024)
#endif

#ifndef ANALYSIS_EN_RAW_MAX_BYTES
#define ANALYSIS_EN_RAW_MAX_BYTES (64 * 1024)
#endif

#ifndef ANALYSIS_ONLY_ESPNOW
// 1 = SPIFFS + serial only EN (skip building other frames — less CPU/RAM).
#define ANALYSIS_ONLY_ESPNOW 0
#endif

#ifndef ANALYSIS_SERIAL_VERBOSE
// 0 = default: Serial prints status + tag=EN only; full classified log stays on SPIFFS.
// 1 = print every classified packet on Serial (very noisy).
#define ANALYSIS_SERIAL_VERBOSE 0
#endif

#ifndef ANALYSIS_SAVE_SPIFFS
// Default off: flash writes are slow and the 128 KiB partition is too small for sniffing.
#define ANALYSIS_SAVE_SPIFFS 0
#endif

#ifndef ANALYSIS_STREAM_MSP_CANDIDATES
// Keep MSP-looking frames separate from ESP-NOW OUI-confirmed frames while still saving them.
#define ANALYSIS_STREAM_MSP_CANDIDATES 1
#endif

#ifndef ANALYSIS_CAP_QUEUE_DEPTH
// Each slot is ~sizeof(CapEvent) (~400 B); ~80 KiB @ 192 vs ~145 KiB @ 384 — avoid WiFi heap pressure.
#define ANALYSIS_CAP_QUEUE_DEPTH 192
#endif

// IEEE 802.11: management + Action uses a 24-byte header (FC, dur, 3×addr, seq) before body.
static constexpr size_t k80211MgmtActionBodyOff = 24;

/// Espressif ESP-NOW uses Vendor Specific Public Action: category 0x7f + OUI 18:fe:34 (IDF docs).
static bool body_is_espnow_vendor_action(const uint8_t *body, size_t bodyLen) {
    if (bodyLen < 4) return false;
    return body[0] == 0x7F && body[1] == 0x18 && body[2] == 0xFE && body[3] == 0x34;
}

/// Scan raw MPDU for Espressif ESP-NOW signature (fallback if header length differs).
static bool scan_contains_espnow_oui(const uint8_t *p, size_t len) {
    if (len < 4) return false;
    for (size_t i = 0; i + 4 <= len; i++) {
        if (body_is_espnow_vendor_action(p + i, len - i)) return true;
    }
    return false;
}

/// MSP v1 ($M…), MSPv2 ($X…), and case variants — often inside Backpack / ELRS paths.
static bool payload_maybe_msp(const uint8_t *p, size_t len) {
    for (size_t i = 0; i + 2 < len; i++) {
        if (p[i] != '$') continue;
        uint8_t b = p[i + 1];
        if (b == 'M' || b == 'm' || b == 'X' || b == 'x') return true;
    }
    return false;
}

enum class FrameTag : uint8_t {
    Other = 0,
    Beacon,
    Espnow,
    MspCandidate,
    MgmtOther,
    Data,
    Control,
};

static FrameTag classify_frame(const uint8_t *p, uint16_t len, bool *out_mspHint) {
    *out_mspHint = false;
    if (len < 2) return FrameTag::Other;
    uint16_t fc = static_cast<uint16_t>(p[0] | (p[1] << 8));
    unsigned type = (fc >> 2) & 3U;
    unsigned subtype = (fc >> 4) & 0xFU;

    if (type == 0U) { // management
        if (subtype == 8U) return FrameTag::Beacon;
        if (subtype == 13U && len >= k80211MgmtActionBodyOff + 4) {
            const uint8_t *body = p + k80211MgmtActionBodyOff;
            size_t bodyLen = len - k80211MgmtActionBodyOff;
            if (body_is_espnow_vendor_action(body, bodyLen)) {
                *out_mspHint = payload_maybe_msp(p, len);
                return FrameTag::Espnow;
            }
        }
        if (scan_contains_espnow_oui(p, len)) {
            *out_mspHint = payload_maybe_msp(p, len);
            return FrameTag::Espnow;
        }
        return FrameTag::MgmtOther;
    }
    if (type == 2U) { // data
        if (scan_contains_espnow_oui(p, len)) {
            *out_mspHint = payload_maybe_msp(p, len);
            return FrameTag::Espnow;
        }
#if ANALYSIS_STREAM_MSP_CANDIDATES
        if (payload_maybe_msp(p, len)) {
            *out_mspHint = true;
            return FrameTag::MspCandidate;
        }
#endif
        return FrameTag::Data;
    }
    if (type == 1U) { // control
        if (scan_contains_espnow_oui(p, len)) {
            *out_mspHint = payload_maybe_msp(p, len);
            return FrameTag::Espnow;
        }
        return FrameTag::Control;
    }
    return FrameTag::Other;
}

static const char *tag_str(FrameTag t) {
    switch (t) {
    case FrameTag::Espnow:
        return "EN";
    case FrameTag::MspCandidate:
        return "MS";
    case FrameTag::Beacon:
        return "BC";
    case FrameTag::MgmtOther:
        return "MG";
    case FrameTag::Data:
        return "DA";
    case FrameTag::Control:
        return "CT";
    default:
        return "OT";
    }
}

static constexpr const char *kLogPath = "/espnow_cap.txt";
static constexpr const char *kEnRawPath = "/espnow_en_raw.csv";

#pragma pack(push, 1)
struct CapEvent {
    uint32_t ms;
    wifi_promiscuous_pkt_type_t wtype;
    int8_t rssi;
    uint8_t channel;
    uint16_t len;
    uint8_t data[ANALYSIS_MAX_CAP_BYTES];
};
#pragma pack(pop)

static QueueHandle_t g_cap_queue;
static File g_log;
static bool g_spiffs_ok;
static uint32_t g_total_packets = 0;
static uint32_t g_dropped_queue = 0;
static uint32_t g_espnow_packets = 0;
static uint32_t g_msp_candidate_packets = 0;

static void rotateLogIfHuge() {
    if (!g_spiffs_ok || !SPIFFS.exists(kLogPath)) return;
    size_t sz = SPIFFS.open(kLogPath, FILE_READ).size();
    if (sz < ANALYSIS_LOG_MAX_BYTES) return;
    Serial.printf("espnow_analysis: rotating log (%u bytes)\n", (unsigned)sz);
    if (SPIFFS.exists("/espnow_cap.old")) SPIFFS.remove("/espnow_cap.old");
    SPIFFS.rename(kLogPath, "/espnow_cap.old");
    g_log = SPIFFS.open(kLogPath, FILE_APPEND, true);
}

static void rotateEnRawIfHuge() {
    if (!g_spiffs_ok || !SPIFFS.exists(kEnRawPath)) return;
    size_t sz = SPIFFS.open(kEnRawPath, FILE_READ).size();
    if (sz < ANALYSIS_EN_RAW_MAX_BYTES) return;
    Serial.printf("espnow_analysis: rotating EN raw (%u bytes)\n", (unsigned)sz);
    if (SPIFFS.exists("/espnow_en_raw.old")) SPIFFS.remove("/espnow_en_raw.old");
    SPIFFS.rename(kEnRawPath, "/espnow_en_raw.old");
}

/// Optional one line per EN frame in SPIFFS. Serial streaming is the primary capture path.
static void appendEnRawCsv(const CapEvent &e, size_t n, int mspHint, wifi_promiscuous_pkt_type_t wtype) {
#if ANALYSIS_SAVE_SPIFFS
    if (!g_spiffs_ok || n == 0) return;
    rotateEnRawIfHuge();
    File f = SPIFFS.open(kEnRawPath, FILE_APPEND, true);
    if (!f) return;
    f.printf("%lu,%d,%u,%u,%d,%d,", (unsigned long)e.ms, (int)e.rssi, (unsigned)e.channel,
             (unsigned)e.len, (int)wtype, mspHint);
    for (size_t i = 0; i < n; i++) {
        f.printf("%02x", e.data[i]);
    }
    f.printf("\n");
    f.close();
#else
    (void)e;
    (void)n;
    (void)mspHint;
    (void)wtype;
#endif
}

static void writeHex(Print &out, const uint8_t *data, size_t n) {
    static const char kHex[] = "0123456789abcdef";
    char pair[2];
    for (size_t i = 0; i < n; i++) {
        uint8_t b = data[i];
        pair[0] = kHex[b >> 4];
        pair[1] = kHex[b & 0x0F];
        out.write((const uint8_t *)pair, sizeof(pair));
    }
}

static void streamRawCsv(const char *tag, const CapEvent &e, size_t n) {
    Serial.printf("%s,%lu,%d,%u,%u,%d,", tag, (unsigned long)e.ms, (int)e.rssi,
                  (unsigned)e.channel, (unsigned)e.len, (int)e.wtype);
    writeHex(Serial, e.data, n);
    Serial.write('\n');
}

static void appendHexLine(const CapEvent &e) {
    constexpr size_t kHexPerByte = 2;
    size_t n = e.len;
    if (n > sizeof(e.data)) n = sizeof(e.data);
    bool mspHint = false;
    FrameTag tag = classify_frame(e.data, e.len, &mspHint);
#if ANALYSIS_ONLY_ESPNOW
    if (tag != FrameTag::Espnow && tag != FrameTag::MspCandidate) return;
#endif
    if (tag == FrameTag::Espnow) {
        g_espnow_packets++;
        appendEnRawCsv(e, n, mspHint ? 1 : 0, e.wtype);
        streamRawCsv("EN", e, n);
        return;
    }
    if (tag == FrameTag::MspCandidate) {
        g_msp_candidate_packets++;
        streamRawCsv("MS", e, n);
        return;
    }

#if ANALYSIS_SAVE_SPIFFS || ANALYSIS_SERIAL_VERBOSE
    size_t hex_chars = n * kHexPerByte;
    constexpr size_t kPrefix = 192;
    char *buf = (char *)malloc(kPrefix + hex_chars + 4);
    if (!buf) return;
    int ph = snprintf(buf, kPrefix,
                      "tag=%-2s msp=%d %10lu t=%d rssi=%d ch=%u len=%u ",
                      tag_str(tag), mspHint ? 1 : 0, (unsigned long)e.ms, (int)e.wtype,
                      (int)e.rssi, (unsigned)e.channel, (unsigned)e.len);
    if (ph < 0 || (size_t)ph >= kPrefix) ph = 0;
    static const char kHex[] = "0123456789abcdef";
    char *p = buf + ph;
    for (size_t i = 0; i < n; i++) {
        uint8_t b = e.data[i];
        p[i * 2] = kHex[b >> 4];
        p[i * 2 + 1] = kHex[b & 0x0F];
    }
    p[n * 2] = '\n';
    p[n * 2 + 1] = '\0';
    size_t total = (size_t)ph + n * 2 + 1;
#if ANALYSIS_SERIAL_VERBOSE
    Serial.write((const uint8_t *)buf, total);
#else
    if (tag == FrameTag::Espnow) {
        Serial.write((const uint8_t *)buf, total);
    }
#endif
    if (g_log && g_spiffs_ok) {
        rotateLogIfHuge();
        g_log.write((const uint8_t *)buf, total);
        g_log.flush();
    }
    free(buf);
#else
    (void)kHexPerByte;
#endif
}

static void promiscuous_rx(void *buf, wifi_promiscuous_pkt_type_t type) {
    if (!g_cap_queue) return;
    auto *pkt = (wifi_promiscuous_pkt_t *)buf;
    const wifi_pkt_rx_ctrl_t *rx = &pkt->rx_ctrl;
    CapEvent ev{};
    ev.ms = millis();
    ev.wtype = type;
    ev.rssi = rx->rssi;
    ev.channel = rx->channel;
    // `sig_len` is a bitfield in IDF; promote to uint16_t for memcpy bounds.
    uint16_t sig = (uint16_t)rx->sig_len;
    ev.len = sig;
    if (ev.len > sizeof(ev.data)) ev.len = sizeof(ev.data);
    memcpy(ev.data, pkt->payload, ev.len);
    if (xQueueSend(g_cap_queue, &ev, 0) != pdTRUE) {
        g_dropped_queue++;
    }
    g_total_packets++;
}

void setup() {
    Serial.begin(921600);
    delay(200);
    auto cfg = M5.config();
    M5.begin(cfg);
    M5.Display.setRotation(1);
    M5.Display.setTextSize(1);
    M5.Display.printf("ESPNOW ANALYSIS\nch%d\n", ANALYSIS_WIFI_CHANNEL);

    g_cap_queue = xQueueCreate(ANALYSIS_CAP_QUEUE_DEPTH, sizeof(CapEvent));
    if (!g_cap_queue) {
        Serial.println("espnow_analysis: queue alloc failed");
    }

#if ANALYSIS_SAVE_SPIFFS
    g_spiffs_ok = SPIFFS.begin(true);
    if (!g_spiffs_ok) {
        Serial.println("espnow_analysis: SPIFFS mount failed — Serial only");
    } else {
        g_log = SPIFFS.open(kLogPath, FILE_APPEND, true);
        if (!g_log) {
            Serial.println("espnow_analysis: log open failed");
        } else {
            g_log.printf("\n# espnow_analysis boot millis=%lu ch=%d\n",
                         (unsigned long)millis(), ANALYSIS_WIFI_CHANNEL);
            g_log.flush();
        }
    }
#else
    g_spiffs_ok = false;
#endif

    WiFi.mode(WIFI_STA);
    WiFi.begin("_", "_", ANALYSIS_WIFI_CHANNEL);
    delay(200);
    // Must not use disconnect(true) — on Arduino-ESP32 it can power down the
    // radio; promiscuous mode then sees nothing (same pattern as espnow_link.h
    // + ExpressLRS Backpack Tx_main SetSoftMACAddress: plain disconnect() only).
    WiFi.disconnect();
    esp_wifi_set_channel(ANALYSIS_WIFI_CHANNEL, WIFI_SECOND_CHAN_NONE);
    esp_err_t perr = esp_wifi_set_promiscuous(true);
    if (perr != ESP_OK) {
        Serial.printf("espnow_analysis: set_promiscuous failed %d\n", (int)perr);
    }
    esp_err_t cerr = esp_wifi_set_promiscuous_rx_cb(promiscuous_rx);
    if (cerr != ESP_OK) {
        Serial.printf("espnow_analysis: set_promiscuous_rx_cb failed %d\n", (int)cerr);
    }

    Serial.printf("# espnow_analysis: ch=%d serial=921600 spiffs=%s full=%s EN-raw=%s mode=%s\n",
                   ANALYSIS_WIFI_CHANNEL,
#if ANALYSIS_SAVE_SPIFFS
                   "on",
#else
                   "off",
#endif
                   kLogPath, kEnRawPath,
#if ANALYSIS_SERIAL_VERBOSE
                   "VERBOSE all tags"
#else
                   "raw EN/MS + comment stats"
#endif
    );
    Serial.println(
        "# format: EN|MS,millis,rssi,ch,len,wtype,hex ; EN=OUI 7f:18:fe:34, MS=MSP $M/$X candidate");
}

void loop() {
    M5.update();
    CapEvent ev;
    uint32_t lines = 0;
    while (g_cap_queue && xQueueReceive(g_cap_queue, &ev, 0) == pdTRUE) {
        appendHexLine(ev);
        lines++;
        if (lines > 256) break; // yield UI / USB; drain more per tick when air is busy
    }

    static uint32_t last_status = 0;
    if (millis() - last_status > 2000) {
        last_status = millis();
        char s[96];
        snprintf(s, sizeof(s), "# pkts=%lu en=%lu ms=%lu dropQ=%lu\n",
                 (unsigned long)g_total_packets, (unsigned long)g_espnow_packets,
                 (unsigned long)g_msp_candidate_packets, (unsigned long)g_dropped_queue);
        Serial.print(s);
        if (g_log && g_spiffs_ok) {
            rotateLogIfHuge();
            g_log.print(s);
            g_log.flush();
        }
        M5.Display.fillScreen(TFT_BLACK);
        M5.Display.setCursor(0, 0);
        M5.Display.printf("ANALYSIS ch%d\npkts %lu\nEN %lu MS %lu\nD %lu\n",
                          ANALYSIS_WIFI_CHANNEL, (unsigned long)g_total_packets,
                          (unsigned long)g_espnow_packets,
                          (unsigned long)g_msp_candidate_packets,
                          (unsigned long)g_dropped_queue);
        lines = 0;
    }

    // BtnA: dump SPIFFS logs to Serial (quick grab without removing USB).
    if (M5.BtnA.wasPressed()) {
        if (!g_spiffs_ok) {
            Serial.println("(SPIFFS not mounted)");
        } else {
            bool any = false;
            if (SPIFFS.exists(kLogPath)) {
                any = true;
                File r = SPIFFS.open(kLogPath, FILE_READ);
                if (r) {
                    size_t sz = r.size();
                    Serial.printf("\n--- BEGIN %s (%u bytes) ---\n", kLogPath, (unsigned)sz);
                    constexpr size_t kChunk = 512;
                    uint8_t chunk[kChunk];
                    while (r.available()) {
                        size_t n = r.read(chunk, sizeof(chunk));
                        Serial.write(chunk, n);
                    }
                    r.close();
                    Serial.printf("\n--- END %s ---\n", kLogPath);
                }
            }
            if (SPIFFS.exists(kEnRawPath)) {
                any = true;
                File r = SPIFFS.open(kEnRawPath, FILE_READ);
                if (r) {
                    size_t sz = r.size();
                    Serial.printf("\n--- BEGIN %s (%u bytes) ---\n", kEnRawPath, (unsigned)sz);
                    constexpr size_t kChunk = 512;
                    uint8_t chunk[kChunk];
                    while (r.available()) {
                        size_t n = r.read(chunk, sizeof(chunk));
                        Serial.write(chunk, n);
                    }
                    r.close();
                    Serial.printf("\n--- END %s ---\n", kEnRawPath);
                }
            }
            if (!any) {
                Serial.println("(no SPIFFS capture files yet)");
            }
        }
    }

    delay(1);
}
