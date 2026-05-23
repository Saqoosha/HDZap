# App Store Screenshot Capture

How to regenerate the App Store listing screenshots from the iOS Simulator
when a release ships visible UI changes. The seed code that drives this
lives in `app/HDZap/Models/{LapTimer,BluetoothManager,RaceHistoryStore}.swift`
and `app/HDZap/Views/TimerView.swift`, all behind `#if DEBUG`, so a Release
build never sees the path.

## When to refresh

Apple expects screenshots to reflect the current shipping UI. Refresh
before every submission that touches any visible TimerView / HistoryView
element — readout sizing, control layout, button labels, telemetry strip,
colors, fonts. A bug-fix release with zero UI deltas can reuse the prior
screenshots.

## Target

App Store Connect display type **`APP_IPHONE_67`** = **1290 × 2796 px**
(6.7" iPhone class — iPhone 14 Pro Max / 15 Pro Max / 15 Plus / 16 Plus
all match). The `iPhone 16 Plus` simulator outputs exactly 1290 × 2796.

Three screenshots per locale (en-US + ja):

| Order | Filename | Source |
|---|---|---|
| 1 | `01-timer-<locale>.png` | Live timer mid-race (seeded) |
| 2 | `02-history-<locale>.png` | History sheet with 5 prior races (seeded) |
| 3 | `03-composite-<locale>.png` | 3-panel marketing collage (manual recompose) |

UI labels in this app aren't localized — en/ja screenshots are identical
pixel-for-pixel unless TimerView gains real localized strings. Either
upload the same PNG twice or capture once and reuse.

## Tooling

- Xcode + iOS Simulator (any version that includes iPhone 16 Plus)
- `xcrun simctl` for boot / install / launch / screenshot / status-bar override
- App Store Connect API key in `~/.appstoreconnect/private_keys/AuthKey_<KEY>.p8`
- Python 3 with `pyjwt` and `cryptography` for the ASC upload script

## Step 1 — Boot the simulator

The simulator's iOS runtime should match (or be ≥) the version most pilots run, because iOS 26 sub-versions changed Settings card padding and section-header casing (`FORMAT` → `Format` between 26.4 and 26.5). Captures from a stale runtime look subtly different from what readers see on their own phone.

```bash
# Pick the newest iOS 26.x runtime available locally
RUNTIME=$(xcrun simctl list runtimes | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS-26-[0-9]+' | sort -t'-' -k4 -n | tail -1)
# Reuse an existing iPhone 16 Plus on that runtime, or create one
SIM=$(xcrun simctl list devices "$RUNTIME" | grep "iPhone 16 Plus" | head -1 | grep -oE '[0-9A-F-]{36}')
if [ -z "$SIM" ]; then
  SIM=$(xcrun simctl create "iPhone 16 Plus" \
        com.apple.CoreSimulator.SimDeviceType.iPhone-16-Plus "$RUNTIME")
fi
xcrun simctl boot "$SIM"
open -a Simulator
```

## Step 2 — Build for the simulator

The seed code lives under `#if DEBUG`, so use the `Debug` configuration.

```bash
cd app
xcodegen generate
xcodebuild \
  -project HDZap.xcodeproj \
  -scheme HDZap \
  -configuration Debug \
  -destination "id=$SIM" \
  -derivedDataPath build/derived \
  build
APP=build/derived/Build/Products/Debug-iphonesimulator/HDZap.app
```

## Step 3 — Status bar override (Apple convention)

```bash
xcrun simctl status_bar "$SIM" override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100
```

## Step 4 — Install + capture

The seed code is driven by two launch arguments:

- `-screenshotTimer` — pre-populates `LapTimer` with 4 laps + frozen
  elapsed, seeds `BluetoothManager` with a live flight-battery reading,
  and triggers `refreshMetricsSnapshot()` so the PACE / AVG / DIFF / NEED
  cells render mid-race instead of as `—` placeholders. First render
  shows a mid-race state with the green VBAT strip.
- `-screenshotHistory` — pre-populates `RaceHistoryStore` with 5 races
  whose totals / best-laps match the original 02-history.png shape (the
  start dates are now computed relative to `Date()`, so they always look
  recent), and auto-opens the history sheet.

For each shot:

