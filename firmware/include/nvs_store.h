#pragma once

#include <cstdint>
#include <Arduino.h>
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
    // Distinguish "no key" (first boot on this namespace) from "key exists
    // but read returned fewer bytes" (possible corruption / truncated write).
    if (!prefs.isKey("uid")) {
        prefs.end();
        return false;
    }
    size_t read = prefs.getBytes("uid", uid, 6);
    prefs.end();
    if (read != 6) {
        Serial.printf("nvs_store: uid read returned %u bytes (expected 6, possible corruption)\n",
                      (unsigned)read);
        return false;
    }
    return true;
}

}
