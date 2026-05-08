# HDZero OSD Lap Timer

## Project Overview

iPhone manual lap timer → BLE → ESP32 bridge → ESP-NOW → HDZero goggle OSD.
FPV drone racing use case: operator taps LAP on phone, lap time appears on pilot's goggle.

## Repository Structure

```
firmware/                 ESP32 PlatformIO project (Arduino framework)
app/                      iOS SwiftUI app (iOS 18+, xcodegen)
docs/                     Architecture, research, TestFlight setup (allow-listed: only docs/manual/ + docs/flash/ ship to Pages)
docs/manual/              End-user manual (en + ja); served on GitHub Pages
docs/flash/               Browser firmware flasher (esptool-js); served on GitHub Pages
scripts/                  build / upload-testflight / release helpers
.github/workflows/        CI: builds firmware, composes Pages artefact, deploys (TestFlight upload is scripts/-driven via the release skill)
.claude/skills/release/   Claude Code skill for cutting a release end-to-end (develop bump → TestFlight → PR develop→main → tag → GitHub Release)
```

## Branching & Deployment

- `develop` = default branch; CI deploys staging to <https://saqoosha.github.io/HDZap/dev/> (`/dev/flash/`, `/dev/ja/`).
- `main` = release branch, protected (PR-only merge, no force push, no delete, admin bypass enabled). CI deploys production at the canonical paths (`/`, `/flash/`, `/ja/`).
- Pages is one site per repo, so the workflow checks out **both** branches on every push, builds firmware for each, and composes a single `_site/` with main at the root and develop mirrored under `/dev/`. Pushing to either branch refreshes its slice without touching the other.
- Releases promote develop → main through a release PR (script-driven). Direct push to `main` is rejected.

## Build Commands

```sh
# Firmware
cd firmware && pio run                    # build
cd firmware && pio run -t upload          # flash
cd firmware && pio device monitor         # serial 115200

# iOS
cd app && xcodegen generate               # regenerate .xcodeproj after changes
# Then build in Xcode (BLE requires physical device)
```

## Web Flasher (`docs/flash/`)

Browser-based firmware installer hosted on GitHub Pages. Production at
`https://saqoosha.github.io/HDZap/flash/`, staging at
`https://saqoosha.github.io/HDZap/dev/flash/`. Drives `esptool-js` directly (NOT
ESP Web Tools / `<esp-web-install-button>`) so the entire UI is custom Japanese
copy with no English library dialogs. Target hardware: M5StickS3 only.

- `docs/flash/index.html` + `style.css` — Japanese UI with a 4-state machine
  (idle / working / done / error). No external custom elements.
- `docs/flash/flasher.js` — ES module that imports `ESPLoader` + `Transport`
  from `https://unpkg.com/esptool-js@0.5.7/bundle.js` and runs the flash flow.
  All firmware paths are resolved via `new URL("firmware/...", import.meta.url)`
  so the page works at any subpath (root `/flash/` *and* `/dev/flash/`)
  without modification. Pinned to 0.5.7: 0.6.x has a known regression where
  compressed `writeFlash` on ESP32-S3 fails with
  `status 201 (ESP_TOO_MUCH_DATA)`.
- `docs/flash/manifest.json` — single field (`version`). CI overwrites the
  value with `<branch>-<short SHA>` (e.g. `main-743c728`, `develop-9f09570`)
  per side so the deployed page can show which build is live and which slice
  it belongs to; nothing else is consumed at runtime.
- `docs/flash/m5sticks3.jpg` — product photo (M5Stack), credited in footer.
- `docs/flash/firmware/*.bin` — produced by CI, **gitignored**; copying locally
  for testing is fine.
- `.github/workflows/flasher.yml` — checks out `main` and `develop` side by
  side, runs `pio run -e m5stick-s3` for each, stages 4 bins
  (`bootloader.bin`, `partitions.bin`, `boot_app0.bin`,
  `firmware.bin → hdzap.bin`), size-checks each (>= 1 KiB), writes
  `CHECKSUMS.txt`, stamps the per-branch `manifest.json`, then composes
  `_site/` with **main at the root** (`_site/flash/`, `_site/index.html`,
  `_site/ja/`) and **develop mirrored under `/dev/`** (`_site/dev/flash/`,
  `_site/dev/index.html`, `_site/dev/ja/`). Allow-list approach: ONLY the
  paths under `docs/manual/` and `docs/flash/` are copied — never the whole
  `docs/` tree, so `docs/report.md` / `docs/architecture.md` / etc. stay
  unpublished. PR builds compose the same artefact (with the PR head on the
  targeted side) but the deploy job is gated to push events.
- ESP32-S3 partition offsets used by `flasher.js` `PARTS`:
  `0x0 / 0x8000 / 0xe000 / 0x10000` (S3 starts the bootloader at 0,
  **not** 0x1000 like classic ESP32).
- The `eraseAll` parameter in `writeFlash` is wired to the "完全初期化する"
  checkbox in the UI. Default unchecked → existing NVS is preserved
  (UID, sleep timeout in namespace `hdzero`). Checked → full chip erase,
  wiping all saved state. There is no OTA / Wi-Fi update path: every
  re-flash goes through this same Web Serial flow.
