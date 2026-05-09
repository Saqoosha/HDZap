#pragma once

#include <cstddef>
#include <cstdint>

#include "msp.h"

/// CRSF framing + Battery sensor decoding (Betaflight telemetry output).
///
/// Backpack wraps a raw CRSF frame as the MSP_ELRS_BACKPACK_CRSF_TLM (0x0011)
/// payload — see ExpressLRS `sendCRSFTelemetryToBackpack` (devBackpack.cpp).

static constexpr uint8_t  CRSF_ADDRESS_FLIGHT_CONTROLLER = 0xC8;
static constexpr uint8_t  CRSF_ADDRESS_RADIO_TRANSMITTER = 0xEA;
static constexpr uint8_t  CRSF_FRAMETYPE_BATTERY_SENSOR = 0x08;

struct CrsfFlightBatteryDecoded {
    int16_t voltage_dv; ///< decivolts (0.1 V)
    int16_t current_da; ///< deciamps (0.1 A); may be negative
    int32_t consumed_mah;///< mAh consumed (best-effort unsigned int24 upstream)
    int8_t remaining_pct;
};

inline bool crsf_battery_crc_ok(const uint8_t *frame, size_t frame_len) {
    if (frame_len < 4)
        return false;
    unsigned crc_in = frame[frame_len - 1];
    unsigned crc = 0;
    for (size_t i = 2; i + 1 < frame_len; i++) {
        crc ^= frame[i];
        for (unsigned j = 0; j < 8; j++) {
            crc = (crc & 0x80) ? (crc << 1) ^ 0xD5 : (crc << 1);
            crc &= 0xFF;
        }
    }
    return crc == crc_in;
}

inline bool crsf_battery_address_ok(uint8_t address) {
    return address == CRSF_ADDRESS_FLIGHT_CONTROLLER ||
           address == CRSF_ADDRESS_RADIO_TRANSMITTER;
}

/// Try to locate a CRSF Battery frame inside arbitrary bytes (e.g. MSP payload).
inline bool crsf_battery_scan_payload(const uint8_t *buf, int len,
                                      CrsfFlightBatteryDecoded *out) {
    constexpr int kMinBatteryFrameBytes = 12; // address + len + type + 8-byte payload + crc
    if (!out || len < kMinBatteryFrameBytes)
        return false;
    for (int off = 0; off <= len - kMinBatteryFrameBytes; ++off) {
        if (!crsf_battery_address_ok(buf[off]))
            continue;
        uint8_t frame_len_field = buf[off + 1];
        unsigned total =
            static_cast<unsigned>(frame_len_field) + 2; // sync + len field excluded from field
        if (total < 10 || total > static_cast<unsigned>(len - off))
            continue;

        uint8_t typ = buf[off + 2];
        if (typ != CRSF_FRAMETYPE_BATTERY_SENSOR)
            continue;

        constexpr unsigned kBatPayloadLen = 8;
        constexpr unsigned expect_field = kBatPayloadLen + 2; // type + payload + crc
        if (static_cast<unsigned>(frame_len_field) != expect_field)
            continue;

        if (!crsf_battery_crc_ok(buf + off, total))
            continue;

        size_t payload_off = static_cast<size_t>(off + 3);
        int16_t v = static_cast<int16_t>((buf[payload_off] << 8) | buf[payload_off + 1]);
        int16_t c = static_cast<int16_t>((buf[payload_off + 2] << 8) | buf[payload_off + 3]);
        uint32_t mah = (uint32_t)buf[payload_off + 4] << 16 | (uint32_t)buf[payload_off + 5] << 8 |
                       (uint32_t)buf[payload_off + 6];
        int8_t rem = static_cast<int8_t>(buf[payload_off + 7]);

        if (mah > 999999 || rem < -1 || rem > 101)
            continue;

        out->voltage_dv = v;
        out->current_da = c;
        out->consumed_mah = static_cast<int32_t>(mah & 0xFFFFFFu);
        out->remaining_pct = rem;
        return true;
    }
    return false;
}

/// If `buf` holds a plausible MSPv2 packet with Backpack CRSF TLM, extract Battery sensor.
inline bool crsfp_try_battery_from_any_msp_payload(const uint8_t *buf, int len,
                                                   CrsfFlightBatteryDecoded *out) {
    if (!buf || !out || len < 13)
        return false;
    for (int base = 0; base <= len - 11; ++base) {
        if (buf[base] != '$' || buf[base + 1] != 'X')
            continue;
        uint8_t dir = buf[base + 2];
        if (dir != '<' && dir != '>')
            continue;
        auto function = static_cast<uint16_t>(buf[base + 4] | (buf[base + 5] << 8));
        auto psize =
            static_cast<uint16_t>(buf[base + 6] | (buf[base + 7] << 8));
        if (function != MSP_ELRS_BACKPACK_CRSF_TLM)
            continue;
        int hdr = base + 8;
        long need_long = static_cast<long>(hdr) + static_cast<long>(psize) + 1; // crc
        if (need_long > len || hdr + static_cast<int>(psize) + 1 > len)
            continue;
        uint8_t crc_calc = 0;
        const int crc_start = base + 3;
        const int crc_end_exclusive = hdr + static_cast<int>(psize);
        for (int i = crc_start; i < crc_end_exclusive; ++i) {
            crc_calc = crc8_dvb_s2(crc_calc, buf[i]);
        }
        if (crc_calc != buf[crc_end_exclusive])
            continue;
        if (!crsf_battery_scan_payload(buf + hdr, static_cast<int>(psize), out))
            continue;
        return true;
    }
    return false;
}
