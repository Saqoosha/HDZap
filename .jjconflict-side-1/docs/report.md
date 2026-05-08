# HDZero OSD via ESP-NOW — Research & Test Report

## Overview

Standalone ESP32 devboard から HDZero ゴーグル内蔵 ESP32 Backpack に ESP-NOW 経由で カスタム OSD メッセージを送信するテストを実施。最終目標は RotorHazard レースシステムとの連携。

## Architecture

```
[ESP32 DevKit]                    [HDZero Goggle]
 PlatformIO                       ELRS Backpack FW (built-in ESP32)
 Arduino Framework                    │
      │                               │ Internal UART
      │  ESP-NOW (2.4GHz, Ch1)        │
      └──────────────────────────►[Goggle Main SoC]
         MSPv2 packets                    │
         No encryption                    ▼
         MAC = UID                   OSD Overlay
```

## Protocol Details

### Bind Phrase → UID (MAC Address)

ELRS 方式で bind phrase から 6-byte UID を生成:

1. 入力文字列: `-DMY_BINDING_PHRASE="<phrase>"`
2. MD5 ハッシュの先頭 6 バイトを取得
3. 1st byte の bit0 をクリア（unicast MAC 要件）
4. 送受信ともにこの UID を MAC address として spoof

Online tool: https://busheezy.github.io/elrs-binding-phrase-to-bytes

### ESP-NOW Setup

- WiFi mode: STA
- Channel: 1 (固定)
- Protocol: 11B + 11G + 11N + LR
- Encryption: なし
- TX Power: 19.5dBm

### MSPv2 Packet Format

```
Offset  Size  Field
0       1     '$' (0x24)
1       1     'X' (0x58)       ← MSPv2 marker
2       1     '<' (0x3C)       ← command direction
3       1     flags (0x00)
4       2     function (LE)    ← 0x00B6 = MSP_SET_OSD_ELEM
6       2     payload_size (LE)
8       N     payload
8+N     1     CRC8/DVB-S2      ← over bytes [3]..[8+N-1]
```

### OSD Sub-Commands (payload[0])

| ID   | Name         | Effect                                     |
|------|--------------|--------------------------------------------|
| 0x00 | Heartbeat    | No-op                                      |
| 0x01 | Release      | Clear overlay + draw immediately            |
| 0x02 | Clear        | Zero overlay buffer (not yet visible)       |
| 0x03 | Write String | Write text at (row, col) to overlay buffer  |
| 0x04 | Draw         | Copy overlay → visible screen, trigger redraw |

### Write String Payload (sub-command 0x03)

```
payload[0] = 0x03          sub-command
payload[1] = row           0-based
payload[2] = col           0-based
payload[3] = attr          bit0: font page (0 or 1)
payload[4..N] = characters raw bytes, NOT null-terminated
```

### Update Sequence

```
Clear (0x02) → WriteString (0x03) x N → Draw (0x04)
```

All packets sent back-to-back, no delay between them.

## Test Results

### OSD Grid

- Grid size: **50 columns × 18 rows** (HD mode)
- Usable columns: **0–49** (ただし col 49 は右端クリップの可能性あり。col 48 まで確実に表示)
- Usable rows: **0–17**
- Row 0 / Row 17 の top/bottom edge は表示可能

### Character Encoding

- **大文字 A-Z (0x41-0x5A)**: 正常表示
- **数字 0-9 (0x30-0x39)**: 正常表示
- **小文字 a-z (0x61-0x7A)**: FPV 特殊シンボルとして表示される（バッテリー、GPS、方位矢印等）
- **対策**: lowercase → uppercase 変換を実装

BF OSD フォントの character map では 0x60-0x7F に FPV 用特殊グリフが配置されており、ASCII lowercase と衝突する。

### ESP-NOW Packet Throughput

- **10 packets/cycle まで安定** (clear + 8 writeString + draw)
- **11 packets/cycle 以上で packet drop 発生**
- 原因: ESP-NOW の TX queue overflow（back-to-back 送信時）
- `delay()` をパケット間に入れると全く表示されなくなる（ESP-NOW の内部 state に干渉）

### delay() の問題

`send_osd()` 内に `delay(20)` を入れたところ、たった 4 パケットの simple test でも表示不能になった。Arduino ESP32 の `delay()` は内部で `vTaskDelay()` を呼び、FreeRTOS scheduler に yield する。これが ESP-NOW の WiFi タスクと干渉し、パケット送信を破壊する。

**教訓: 個々のパケット間に delay を入れない。更新サイクル間でのみ待機する。**

### VTX 不要 / アナログ入力対応

Backpack OSD は VTX 映像とは独立したパス（`elrs.c` → `elrs_osd_overlay`）で処理される。

