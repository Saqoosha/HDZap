# browser-firmware-flasher Specification

## Purpose

Let a user with no toolchain installed flash the M5StickS3 directly from a web page using the Web Serial API and esptool-js, with clear error messaging when their browser, cable, or device state isn't ready.

## Requirements

### Requirement: M5StickS3-only target / M5StickS3 のみ対応

The flasher SHALL declare M5StickS3 as the only supported target. Other ESP32-S3 boards (DevKitC, XIAO, AtomS3, etc.) MAY accept the flash but will not work correctly because HDZap's LCD, PMIC, buttons, and speaker wiring assume the M5StickS3 hardware.

The supported-device section SHALL show a product photo and explain the wiring-incompatibility risk so users don't waste time on incompatible hardware.

#### Scenario: User with a non-M5StickS3 board
- Given the user has an AtomS3
- When they read the supported-device section
- Then they see "M5StickS3 only" with a meta-text explanation that other ESP32-S3 boards will accept the flash but won't work correctly
- And they don't proceed to flash

### Requirement: Web Serial API gate / Web Serial API ゲート

The page SHALL detect Web Serial API support and, when unsupported, hide the install controls and show an "unsupported browser" callout naming the supported browsers (Google Chrome, Microsoft Edge, Brave, Opera, Vivaldi, Arc) and platforms (macOS, Windows). It SHALL explicitly call out Safari, Firefox, and all iOS browsers as unsupported.

The detection MUST happen before the user can click the install button — the install attempt would fail anyway, but a pre-check produces a more actionable error.

Web Serial は iOS/Safari/Firefox では恒久的にサポートされていない (Mozilla / Apple は意図的に実装しない方針)。一時的な制約ではなくブラウザ採用判定なので、明示的に拒否する。

#### Scenario: Open in Safari
- Given the page is opened in Safari
- When the page evaluates Web Serial support
- Then the install section is hidden
- And the "browser is not supported" section is shown with browser/platform guidance

### Requirement: Manifest schema / Manifest スキーマ

The flasher SHALL load a `manifest.json` co-located at `./manifest.json`. The manifest SHALL contain at least:

- `version: string` — `<branch>-<short sha>` stamped by CI per `dual-branch-deployment`.

Future additions MUST be optional / forward-compatible. The displayed version SHALL match the firmware bundle being served from the same `firmware/` directory.

`develop` 側で開発中の version は `manifest.json` の `version` 値で見分けられる。staging 確認のときに `dev-<sha>` が表示されるか確認する目視チェックの根拠。

#### Scenario: Production page version
- Given the page is served at `/flash/manifest.json` (main side)
- When the page loads
- Then the version display shows `main-<sha>` matching the deployed firmware

### Requirement: Firmware artifact set / ファームウェア成果物セット

The flasher SHALL flash exactly four binaries from `./firmware/`:

- `bootloader.bin` (ESP32-S3 second-stage bootloader)
- `partitions.bin` (partition table)
- `boot_app0.bin` (boot app selector, sourced from PlatformIO's Arduino-ESP32 framework)
- `hdzap.bin` (the application binary)

The names SHALL be stable so the manifest and the flasher script can reference them without per-build path lookup. CI's pages-staging step (per `dual-branch-deployment`) renames PlatformIO's `firmware.bin` to `hdzap.bin`.

#### Scenario: All four binaries present
- Given the CI staged `bootloader.bin`, `partitions.bin`, `boot_app0.bin`, `hdzap.bin` into `docs/flash/firmware/`
- When the user installs
- Then esptool-js writes all four to their canonical offsets

### Requirement: Erase-everything opt-in / 全消去オプトイン

The flasher SHALL expose an "Erase everything" checkbox, default unchecked. When unchecked, the flash preserves user state (saved UID, pairing data, sleep settings) by writing only the application partitions. When checked, the entire flash is erased, including NVS.

The UI text SHALL warn that erase wipes saved UID, pairing data, and sleep settings, and SHALL note "Usually leave this unchecked".

#### Scenario: Default flash preserves NVS
- Given the user clicks "Connect & flash" with the checkbox unchecked
- When the flasher writes the four binaries
- Then NVS-stored UID and `slpmin` survive the flash
- And the user does not need to re-bind on first boot

#### Scenario: Erase-everything wipes NVS
- Given the user checks "Erase everything" and flashes
- When flashing completes
- Then on first boot `loadUid` returns false (no UID saved)
- And the firmware falls back to the station MAC

### Requirement: Flash mode entry instructions / フラッシュモード突入手順

The page SHALL document the M5StickS3-specific flash-mode entry: hold the power button (the small one on the left side) for 2 seconds. The green LED starts blinking when flash mode is active.

The instructions SHALL also call out:

- USB-C *data* cable required (charge-only cables won't be detected).
- Port name patterns: `cu.usbmodem...` on macOS, `COMx` on Windows.
- Flash takes 30-90 s.
- After completion, press the power button once to boot HDZap.

#### Scenario: User with a charge-only cable
- Given the M5StickS3 is connected via a charge-only cable
- When the user clicks "Connect & flash"
- Then the browser port picker shows no M5StickS3
- And the troubleshooting section explains the cable type difference

### Requirement: Progress + done + error states / プログレス・完了・エラーの 3 状態

The page SHALL render four state sections, mutually exclusive:

- `state-idle` — pre-flash form (instructions + erase checkbox + Connect & flash button + version).
- `state-working` — progress bar with percentage + status message + a "don't unplug" warning.
- `state-done` — success indicator + boot instructions + a callout for auto-restart-failed cases.
- `state-error` — error indicator + message + hint + Retry button.

Only one section SHALL be visible at a time. The Retry button SHALL transition `state-error → state-idle` so the user can correct and try again. The "Flash again" button on `state-done` SHALL also return to `state-idle`.

`aria-live` attributes SHALL be set: `polite` on working/done, `assertive` on error, so screen readers announce state changes.

#### Scenario: Flash succeeds and reboots
- Given a successful flash
- When esptool-js triggers the auto-reset and the device boots
- Then `state-done` shows
- And the "auto-restart may have failed" callout is hidden (auto-reset succeeded)

#### Scenario: Auto-reset fails post-flash
- Given the flash succeeded but the auto-reset didn't take
- When the flasher detects the failure
- Then `state-done` shows with the auto-restart-failed callout visible
- And the user is told to reseat USB-C and press the power button

### Requirement: Troubleshooting section / トラブルシューティングセクション

The page SHALL include a troubleshooting section covering at minimum:

- Device doesn't appear in port picker (cable / flash mode / Windows driver).
- "Couldn't connect to the bootloader" (flash mode confirmation).
- "Couldn't open the serial port" (other process holding the port).
- Browser refuses to connect (Chromium-only + https/localhost).
- Power button doesn't boot post-flash (battery level / USB still connected).

These are the failure modes seen in production support; the section keeps users from filing issues for known causes.

#### Scenario: Port not visible on Windows
- Given a first-time Windows user
- When they don't see the M5StickS3 in the port picker
- Then they read troubleshooting bullet 1 ("drivers may take a few seconds to install on first connect") and retry

### Requirement: Bilingual page / バイリンガルページ

The flasher SHALL be available in English (`/flash/`) and Japanese (`/flash/ja/` — composed by CI from `docs/flash/ja/`). Both versions SHALL describe the same workflow with parity of error messaging. A language switcher at the top of the page SHALL link between them.

#### Scenario: Japanese user clicks language switch
- Given the user is on `/flash/`
- When they click the 日本語 link
- Then the page navigates to `/flash/ja/` with equivalent content
