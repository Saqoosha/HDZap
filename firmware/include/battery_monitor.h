#pragma once

#include <M5Unified.h>
#include <cstdint>

/// PMIC-backed battery monitor with a tiered alarm + speaker driver.
/// On M5StickS3 the underlying PMIC is `pmic_m5pm1` (per M5Unified board
/// dispatch); the class talks to it only through the `M5.Power` facade.
///
/// Polls `M5.Power` every `kPollIntervalMs` (5 s, compile-time constant).
/// Owns:
///   - cached percent + charging state (latest valid read; -1 = unknown)
///   - an alarm tier with hysteresis (NONE / LOW <= 20% / CRITICAL <= 10%)
///   - a single `m_silenced` latch the operator toggles via the buttons,
///     cleared automatically on every tier transition (so any change of
///     tier — escalate, de-escalate, or recover — re-arms beeps)
///   - a beep cadence gate (LOW: every 30 s, CRITICAL: every 15 s)
///
/// `poll()` itself is side-effect free — no LCD writes, no BLE writes, no
/// audio. `begin()` only sets the speaker volume so `M5.Speaker.tone()`
/// fires in `main.cpp`, mirroring how the rest of the firmware separates
/// monitors from the loop owner.
///
/// Charging is treated as full recovery: plugging USB in clears the alarm
/// tier, drops any sticky LOW/CRITICAL message via main.cpp, and resets
/// the silenced latch so a future low-battery event starts a fresh beep
/// session. This matches the user intent that plugging in is an explicit
/// "I'm dealing with it."
class BatteryMonitor {
public:
    enum class Tier : uint8_t { None = 0, Low = 1, Critical = 2 };

    struct PollResult {
        /// True iff caller-relevant state changed during this poll
        /// (percent step, charging edge, tier change, or first-prime).
        /// Silence edges go through the separate `consumeSilencedDirty()`
        /// channel — they're driven by button presses between polls,
        /// outside the throttled poll cadence.
        bool stateChanged;
        /// True iff `tier()` value changed in this poll. Subset of
        /// `stateChanged`; lets `main.cpp` toggle the sticky strip
        /// message without diffing the tier itself.
        bool tierChanged;
    };

    /// Sets the speaker volume. M5.begin() must have already run (it does,
    /// via StickDisplay::begin in setup()). Cheap to call multiple times.
    ///
    /// Charge current is NOT exposed: M5StickS3's `pmic_m5pm1` PMIC has no
    /// case in `Power_Class::setChargeCurrent`, so the default ~100 mA from
    /// the hardware is what we get. With BLE + ESP-NOW + LCD all active the
    /// device draws roughly that much, so a USB-tethered stick floats at
    /// ~50 % indefinitely. The fix is to cut consumption (LCD brightness,
    /// BLE/WiFi TX power), not to push the PMIC harder.
    void begin() {
        M5.Speaker.setVolume(kSpeakerVolume);
    }

