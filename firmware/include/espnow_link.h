#pragma once

#include <cstdint>
#include <WiFi.h>
#include <esp_wifi.h>
#include <esp_now.h>
#include <MD5Builder.h>

// ESP-NOW peer.channel convention: 0 means "use the current WiFi channel"
// (we hold that at 1 via WiFi.begin(..., 1) below). Keeping this one comment
// avoids re-explaining at every peer_info_t init.

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
    uid[0] &= ~0x01; // unicast MAC invariant
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

    if (esp_wifi_set_mac(WIFI_IF_STA, uid) != ESP_OK) return false;

    esp_err_t init_err = esp_now_init();
    if (init_err != ESP_OK && init_err != ESP_ERR_ESPNOW_NOT_INIT) {
        // ESP_ERR_ESPNOW_NOT_INIT from the opposite path (already init) —
        // any other error is fatal for this attempt.
        return false;
    }

    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, uid, 6);
    peer.channel = 0;
    peer.encrypt = false;
    esp_err_t add_err = esp_now_add_peer(&peer);
    return add_err == ESP_OK || add_err == ESP_ERR_ESPNOW_EXIST;
}

/// Reinitialize ESP-NOW with a new UID at runtime.
/// Removes every registered peer (bounded), updates MAC, adds the new peer.
/// Logs which stage failed so the caller can tell whether the radio is
/// partially torn down.
inline bool espnow_reinit(uint8_t new_uid[6]) {
    new_uid[0] &= ~0x01; // unicast MAC invariant

    // esp_now_fetch_peer(from_head=true) begins iteration; subsequent calls
    // with false continue. Because we delete as we go, the head shifts each
    // time, so a fresh "from_head=true" on the next loop happens to also
    // work — but using the documented pattern avoids surprise in future IDFs.
    esp_now_peer_info_t peer;
    bool from_head = true;
    for (int i = 0; i < ESP_NOW_MAX_TOTAL_PEER_NUM; i++) {
        if (esp_now_fetch_peer(from_head, &peer) != ESP_OK) break;
        from_head = false;
        esp_err_t del_err = esp_now_del_peer(peer.peer_addr);
        if (del_err != ESP_OK && del_err != ESP_ERR_ESPNOW_NOT_FOUND) {
            Serial.printf("espnow_reinit: del_peer failed (%d)\n", del_err);
            return false;
        }
    }

    if (esp_wifi_set_mac(WIFI_IF_STA, new_uid) != ESP_OK) {
        Serial.println("espnow_reinit: set_mac failed");
        return false;
    }

    esp_now_peer_info_t new_peer = {};
    memcpy(new_peer.peer_addr, new_uid, 6);
    new_peer.channel = 0;
    new_peer.encrypt = false;
    esp_err_t add_err = esp_now_add_peer(&new_peer);
    if (add_err != ESP_OK && add_err != ESP_ERR_ESPNOW_EXIST) {
        Serial.printf("espnow_reinit: add_peer failed (%d)\n", add_err);
        return false;
    }
    return true;
}

/// Send raw bytes via ESP-NOW to the UID peer.
inline bool espnow_send(uint8_t uid[6], const uint8_t *data, size_t len) {
    return esp_now_send(uid, data, len) == ESP_OK;
}

/// Broadcast send (for ELRS bind). Temporarily adds the broadcast peer,
/// transmits, then removes it so the goggle peer table stays clean.
/// ESP_ERR_ESPNOW_EXIST on add means an earlier cleanup missed — treat as
/// success rather than breaking the next bind attempt silently.
inline bool espnow_send_broadcast(const uint8_t *data, size_t len, int repeat = 1) {
    static const uint8_t kBroadcast[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, kBroadcast, 6);
    peer.channel = 0;
    peer.encrypt = false;
    esp_err_t add_err = esp_now_add_peer(&peer);
    if (add_err != ESP_OK && add_err != ESP_ERR_ESPNOW_EXIST) return false;

    bool ok = true;
    for (int i = 0; i < repeat; i++) {
        if (esp_now_send(kBroadcast, data, len) != ESP_OK) ok = false;
    }

    esp_err_t del_err = esp_now_del_peer(kBroadcast);
    if (del_err != ESP_OK && del_err != ESP_ERR_ESPNOW_NOT_FOUND) {
        Serial.printf("espnow_send_broadcast: del_peer failed (%d)\n", del_err);
    }
    return ok;
}
