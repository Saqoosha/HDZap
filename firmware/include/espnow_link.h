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

/// Delivery-status counters updated from the ESP-NOW send callback (runs
/// in WiFi task context). The main loop snapshots g_espnow_sent_fail
/// before dispatching a render cycle and re-checks after a verify window
/// to detect MAC-layer delivery failure — the only feedback available
/// since the HDZero goggle does not emit an application-level ack.
///
/// Single-word uint32_t load/store is atomic on ESP32 (32-bit aligned),
/// so `volatile` without a mux is sufficient for the one-writer /
/// one-reader pattern here. Wraparound is safe: readers compute deltas
/// via unsigned subtraction.
inline volatile uint32_t g_espnow_sent_ok = 0;
inline volatile uint32_t g_espnow_sent_fail = 0;

inline void _espnow_send_status_cb(const uint8_t *mac_addr, esp_now_send_status_t status) {
    (void)mac_addr;
    if (status == ESP_NOW_SEND_SUCCESS) {
        g_espnow_sent_ok++;
    } else {
        g_espnow_sent_fail++;
    }
}

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
/// Safe to retry after a prior failure: IDF only documents
/// ESP_ERR_ESPNOW_INTERNAL as "Internal error" (no subtype breakdown), but
/// empirically it shows up when esp_now_init is called on top of an
/// already-initialized stack. deinit + retry recovers cleanly.
inline bool espnow_init(uint8_t uid[6]) {
    WiFi.mode(WIFI_STA);
    WiFi.setTxPower(WIFI_POWER_19_5dBm);
    esp_err_t proto_err = esp_wifi_set_protocol(WIFI_IF_STA,
        WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G |
        WIFI_PROTOCOL_11N | WIFI_PROTOCOL_LR);
    if (proto_err != ESP_OK) {
        // LR mode is ESP32-family only; silent failure here means range
        // is limited to plain B/G/N even though the rest of init succeeds.
        Serial.printf("espnow_init: set_protocol failed (%d) — LR may be unavailable\n", proto_err);
    }
    WiFi.begin("_", "_", 1); // Force channel 1
    WiFi.disconnect();
    uint8_t primary = 0;
    wifi_second_chan_t second = WIFI_SECOND_CHAN_NONE;
    esp_err_t ch_err = esp_wifi_get_channel(&primary, &second);
    if (ch_err != ESP_OK) {
        // The verification step itself failed — don't silently proceed
        // assuming channel 1. Log so a misconfigured WiFi stack is
        // diagnosable from serial alone.
        Serial.printf("espnow_init: get_channel failed (%d) — channel unverified\n", ch_err);
    } else if (primary != 1) {
        // peer.channel = 0 means "current channel" — a post-WiFi.begin
        // channel drift would silently send every packet to a channel
        // the goggle isn't listening on. Force it back to 1 so the
        // invariant the rest of the stack assumes actually holds.
        Serial.printf("espnow_init: WiFi on channel %u, forcing to 1\n", primary);
        esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE);
    }

    if (esp_wifi_set_mac(WIFI_IF_STA, uid) != ESP_OK) return false;

    esp_err_t init_err = esp_now_init();
    if (init_err == ESP_ERR_ESPNOW_INTERNAL) {
        esp_err_t deinit_err = esp_now_deinit();
        if (deinit_err != ESP_OK && deinit_err != ESP_ERR_ESPNOW_NOT_INIT) {
            Serial.printf("espnow_init: esp_now_deinit failed (%d) before retry\n", deinit_err);
        }
        init_err = esp_now_init();
    }
    if (init_err != ESP_OK) {
        Serial.printf("espnow_init: esp_now_init failed (%d)\n", init_err);
        return false;
    }

    // Register BEFORE peer add so the ESP_ERR_ESPNOW_EXIST early-return
    // below still has delivery tracking wired. Non-fatal: transmission
    // works without the callback, but the main loop's retry state
    // machine sees no "fail" events and silently skips retries, so log
    // loudly enough to diagnose from serial alone.
    esp_err_t cb_err = esp_now_register_send_cb(_espnow_send_status_cb);
    if (cb_err != ESP_OK) {
        Serial.printf("espnow_init: register_send_cb failed (%d) — delivery tracking disabled\n", cb_err);
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
/// documented behaviour, and fetch_peer may skip broadcast/multicast
/// peers, so "delete shifts the head" is fragile regardless. After the
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
/// `uid` is `const` so callers (notably OSD) can pass a pointer into
/// shared live-UID storage without const_cast — esp_now_send itself
/// takes a `const uint8_t *` peer address.
inline bool espnow_send(const uint8_t *uid, const uint8_t *data, size_t len) {
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
        Serial.println("espnow_send_broadcast: peer already present (stale cleanup)");
    } else if (add_err != ESP_OK) {
        Serial.printf("espnow_send_broadcast: add_peer failed (%d)\n", add_err);
        return false;
    }

    bool ok = true;
    for (int i = 0; i < repeat; i++) {
        if (i > 0) {
            // ELRS backpack needs a gap between consecutive bind
            // broadcasts to process each MSP_ELRS_BIND before the next
            // arrives. Removing this gap in an earlier refactor silently
            // broke bind (all 3 queued too fast, receiver dropped
            // everything past the first — goggle UID stayed stale).
            //
            // delayMicroseconds is a busy-wait: it does NOT yield to
            // FreeRTOS, so it does NOT fall under CLAUDE.md's "no
            // delay() between ESP-NOW packets" rule. The original
            // experimental code used this same 5 ms.
            delayMicroseconds(5000);
        }
        esp_err_t send_err = esp_now_send(kBroadcast, data, len);
        if (send_err != ESP_OK) {
            Serial.printf("espnow_send_broadcast: send %d/%d failed (%d)\n",
                          i + 1, repeat, send_err);
            ok = false;
        }
    }

    esp_err_t del_err = esp_now_del_peer(kBroadcast);
    if (del_err != ESP_OK && del_err != ESP_ERR_ESPNOW_NOT_FOUND) {
        Serial.printf("espnow_send_broadcast: del_peer failed (%d)\n", del_err);
    }
    return ok;
}
