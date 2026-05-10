#pragma once

#include <cstdint>
#include <Arduino.h>
#include <Preferences.h>

// Persistent UID + sleep-config storage in ESP32 NVS.
// Namespace "hdzero", keys:
//   - "init"   : sentinel, removed before uid writes and rewritten after.
//   - "uid"    : 6 bytes.
//   - "teleuid": 6-byte ESP-NOW sender MAC accepted for flight-pack telemetry.
//   - "slpmin" : single byte, deep-sleep timeout in minutes (0 = disabled).
//                No sentinel pattern: a single putUChar is one NVS entry,
//                so it can't be torn at the entry level. The failure mode
//                of a torn write is "value snaps back to kSleepDefaultMin",
//                which is benign. A sentinel can't disambiguate a torn
//                write from "user explicitly set 0 to disable" anyway.
//   - "btname" : BLE GAP device name string, ≤ kDeviceNameMaxLen bytes.
//                No sentinel — single putString is one entry. Torn write
//                falls back to kDeviceNameDefault, which is harmless: the
//                user just sees the default until they re-rename.
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

inline bool saveTelemetrySourceUid(const uint8_t uid[6]) {
    // Unicast MAC invariant: ESP-NOW sender MACs we accept telemetry
    // from must have bit 0 of the first byte clear, same rule as the
    // OSD UID. Reject before persisting so a corrupt RAM value can't
    // outlive the reboot.
    if (!uid || (uid[0] & 0x01)) {
        Serial.println("nvs_store: saveTelemetrySourceUid: rejected non-unicast MAC");
        return false;
    }
    Preferences prefs;
    if (!prefs.begin("hdzero", false)) return false;
    size_t written = prefs.putBytes("teleuid", uid, 6);
    prefs.end();
    if (written != 6) {
        Serial.printf("nvs_store: saveTelemetrySourceUid wrote %u bytes (expected 6)\n",
                      (unsigned)written);
        return false;
    }
    return true;
}

inline bool loadTelemetrySourceUid(uint8_t uid[6]) {
    Preferences prefs;
    if (!prefs.begin("hdzero", true)) return false;
    bool hasUid = prefs.isKey("teleuid");
    if (!hasUid) {
        prefs.end();
        return false;
    }
    size_t read = prefs.getBytes("teleuid", uid, 6);
    prefs.end();
    if (read != 6) {
        Serial.printf("nvs_store: telemetry source read returned %u bytes (expected 6)\n",
                      (unsigned)read);
        return false;
    }
    // Same unicast-MAC invariant as the save path. Catches a corrupt
    // NVS entry or a downgrade from a build that didn't enforce the
    // check on save — better to fall back to "no telemetry source"
    // than to filter against a bogus broadcast/multicast address.
    if (uid[0] & 0x01) {
        Serial.println("nvs_store: telemetry source UID is non-unicast — rejecting");
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

// BLE GAP device name. Capped at 20 bytes to fit comfortably inside the
// 31-byte BLE adv PDU's scan-response slot once the 128-bit service UUID
// (18 bytes incl. AD overhead) and AD-type/length bytes are accounted
// for; a longer name would get truncated or pushed entirely out of the
// scan response, leaving iOS scan results showing "Unknown".
inline constexpr size_t kDeviceNameMaxLen = 20;
inline constexpr const char* kDeviceNameDefault = "HDZeroOSD";
// Compile-time proof that the default itself satisfies the cap, so a
// future kDeviceNameDefault change that exceeds kDeviceNameMaxLen fails
// the build instead of silently truncating in saveDeviceName / the
// caption renderer at runtime.
static_assert(__builtin_strlen(kDeviceNameDefault) <= kDeviceNameMaxLen,
              "kDeviceNameDefault exceeds kDeviceNameMaxLen");

inline bool saveDeviceName(const char* name) {
    if (!name) return false;
    size_t len = strnlen(name, kDeviceNameMaxLen + 1);
    if (len == 0 || len > kDeviceNameMaxLen) {
        Serial.printf("nvs_store: saveDeviceName: invalid length %u\n", (unsigned)len);
        return false;
    }
    Preferences prefs;
    if (!prefs.begin("hdzero", false)) {
        Serial.println("nvs_store: saveDeviceName: begin failed");
        return false;
    }
    size_t n = prefs.putString("btname", name);
    prefs.end();
    if (n != len) {
        Serial.printf("nvs_store: saveDeviceName: putString wrote %u (expected %u)\n",
                      (unsigned)n, (unsigned)len);
        return false;
    }
    return true;
}

// Always fills `out` with a null-terminated string of length ≤ cap-1.
// Falls back to kDeviceNameDefault on missing key, NVS error, or
// length overflow (a stored value longer than cap-1 would otherwise
// be truncated mid-UTF-8; defaulting is the safer signal).
//
// Failure modes log distinctly so a user whose name silently snaps
// back to the default has a diagnostic trail. The "first boot, no
// btname key yet" case is correctly silent — getString returns the
// default and v.length() will be the default's length (>0), so we
// fall through to the normal copy path without entering either of
// the warning branches below.
inline void loadDeviceName(char* out, size_t cap) {
    if (!out || cap == 0) return;
    out[0] = 0;
    Preferences prefs;
    if (!prefs.begin("hdzero", true)) {
        Serial.println("nvs_store: loadDeviceName: namespace open failed — using default");
        strncpy(out, kDeviceNameDefault, cap - 1);
        out[cap - 1] = 0;
        return;
    }
    String v = prefs.getString("btname", String(kDeviceNameDefault));
    prefs.end();
    if (v.length() == 0) {
        Serial.println("nvs_store: loadDeviceName: stored value empty — using default");
        strncpy(out, kDeviceNameDefault, cap - 1);
        out[cap - 1] = 0;
        return;
    }
    if (v.length() >= cap) {
        Serial.printf("nvs_store: loadDeviceName: stored value too long (%u >= %u) — using default\n",
                      (unsigned)v.length(), (unsigned)cap);
        strncpy(out, kDeviceNameDefault, cap - 1);
        out[cap - 1] = 0;
        return;
    }
    strncpy(out, v.c_str(), cap - 1);
    out[cap - 1] = 0;
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
