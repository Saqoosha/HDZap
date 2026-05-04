#pragma once

#include <Arduino.h>
#include <SPIFFS.h>
#include <M5Unified.h>

/// On-device power consumption log to SPIFFS.
///
/// Why on-device: phase 2 redux measurement requires battery-only runs,
/// which means USB (and Serial) are gone for the duration. Logging to
/// flash lets the operator unplug the stick, leave it on a table for
/// hours, then plug back in to read the trail.
///
/// Layout:
///   /power.csv — append-only CSV, one row per `appendSample`. Header
///   line emitted lazily on first write of a freshly-formatted FS.
///
/// Format:
///   millis,voltage_mv,percent,charging,panel_asleep,ble_connected
///
/// `voltage_mv` is logged instead of instantaneous current because
/// M5Unified's `Power.getBatteryCurrent()` returns 0 for the M5StickS3's
/// `pmic_m5pm1` (no INA chip on the board, gauge current not exposed
/// through the public API). VBAT in mV is monotonic-ish under steady
/// discharge, so the slope dV/dt across a multi-minute window stands in
/// for instantaneous current — good enough for before/after Phase 2
/// optimization deltas.
///
/// Sample interval is the caller's choice — `appendSample` is dumb,
/// it just writes whatever it's given. main.cpp throttles to 30 s
/// (matches issue #5's measurement cadence; ~21 h capacity in the
/// 128 KB SPIFFS partition before rollover).
///
/// Capacity / overflow policy: when the file approaches the partition
/// cap we drop the *oldest* line by truncating to the most recent
/// `kRotateRetainBytes`. Power data is interesting in trends, not
/// individual rows from hours ago, and silently failing the append
/// (the SPIFFS default) would mask a multi-hour run going dark.
///
/// `dumpToSerial()` streams the whole file in one go on USB plug-in
/// (called from setup()). That's the only readout path — no BLE GATT
/// download yet, deliberately, to keep the surface tiny.
class PowerLog {
public:
    /// Mount SPIFFS and open the log for append. Logs failures to Serial
    /// but never blocks boot — a missing partition just disables logging.
    /// Also handles schema migration: if the existing file's header
    /// doesn't match the current schema, drop it and start fresh — better
    /// than appending incompatible rows that break downstream parsing.
    void begin() {
        if (!SPIFFS.begin(true)) {
            Serial.println("power_log: SPIFFS mount failed (logging disabled)");
            m_ok = false;
            return;
        }
        m_ok = true;
        if (SPIFFS.exists(kLogPath)) {
            File r = SPIFFS.open(kLogPath, FILE_READ);
            if (r) {
                char header[96] = {};
                size_t n = r.readBytesUntil('\n', header, sizeof(header) - 1);
                r.close();
                // println() writes "\r\n" so readBytesUntil('\n') leaves
                // a trailing CR; strip it before comparing or every boot
                // would falsely report a schema mismatch and wipe the log.
                if (n > 0 && header[n - 1] == '\r') header[n - 1] = 0;
                if (n == 0 || strcmp(header, kHeader) != 0) {
                    Serial.printf("power_log: schema mismatch, resetting (was: '%s')\n",
                                  header);
                    SPIFFS.remove(kLogPath);
                }
            }
        }
        File f = SPIFFS.open(kLogPath, FILE_APPEND);
        if (!f) {
            Serial.println("power_log: open failed (logging disabled)");
            m_ok = false;
            return;
        }
        if (f.size() == 0) {
            f.println(kHeader);
        }
        f.close();
    }

    /// Stream the whole log to Serial. Intended for "plugged USB back in,
    /// what happened?" readout. No-op when logging is disabled.
    void dumpToSerial() {
        if (!m_ok) return;
        File f = SPIFFS.open(kLogPath, FILE_READ);
        if (!f) {
            Serial.println("power_log: dump open failed");
            return;
        }
        Serial.println("--- power_log dump start ---");
        Serial.printf("size=%u bytes\n", (unsigned)f.size());
        while (f.available()) {
            Serial.write(f.read());
        }
        Serial.println("--- power_log dump end ---");
        f.close();
    }

    /// Drop all logged samples (keeps the header line). Use after
    /// dumpToSerial() to start a fresh measurement run without
    /// hand-cleaning the partition.
    void clear() {
        if (!m_ok) return;
        SPIFFS.remove(kLogPath);
        File f = SPIFFS.open(kLogPath, FILE_WRITE);
        if (f) {
            f.println(kHeader);
            f.close();
        }
        Serial.println("power_log: cleared");
    }

    /// Append one sample row. Cheap (single write); rotates when the
    /// file approaches the partition limit so a long-running test
    /// doesn't silently lose the tail.
    void appendSample(uint32_t now_ms,
                      int16_t voltage_mv,
                      int8_t percent,
                      bool charging,
                      bool panel_asleep,
                      bool ble_connected) {
        if (!m_ok) return;

        // Cap at ~110 KB to leave headroom in the 128 KB partition for
        // SPIFFS metadata + the in-flight write.
        File stat = SPIFFS.open(kLogPath, FILE_READ);
        size_t sz = stat ? stat.size() : 0;
        if (stat) stat.close();
        if (sz >= kRotateThresholdBytes) {
            rotate();
        }

        File f = SPIFFS.open(kLogPath, FILE_APPEND);
        if (!f) return;
        f.printf("%lu,%d,%d,%d,%d,%d\n",
                 (unsigned long)now_ms,
                 (int)voltage_mv,
                 (int)percent,
                 charging ? 1 : 0,
                 panel_asleep ? 1 : 0,
                 ble_connected ? 1 : 0);
        f.close();
    }

private:
    static constexpr const char* kLogPath = "/power.csv";
    static constexpr const char* kHeader =
        "millis,voltage_mv,percent,charging,panel_asleep,ble_connected";
    // SPIFFS partition is 128 KB (0x20000). Rotate at ~85 % to leave
    // overhead room — SPIFFS needs spare blocks for GC.
    static constexpr size_t kRotateThresholdBytes = 110 * 1024;
    // After rotation, retain the most recent ~80 KB. Power trends across
    // a multi-hour run are visible in this window; older noise is
    // dropped without ceremony.
    static constexpr size_t kRotateRetainBytes = 80 * 1024;

    bool m_ok = false;

    void rotate() {
        // Read the tail of the current file, write it back as the new
        // file. SPIFFS doesn't support in-place truncate-from-head, so
        // we copy. The "tmp" path is needed because SPIFFS_open with
        // FILE_WRITE would truncate the source we're copying from.
        const char* tmp = "/power.csv.tmp";
        File src = SPIFFS.open(kLogPath, FILE_READ);
        if (!src) return;
        size_t total = src.size();
        size_t skip = (total > kRotateRetainBytes) ? (total - kRotateRetainBytes) : 0;
        src.seek(skip);
        // Skip to the next newline so we don't start the rotated file
        // mid-row. CSV-friendly.
        if (skip > 0) {
            while (src.available()) {
                int c = src.read();
                if (c == '\n') break;
            }
        }

        File dst = SPIFFS.open(tmp, FILE_WRITE);
        if (!dst) {
            src.close();
            return;
        }
        // Re-emit header so a downstream parser sees the column names.
        dst.println(kHeader);
        uint8_t buf[256];
        while (src.available()) {
            size_t n = src.read(buf, sizeof(buf));
            dst.write(buf, n);
        }
        src.close();
        dst.close();
        SPIFFS.remove(kLogPath);
        SPIFFS.rename(tmp, kLogPath);
        Serial.println("power_log: rotated");
    }
};