```bash
mkdir -p /tmp/hdzap_shots/new
xcrun simctl install "$SIM" "$APP"

# 01-timer (en-US)
xcrun simctl terminate "$SIM" sh.saqoo.HDZap 2>/dev/null
xcrun simctl launch "$SIM" sh.saqoo.HDZap -screenshotTimer
sleep 3
xcrun simctl io "$SIM" screenshot /tmp/hdzap_shots/new/01-timer-en.png

# 01-timer (ja)
xcrun simctl terminate "$SIM" sh.saqoo.HDZap
xcrun simctl launch "$SIM" sh.saqoo.HDZap \
  -AppleLanguages "(ja)" -AppleLocale ja_JP -screenshotTimer
sleep 3
xcrun simctl io "$SIM" screenshot /tmp/hdzap_shots/new/01-timer-ja.png

# 02-history (en-US)
xcrun simctl terminate "$SIM" sh.saqoo.HDZap
xcrun simctl launch "$SIM" sh.saqoo.HDZap -screenshotHistory
sleep 3
xcrun simctl io "$SIM" screenshot /tmp/hdzap_shots/new/02-history-en.png

# 02-history (ja)
xcrun simctl terminate "$SIM" sh.saqoo.HDZap
xcrun simctl launch "$SIM" sh.saqoo.HDZap \
  -AppleLanguages "(ja)" -AppleLocale ja_JP -screenshotHistory
sleep 3
xcrun simctl io "$SIM" screenshot /tmp/hdzap_shots/new/02-history-ja.png
```

Verify each PNG is 1290 × 2796:

```bash
sips -g pixelWidth -g pixelHeight /tmp/hdzap_shots/new/*.png
```

## Step 5 — Tweaking the seeded data

If a new release changes the displayed shape of either screenshot
(different default session, new metric column, etc.), edit the constants
near each seed site:

- **Lap times for shot 1** — `app/HDZap/Models/LapTimer.swift` `init()`,
  the `lapTimes` and `currentLapElapsed` args. The displayed elapsed is
  `sum(lapTimes) + currentLapElapsed`; pick values so the total stays
  inside `RaceMetrics.defaultSessionLimit` and the lap count under
  `RaceMetrics.defaultTargetLapCount`. (HDZapApp also force-sets those
  two UserDefaults keys to their defaults whenever a screenshot launch
  arg is present, so any prior in-simulator tweak can't drift the
  output.)
- **Flight-battery values for shot 1** — `app/HDZap/Models/BluetoothManager.swift`
  `init()`, the `voltageDv` (deciVolts) / `consumedMah` / `remainingPercent`
  args. `currentDa` is not rendered in the strip.
- **History rows for shot 2** — `app/HDZap/Views/TimerView.swift`
  `makeScreenshotHistory()`, the `rows` array. Each tuple is
  `(lapTimes, start)`; the row caption shows `start`, and total /
  best are derived from `lapTimes`.

The seeds use the v1.0 marketing screenshots as the original baseline so
the first regeneration after a UI change still reads as "the same race,
new app version." That baseline is a moving anchor: each release that
successfully composites a fresh shot 3 becomes the next reference, and
subsequent edits to this doc should bump the version it cites.
Diverging only when the displayed columns change keeps the marketing
material visually consistent across releases.

## Step 6 — Upload to App Store Connect

Replace the screenshot sets on the PREPARE_FOR_SUBMISSION version. The
flow: delete the inherited shots, then reserve / upload / commit each new
shot via the ASC API. Composite shot 3 carries forward from v1.0 (no
visible app surface inside it has changed enough to invalidate it); if
the app surface in the composite does change, recompose externally.

API call sequence per shot:

1. `POST /v1/appScreenshots` with `fileName` + `fileSize` + relationship
   to the target `appScreenshotSet`. Response includes `uploadOperations`.
2. Issue each `uploadOperations[].method` against `uploadOperations[].url`
   with the prescribed headers and the matching byte slice.
3. `PATCH /v1/appScreenshots/{id}` with `uploaded: true` and the file's
   MD5 as `sourceFileChecksum`.

To find the right set: walk `appStoreVersions/<vid>/appStoreVersionLocalizations`
→ pick the locale → `…/appScreenshotSets` → filter
`screenshotDisplayType == "APP_IPHONE_67"`. Create the set with
`POST /v1/appScreenshotSets` if it doesn't exist.

To replay the composite shot from v1.0 without re-rendering: fetch its
binary via `imageAsset.templateUrl` (substitute `{w}x{h}{f}` → real
dimensions + `png`), then upload the result onto the v1.0.1 set using
the same flow.

## Step 7 — Composite shot 3 (manual)

