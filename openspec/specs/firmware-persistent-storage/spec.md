# firmware-persistent-storage Specification

## Purpose

Survive boots without losing the goggle's UID or the operator's deep-sleep timeout, while degrading gracefully through torn writes, missing keys, and partial NVS corruption.

## Requirements

### Requirement: NVS namespace and keys / NVS ネームスペースとキー

The firmware SHALL use NVS namespace `"hdzero"` exclusively. Keys are:

- `"uid"` (6 bytes) — the goggle UID.
- `"init"` (1 byte sentinel) — torn-write detection for `uid`.
- `"slpmin"` (1 byte) — deep-sleep idle timeout in minutes; 0 = disabled.

No other keys MUST be written to this namespace. Adding a new key is a spec change.

#### Scenario: Fresh device with no NVS state
- Given a brand-new device with empty NVS
- When `loadUid` is called
- Then it returns `false` (no UID present)
- When `loadSleepMinutes` is called
- Then it returns `kSleepDefaultMin` (5)

### Requirement: UID save with sentinel order / Sentinel 順序での UID 保存

`saveUid(uid)` SHALL execute writes in this exact order:

1. `prefs.remove("init")` — drop the sentinel first.
2. `prefs.putBytes("uid", uid, 6)` — write the UID.
3. If step 2 wrote 6 bytes: `prefs.putUChar("init", 1)` — re-write the sentinel.

A torn save (power loss between steps 2 and 3) leaves "uid present, sentinel absent" — `loadUid` SHALL recognize this state and warn while still returning the value (fail-soft). Step 2 returning fewer than 6 bytes SHALL fail the save without writing the sentinel.

`prefs.end()` の戻り値が無いため commit 失敗の signal は putBytes / putUChar の戻りバイト数しか持たない。完全サイズの戻りを「コミットされた」最強のシグナルとみなして残余リスクを受け入れる。

#### Scenario: Successful save
- Given a valid UID
- When `saveUid` runs to completion
- Then NVS has both `uid` (6 bytes) and `init` (sentinel)
- And the function returns true

#### Scenario: Power loss between uid write and sentinel
- Given `saveUid` has completed `putBytes` but `putUChar` has not yet committed
- When power is restored
- Then NVS has `uid` present but `init` absent
- And `loadUid` returns the UID with a warning log
- And the firmware continues with the (likely correct) value

### Requirement: Fail-soft load / フェイルソフトロード

`loadUid(out_uid)` SHALL:

- Return `false` if the namespace open fails (first boot before any save).
- Return `false` if `uid` key is absent (genuine first boot).
- Return `false` if `getBytes("uid")` reads fewer than 6 bytes (truncated write — log and refuse).
- Return `true` with the 6 bytes when present, even if the sentinel is missing — log the torn-write warning but proceed.

A 6-byte UID is a legitimately usable value either way (pre-sentinel legacy data or torn save with new uid already written). Dropping a valid UID on every torn save would silently break goggle communication for the user, which is worse than a warning.

#### Scenario: Sentinel missing but uid intact
- Given NVS has `uid` (6 bytes) but no `init` key
- When `loadUid` is called
- Then it returns true with the UID
- And serial logs `nvs_store: uid present but sentinel missing — torn write or pre-sentinel data; using uid anyway`

### Requirement: Sleep-minutes single-byte save / Sleep minutes は単一バイト保存

`saveSleepMinutes(minutes)` SHALL write a single `putUChar("slpmin", minutes)`. `loadSleepMinutes` SHALL return the value with `getUChar("slpmin", kSleepDefaultMin)` so an absent key falls back to the compile-time default (5 min).

No sentinel pattern is used for `slpmin` — a single `putUChar` is one NVS entry which cannot be torn at the entry level. The failure mode of a torn write is "value snaps back to `kSleepDefaultMin`", which is benign. A sentinel cannot disambiguate a torn write from "user explicitly set 0 to disable" anyway.

#### Scenario: User sets sleep to 10 min
- Given `saveSleepMinutes(10)` is called
- When boot reads the value
- Then `loadSleepMinutes` returns 10

#### Scenario: User disables sleep
- Given `saveSleepMinutes(0)` is called
- When boot reads
- Then `loadSleepMinutes` returns 0
- And the main loop interprets 0 as "deep sleep disabled"

### Requirement: Unicast invariant on load / ロード時のユニキャスト不変条件

After `loadUid` returns true (or after the MAC fallback in `setup()`), the firmware SHALL apply `g_uid[0] &= ~0x01` so a multicast bit set in legacy or corrupted NVS data cannot reach `esp_wifi_set_mac` (which would reject it).

#### Scenario: Legacy NVS UID with multicast bit
- Given NVS holds `01:02:03:04:05:06`
- When `setup()` loads and clears
- Then `g_uid == 00:02:03:04:05:06`
- And `espnow_init` accepts the MAC