    /// Run once per loop iteration. Internally throttled to `kPollIntervalMs`;
    /// returns `{false,false}` when the throttle hasn't elapsed. The first
    /// call after construction always reports `stateChanged = true` so the
    /// caller pushes the initial value to the LCD + BLE.
    PollResult poll(uint32_t now) {
        PollResult r{false, false};
        if (m_primed && (now - m_lastPollMs) < kPollIntervalMs) return r;
        m_lastPollMs = now;

        // M5.Power returns int32 percent (0-100) or -1 when the PMIC
        // hasn't reported yet. Anything outside [0,100] is treated as
        // unknown so the wire format's 0xFF sentinel is well-defined.
        int level = M5.Power.getBatteryLevel();
        bool valid = (level >= 0 && level <= 100);
        int8_t pct = valid ? (int8_t)level : -1;
        // Log on the validity edge so a sustained PMIC fault is visible
        // over serial without spamming every poll. Boot transient (first
        // poll returning -1) flips m_lastReadValid silently; only later
        // edges produce output.
        if (m_primed && valid != m_lastReadValid) {
            if (valid) {
                Serial.printf("BatteryMonitor: PMIC reads recovered (%d%%)\n", level);
            } else {
                Serial.printf("BatteryMonitor: PMIC reported %d (out of range), treating as unknown\n", level);
            }
        }
        m_lastReadValid = valid;
        // M5Unified `is_charging_t` is `{ is_discharging=0, is_charging=1,
        // charge_unknown=2 }`. We compare against the explicit `is_charging`
        // enumerator rather than `> 0` because `charge_unknown` would
        // otherwise be misread as "USB plugged in" — that path silences the
        // alarm tier, hiding a real low-battery condition behind a PMIC
        // ambiguity.
        bool charging = (M5.Power.isCharging() == m5::Power_Class::is_charging);

        Tier newTier = m_tier;
        if (charging || pct < 0) {
            // Charging or unknown → no alarm. Charging is the user's
            // explicit recovery; unknown is "we don't have a reading yet"
            // and beeping on that would just confuse boot-time UX.
            newTier = Tier::None;
        } else {
            // Hysteresis: escalate at strict thresholds, exit only past
            // a recovery margin so a single +/-1% jitter near 20% doesn't
            // spam the operator with on/off beeps.
            switch (m_tier) {
                case Tier::None:
                    if (pct <= kCriticalThreshold)      newTier = Tier::Critical;
                    else if (pct <= kLowThreshold)      newTier = Tier::Low;
                    break;
                case Tier::Low:
                    if (pct <= kCriticalThreshold)      newTier = Tier::Critical;
                    else if (pct >= kLowRecover)        newTier = Tier::None;
                    break;
                case Tier::Critical:
                    // Critical recovery uses the same recover-margin pattern
                    // as Low → None, applied symmetrically to both edges of
                    // the Critical band. Without `kCriticalRecover`, a cell
                    // sagging across the 10 % line every poll would re-arm
                    // beeps every 5 s; without routing Critical → None
                    // through `kLowRecover`, the same 21 % reading would
                    // mean "alarm clear" if you came from Critical and
                    // "still Low" if you came from Low.
                    if (pct >= kLowRecover)             newTier = Tier::None;
                    else if (pct >= kCriticalRecover)   newTier = Tier::Low;
                    break;
            }
        }

        bool tierChanged = (newTier != m_tier);
        if (tierChanged) {
            // Every tier transition (escalate, de-escalate, recover) clears
            // silenced — the operator's "I know" acknowledgement was for
            // the prior tier, not the new one. The asymmetry is deliberate:
            // a CRITICAL → LOW de-escalation re-arms beeps, which can
            // surprise an operator who silenced at 9 % and saw the cell
            // sag back to 12 %. Acceptable trade-off vs. the alternative
            // (silenced state lingering across an unrelated tier change).
            //
            // Keep `m_silencedDirty` consistent with the underlying value
            // so any future caller path that triggers the BLE notify on
            // silence-edge stays correct even when the reset is implicit.
            if (m_silenced) m_silencedDirty = true;
            m_silenced = false;
            // Force the next consumeBeepDue() to fire immediately so
            // entering a tier always announces itself once.
            m_lastBeepMs = 0;
        }

        bool stateChanged = !m_primed
                          || pct != m_pct
                          || charging != m_charging
                          || tierChanged;

        m_pct = pct;
        m_charging = charging;
        m_tier = newTier;
        m_primed = true;

        r.stateChanged = stateChanged;
        r.tierChanged = tierChanged;
        return r;
    }

    /// Operator pressed a hardware button while an alarm was active.
    /// Latches a single silenced flag (no per-tier history); cleared
    /// automatically on the next tier transition, so a LOW→CRITICAL
    /// escalation, a CRITICAL→LOW de-escalation, or any recovery to
    /// NONE all re-arm beeps.
    void silence() {
        if (m_tier == Tier::None) return;
        if (!m_silenced) {
            m_silenced = true;
            m_silencedDirty = true;
        }
    }

