#pragma once

#include <cstdint>
#include <Preferences.h>

// Persistent UID storage in ESP32 NVS.
// Namespace "hdzero", key "uid". Survives power cycles and flashes that keep NVS.
namespace nvs_store {

inline bool saveUid(const uint8_t uid[6]) {
    Preferences prefs;
    if (!prefs.begin("hdzero", false)) return false;
    size_t written = prefs.putBytes("uid", uid, 6);
    prefs.end();
    return written == 6;
}

inline bool loadUid(uint8_t uid[6]) {
    Preferences prefs;
    // Read-only open fails when the namespace doesn't exist yet (first boot).
    if (!prefs.begin("hdzero", true)) return false;
    size_t read = prefs.getBytes("uid", uid, 6);
    prefs.end();
    return read == 6;
}

}
