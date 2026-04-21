#pragma once

#include <cstdint>
#include <WiFi.h>
#include <esp_wifi.h>
#include <esp_now.h>
#include <MD5Builder.h>

// IEEE 802.3 marks bit0 of the first MAC octet as the multicast flag.
// ESP-NOW peers must be unicast, so every UID assignment must leave bit0
// cleared — see "unicast MAC invariant" at each site.
//
// ESP-NOW peer.channel = 0 means "use the current WiFi channel" (we pin
// that to 1 via WiFi.begin below). One comment here avoids re-explaining
// at every peer_info_t init.

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
/// Safe to call again after a prior failure: if ESP-NOW is already inside
/// a started state we deinit first so add_peer gets a clean table.
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
    if (init_err == ESP_ERR_ESPNOW_INTERNAL) {
        // IDF returns INTERNAL when esp_now_init is called while already
        // initialized. Tear down and retry so the peer table is clean.
        esp_now_deinit();
        init_err = esp_now_init();
    }
    if (init_err != ESP_OK) {
        Serial.printf("espnow_init: esp_now_init failed (%d)\n", init_err);
        return false;
    }

    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, uid, 6);
    peer.channel = 0;
    peer.ifidx = WIFI_IF_STA;
    peer.encrypt = false;
    esp_err_t add_err = esp_now_add_peer(&peer);
    if (add_err == ESP_ERR_ESPNOW_EXIST) {
        Serial.println("espnow_init: peer already present (stale state)");
        return true;
    }
    if (add_err != ESP_OK) {
        Serial.printf("espnow_init: add_peer failed (%d)\n", add_err);
        return false;
    }
    return true;
}

/// Reinitialize ESP-NOW with a new UID at runtime.
/// Snapshots every registered peer into a local array, then deletes them —
/// mutating the peer list while iterating with esp_now_fetch_peer is not
/// documented behaviour, and relying on "delete shifts the head" broke in
/// practice with broadcast peers that fetch_peer doesn't return. After the
/// peer table is empty we update the MAC and add the new peer.
inline bool espnow_reinit(uint8_t new_uid[6]) {
    new_uid[0] &= ~0x01; // unicast MAC invariant

    uint8_t addrs[ESP_NOW_MAX_TOTAL_PEER_NUM][6];
    int count = 0;
    esp_now_peer_info_t peer;
    bool from_head = true;
    while (count < ESP_NOW_MAX_TOTAL_PEER_NUM
           && esp_now_fetch_peer(from_head, &peer) == ESP_OK) {
        from_head = false;
        memcpy(addrs[count++], peer.peer_addr, 6);
    }
    for (int i = 0; i < count; i++) {
        esp_err_t del_err = esp_now_del_peer(addrs[i]);
        if (del_err != ESP_OK && del_err != ESP_ERR_ESPNOW_NOT_FOUND) {
            Serial.printf("espnow_reinit: del_peer failed (%d)\n", del_err);
            return false;
        }
    }

    if (esp_wifi_set_mac(WIFI_IF_STA, new_uid) != ESP_OK) {
        Serial.println("espnow_reinit: set_mac failed");
        // Caller will mark espnow_ready=false and next retry goes through
        // espnow_init which deinits + reinits for a clean slate.
        return false;
    }

    esp_now_peer_info_t new_peer = {};
    memcpy(new_peer.peer_addr, new_uid, 6);
    new_peer.channel = 0;
    new_peer.ifidx = WIFI_IF_STA;
    new_peer.encrypt = false;
    esp_err_t add_err = esp_now_add_peer(&new_peer);
    if (add_err == ESP_ERR_ESPNOW_EXIST) {
        Serial.println("espnow_reinit: peer already present (stale cleanup)");
        return true;
    }
    if (add_err != ESP_OK) {
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
/// success (logging it, so a stuck state is diagnosable) rather than
/// silently failing the next bind attempt.
inline bool espnow_send_broadcast(const uint8_t *data, size_t len, int repeat = 1) {
    static const uint8_t kBroadcast[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, kBroadcast, 6);
    peer.channel = 0;
    peer.ifidx = WIFI_IF_STA;
    peer.encrypt = false;
    esp_err_t add_err = esp_now_add_peer(&peer);
    if (add_err == ESP_ERR_ESPNOW_EXIST) {
        Serial.println("espnow_send_broadcast: broadcast peer leaked from prior call");
    } else if (add_err != ESP_OK) {
        return false;
    }

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