Shot 3 is a 3-panel collage: top = FPV gate footage with OSD overlay,
middle = M5StickS3 device photo, bottom = cropped iOS Timer screenshot.
It is not pure simulator output — it requires the FPV video frame and
the StickS3 product photo as external assets. When a release changes the
iOS Timer enough that the bottom panel reads stale:

1. Crop the bottom panel out of the new `01-timer-en.png` (no status bar).
2. Composite over the existing FPV + StickS3 frames (Pixelmator / Affinity / etc.).
3. Export at 1290 × 2796.
4. Upload to position 3 of both locales via the same API flow.

## Gotchas

- **`-screenshotTimer` freezes the clock**. The 60 Hz timer never starts,
  so the elapsed never advances. This is deliberate: it means capture
  timing can slip a few seconds without the displayed clock moving.
- **VBAT strip stays green for an hour** in screenshot mode. The seed
  sets `lastFlightBatteryReceivedAt` an hour into the future so the
  `.live → .stale` flip threshold (`flightBatteryStaleAfter` in
  TimerView) can't catch the capture window.
- **Don't capture before `sleep 3`** after `xcrun simctl launch`. The
  process needs a moment to instantiate models and complete the first
  layout pass, and on a cold simulator boot this can be longer (give it
  6+ seconds the first time).
- **`-AppleLanguages "(ja)"` is positional** — the parens are part of the
  argument value, not the shell. Don't drop them.
- **Simulator.app does not need to be the active window.**
  `xcrun simctl io … screenshot` reads CoreSimulator's framebuffer
  directly — the `open -a Simulator` step in Step 1 is just so the
  operator can watch what's being captured. The booted device does
  need to be the booted state (the `xcrun simctl boot` step), but
  Simulator.app can be backgrounded or hidden.
- **No Release-build path**. The seed code is entirely under `#if DEBUG`;
  trying to capture screenshots from a TestFlight build will silently
  produce an empty timer view because the launch args are ignored.

## Manual / marketing screenshots (Settings panes)

The App Store screenshots above cover the headline surfaces (Timer +
History). The end-user manual at `docs/manual/{en,ja}.md` needs
Settings sub-views too — those go through a separate launch-arg path:
`-screenshotRoute <name>` (parsed in
`app/HDZap/Utils/ScreenshotMode.swift`).

Each route auto-opens the matching sub-screen on first appear:
`SettingsView.applyScreenshotRouteIfNeeded()` pushes drilldowns via
hidden `.navigationDestination(isPresented:)` flags, and
`AudioSettingsView.applyScreenshotRouteIfNeeded()` walks the rest of
the audio sub-tree (Premium voice picker / Paywall). Model layer
fakes a connected M5Stick (`BluetoothManager.seedConnectedForScreenshot()`)
and entitled Premium (`SubscriptionManager.seedEntitledForScreenshot()`)
where the route needs them.

Available routes (ScreenshotMode.swift is the authoritative list):

| Route | Surface |
|---|---|
| `settingsRoot` | Settings root (bridge ON, fake connected) |
| `settingsRootStandalone` | Settings root (bridge OFF — standalone hint visible) |
| `settingsRootBridgeOnUnconnected` | Settings root — bridge ON but not yet linked |
| `settingsRootAbout` | Settings root scrolled so the About card is in view |
| `connection` | Settings → M5StickS3 (Connection) |
| `rename` | Settings → M5StickS3 → Rename device |
| `pairing` | Settings → Goggle pairing (Bind Phrase mode pre-filled) |
| `pairingManualUID` | Goggle pairing with Manual UID mode pre-filled |
| `pairingNewPairing` | Goggle pairing with New Pairing mode |
| `pairingSuccess` | Goggle pairing with green "Pairing works" banner |
| `osdLayout` | Settings → OSD layout |
| `audio` | Settings → Lap announcer (System engine) |
| `audioCountdownOn` | Lap announcer with "Count down final seconds" toggled ON |
| `audioPremium` | Settings → Lap announcer (Premium engine, entitled) |
| `premiumVoicePicker` | Settings → Lap announcer → Premium voice (entitled) |
| `premiumVoicePickerLocked` | Same picker, non-subscriber view (Subscribers-only banner) |
| `paywall` | Premium subscribe sheet |
| `timerReady` | Main timer, pre-race READY state |
| `timerRunning` | Main timer mid-race (VBAT strip + 4 laps) |
| `timerDone` | Main timer post-race DONE state |
| `historyList` | History sheet listing past races |
| `historyDetail` | History sheet drilled into a specific race detail (with VBAT chart) |

Capture loop (run from `app/`):