- Local test: `python3 -m http.server 8765 --directory docs --bind 127.0.0.1`
  then open `http://127.0.0.1:8765/flash/` in Chrome (Web Serial requires
  HTTPS or `localhost`). Copy build artifacts into `docs/flash/firmware/`
  first; the page header will show `version: dev` because the CI version
  stamp only runs on deploy.
- GitHub Pages must be set to Source = "GitHub Actions" in repo
  Settings → Pages for the workflow to deploy. The `github-pages`
  environment's deployment-branch policy explicitly allows both `main` and
  `develop`; new branches that need to deploy must be added there.

## Key Technical Constraints

- **NEVER use delay() between ESP-NOW packets** — breaks packet delivery
- ESP-NOW max 10 packets per OSD cycle (clear + 8 writes + draw)
- OSD grid: 50x18, lowercase ASCII maps to FPV glyphs (auto-uppercase in osd.h)
- BLE UUIDs must match between firmware (ble_service.h) and iOS (BluetoothManager.swift)
- Service UUID: `f47ac10b-58cc-4372-a567-0e02b2c3d48d` (bumped from `…d48c`; iOS CoreBluetooth caches GATT per-peripheral for unbonded devices, so a new service UUID is the only reliable cache-invalidation hook short of rebooting the iPhone). **Adding a characteristic — or changing its property bitmap — without a service bump is safe ONLY when no existing iOS build attempts to read or write it** — iOS won't see the new char/property until the service UUID changes. The most recent bump (`…d48c → …d48d`) accompanied CHR_OSD_LAYOUT gaining `PROPERTY_WRITE_NR` so the iOS slider could write it as `writeWithoutResponse` and skip the ATT ack round-trip on every drag.
- `BLEServer::createService()` must be passed an explicit `numHandles` covering `1 (service decl) + 2 per characteristic + 1 per BLE2902 descriptor` — the default of 15 silently truncates overflow characteristics. The call uses 32 for headroom; recompute and bump if a future GATT addition pushes the count past ~28.
- Bind phrase UID derivation: MD5(`-DMY_BINDING_PHRASE="<phrase>"`), first 6 bytes, bit0 cleared
- VTX not required for backpack OSD display
- Binding overwrites existing UID — scenarios 1 & 2 avoid this by reusing existing UID

## Architecture Boundaries

