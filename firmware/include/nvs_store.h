#pragma once

#include <cstdint>
#include <Arduino.h>
#include <Preferences.h>

// Persistent UID storage in ESP32 NVS.
// Namespace "hdzero", keys:
//   - "init" : sentinel, removed before uid writes and rewritten after.
//   - "uid"  : 6 bytes.
// Save order is [remove sentinel → write uid → write sentinel]. A power
// loss at any point leaves a state loadUid can detect:
//   remove OK, uid fail                     → sentinel-absent + stale uid
//   remove OK, uid OK, sentinel fail        → sentinel-absent + new uid
//   remove + uid + sentinel OK              → sentinel-present + new uid (good)
// loadUid treats "uid present but sentinel absent" as corruption, which
// catches torn writes on BOTH first save and re-save. A valid UID is
// always accompanied by its sentinel.
namespace nvs_store {

inline bool saveUid(const uint8_t uid[6]) {
    Preferences prefs;
    if (!prefs.begin("hdzero", false)) return false;
    // Drop the sentinel first so any subsequent torn write leaves the
    // namespace in the "uid present, sentinel absent" state loadUid
    // rejects — instead of leaving a stale valid-looking pair.
    prefs.remove("init");
    size_t uidWritten = prefs.putBytes("uid", uid, 6);
    size_t sentinelWritten = (uidWritten == 6) ? prefs.putUChar("init", 1) : 0;
    prefs.end();
    if (uidWritten != 6 || sentinelWritten != 1) {
        Serial.printf("nvs_store: partial save (uid=%u, sentinel=%u)\n",
                      (unsigned)uidWritten, (unsigned)sentinelWritten);
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
    if (!hasUid) {
        prefs.end();
        return false; // genuine first boot
    }
    if (!hasSentinel) {
        // uid is present but sentinel absent — the save sequence didn't
        // commit the final sentinel write, so uid was left in an
        // indeterminate state (torn write or flash corruption).
        Serial.println("nvs_store: uid key present but sentinel missing — torn write suspected");
        prefs.end();
        return false;
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
