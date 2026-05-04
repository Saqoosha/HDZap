#pragma once

#include <cstdint>
#include <Arduino.h>
#include <Preferences.h>

// Persistent UID + sleep-config storage in ESP32 NVS.
// Namespace "hdzero", keys:
//   - "init"   : sentinel, removed before uid writes and rewritten after.
//   - "uid"    : 6 bytes.
//   - "slpmin" : single byte, deep-sleep timeout in minutes (0 = disabled).
//                No sentinel pattern: a single putUChar is one NVS entry,
//                so it can't be torn at the entry level. The failure mode
//                of a torn write is "value snaps back to kSleepDefaultMin",
//                which is benign. A sentinel can't disambiguate a torn
//                write from "user explicitly set 0 to disable" anyway.
// UID save order is [remove sentinel → write uid → write sentinel]. On load:
//   - sentinel-present + uid-present  → normal success path
//   - sentinel-absent  + uid-present  → torn save or legacy data; log a
//       warning but still return the uid (a 6-byte value is usable either
//       way, and dropping it would silently break goggle comms)
//   - sentinel-either  + uid-absent   → first boot (or full NVS wipe)
// The sentinel is a diagnostic signal, not a gate — losing a working UID
// on every power-cut-during-save would be a worse failure than the
// possibility of using slightly-stale state.
namespace nvs_store {

// Note on acknowledgement: Arduino's Preferences wrapper exposes putBytes
// / putUChar via their byte counts (1 or 6 = "written as far as we can
// tell") but `end()` commits without a return path — if the underlying
// nvs_commit fails, we have no signal. We treat a full-size put as the
// strongest commitment signal available and accept the residual risk.

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

// Deep-sleep timeout (issue #5 phase 3), persisted as a single byte =
// minutes. 0 = disabled (never deep-sleep). Default returned by load
// when no key exists is the kSleepDefaultMin compile-time fallback.
inline constexpr uint8_t kSleepDefaultMin = 5;

inline bool saveSleepMinutes(uint8_t minutes) {
    Preferences prefs;
    if (!prefs.begin("hdzero", false)) {
        Serial.println("nvs_store: saveSleepMinutes: begin failed");
        return false;
    }
    size_t n = prefs.putUChar("slpmin", minutes);
    prefs.end();
    if (n != 1) {
        Serial.printf("nvs_store: saveSleepMinutes: putUChar wrote %u (expected 1)\n",
                      (unsigned)n);
        return false;
    }
    return true;
}

inline uint8_t loadSleepMinutes() {
    Preferences prefs;
    // begin returns false when the namespace doesn't exist yet (first
    // boot before any saveUid/saveSleepMinutes). getUChar's default
    // fallback covers the absent-key case so isKey is redundant here.
    if (!prefs.begin("hdzero", true)) return kSleepDefaultMin;
    uint8_t v = prefs.getUChar("slpmin", kSleepDefaultMin);
    prefs.end();
    return v;
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
