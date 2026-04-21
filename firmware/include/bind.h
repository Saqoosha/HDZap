#pragma once

#include <cstdint>
#include <esp_now.h>
#include "msp.h"
#include "espnow_link.h"

/// Send ELRS backpack bind packet (broadcast).
/// Sends 3 times for reliability since there is no ACK.
/// Returns true if all sends succeeded.
inline bool send_bind_packet(uint8_t uid[6]) {
    // Add broadcast peer temporarily
    static const uint8_t broadcast[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, broadcast, 6);
    peer.channel = 0;
    peer.encrypt = false;

    if (esp_now_add_peer(&peer) != ESP_OK) return false;

    // Build MSPv2 bind packet: function=0x0009, payload=UID (6 bytes)
    uint8_t buf[MSP_MAX_PACKET];
    size_t len = msp_build_packet(buf, MSP_ELRS_BIND, uid, 6);

    bool ok = true;
    for (int i = 0; i < 3; i++) {
        if (esp_now_send(broadcast, buf, len) != ESP_OK) {
            ok = false;
        }
        if (i < 2) delayMicroseconds(5000); // 5ms between sends
    }

    esp_now_del_peer(broadcast);
    return ok;
}
