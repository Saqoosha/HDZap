# HDZap User Manual

<p align="center">
  <img src="images/app-icon-squircle.png" alt="HDZap" width="120" border="0" style="border:0" />
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6766197336">
    <img src="https://toolbox.marketingtools.apple.com/api/badges/download-on-the-app-store/black/en-us?size=250x83" alt="Download HDZap on the App Store" height="40" />
  </a>
</p>

<p align="center">
  <strong>English</strong> ・ <a href="https://saqoosha.github.io/HDZap/ja/">日本語</a>
</p>

> **Need help?** Email [a@saqoo.sh](mailto:a@saqoo.sh) or open an issue on [GitHub Issues](https://github.com/Saqoosha/HDZap/issues). Common problems are covered in [§12 Troubleshooting](#12-troubleshooting) below.

---

## Table of Contents

1. [What is this?](#1-what-is-this)
2. [What you'll need](#2-what-youll-need)
3. [Flashing firmware to the M5StickS3](#3-flashing-firmware-to-the-m5sticks3)
4. [Installing the iPhone app](#4-installing-the-iphone-app)
5. [Pairing the M5StickS3 with the iPhone (Bluetooth)](#5-pairing-the-m5sticks3-with-the-iphone-bluetooth)
6. [Binding to the Digital FPV Goggle](#6-binding-to-the-digital-fpv-goggle)
7. [Flight battery telemetry](#7-flight-battery-telemetry)
8. [Running a race](#8-running-a-race)
9. [After the race](#9-after-the-race)
10. [Premium voices (subscription)](#10-premium-voices-subscription)
11. [Settings reference](#11-settings-reference)
12. [Troubleshooting](#12-troubleshooting)
13. [Appendix](#13-appendix)

---

## 1. What is this?

<p align="center">
  <iframe src="https://www.youtube.com/embed/FXDKoBYkyB4"
          title="HDZap demo"
          width="640"
          height="480"
          style="max-width: 100%; aspect-ratio: 4 / 3; height: auto; border: 0;"
          frameborder="0"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
          allowfullscreen></iframe>
</p>

HDZap is a system that **shows lap times measured on an iPhone on the OSD of a Digital FPV Goggle**. It assumes a **two-person setup**: a pilot and a separate spotter who runs the timer.

```mermaid
flowchart LR
    A["iPhone<br/>HDZap App<br/><i>Spotter</i>"] -- Bluetooth --> B["M5StickS3<br/><i>Bridge</i>"]
    B -- ESP-NOW --> C["Digital FPV Goggle<br/><i>Pilot</i>"]
```

The system has three components:

- **iPhone app**: the timer UI the spotter operates — Start / Lap / Stop / history.
- **M5StickS3**: a palm-sized ESP32 device that acts as a bridge. It receives commands from the iPhone over Bluetooth and forwards OSD commands to the Goggle over a separate radio (ESP-NOW).
- **Digital FPV Goggle**: the FPV goggle the pilot wears. Its built-in ELRS Backpack receives OSD commands and overlays the lap times on the video.

> 💡 **The iPhone app works standalone too.** Lap timing, lap history, and voice announcements all work in-app without any extra hardware. Adding the M5StickS3 and Goggle just makes the lap times also appear on the Goggle's OSD.

### Glossary at a glance

These terms come up throughout the manual. Full definitions are in the [Appendix](#13-appendix).

| Term | One-line description |
|---|---|
| **Goggle** | FPV goggle the pilot wears. Supports Digital FPV Goggle / Digital FPV Goggle 2 |
| **ELRS Backpack** | ESP32 module built into the Goggle. Receives OSD commands |
| **UID** | 6-byte identifier. The Goggle and the M5StickS3 must share the same UID to communicate |
| **bind phrase** | A string that derives the UID. The same phrase always produces the same UID on any device |
| **OSD** | On-Screen Display. Text overlaid on the video |

---

## 2. What you'll need

### Hardware

- **M5StickS3** ×1 (the bridge)

  <img src="images/m5sticks3.jpg" alt="M5StickS3" width="240" />

- **USB-C data cable** ×1
  - **Charge-only cables won't work.** You need a cable that carries data.
- **Digital FPV Goggle** (Digital FPV Goggle / Digital FPV Goggle 2)
- **iPhone** (iOS 18 or later)

### Software

- **Google Chrome**
  - The Web Flasher uses the Web Serial API, so **Safari and Firefox will not work.** Other Chromium-based browsers (Edge, Brave, etc.) also support Web Serial and should work in theory, but are untested.
- Tested environment: **macOS 26.4 + Chrome** only.

### Required: Goggle backpack firmware v1.5.5 or newer

> ⚠️ **The Digital FPV Goggle's ELRS Backpack firmware must be v1.5.5 or newer.**
>
> Older versions silently drop or mis-render some of the OSD commands HDZap sends.

#### Checking the version

Open the Goggle menu → **ELRS** to read the current backpack firmware version.

#### Updating

Use the ExpressLRS Configurator to flash a newer firmware to the ELRS Backpack. HDZap can't update the Goggle side itself.

- ExpressLRS Configurator: https://github.com/ExpressLRS/ExpressLRS-Configurator/releases

![ExpressLRS Configurator](images/02-elrs-configurator.png)

> 💡 **Most "nothing shows on the goggle" problems are stale firmware.** When something goes wrong in Chapter 6, suspect the firmware version first.

---

## 3. Flashing firmware to the M5StickS3

This step uses the **Web Flasher** — a tool that runs entirely in your browser.

### Steps

1. Open the URL below in **Chrome**:
   👉 https://saqoosha.github.io/HDZap/flash/

2. Plug the **M5StickS3** into your computer with a USB-C data cable.

3. Click **Connect** in the browser. A serial-port picker appears — choose the port whose name starts with something like `USB JTAG/serial debug unit` or `USB Serial`. In most cases esptool will put the M5StickS3 into bootloader mode automatically and start flashing.

4. **If it can't connect — enter DFU mode manually:**
   If the browser hangs on `Connecting to bootloader…` or shows an error, **press and hold the small power button on the left side of the M5StickS3 for about 2 seconds**. The green LED starts blinking — that's DFU mode. Click **Connect** again.

5. The **"Erase everything"** checkbox:
   - **First-time flash: leave it checked.** This wipes the M5StickS3's flash memory before writing.
   - **Updating an existing install: uncheck it.** This preserves the UID stored in NVS (the Goggle pairing).

6. Click **Write**. The progress bar runs for about 30 seconds to a minute.

7. **When the flash finishes**, press the **small power button on the left side of the M5StickS3 once** to reboot. If the LCD lights up with a status display, you're done.

   ![M5StickS3 after flashing](images/03-flasher-done.jpg)

### When things go wrong

- **`ESP_TOO_MUCH_DATA` error:** Update Chrome to the latest version.
- **Port doesn't appear / can't be selected:** Try a different cable (it might be charge-only). Still no luck → enter DFU mode manually (hold power button 2 seconds) and click Connect again.
- **Allow dialog never appears:** Close the browser and reopen the URL.

---

## 4. Installing the iPhone app

HDZap is available on the App Store.

<p align="center">
  <a href="https://apps.apple.com/app/id6766197336">
    <img src="https://toolbox.marketingtools.apple.com/api/badges/download-on-the-app-store/black/en-us?size=250x83" alt="Download HDZap on the App Store" height="60" />
  </a>
</p>

1. On your iPhone, open the App Store link above and tap **Get** to install HDZap.
2. Tap the HDZap icon on your home screen to launch the app.

3. On first launch, iOS asks you to **allow Bluetooth access** — tap **Allow**. If you decline, the app can't talk to the M5StickS3.

   <p align="center">
     <img src="images/04-bluetooth-permission.png" alt="Bluetooth permission dialog" width="320" />
   </p>

---

## 5. Pairing the M5StickS3 with the iPhone (Bluetooth)

Connect the iPhone to the M5StickS3 over Bluetooth.

### Steps

1. Power on the M5StickS3 (the LCD should be lit).
2. Open the HDZap app on the iPhone, then tap the **gear icon (⚙️)** in the top right to open the Settings sheet.

   <p align="center">
     <img src="images/timer-masthead.png" alt="Top of the timer screen — gear icon on the right" width="360" />
     <br />
     <em>Top of the timer screen — tap the gear icon on the right</em>
   </p>

3. Under the **Device** section, flip on **Use bridge** if it isn't already. On a fresh install the toggle is off and the **M5StickS3**, **Goggle pairing**, and **OSD layout** rows stay hidden until you turn it on; iOS also asks for Bluetooth permission the first time you flip it on.

   <p align="center">
     <img src="images/settings-device-standalone.png" alt="Bridge OFF — drilldowns hidden" width="360" />
     <br />
     <em>Before: bridge OFF on a fresh install</em>
   </p>

4. With the toggle on, three rows appear: **M5StickS3** / **Goggle pairing** / **OSD layout**. Tap **M5StickS3** to drill into the connection screen.

   <p align="center">
     <img src="images/settings-device-bridgeon.png" alt="Bridge just turned on — M5StickS3 not connected, Goggle pairing not set" width="360" />
     <br />
     <em>Right after enabling — M5StickS3 reads <strong>Not connected</strong>, Goggle pairing reads <strong>—</strong>. Tap M5StickS3 to open the connection screen.</em>
   </p>

5. Tap **Scan**. Nearby M5StickS3 devices appear under **Other devices**.

   <p align="center">
     <img src="images/connection-other-devices.png" alt="Other devices card (empty before scan)" width="360" />
     <br />
     <img src="images/connection-scan.png" alt="Scan button" width="360" />
   </p>

6. Tap **Connect** next to the device named **HDZapBridge** (or whatever name you previously gave it — see [Renaming the M5StickS3](#renaming-the-m5sticks3-optional) below).

7. On a successful connection:
   - A green dot appears in the **Connected** section with the device name and a Disconnect button
   - The battery percentage, charging icon, and a **Version** row (app + firmware) appear below the name
   - The M5StickS3's LCD also shows the connected state

   <p align="center">
     <img src="images/connection-connected.png" alt="Connected card after a successful link" width="360" />
   </p>

You now have a working link between the iPhone and the M5StickS3. Next: bind to the Goggle.

### Renaming the M5StickS3 (optional)

If you have several M5StickS3 units, the default `HDZapBridge` name makes them hard to tell apart. While connected:

1. Settings → **Device** → **M5StickS3**.
2. Tap **Bluetooth name**.

   <p align="center">
     <img src="images/rename.png" alt="Rename device screen" width="360" />
   </p>

3. Type the new name (UTF-8, up to 20 bytes — most emoji count as 4+ bytes, ZWJ-joined or flag-pair emoji more) and tap **Save**.
4. The M5StickS3 reboots once (about 3 seconds). The iPhone reconnects automatically; the new name appears on the M5StickS3's LCD UID band and in the iOS connected section.

> 💡 The new name is persisted to flash memory, so it survives power cycles. To restore the default, save `HDZapBridge`.

### When things go wrong

- **Nothing shows up in the device list:** Open iOS Settings → HDZap → make sure Bluetooth permission is on. Power-cycle the M5StickS3.
- **Tapping Connect doesn't connect:** Open iOS Settings → Bluetooth, "Forget" HDZap if it's listed, and try again.

---

## 6. Binding to the Digital FPV Goggle

Every bind path below starts from the same place: **Settings (⚙) → Device → Goggle pairing** (the sub-screen is titled **Pairing**). The smoke test for any path is **Settings → Device → OSD layout** — opening it auto-pushes a preview to the Goggle.

<p align="center">
  <img src="images/settings-device.png" alt="Device section — Goggle pairing row" width="360" />
  <br />
  <em>All bind paths start here — tap the <strong>Goggle pairing</strong> row</em>
</p>

### Prerequisite

> ⚠️ Confirm the Goggle's ELRS Backpack firmware is **v1.5.5 or newer**. See [Chapter 2](#required-goggle-backpack-firmware-v155-or-newer).

### Why bind?

For the M5StickS3 to push OSD commands to the Goggle, **both must share the same UID (a 6-byte identifier)**. The work of matching them is called "binding".

### Decision flowchart: which path is yours?

```mermaid
flowchart TD
    A[Bind phrase set on the<br/>ELRS Backpack firmware?] -- Yes --> B[6.4 Use a known<br/>bind phrase]
    A -- No --> C[Have you ever bound the<br/>radio to the Goggle?]
    C -- Yes --> D[6.2 TX UID Capture]
    C -- No --> E[6.1 New Pairing]
```

> 📝 **6.3 Manual UID** is also listed below, but **the current official Goggle firmware has a bug** that effectively prevents reading the UID from the Goggle menu. That path isn't in the flowchart above. Only people who can work around the bug should use [6.3](#63-manual-uid-advanced).

### Bind phrase vs UID

- **bind phrase**: a human-readable string you choose (e.g. `my-race-2026`).
- **UID**: a 6-byte number (e.g. `123,45,67,89,0,12`).

The first 6 bytes of the MD5 hash of the bind phrase become the UID. **The same bind phrase always produces the same UID on any device.**

---

### 6.1 New Pairing

**For:** brand-new Goggles, or people who want to start from a clean slate with just the M5StickS3 and the Goggle.

> ⚠️ **This overwrites the Goggle's existing binding.** Any prior radio↔Goggle pairing is lost (you'd have to bind the radio again afterwards).

#### Steps

1. **Put the Goggle into bind mode:**
   1. Open the Goggle menu → **ELRS**
   2. Set **Backpack** to **On**
   3. Select **Bind** → **Click to start**
   4. The Goggle is now waiting for a bind broadcast.
2. App Settings sheet → **Device** → **Goggle pairing**.
3. Set the segmented control to **New Pairing**.

   <p align="center">
     <img src="images/pairing-configure-new-pairing.png" alt="Pairing — New Pairing mode" width="360" />
   </p>

4. Tap **Pair with new goggle**. The M5StickS3 broadcasts a bind packet.
5. The Goggle accepts and the binding is complete.
6. The status banner should step through `Verifying…` → `Pairing works`.
7. **Smoke test:** Settings → **Device** → **OSD layout** — the page auto-pushes a live preview to the Goggle. Anything visible there means it worked.

---

### 6.2 TX UID Capture (Goggle already bound to a radio)

**For:** people who have already bound the Goggle to a radio (transmitter), have the radio at hand, and never set a bind phrase explicitly (or didn't write it down).

> ✅ This path **does not break the existing radio↔Goggle binding.** The M5StickS3 is a passive listener: it sniffs the bind broadcast over ESP-NOW and just extracts the UID.

#### Steps

1. Power on the Goggle and confirm it's actually bound to the radio. **Video showing up by itself isn't proof** — that's the VTX side. The real check is: change the VTX channel from EdgeTX's ExpressLRS Lua script and see whether the Goggle picks up the change.
2. App Settings sheet → **Device** → **Goggle pairing**. Scroll down to the **TX UID Capture** section.
3. Tap **Start TX UID Capture**. The M5StickS3 starts listening for ESP-NOW broadcasts.

   <p align="center">
     <img src="images/pairing-tx-uid-capture.png" alt="Pairing — TX UID Capture card" width="360" />
   </p>

4. **Open the ExpressLRS Lua script on EdgeTX and run the Bind menu** from there.
5. The M5StickS3 receives the bind broadcast, extracts the UID, and shows it on screen.
6. Tap **Apply** → `Switching pairing…` → `Verifying…` → `Pairing works`.
7. **Smoke test:** Settings → **Device** → **OSD layout** — the page auto-pushes a live preview to the Goggle. If you see it, you're good.

---

### 6.3 Manual UID (advanced)

> ⚠️ **Heads up:** the current official Goggle firmware has a bug that effectively prevents reading the UID from the Goggle menu. **This path is not usable for most people right now.** It's documented here so it's ready when the firmware is fixed.

**Steps in theory:**

1. On the Goggle, open **Menu → ELRS**. The `Bind` row shows `UID: xxx,xxx,xxx,xxx,xxx,xxx` — six numbers.
2. App Settings sheet → **Device** → **Goggle pairing**.
3. Set the segmented control to **Manual UID**.

   <p align="center">
     <img src="images/pairing-configure-manual-uid.png" alt="Pairing — Manual UID mode" width="360" />
   </p>

4. **Type all six numbers, comma-separated, into the single input field.** The `Parsed:` line below echoes the hex form so you can compare against what the goggle showed.
5. Tap **Apply UID** → `Switching pairing…` → `Verifying…` → `Pairing works`.
6. **Smoke test:** Settings → **Device** → **OSD layout** — the page auto-pushes a live preview to the Goggle. Anything visible there means it worked.

---

### 6.4 Use a known bind phrase

**For:** people who have flashed **both** the **TX backpack** and the **Goggle's ELRS Backpack** with firmware that has the same bind phrase baked in via ExpressLRS Configurator, and remember (or have written down) that phrase.

#### Steps

1. App Settings sheet → **Device** → **Goggle pairing**.
2. Set the segmented control to **Bind Phrase**.

   <p align="center">
     <img src="images/pairing-configure-bind-phrase.png" alt="Pairing — Bind Phrase mode" width="360" />
   </p>

3. Type the same bind phrase that was flashed onto the ELRS Backpack into the text field. The `UID:` line below echoes the derived UID (the MD5-derived hex form) so you can sanity-check it before applying.
4. Tap **Apply UID**.
5. Wait for the status banner to step through `Switching pairing…` → `Verifying…` → `Pairing works` 🎉

   <p align="center">
     <img src="images/pairing-success-banner.png" alt="Green 'Pairing works' success banner — common to all four bind paths" width="360" />
     <br />
     <em>Success looks like this — common to all four bind paths</em>
   </p>

6. **Smoke test:** Settings → **Device** → **OSD layout** — opening the screen auto-pushes a live preview to the Goggle. If you see it, the bind worked 🎉

---

### Verifying the bind

Once the bind reports success, the simplest smoke test is just opening **Settings → Device → OSD layout**.

<p align="center">
  <img src="images/osd-preview.png" alt="OSD layout preview — the same 4 rows are auto-pushed to the goggle on entry" width="360" />
</p>

The screen auto-pushes a live preview (4 rows of dummy text reflecting your current layout) to the Goggle on entry. **If you see the same 4 rows on the Goggle's OSD that you see in the iPhone's preview area above, the entire path (iPhone → M5StickS3 → Goggle) is working 🎉**

If nothing appears on the Goggle, re-walk [Chapter 6's flowchart](#decision-flowchart-which-path-is-yours) from the top.

> 💡 The **Send Test OSD** button on the same screen pushes the **current iPhone time** once — useful when you want a fresh, visibly-changing reference point (each tap updates the timestamp). It doesn't auto-clear, so tap **Clear OSD** next to it when you're done.

### Auto-rollback

If something fails part-way through a bind (the Goggle doesn't ack verification, etc.), HDZap **automatically reverts to the previous UID**, and the banner reads "Goggle didn't accept the new pairing. Restored the previous one."

You can also tap **Restore previous goggle** on the Goggle pairing screen at any time to roll back manually.

### When things go wrong

- **No OSD appears on the Goggle (opening OSD layout, or tapping Send Test OSD)**
  1. Re-check the Goggle backpack firmware version is v1.5.5 or newer — most common cause.
  2. Is the Goggle close enough? Within a few meters is recommended.
  3. Tap Apply UID one more time.
  4. Try a different bind path (6.1 / 6.2 / 6.4).
- **Stuck on `Verifying…`:** It auto-rolls back after about 30 seconds. Re-check the Goggle is powered on and on the right firmware, then start over.

---

## 7. Flight battery telemetry

When the M5StickS3 is receiving CRSF Battery telemetry from the pilot's transmitter, HDZap shows live battery data on the **main timer screen** and records it for post-race review.

### Live VBAT strip (main screen)

<p align="center">
  <img src="images/timer-running.png" alt="Main timer with the green VBAT strip above the progress bar" width="360" />
</p>

A strip appears above the session progress bar showing:

- **Status dot**: green = live data arriving, amber = signal gone stale (TX powered off, out of range, or telemetry disabled on the TX), hidden = no data yet
- **Voltage** (V)
- **Consumed mAh**
- **Remaining %** + progress bar (hidden when the transmitter reports the value as unknown)

The strip disappears entirely when no telemetry has arrived since the device last connected — it never shows a placeholder.

### Post-race (history detail screen)

<p align="center">
  <img src="images/history-detail.png" alt="History detail with VBAT voltage trend chart" width="360" />
</p>

After the race, opening the detail from the history list shows a **VBAT** section with:

- **Start / Min / End** voltage labels and sample count
- Voltage trend chart over race time with lap-boundary markers

The share card image also includes the VBAT chart when samples are present. To export the raw data (voltage, current, consumed mAh, remaining %) as a CSV, tap the **battery icon** in the top-right toolbar of the detail screen.

### Requirements for VBAT data

All three of the following must be in place:

1. **ELRS Backpack telemetry enabled** on the transmitter: in the ExpressLRS Lua script on EdgeTX, go to **Backpack → Telemetry** and set it to **ESPNOW**.
2. **TX and Goggle are paired** — the TX's bind broadcast is how HDZap learns the TX's identity.
3. **TX UID Capture has been performed at least once** (the [6.2 TX UID Capture](#62-tx-uid-capture-goggle-already-bound-to-a-radio) path). This captures the TX's sender MAC and saves it to the M5StickS3's flash. Once saved it survives reboots — you only need to repeat it if you erase the M5StickS3's flash ("Erase everything" in the Web Flasher).

> ⚠️ Binding via [new pairing (6.1)](#61-new-pairing) or [bind phrase (6.4)](#64-use-a-known-bind-phrase) does **not** set the TX sender filter. If you used one of those paths, run TX UID Capture once (while keeping your existing goggle pairing) to enable flight battery recording.

---

## 8. Running a race

With the bind working, you can run a race.

### Race setup

1. Tap the gear icon at the top right → open the Settings sheet.
2. Adjust **Race time** (default 90 s) and **Target lap** in the **Format** section at the top.

   <p align="center">
     <img src="images/settings-format.png" alt="Format section — Race time / Target lap / Target pace" width="360" />
   </p>

3. Close the Settings sheet.

### Running

<p align="center">
  <img src="images/timer-ready.png" alt="Pre-race READY state — empty laps, large START button" width="360" />
  <br />
  <em>Pre-race READY state — tap START to begin</em>
</p>

1. Tap the **START** button on the main screen. The timer starts.
2. Tap the **LAP** button each time the pilot crosses the finish line.

   <p align="center">
     <img src="images/timer-running.png" alt="Mid-race — LAP button, lap table populating, VBAT strip" width="360" />
     <br />
     <em>Mid-race — 4 laps recorded, current lap in flight, VBAT strip live</em>
   </p>

3. When the race time is up (default 90 s), the button label switches to **`FINAL`**. **You must tap `FINAL` to record the last lap and end the race** — it does not end automatically.
4. To bail out partway, tap **STOP**.

### After the race ends

<p align="center">
  <img src="images/timer-done.png" alt="Post-race DONE state — RESET / DONE / SHARE buttons" width="360" />
  <br />
  <em>Post-race DONE state — results visible, share enabled</em>
</p>

When the race ends (FINAL lap recorded or STOP after at least one lap):

- The button label switches to **DONE** (disabled) and **RESET** + **SHARE** appear on either side.
- The race is automatically saved to history.
- The masthead state pill reads **DONE** and the best lap is highlighted in the per-lap table.
- Tap **SHARE** to render a result card image and open the iOS share sheet (see [§9 After the race](#9-after-the-race)).
- Tap **RESET** to clear the screen for the next race.

### What's on the Goggle's OSD

During the race, the Goggle shows up to a 4-line overlay along the bottom (**Settings → Device → OSD layout** lets you hide individual rows and tweak alignment / vertical position). Each visible line defaults to centered within the 50-column OSD grid.

**Pre-race (READY):**

<pre style="text-align: center;"><code>READY
RACE 90
5LAPS @ 18.00</code></pre>

**During the race (per lap):**

<pre style="text-align: center;"><code>TIME LEFT 67
LAP 3 23.456
AVG 22.123 PACE 5L
D-1.234 BANK +0.5/L</code></pre>

**Right on pace** (diff within ±0.005 s) — the last line switches to `ON TARGET`:

<pre style="text-align: center;"><code>D+0.00 ON TARGET</code></pre>

**Post-race (DONE):**

<pre style="text-align: center;"><code>DONE
3LAPS 247.36
AVG 82.45 BEST 81.78</code></pre>

What each field means:

- **TIME LEFT**: seconds remaining
- **LAP N**: latest lap number and time, in seconds
- **AVG / PACE**: average so far, and how many laps you'll finish at the current pace
- **D±x BANK / NEED / ON TARGET**: gap to the target pace. BANK = ahead, NEED = behind, ON TARGET = on target. `/L` is the per-lap delta.

### Tips while flying

- **Voice announcements**: turn it on in Settings and the iPhone reads each lap time aloud.
- **Haptics**: the iPhone vibrates on Start / Lap, so you can confirm the tap registered without looking at the screen.
- **Best lap**: highlighted automatically (star + accent color).

---

## 9. After the race

### Sharing

When you tap the **SHARE** button on the timer screen (visible after a race ends — see the [§8 post-race screenshot](#after-the-race-ends)), HDZap renders a result card image and opens the iOS share sheet. From there you can save the image, post it on social media, send it via Messages, etc.

The card includes:

- Lap count (rendered large)
- Total time
- Pace, average lap, best lap
- Lap table
- **VBAT voltage chart** (only when flight battery telemetry was recorded — see [Chapter 7](#7-flight-battery-telemetry))

### History

<p align="center">
  <img src="images/history-list.png" alt="History sheet listing past races, newest first" width="360" />
  <br />
  <em>History sheet — newest race on top, each row shows laps · total · trend · best</em>
</p>

1. Tap the **clock icon** at the top right of the main screen → the history sheet opens.
2. Past races are listed newest first. Each row shows **laps, total time, a lap-trend sparkline, and best lap**.
3. Tap a row to open the detail screen.

<p align="center">
  <img src="images/history-detail.png" alt="History detail — per-lap table, trend chart, VBAT chart" width="360" />
  <br />
  <em>History detail — per-lap breakdown, trend sparkline, VBAT chart (when recorded)</em>
</p>

The detail screen shows the same layout as the result card, plus the VBAT chart at the bottom when flight-battery telemetry was captured for that race. Tap the **battery icon** in the top toolbar to export the raw VBAT samples as CSV.

### Deleting

- **Single race**: swipe left on a row in the history list → Delete.
- **All races**: tap the menu (`…`) at the top right of the history screen → "Delete all". A confirmation dialog appears.

---

## 10. Premium voices (subscription)

The free Lap announcer uses your iPhone's built-in voices. **HDZap Premium** swaps that out for cloud-rendered, broadcast-grade AI voices (AWS Polly + Microsoft Azure, 30+ choices across English and Japanese).

<p align="center">
  <img src="images/13-paywall.png" alt="HDZap Premium paywall" width="320" />
</p>

> 💡 **You can audition every Premium voice for free, no subscription needed.** Subscribing is only required to actually use a Premium voice during a race.

### What Premium gives you

- **30+ voices** in EN + JA, grouped by provider (Polly / Azure)
- **Natural number reading** — `12.34` reads as "twelve point three four", not digit-by-digit
- **Broadcast-quality audio** — cleanly intelligible over the iPhone speaker or Bluetooth headphones
- **Per-provider prosody** — rate slider for both providers; pitch slider on Azure voices
- **Automatic fallback** — when offline or signal is weak, the announcer drops back to the System voice so the race never goes silent

### Audition the catalog (no subscription needed)

1. Open Settings (⚙) → **App → Lap announcer**.

   <p align="center">
     <img src="images/settings-app.png" alt="Settings → App section — Lap announcer row" width="360" />
   </p>

2. Tap **Listen to Premium voices** (Free preview).

   <p align="center">
     <img src="images/audio-voice-system.png" alt="Voice card showing the 'Listen to Premium voices' entry row" width="360" />
     <br />
     <em>The <strong>Listen to Premium voices</strong> row sits near the top of the Voice card (non-subscriber view only)</em>
   </p>
3. The picker lists every voice grouped under **AWS Polly** and **Azure**. Tap the **▶** button on any row to hear a sample call-out.

   <p align="center">
     <img src="images/12-premium-voice-picker-locked.png" alt="Premium voice picker — non-subscriber view" width="320" />
   </p>

   - Tapping a voice **name** opens the Paywall — selection is a paid action.
   - Tapping the **▶** button only plays a sample — it doesn't commit anything.

### Subscribing

1. From the picker, tap any voice name OR tap **Subscribe ›** in the pink banner at the top of the list.
2. The Paywall sheet opens (image above).
3. Pick **Monthly** or **Yearly** and confirm via Face ID / Touch ID. Apple handles the payment — HDZap never sees your card.
4. After a successful purchase the Paywall auto-dismisses. The picker now lets you commit a voice on tap, and the **Engine** picker on the Lap announcer screen gains a working **Premium (cloud)** option.

### Using a Premium voice during a race

Once subscribed:

1. **Settings → App → Lap announcer**.
2. Set **Engine** to **Premium (cloud)**.
3. Tap **Premium voice** to pick from the catalog (the row shows your current choice).

   <p align="center">
     <img src="images/audio-voice-premium.png" alt="Voice section with Premium engine selected" width="360" />
   </p>

4. Adjust the **Rate** slider (and **Pitch** on Azure voices) to taste.
5. Tap **Test voice** to hear a sample with your current settings.

The first time the Settings sheet is dismissed after switching to Premium, the announcer **pre-warms** all the fixed phrases ("Lap 1", "best lap", countdown numbers) into a local cache, so subsequent calls play instantly without a network round-trip. Race-time variable phrases (lap times) stream live.

### Restoring on a new device

Already subscribed and on a new iPhone? Open the Paywall and tap **Restore Purchases** at the bottom. Apple re-delivers your active subscription to the app.

### Subscription details

- **Auto-renewing**, billed monthly or yearly via your Apple ID
- Manage / cancel any time from **iOS Settings → Apple ID → Subscriptions**
- Pricing is set per region; the Paywall shows the price for your current Apple ID locale
- Apple's standard subscription refund policy applies

### When things go wrong

- **Premium engine selected but lap calls sound like the System voice:** check the Paywall via Settings → App → Lap announcer → tap **Listen to Premium voices** → check the bottom of the Lap announcer screen for a red error message. Common causes: offline, restored on a different Apple ID, subscription expired.
- **First lap call is laggy, later ones are instant:** that's the normal cold-cache path. The fixed-phrase pre-warm runs on Settings dismissal — pop the Settings sheet open and closed once before the race to force it.

---

## 11. Settings reference

### Format

<p align="center">
  <img src="images/settings-format.png" alt="Format section" width="360" />
</p>

- **Race time**: 60–180 s (5 s steps)
- **Target lap**: e.g. 5L
- **Target pace**: derived from race time and target lap (read-only)

### Device → Use bridge

<p align="center">
  <img src="images/settings-device.png" alt="Device section, bridge ON" width="360" />
  <br />
  <em>Bridge ON, connected — drilldowns visible</em>
</p>

- **Use bridge**: master switch for the M5StickS3 bridge integration. **Off by default on a fresh install** — flip it on if you have a flashed M5StickS3, and the **M5StickS3**, **Goggle pairing**, and **OSD layout** drilldowns appear below this toggle (the first flip-on also triggers the iOS Bluetooth permission prompt). Turning it off hides the three drilldowns and replaces them with a hint that a bridge is needed to mirror lap times on the goggle.
- Existing users who already have a goggle pairing keep this on automatically after upgrading — the toggle preserves their setup rather than asking them to opt back in.

<p align="center">
  <img src="images/settings-device-standalone.png" alt="Device section, bridge OFF (standalone mode)" width="360" />
  <br />
  <em>Bridge OFF — drilldowns hidden, footer hint shown</em>
</p>

### Device → M5StickS3 (Connection)

Only visible when **Use bridge** is on. Drills into the connection screen below.

<p align="center">
  <img src="images/connection-connected.png" alt="Connection — Connected card" width="360" />
</p>

- **Connected** card: name, status dot, **Disconnect** button, battery %, flight pack telemetry indicator, and a Version row showing the App + Firmware version side by side.
- **Bluetooth name** (only visible while connected, below the card): tap to open the rename screen for the M5StickS3. UTF-8 up to 20 bytes; the unit reboots once after Save and the iPhone reconnects automatically. See [Chapter 5 → Renaming the M5StickS3](#renaming-the-m5sticks3-optional).

<p align="center">
  <img src="images/connection-other-devices.png" alt="Connection — Other devices card" width="360" />
</p>

- **Other devices**: discovered M5StickS3 units, each with a **Connect** button. Empty until you tap **Scan**.

<p align="center">
  <img src="images/connection-scan.png" alt="Connection — Scan button" width="360" />
</p>

- **Scan**: rescan for nearby M5StickS3 devices.

### Device → Goggle pairing

The mode picker switches the form between bind phrase, manual UID, and new pairing. **TX UID Capture** lives on the same screen, below the mode form. See [Chapter 6](#6-binding-to-the-digital-fpv-goggle) for the full workflow.

<p align="center">
  <img src="images/pairing-current-uid.png" alt="Pairing — Current UID card" width="360" />
</p>

- **Current UID**: live display of what's currently active on the M5StickS3 (decimal + hex side by side).

<p align="center">
  <img src="images/pairing-configure-bind-phrase.png" alt="Pairing — Configure card (Bind Phrase mode)" width="360" />
</p>

- **Configure** (mode picker + form): pick **Bind Phrase**, **Manual UID**, or **New Pairing**. The text fields and buttons below adapt to the picked mode — see [§6.1](#61-new-pairing) / [§6.3](#63-manual-uid-advanced) / [§6.4](#64-use-a-known-bind-phrase) for screenshots of each mode.
- **Apply UID** / **Pair with new goggle**: trigger the chosen flow; the apply alert and verification banner step you through `Switching pairing…` → `Verifying…` → `Pairing works` / auto-rollback.
- **Restore previous goggle** (appears only after an apply): roll back to the prior UID.

<p align="center">
  <img src="images/pairing-tx-uid-capture.png" alt="Pairing — TX UID Capture card" width="360" />
</p>

- **Start TX UID Capture**: kick off the passive sniff used in path 6.2. Press Bind on the radio (EdgeTX) once this is armed.

### Device → OSD layout

Live editor for the goggle OSD with a 4-row preview at the top. Adjustments push to the goggle in real time so the pilot can see the new arrangement without running a race.

<p align="center">
  <img src="images/osd-preview.png" alt="OSD layout — Preview card" width="360" />
</p>

- **Preview**: the literal 4-row block that lands on the goggle, with the current alignment + visible-row settings applied. Updates live as you change the controls below.

<p align="center">
  <img src="images/osd-position.png" alt="OSD layout — Top row slider" width="360" />
</p>

- **Top row** slider: where the visible OSD block sits on the 18-row goggle grid (1 = very top, default = bottom-anchored). The slider's range shrinks automatically as you hide rows so the block can never fall off the bottom.

<p align="center">
  <img src="images/osd-alignment.png" alt="OSD layout — Alignment picker" width="360" />
</p>

- **Alignment**: left / center / right — applies to all visible rows.

<p align="center">
  <img src="images/osd-show-rows.png" alt="OSD layout — Show rows toggles" width="360" />
</p>

- **Show rows** toggles: independently hide **Time**, **Lap**, **Pace**, **Diff**. Hidden rows close up so the visible block stays compact; drag the right-edge handle to reorder.
- **Send Test OSD** (below the SHOW ROWS card): pushes the iPhone's current date + time to the goggle once. Each tap updates the timestamp so you can confirm packets are landing.
- **Clear OSD**: wipes the goggle overlay buffer.
- **Reset layout**: returns the editor to the defaults (bottom-anchored, centered, all rows visible).

### App → Lap announcer (Audio)

<p align="center">
  <img src="images/audio-announcement.png" alt="Lap announcer — Announcement card" width="360" />
</p>

Announcement section — applies to both engines:

- **Announce lap times**: on / off. Also triggers a "Last lap!" voice cue at the moment the session timer hits zero (or "ファイナルラップです" when the language is set to Japanese).
- **Say "best lap" on new best**: prefix the announcement with "best lap" when a lap sets a new fastest
- **Announce need / bank**: off by default. When enabled, each applicable lap call adds the one-decimal pace correction or time in hand per remaining target lap (for example, “need 0.2 seconds per lap” or “bank 0.2 seconds per lap”). Nothing is added when the pace is on target. Japanese calls use the shorter “0.2秒不足” / “0.2秒余裕” wording.
- **Count down final seconds**: off by default. When on, the announcer counts down the closing seconds of the session window using the selected voice ("ten, nine, ..." in English, "じゅう、きゅう..." in Japanese).
- **Start at**: 5–15 s — when the countdown begins. Default 10. Only shown when **Count down final seconds** is on.

<p align="center">
  <img src="images/audio-announcement-countdown.png" alt="Count down final seconds toggled ON, with the Start at stepper revealed" width="360" />
  <br />
  <em>Countdown ON — the <strong>Start at</strong> stepper appears below the toggle</em>
</p>

<p align="center">
  <img src="images/audio-voice-system.png" alt="Voice section — System engine" width="360" />
  <br />
  <em>System engine — uses the iPhone's built-in voices</em>
</p>

Voice section, common to both engines:

- **Language**: Japanese, English, etc. Changing this resets the picked voice for both engines.
- **Engine**: **System** (uses the iPhone's built-in voices, free) or **Premium (cloud)** (HDZap Premium subscription — see [Chapter 10](#10-premium-voices-subscription)). The row reads **Premium — Subscribe ›** for non-subscribers; tapping it routes to the audition picker rather than flipping the engine.

System engine controls:

- **Voice**: system default + any installed voices
- **Rate**: speech speed
- **Pitch**: voice pitch

<p align="center">
  <img src="images/audio-voice-premium.png" alt="Voice section — Premium engine" width="360" />
  <br />
  <em>Premium engine — cloud-rendered AI voices</em>
</p>

Premium engine controls (only with an active subscription):

- **Premium voice**: drill into the catalog grouped by provider. See [Chapter 10](#10-premium-voices-subscription) for the audition flow.
- **Rate**: applied via SSML on both Polly and Azure
- **Pitch**: applied via SSML on Azure voices only (Polly Neural rejects pitch)

Shared controls (visible on either engine):

- **Test voice**: try the current settings out loud
- **Reset**: restore the announcer defaults (per-engine voice + rate + pitch)

### App → Appearance

<p align="center">
  <img src="images/settings-app.png" alt="App section — Lap announcer + Appearance rows" width="360" />
</p>

- **Hue slider** (inside the Appearance drilldown): changes the UI accent color across 0°–360°.

### About

<p align="center">
  <img src="images/settings-about.png" alt="About section — App + Firmware versions" width="360" />
</p>

- **App version**: the HDZap app's version. Always shown.
- **Firmware**: the M5StickS3's current firmware version. Shown after a successful connection. If it disagrees with the app version, this row turns **red** with a warning — re-flash the M5StickS3 from the Web Flasher to bring it back in line. The same info also shows in **Settings → Device → M5StickS3** under **Version**.

---

## 12. Troubleshooting

### M5StickS3

| Symptom | Fix |
|---|---|
| LCD stays blank / device doesn't boot | Re-flash via Web Flasher with "Erase everything" checked |
| `ESP_TOO_MUCH_DATA` error in the Web Flasher | Update Chrome to the latest version |
| Can't pick a serial port | Try a different cable (verify it's not charge-only). Then enter DFU mode manually (hold power 2 s) and reconnect |
| The browser's Allow dialog never shows | Close the browser and reopen the URL |
| Want to reset everything | Re-flash via Web Flasher with "Erase everything" checked |

### Bluetooth

| Symptom | Fix |
|---|---|
| M5StickS3 not in the device list | Check iOS Settings → HDZap → Bluetooth permission. Power-cycle the M5StickS3 |
| Connection keeps dropping | Move the iPhone closer. In iOS Settings → Bluetooth, "Forget" HDZap and reconnect |

### Goggle / OSD

| Symptom | Fix |
|---|---|
| OSD doesn't appear on the Goggle | **First, verify the Goggle backpack firmware is v1.5.5 or newer** (most common cause). Then re-walk [Chapter 6's flowchart](#decision-flowchart-which-path-is-yours) from the top |
| OSD text is garbled / partially missing | Re-check the Goggle firmware version. Then suspect 2.4 GHz interference (Wi-Fi, the drone itself, etc.) |
| OSD fails to appear immediately after binding | Use **Restore previous goggle** to revert, then try a different bind path |

---

## 13. Appendix

### Glossary

- **bind phrase**: a human-readable string the UID is derived from. The first 6 bytes of its MD5 hash become the UID.
- **UID**: 6-byte identifier. The M5StickS3 and the Goggle must share the same UID to communicate. The low bit of the first byte is always 0 (a constraint to avoid multicast MACs).
- **MSP / MSPv2**: MultiWii Serial Protocol — a lightweight binary protocol common across FPV gear. HDZap sends OSD commands via v2.
- **OSD**: On-Screen Display. The text overlay rendered on top of the video.
- **ELRS (ExpressLRS)**: an open-source RC link ecosystem that includes receivers, transmitters, and backpacks.
- **Backpack**: an ESP32 module attached to a Goggle or radio (built into the Digital FPV Goggle). A control channel separate from the video link.
- **ESP-NOW**: a peer-to-peer wireless protocol on top of Wi-Fi PHY that ESP32s can use without pairing.
- **BLE / GATT**: Bluetooth Low Energy / Generic Attribute Profile. Used between the iPhone and the M5StickS3.

### Compatible hardware

Only the **M5StickS3** is officially supported. Support for other ESP32 boards may be added based on user requests. Reference notes live in the [compatible boards list](https://github.com/saqoosha/HDZap/blob/main/docs/compatible-devices.md).

### Developer-facing technical details

- [README](https://github.com/saqoosha/HDZap) (developer-oriented overview of the whole repository)
- [docs/report.md](https://github.com/saqoosha/HDZap/blob/main/docs/report.md) (research notes on MSPv2 / ESP-NOW / ELRS bind protocols)
- [docs/architecture.md](https://github.com/saqoosha/HDZap/blob/main/docs/architecture.md) (system architecture)

### License & contributing

- Source: [GitHub repository](https://github.com/saqoosha/HDZap)
- Bug reports / feature requests: [Issues](https://github.com/saqoosha/HDZap/issues)

---

<p align="center">
  <em>Happy racing!</em> 🏁
</p>