- **信号なし**: ゴーグル単体（VTX なし）で OSD overlay 表示確認済み
- **アナログ入力**: アナログ映像受信中でも OSD overlay 表示確認済み
- **結論**: Backpack OSD は映像ソース（HDZero / アナログ / 信号なし）に依存しない

## Project Structure

Run `ls firmware/include firmware/src` for the current module list.
Architecture boundaries and responsibilities live in
[CLAUDE.md](../CLAUDE.md#architecture-boundaries).

## Configuration

The bind phrase / UID is configured at runtime from the iOS app over BLE
(no build-time flag). See iOS `ConnectionView` → "Goggle Pairing".

### Goggle Setup

1. ELRS Configurator で HDZero Goggles Built-in ESP32 Backpack ターゲットを選択
2. 同じ bind phrase を設定してビルド
3. 4 ファイルを SD カードの `ELRS/` フォルダにコピー
4. ゴーグルメニュー → Firmware → Update ESP32

## Practical Limits for RH Integration

| Constraint        | Value                |
|-------------------|----------------------|
| Max lines/update  | 8                    |
| Max cols          | ~49 (safe: 48)       |
| Max rows          | 18 (0-17)            |
| Character set     | Uppercase + digits   |
| Update rate       | No strict limit      |
| Keepalive         | Not required         |
| VTX required      | No                   |

## Key Source References

- **ExpressLRS/Backpack**: `Tx_main.cpp`, `Vrx_main.cpp`, `lib/MSP/msp.cpp`
- **hd-zero/hdzero-goggle**: `src/core/elrs.c` (`handle_osd()`), `src/core/elrs.h`
- **Bind phrase tool**: https://busheezy.github.io/elrs-binding-phrase-to-bytes

## Timer Backpack 方式（RH 連携向け）

### Architecture

```
[RotorHazard (RPi)]
    │ USB Serial (460800 baud)
    ▼
[Timer Backpack]        ← ESP32 devboard に ELRS Timer Backpack FW
    │ ESP-NOW
    ▼
[HDZero Goggle]         ← ELRS VRx Backpack FW
```

### Multi-Pilot MAC 切り替え

ELRS Backpack FW に `MSP_ELRS_SET_SEND_UID` (0x00B5) コマンドが実装済み:

```
1. SET_SEND_UID(pilot_A_uid)  → Timer が自分の MAC を pilot A の UID に変更
2. OSD packets (clear/write/draw) 送信
3. RESET_SEND_UID             → デフォルトに戻す
4. SET_SEND_UID(pilot_B_uid)  → pilot B の UID に変更
5. OSD packets 送信
6. RESET_SEND_UID
... 全パイロット分繰り返し
```

Timer Backpack 内部で `esp_wifi_set_mac()` を WiFi stop なしで直接呼んでいる。
ESP-NOW は AP 未接続の STA モードで動作するため、MAC 変更が即座に反映される。

### SET_SEND_UID Payload

```
function = 0x00B5

Set:   payload = [0x01, uid0, uid1, uid2, uid3, uid4, uid5]
Reset: payload = [0x00]
```

### Timer Backpack FW

ELRS Configurator の以下どちらでも同一 FW:
- "Generic backpack for any Race Timer" → `Backpack for Race Timer with ESP32`
- "RotorHazard Timer Backpack" → `ESP32 Module (DIY)`

### RH 連携ソフトウェア

- **VRxC_ELRS プラグイン** (https://github.com/i-am-grub/VRxC_ELRS)
- Python ベース、RH v4.1.0+ で動作
- 各パイロットの bind phrase を RH UI で設定
- レース状態（Stage/Start/Finish）、ラップタイム、順位、ギャップを自動送信

### Test: Serial → Timer Backpack → Goggle OSD

`test_timer_backpack.py` で RH なしでの動作を確認済み:
- Python から USB Serial (460800 baud) で MSPv2 パケットを送信
- Timer Backpack が ESP-NOW でゴーグルに中継
- OSD テキスト表示成功

## Test Summary

| Test | Method | Result |
|------|--------|--------|
| Custom FW → ESP-NOW → Goggle | ESP32 自作 FW 直接送信 | OK |
| Timer Backpack → ESP-NOW → Goggle | Python Serial → Timer FW 中継 | OK |
| Multi-line stress test | 1-8 lines per cycle | OK (9+ で drop) |
| Corner position test | Row 0/17, Col 0/48 | OK (col 49 clip) |
| Lowercase characters | a-z → FPV glyphs | NG → uppercase 変換で解決 |

## Next Steps

- RH に VRxC_ELRS プラグインを導入してフルレース連携テスト
- 複数パイロット同時 OSD 送信テスト
- OSD レイアウト設計（8行以内）
