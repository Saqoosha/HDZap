#pragma once

#include <cstdint>
#include <WiFi.h>
#include <esp_wifi.h>
#include <esp_now.h>
#include <MD5Builder.h>

/// Derive 6-byte UID from bind phrase using MD5.
/// Matches ELRS: MD5('-DMY_BINDING_PHRASE="<phrase>"'), first 6 bytes, bit0 of [0] cleared.
inline void uid_from_bind_phrase(const char *phrase, uint8_t uid[6]) {
    char input[128];
    snprintf(input, sizeof(input), "-DMY_BINDING_PHRASE=\"%s\"", phrase);

    MD5Builder md5;
    md5.begin();
    md5.add(input);
    md5.calculate();
    uint8_t hash[16];
    md5.getBytes(hash);

    memcpy(uid, hash, 6);
    uid[0] &= ~0x01; // Must be even for unicast MAC
}

/// Initialize ESP-NOW with the given UID as both our MAC and the peer MAC.
/// Returns true on success.
inline bool espnow_init(uint8_t uid[6]) {
    WiFi.mode(WIFI_STA);
    WiFi.setTxPower(WIFI_POWER_19_5dBm);
    esp_wifi_set_protocol(WIFI_IF_STA,
        WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G |
        WIFI_PROTOCOL_11N | WIFI_PROTOCOL_LR);
    WiFi.begin("_", "_", 1); // Force channel 1
    WiFi.disconnect();

    // Spoof our MAC to the UID
    esp_err_t err = esp_wifi_set_mac(WIFI_IF_STA, uid);
    if (err != ESP_OK) return false;

    if (esp_now_init() != ESP_OK) return false;

    // Add goggle VRX backpack as peer (same UID as MAC)
    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, uid, 6);
    peer.channel = 0; // Use current channel (1)
    peer.encrypt = false;
    return esp_now_add_peer(&peer) == ESP_OK;
}

/// Reinitialize ESP-NOW with a new UID at runtime.
/// Removes old peer, updates MAC, adds new peer.
inline bool espnow_reinit(uint8_t new_uid[6]) {
    new_uid[0] &= ~0x01; // defensive: enforce unicast MAC invariant
    // ESP-NOW caps the peer table at ESP_NOW_MAX_TOTAL_PEER_NUM; bound the
    // loop so a del_peer failure can't spin forever.
    esp_now_peer_info_t peer;
    for (int i = 0; i < ESP_NOW_MAX_TOTAL_PEER_NUM; i++) {
        if (esp_now_fetch_peer(true, &peer) != ESP_OK) break;
        if (esp_now_del_peer(peer.peer_addr) != ESP_OK) return false;
    }

    if (esp_wifi_set_mac(WIFI_IF_STA, new_uid) != ESP_OK) return false;

    esp_now_peer_info_t new_peer = {};
    memcpy(new_peer.peer_addr, new_uid, 6);
    new_peer.channel = 0;
    new_peer.encrypt = false;
    return esp_now_add_peer(&new_peer) == ESP_OK;
}

/// Send raw bytes via ESP-NOW to the UID peer.
inline bool espnow_send(uint8_t uid[6], const uint8_t *data, size_t len) {
    return esp_now_send(uid, data, len) == ESP_OK;
}

/// Broadcast send (for ELRS bind). Temporarily adds the broadcast peer,
/// transmits, then removes it so the goggle peer table stays clean.
inline bool espnow_send_broadcast(const uint8_t *data, size_t len, int repeat = 1) {
    static const uint8_t kBroadcast[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, kBroadcast, 6);
    peer.channel = 0;
    peer.encrypt = false;
    if (esp_now_add_peer(&peer) != ESP_OK) return false;

    bool ok = true;
    for (int i = 0; i < repeat; i++) {
        if (esp_now_send(kBroadcast, data, len) != ESP_OK) ok = false;
    }

    // Best-effort cleanup; a failure here doesn't invalidate the transmit.
    esp_now_del_peer(kBroadcast);
    return ok;
}
