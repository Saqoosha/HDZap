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
/// M5Unified's pmic_m5pm1 path does not implement getBatteryCurrent()
/// (the switch falls through to the default 0 return; M5PM1 may expose
/// current via its own registers in a future release). VBAT in mV is
/// monotonic-ish under steady discharge, so the slope dV/dt across a
/// multi-minute window stands in for instantaneous current — good
/// enough for before/after Phase 2 optimization deltas. Caller is
/// responsible for sentinel-marking out-of-range readings (-1) before
/// passing in; appendSample writes whatever it gets.
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

        // Clean up a stale tmp file from an interrupted prior rotate
        // (power loss between dst.close() and rename in rotate()).
        // Otherwise the residue stays on disk forever, eats into the
        // partition's free space, and the next rotate's tmp write fails.
        if (SPIFFS.exists(kTmpPath)) {
            Serial.println("power_log: cleaning up stale tmp from interrupted rotate");
            SPIFFS.remove(kTmpPath);
        }

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
                    if (!SPIFFS.remove(kLogPath)) {
                        // remove failed → next open with FILE_APPEND would
                        // see size > 0 and skip the header write, leaving
                        // new-schema rows under a stale header. Disable
                        // logging instead of corrupting the file.
                        Serial.println("power_log: schema-reset remove failed (logging disabled)");
                        m_ok = false;
                        return;
                    }
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
        // Read in chunks (faster than per-byte) and check for read
        // errors mid-stream — single-byte read returning -1 would
        // otherwise be cast to 0xFF and silently corrupt the dump.
        uint8_t buf[256];
        while (f.available()) {
            int n = f.read(buf, sizeof(buf));
            if (n < 0) {
                Serial.println("\n--- power_log: read error mid-dump ---");
                break;
            }
            Serial.write(buf, n);
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
        int wrote = f.printf("%lu,%d,%d,%d,%d,%d\n",
                             (unsigned long)now_ms,
                             (int)voltage_mv,
                             (int)percent,
                             charging ? 1 : 0,
                             panel_asleep ? 1 : 0,
                             ble_connected ? 1 : 0);
        f.close();
        if (wrote <= 0) {
            // SPIFFS-full despite the rotation threshold (rotate may
            // have failed silently), or write error mid-format. Throttle
            // the warning to one per minute so a sustained fault doesn't
            // spam Serial during a multi-hour battery run.
            static uint32_t lastWarnMs = 0;
            uint32_t now = millis();
            if (now - lastWarnMs > 60000) {
                Serial.printf("power_log: append failed (printf=%d)\n", wrote);
                lastWarnMs = now;
            }
        }
    }

private:
    static constexpr const char* kLogPath = "/power.csv";
    static constexpr const char* kTmpPath = "/power.csv.tmp";
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
        File src = SPIFFS.open(kLogPath, FILE_READ);
        if (!src) {
            Serial.println("power_log: rotate: src open failed");
            return;
        }
        size_t total = src.size();
        size_t skip = (total > kRotateRetainBytes) ? (total - kRotateRetainBytes) : 0;
        src.seek(skip);
        // Skip to the next newline so we don't start the rotated file
        // mid-row. CSV-friendly. If the tail contains no newline at all
        // (one giant row, or earlier truncation), bail before destroying
        // the original — better to keep stale data than to wipe it.
        if (skip > 0) {
            bool foundNewline = false;
            while (src.available()) {
                int c = src.read();
                if (c < 0) break;  // read error, give up
                if (c == '\n') { foundNewline = true; break; }
            }
            if (!foundNewline) {
                Serial.println("power_log: rotate aborted (no newline in retain window)");
                src.close();
                return;
            }
        }

        File dst = SPIFFS.open(kTmpPath, FILE_WRITE);
        if (!dst) {
            Serial.println("power_log: rotate: dst open failed");
            src.close();
            return;
        }
        // Re-emit header so a downstream parser sees the column names.
        dst.println(kHeader);
        uint8_t buf[256];
        bool writeFailed = false;
        while (src.available()) {
            int rn = src.read(buf, sizeof(buf));
            if (rn <= 0) {
                Serial.println("power_log: rotate: read error");
                writeFailed = true;
                break;
            }
            size_t w = dst.write(buf, (size_t)rn);
            if (w != (size_t)rn) {
                Serial.printf("power_log: rotate: short write (%u/%d) — keeping original\n",
                              (unsigned)w, rn);
                writeFailed = true;
                break;
            }
        }
        src.close();
        dst.close();
        if (writeFailed) {
            // Don't replace the original with a half-rotated tmp; the
            // operator's data still lives in the source file.
            SPIFFS.remove(kTmpPath);
            return;
        }
        if (!SPIFFS.remove(kLogPath) || !SPIFFS.rename(kTmpPath, kLogPath)) {
            Serial.println("power_log: rotate finalize failed (tmp may persist)");
            return;
        }
        Serial.println("power_log: rotated");
    }
};