```bash
SIM=$(xcrun simctl list devices available | grep "iPhone 16 Plus" | head -1 | grep -oE '[0-9A-F-]{36}')
APP=build/derived/Build/Products/Debug-iphonesimulator/HDZap.app
# Uninstall + reinstall first — UserDefaults persist across launches in the
# simulator, so a stale `ttsLanguageRaw` / `premiumLapVoiceId` from a prior
# capture session can leak through and make e.g. the JA Premium-voice
# screenshot pre-pick an English voice. A clean reinstall guarantees the
# route walkers see only the values they explicitly set.
xcrun simctl uninstall "$SIM" sh.saqoo.HDZap
xcrun simctl install "$SIM" "$APP"
mkdir -p /tmp/hdzap_settings_shots

for ROUTE in settingsRoot settingsRootStandalone settingsRootBridgeOnUnconnected \
             settingsRootAbout \
             connection rename \
             pairing pairingManualUID pairingNewPairing pairingSuccess \
             osdLayout \
             audio audioCountdownOn audioPremium \
             premiumVoicePicker premiumVoicePickerLocked paywall \
             timerReady timerRunning timerDone \
             historyList historyDetail; do
  for LANG in en ja; do
    xcrun simctl terminate "$SIM" sh.saqoo.HDZap 2>/dev/null
    APPLELANG=$([ "$LANG" = "ja" ] && echo "(ja)" || echo "(en)")
    APPLELOC=$([ "$LANG" = "ja" ] && echo "ja_JP" || echo "en_US")
    xcrun simctl launch "$SIM" sh.saqoo.HDZap \
      -AppleLanguages "$APPLELANG" -AppleLocale "$APPLELOC" \
      -screenshotRoute "$ROUTE" >/dev/null
    sleep 8
    xcrun simctl io "$SIM" screenshot "/tmp/hdzap_settings_shots/${ROUTE}-${LANG}.png"
  done
done

# Crop each multi-section settings screenshot into per-iOS-section PNGs and
# downscale full-screen ones. The script auto-detects the iOS section card
# boundaries (gray-band gaps between white cards) and writes the cropped
# pieces to /tmp/hdzap_crops/.
python3 scripts/crop_settings_screenshots.py
# (then rename + copy /tmp/hdzap_crops/* into docs/manual/images/)
```

The DEBUG-only `Debug` section in SettingsView and the DEBUG-only
`Premium TTS (Debug)` section in AudioSettingsView both auto-hide when
`ScreenshotMode.isActive` is true, so captures don't leak dev panels
into the published manual.

Persisted-state caveat: simulator `UserDefaults` survive across
launches. The route walkers explicitly reset the bridge state, TTS
engine, and Premium voice ID on each capture so a `.audioPremium`
followed by a plain `.audio` doesn't render the premium controls in
both shots. If you add a new route that toggles persisted state, do
the symmetric reset in the route handler.

Sleep tuning: the capture loop above waits 8 s after `xcrun simctl
launch` before grabbing the framebuffer. iOS 26.5's Settings sheet
takes longer to settle than 26.4 — a shorter sleep produces captures
mid-sheet-animation with the underlying `TimerView` partly visible
at the top, which then confuses the section detector in
`crop_settings_screenshots.py` (it sees masthead row blocks as
unrelated cards). Don't drop below 6 s unless you've verified the
target runtime's animation timing.

Edge fade: cropped sub-section PNGs get a linear fade to white at
the top and bottom (see `FADE_PX` in `apply_edge_fade` /
`crop_with_header` in the crop script — currently 80 px) so the
horizontal mid-screen cut blends into the white manual page rather
than ending with a hard iOS-gutter-to-white band. The crop is
deliberately extended *beyond* the detected section by the same
FADE_PX so the gradient lives outside the section content — the
section header + card body stay fully visible. Full-screen captures
(timer / history / picker / paywall) skip the fade because they're
complete iPhone surfaces — the status bar at top and home indicator
at bottom are part of what the user actually sees, not something to
soften away.

## When the seed-based approach isn't enough

If a future release adds UI surfaces that need their own screenshot
(Settings panes, race-detail view, share card preview, etc.), extend the
seed by adding a new launch-arg branch in
`seedScreenshotIfNeeded` and a corresponding model setup. Keep the
arg names `-screenshot<Capitalized>` so they sort alphabetically with
the existing ones. For new Settings sub-screens that need auto-open
behavior, prefer the `-screenshotRoute` mechanism above — add the new
case to `ScreenshotRoute` and the corresponding nav handler.
