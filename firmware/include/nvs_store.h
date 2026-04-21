#pragma once

#include <cstdint>
#include <Arduino.h>
#include <Preferences.h>

// Persistent UID storage in ESP32 NVS.
// Namespace "hdzero", keys:
//   - "init" : sentinel, removed before uid writes and rewritten after.
//   - "uid"  : 6 bytes.
// Save order is [remove sentinel → write uid → write sentinel]. On load:
//   - sentinel-present + uid-present  → normal success path
//   - sentinel-absent  + uid-present  → torn save or legacy data; log a
//       warning but still return the uid (a 6-byte value is usable either
//       way, and dropping it would silently break goggle comms)
//   - sentinel-either  + uid-absent   → first boot (or full NVS wipe)
// The sentinel is a diagnostic signal, not a gate — losing a working UID
// on every power-cut-during-save would be a worse failure than the
// possibility of using slightly-stale state.
namespace nvs_store {

inline bool saveUid(const uint8_t uid[6]) {
    Preferences prefs;
    if (!prefs.begin("hdzero", false)) return false;
    // Drop the sentinel first so a torn write leaves "uid present,
    // sentinel absent" — a state loadUid surfaces as a warning. Ignoring
    // the return value is intentional: a missing key on first boot is
    // expected, and a genuine NVS error here is also observable when the
    // subsequent puts return 0.
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
    size_t read = prefs.getBytes("uid", uid, 6);
    prefs.end();
    if (read != 6) {
        Serial.printf("nvs_store: uid read returned %u bytes (expected 6, truncated write?)\n",
                      (unsigned)read);
        return false;
    }
    // Fail-soft on sentinel-missing: a 6-byte uid is a legitimately usable
    // value (either pre-sentinel legacy data, or a torn save that already
    // wrote the new uid). Log so the torn-write case is diagnosable, but
    // still return the uid — dropping a valid UID would silently break
    // goggle communication for the user, which is worse than a warning.
    if (!hasSentinel) {
        Serial.println("nvs_store: uid present but sentinel missing — torn write or pre-sentinel data; using uid anyway");
    }
    return true;
}

}