    /// True if the silence latch changed since the last call. Used by
    /// `main.cpp` so a button press immediately pushes a fresh BLE
    /// notify to the iOS app (the bit lives in the wire format).
    bool consumeSilencedDirty() {
        bool dirty = m_silencedDirty;
        m_silencedDirty = false;
        return dirty;
    }

    /// True iff a beep should fire this tick. Suppressed when the tier
    /// is NONE or silenced. The cadence is paced from the last beep,
    /// so entering a tier always beeps immediately (lastBeep is reset
    /// to 0 on transition) and subsequent beeps follow the period.
    bool consumeBeepDue(uint32_t now) {
        if (m_tier == Tier::None || m_silenced) return false;
        uint32_t period = (m_tier == Tier::Critical) ? kCriticalBeepMs : kLowBeepMs;
        if (m_lastBeepMs != 0 && (now - m_lastBeepMs) < period) return false;
        // Avoid the 0 sentinel landing on `now == 0` (only happens for
        // the first ~1 ms after boot, but cheap to guard).
        m_lastBeepMs = (now == 0) ? 1 : now;
        return true;
    }

    /// Pack 2 bytes for the BLE notify characteristic.
    /// byte 0: percent (0-100) or 0xFF when unknown.
    /// byte 1: flags — bit0 charging, bit1 LOW, bit2 CRITICAL, bit3 silenced.
    void payload(uint8_t out[2]) const {
        out[0] = (m_pct < 0) ? 0xFF : (uint8_t)m_pct;
        uint8_t flags = 0;
        if (m_charging)               flags |= 0x01;
        if (m_tier == Tier::Low)      flags |= 0x02;
        if (m_tier == Tier::Critical) flags |= 0x04;
        if (m_silenced)               flags |= 0x08;
        out[1] = flags;
    }

    int8_t percent() const { return m_pct; }
    bool charging() const { return m_charging; }
    Tier tier() const { return m_tier; }
    bool silenced() const { return m_silenced; }

    /// Tone parameters exposed for `main.cpp`'s beep dispatch. Kept here
    /// so the per-tier mapping lives next to the threshold definitions.
    static uint32_t beepFrequency(Tier t) {
        return (t == Tier::Critical) ? kCriticalBeepFreqHz : kLowBeepFreqHz;
    }
    static uint32_t beepDurationMs(Tier t) {
        return (t == Tier::Critical) ? kCriticalBeepDurMs : kLowBeepDurMs;
    }

private:
    static constexpr uint32_t kPollIntervalMs    = 5000;
    static constexpr int      kLowThreshold      = 20;
    static constexpr int      kCriticalThreshold = 10;
    static constexpr int      kLowRecover        = 25;
    static constexpr int      kCriticalRecover   = 13;
    static constexpr uint32_t kLowBeepMs         = 30000;
    static constexpr uint32_t kCriticalBeepMs    = 15000;
    static constexpr uint32_t kLowBeepFreqHz     = 1000;
    static constexpr uint32_t kCriticalBeepFreqHz = 1500;
    static constexpr uint32_t kLowBeepDurMs      = 200;
    static constexpr uint32_t kCriticalBeepDurMs = 100;
    static constexpr uint8_t  kSpeakerVolume     = 64;  // ~25% — audible indoors

    bool     m_primed         = false;
    bool     m_lastReadValid  = false;
    uint32_t m_lastPollMs     = 0;
    int8_t   m_pct            = -1;
    bool     m_charging       = false;
    Tier     m_tier           = Tier::None;
    bool     m_silenced       = false;
    bool     m_silencedDirty  = false;
    uint32_t m_lastBeepMs     = 0;
};
