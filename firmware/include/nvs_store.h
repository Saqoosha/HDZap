#pragma once

#include <cstdint>
#include <Arduino.h>
#include <Preferences.h>

// Persistent UID storage in ESP32 NVS.
// Namespace "hdzero", keys "uid" (6 bytes) and "init" (sentinel byte).
// `init` is written on every save so its absence alongside a missing `uid`
// means this namespace truly has never been written — distinguishable from
// a post-save corruption where the index page lost the uid pointer.
namespace nvs_store {

inline bool saveUid(const uint8_t uid[6]) {
    Preferences prefs;
    if (!prefs.begin("hdzero", false)) return false;
    size_t written = prefs.putBytes("uid", uid, 6);
    prefs.putUChar("init", 1);
    prefs.end();
    return written == 6;
}

inline bool loadUid(uint8_t uid[6]) {
    Preferences prefs;
    // Read-only open fails when the namespace doesn't exist yet (first boot).
    if (!prefs.begin("hdzero", true)) return false;
    bool hasSentinel = prefs.isKey("init");
    bool hasUid = prefs.isKey("uid");
    if (hasSentinel && !hasUid) {
        // Sentinel written but uid missing — a successful saveUid writes
        // both, so this only happens under NVS corruption.
        Serial.println("nvs_store: sentinel present but uid key missing — possible NVS corruption");
        prefs.end();
        return false;
    }
    if (!hasUid) {
        prefs.end();
        return false; // genuine first boot
    }
    size_t read = prefs.getBytes("uid", uid, 6);
    prefs.end();
    if (read != 6) {
        Serial.printf("nvs_store: uid read returned %u bytes (expected 6, truncated write?)\n",
                      (unsigned)read);
        return false;
    }
    return true;
}

}
