#pragma once

#include <cstdint>
#include <Arduino.h>
#include <Preferences.h>

// Persistent UID storage in ESP32 NVS.
// Namespace "hdzero", keys:
//   - "init" : 1-byte sentinel written BEFORE the uid on every save.
//   - "uid"  : 6 bytes.
// Sentinel-first ordering means a save interrupted by power loss between
// the two puts leaves sentinel-present + uid-missing, which loadUid
// classifies as corruption. The alternative ordering (uid-first) would
// make torn writes look like a normal load.
namespace nvs_store {

inline bool saveUid(const uint8_t uid[6]) {
    Preferences prefs;
    if (!prefs.begin("hdzero", false)) return false;
    size_t sentinelWritten = prefs.putUChar("init", 1);
    size_t uidWritten = (sentinelWritten == 1) ? prefs.putBytes("uid", uid, 6) : 0;
    prefs.end();
    if (sentinelWritten != 1 || uidWritten != 6) {
        Serial.printf("nvs_store: partial save (sentinel=%u, uid=%u)\n",
                      (unsigned)sentinelWritten, (unsigned)uidWritten);
        return false;
    }
    return true;
}

inline bool loadUid(uint8_t uid[6]) {
    Preferences prefs;
    // Read-only open fails when the namespace doesn't exist yet (first boot).
    if (!prefs.begin("hdzero", true)) return false;
    bool hasSentinel = prefs.isKey("init");
    bool hasUid = prefs.isKey("uid");
    if (hasSentinel && !hasUid) {
        // Sentinel was written but uid wasn't — torn write or flash corruption.
        // Don't silently fall back to the factory MAC without surfacing this.
        Serial.println("nvs_store: sentinel present but uid key missing — NVS corruption suspected");
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
