#pragma once

#include <cstdint>
#include "msp.h"
#include "espnow_link.h"

/// Send ELRS backpack bind packet (broadcast).
/// Repeats 3x for reliability since ESP-NOW broadcast has no ACK.
/// Returns true if every transmit enqueued successfully.
inline bool send_bind_packet(uint8_t uid[6]) {
    uint8_t buf[MSP_MAX_PACKET];
    size_t len = msp_build_packet(buf, MSP_ELRS_BIND, uid, 6);
    return espnow_send_broadcast(buf, len, 3);
}