- `msp.h` — packet building only, no I/O
- `espnow_link.h` — ESP-NOW init/send/reinit + broadcast helper, no business logic
- `osd.h` — OSD commands via ESP-NOW, no layout knowledge
- `ble_service.h` — BLE GATT server, stages payloads + sets flags for main loop
- `bind.h` — ELRS bind protocol, stateless (broadcast via espnow_link)
- `tx_sniff.h` — ESP-NOW recv callback for TX UID capture; sniff_start/stop register/unregister the global recv_cb slot; g_sniff_uid + g_sniff_captured guarded by g_sniff_mux. `g_sniff_active` (set on success of sniff_start, cleared on sniff_stop) is read by main.cpp's deep-sleep gate so a deep sleep can't silently drop the BLE-staged sniff session.
- `osd_text_display.h` — iOS-owned 4-row goggle OSD text. Per-row dirty bitmap; `render()` writeStrings just the dirty rows + draw (no clear), and the goggle's overlay buffer keeps prior content between writes. `m_dirty` survives across retries so the state machine can re-emit the same bits; `clearDirtyBits(mask)` is the surgical drop, called from main.cpp on verify-success / give-up.
- `nvs_store.h` — UID persistence (sentinel-protected) + deep-sleep timeout (`slpmin`, single-byte putUChar — no sentinel needed; one NVS entry can't be torn at the entry level). Namespace "hdzero".
- `power_log.h` — SPIFFS-backed CSV append at `/power.csv` for issue #5 phase 2/3 measurement runs. Schema = `millis,voltage_mv,percent,charging,panel_asleep,ble_connected`; main.cpp throttles to one row per 30 s and sentinel-marks out-of-range VBAT readings as -1. Schema-mismatch detection on boot wipes incompatible old logs (with CR strip so println-written headers compare equal); a stale `/power.csv.tmp` from an interrupted rotate is also cleaned up at boot. Auto-rotates at ~110 KB to keep the most recent ~80 KB inside the 128 KB SPIFFS partition; if the rotate write fails the original is preserved (no half-rotated tmp ever replaces the source). `dumpToSerial()` runs in `setup()` so plug-in-USB-after-battery-run prints the trail without a separate tool.
- `stick_display.h` — M5StickS3 LCD status display, no business logic. Battery widget (top row of UID band, left of BLE pill) is fed by `main.cpp` via `setBattery(percent, charging)`. `sleepPanel()` / `wakePanel()` / `isPanelAsleep()` own the panel power state for issue #5 phase 1; `sleepPanel()` calls `M5.Display.sleep()` only — do NOT prepend `setBrightness(0)` or it corrupts LGFX's `_brightness` cache and `wakeup()` restores brightness=0. `wakePanel()` waits 5 ms after `wakeup()` (ST7789 SLPOUT settling) then forces a full repaint.
- `battery_monitor.h` — AXP2101 percent + charging poll, alarm tier (None/Low/Critical with hysteresis) + silence latch. Single `tick(now, silenceRequested) → Outcome` (Throttled/StateChanged/TierChanged) replaces the prior `poll()` + `silence()` + `consumeSilencedDirty()` trio; silence-dirty edges fold into `StateChanged`, and `TierChanged` is returned *instead of* `StateChanged` on a tier transition (callers test `!= Throttled` for the BLE+LCD push and `== TierChanged` for the sticky strip message; the `TierChanged = 0b11 / StateChanged = 0b01` bit pattern encodes the subset relation structurally). Actuator-free — `main.cpp` owns LCD/BLE/speaker dispatch; the only `Serial.printf` paths are PMIC-validity edges and silence-press-but-already-silenced traces. Beep cadence is a separate destructive-read channel: `consumeBeepDue(now)` burns the slot on a `true` return; pair with `scheduleBeepRetry(now)` on a `M5.Speaker.tone()` failure so the next ~1 s retries instead of waiting out the 15-30 s cadence. `payload(uint8_t (&out)[2])` uses a reference-to-array so a single-byte buffer can't compile, and defensively masks bit 3 off when tier==None so a regression in `tick()`'s clear-on-tier-transition policy can't leak a wire-illegal byte to iOS.
- `main.cpp` — event loop; consumes staged BLE data under `g_ble_mux`, runs heavy work (NVS, ESP-NOW reinit) outside the BLE task, and hosts the render-retry state machine (`IDLE` → `PENDING` → `WAITING_ACK`). Snapshots the dispatched dirty mask at render time so verify-success can clear *only* the bits we sent (BLE writes during WAITING_ACK survive). OSD delivery uses MAC-layer feedback from `esp_now_register_send_cb` (counters in `espnow_link.h`) — if any packet in a cycle fails to deliver, `render()` is re-dispatched up to `MAX_RENDER_RETRIES` times. The `IDLE && hasDirty → requestRender` catch-up trigger picks up bits that arrived during a verify window or while ESP-NOW was down. `cancelRender()` drops the cycle when stale state would be rendered (UID change, OSD clear, laps reset). Owns issue #5 power-saving glue: phase-1 LCD-off (30 s idle, `markActivity()` resets on button press or OSD-text dirty), phase-2-redux runtime tuning (`setCpuFrequencyMhz(80)`, BLE/WiFi TX power), phase-3 deep sleep (`g_sleep_timeout_ms` from NVS-backed `slpmin`, ext1 wake on BtnA/BtnB; gate also guards on `g_sniff_active` and pending `g_sleep_minutes_changed`), and the per-30-s power-log append (sentinel-marks VBAT readings outside [2500, 4400] mV). The sleep-config consumer block runs BEFORE the sleep gate so an iOS write at the idle threshold is never lost.

## Conventions

- Firmware: C++ headers in include/, single source in src/
- iOS: @MainActor + @Observable (not ObservableObject), @Environment for DI
- BLE callbacks stage paired state under `g_ble_mux` (UID staging, lap frame); idempotent single-flag commands use bare `volatile`. See `ble_service.h` shared-state docstring. Heavy work (NVS, ESP-NOW reinit) runs in main loop, not in callbacks.
- `CBCentralManager` delegate queue MUST be main (`queue: nil`). `BluetoothManager` is `@MainActor`; `recordError` runtime-asserts main-actor isolation.
- NVS namespace: "hdzero"; keys: `"uid"` (6 bytes) + `"init"` (sentinel for torn-save detection). Save order is remove sentinel → write uid → write sentinel; loadUid warns but still returns a present uid when the sentinel is absent (fail-soft — dropping a valid UID on every torn save would be worse than a log line).
- Unicast MAC invariant: `uid[0] & 0x01 == 0` at every assignment site
- `M5.BtnA/B.wasPressed()` is non-consuming (pure read of a latched edge), so multiple consumers observe the same press in one tick — current pattern: `markActivity()` (LCD wake / phase 1 idle reset) reads the edge, and the same `wasPressed()` derives a `silenceReq` flag passed into `batteryMonitor.tick(now, silenceReq)` (alarm silence; `tick()` no-ops the silence when tier==None or already silenced). Don't add a "consume" wrapper — the multi-observer model is the design.

## Hardware

- Target / current: M5StickS3 (ESP32-S3, 1.14" LCD, 2 buttons, AXP2101 PMIC)
- Goggle: HDZero with ELRS backpack
- Buttons: BtnA + BtnB are multi-purpose — wake the LCD panel from phase-1 idle sleep, silence the battery low/critical alarm (sticky message stays; tier escalation re-arms beeps), and wake the device from phase-3 deep sleep via ext1 (GPIO11 / GPIO12, both RTC-capable on ESP32-S3). Each consumer reads `wasPressed()` independently — the model is multi-observer per the convention above.
