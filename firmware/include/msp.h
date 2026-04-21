#pragma once

#include <cstdint>
#include <cstring>

// MSP function codes
constexpr uint16_t MSP_SET_OSD_ELEM = 0x00B6;
constexpr uint16_t MSP_ELRS_BIND = 0x0009;

// MSP DisplayPort sub-commands
constexpr uint8_t MSP_DP_HEARTBEAT = 0x00;
constexpr uint8_t MSP_DP_RELEASE = 0x01;
constexpr uint8_t MSP_DP_CLEAR = 0x02;
constexpr uint8_t MSP_DP_WRITE_STRING = 0x03;
constexpr uint8_t MSP_DP_DRAW = 0x04;

// HDZero OSD grid (HD mode)
constexpr uint8_t OSD_COLS = 50;
constexpr uint8_t OSD_ROWS = 18;

// Max MSP packet size (ESP-NOW limit is 250 bytes)
constexpr size_t MSP_MAX_PACKET = 128;

/// CRC8/DVB-S2 used by MSPv2
inline uint8_t crc8_dvb_s2(uint8_t crc, uint8_t a) {
    crc ^= a;
    for (int i = 0; i < 8; ++i) {
        crc = (crc & 0x80) ? (crc << 1) ^ 0xD5 : crc << 1;
    }
    return crc;
}

/// Build a MSPv2 packet into buf. Returns total packet size.
/// Format: $X< flags(0) function(2,LE) payload_size(2,LE) payload(N) crc8
inline size_t msp_build_packet(uint8_t *buf, uint16_t function,
                               const uint8_t *payload, uint16_t payload_size) {
    size_t pos = 0;
    buf[pos++] = '$';
    buf[pos++] = 'X';
    buf[pos++] = '<';           // command direction
    buf[pos++] = 0x00;          // flags
    buf[pos++] = function & 0xFF;
    buf[pos++] = function >> 8;
    buf[pos++] = payload_size & 0xFF;
    buf[pos++] = payload_size >> 8;
    if (payload && payload_size > 0) {
        memcpy(&buf[pos], payload, payload_size);
        pos += payload_size;
    }
    // CRC over bytes [3]..[pos-1] (flags through end of payload)
    uint8_t crc = 0;
    for (size_t i = 3; i < pos; i++) {
        crc = crc8_dvb_s2(crc, buf[i]);
    }
    buf[pos++] = crc;
    return pos;
}
