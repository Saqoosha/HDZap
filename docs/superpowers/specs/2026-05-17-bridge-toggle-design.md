# Bridge enable/disable toggle — design

**Status:** approved, ready for implementation plan
**Date:** 2026-05-17
**Scope:** iOS app only (no firmware change, no BLE GATT change)

## Problem

The HDZap pipeline today assumes every user owns an M5StickS3 bridge. The Settings root, the TimerView masthead, and most of the OSD-related sub-views surface BLE connection state prominently, and the iOS app instantiates `CBCentralManager` unconditionally at launch — which triggers the system Bluetooth permission prompt on first run.

About half of HDZap users do not own a bridge. They want to use the app as a standalone manual lap timer (tap LAP, see lap times, save the race). For these users:

- The Bluetooth permission prompt is unnecessary friction.
- The "Not connected — pair an M5StickS3 to use OSD" affordances are confusing noise.
- They have no way to express "I don't have the hardware, please stop nagging me about it."

## Goal

Make the bridge optional via a single iOS-side toggle. When OFF, the app behaves as a clean standalone lap timer with no Bluetooth permission prompt and no bridge-related UI. When ON, today's behavior is unchanged.

**Default for fresh installs: OFF.** Existing users with a remembered UID are migrated to ON automatically (see Migration below).

## Non-goals

- No firmware changes. The M5Stick firmware does not know or care about this toggle.
- No BLE service UUID bump. iOS-only behavior change.
- No new `BluetoothManager` abstraction layer. The existing class gains a single "enabled" gate; it does not move out of the SwiftUI environment.
- No "headless" mode that runs the bridge without UI. Toggle ON = today's full UI; toggle OFF = no bridge surface.

## Approach: lazy `CBCentralManager` init

The toggle controls whether `BluetoothManager` ever instantiates `CBCentralManager`. This is the key architectural choice — it's what lets the app avoid the Bluetooth permission prompt for users who don't own the hardware.

### State

- **UserDefaults key:** `m5StickBridgeEnabled` (Bool, default `false`)
- **In-memory:** `BluetoothManager.isBridgeEnabled: Bool` (`@Observable`), mirrors the stored value.
- **Lifecycle:** `centralManager: CBCentralManager?` (optional, was non-optional). nil when the toggle is OFF.

### Toggle ON

When the user flips the toggle from OFF to ON:

1. Persist `m5StickBridgeEnabled = true`.
2. Instantiate `CBCentralManager(delegate: self, queue: nil)` on the main actor. This is the call that triggers iOS's Bluetooth permission prompt on first run.
3. Wait for `centralManagerDidUpdateState(.poweredOn)` — the existing path. The user can then tap "Scan" in the Connection sub-screen.

No automatic scan. The user explicitly taps Scan, same as today. (Auto-scan-on-enable was considered and rejected — see Alternatives.)

### Toggle OFF

When the user flips the toggle from ON to OFF:

1. If `isConnected`, set `suppressAutoReconnect = true` and `userTappedDisconnect = true`, then call `centralManager?.cancelPeripheralConnection(peripheral)`. Use the same path as `disconnect()` so `didDisconnectPeripheral` runs the existing cleanup (reset battery state, firmware version, characteristics map).
2. After the disconnect callback fires (or immediately if there was no connection), drop `centralManager = nil`. Clear `discoveredDevices`, `advertisedNames`, `isScanning`.
3. Persist `m5StickBridgeEnabled = false`.

`lastKnownUID` is intentionally NOT cleared on toggle-off — so toggling OFF → ON later remembers the previously-paired goggle for the Pairing summary row.

### Gates that already work

Every UI gate that today reads `bluetooth.isReady` or `bluetooth.isConnected` already renders the disabled / not-connected state correctly. When the toggle is OFF, both flags are false, so:

- All `TimerView` write paths (`sendOSDLayout`, `sendOSDControl`, OSD text writes from lap callbacks, etc.) are already gated on `bluetooth.isReady`, so they become no-ops.
- `PairingSettingsView`, `OSDLayoutSettingsView`, `BackpackTelemetryDebugView`, `DeviceRenameView` — all already disable their write buttons on `!isReady`.

The only behavior change required for these views is that they're never reached in the OFF state (Settings hides the entry points; see UI below).

## UI changes

### `SettingsView` — Device section

Currently:

```
Device
  ● M5StickS3              HDZapBridge · 78% · Charging  >
    Goggle pairing         96,210,83,138,178,0           >
    OSD layout             Rows 3–5                       >
```

After:

```
Device
  Use bridge               [Toggle]
  ● M5StickS3              HDZapBridge · 78% · Charging  >   (only when toggle ON)
    Goggle pairing         96,210,83,138,178,0           >   (only when toggle ON)
    OSD layout             Rows 3–5                       >   (only when toggle ON)
```

The toggle row is a standard `Toggle(isOn:)` bound to `bluetooth.isBridgeEnabled`. The three drill-down rows (M5StickS3 / Goggle pairing / OSD layout) render only when `isBridgeEnabled == true`.

Footer text below the toggle when OFF: "Connect to an M5Stick bridge to mirror lap times on your goggle OSD." (Localizable.) Hidden when ON.

### `TimerView` — masthead

The masthead today shows either `bluetooth.lastError` (red) or, if no error and `!bluetooth.isReady`, "Not connected — open Settings to pair." Wrap the second branch in `bluetooth.isBridgeEnabled` — when the bridge is disabled, the masthead is fully suppressed (no warning, no nag).

The error branch stays unconditional. If a transient error somehow surfaces while the bridge is disabled (it shouldn't, but defense in depth), the user still sees it.

### `SettingsView` — About / firmware version row

The About section's firmware row is already gated on `bluetooth.firmwareVersion != nil`, which only becomes non-nil after a connect. So when the bridge is disabled, the firmware row naturally hides itself. No change needed.

### Other views

- `OSDLayoutSettingsView`, `PairingSettingsView`, `BackpackTelemetryDebugView`, `DeviceRenameView`, `ConnectionSettingsView`: unreachable from the Settings root when the bridge is disabled (entry points hidden). No changes inside these views.
- The `#if DEBUG` section in SettingsView stays visible regardless of toggle — debug builds always show debug rows.

## Migration

On `BluetoothManager.init()`, after the existing `lastKnownUID` restore:

```
let key = "m5StickBridgeEnabled"
if UserDefaults.standard.object(forKey: key) == nil {
    // First launch of a build that knows about this toggle.
    let hasPriorPairing = (lastKnownUID != nil)
    UserDefaults.standard.set(hasPriorPairing, forKey: key)
}
isBridgeEnabled = UserDefaults.standard.bool(forKey: key)
```

This means:

- A user upgrading from a version that paired with a bridge keeps their bridge enabled — they never see the toggle flip on them.
- A fresh install (no `lastKnownUID`) starts OFF.
- The migration runs once. Subsequent launches respect whatever the user set explicitly.

The `lastKnownUID` self-heal path in `init()` (which can wipe a corrupted value) runs BEFORE this check — so a corrupted UID on upgrade is treated as "no prior pairing" and the user starts OFF. Acceptable: the worst case is one user has to flip the toggle once.

## BluetoothManager changes (summary)

- `centralManager: CBCentralManager!` → `centralManager: CBCentralManager?`.
- New `@Observable` property: `isBridgeEnabled: Bool`.
- New method: `setBridgeEnabled(_ enabled: Bool)` — toggle handler. Idempotent (no-op if already in target state).
- `init()`: do NOT instantiate `centralManager` unconditionally. Read the migrated `isBridgeEnabled`; if true, instantiate.
- `startScan()`: early-return with no error if `centralManager == nil` (UI shouldn't expose Scan when disabled, but guard anyway).
- `connect(_:)`, `disconnect()`: nil-safe on `centralManager`.
- All `centralManager.foo(...)` call sites: nil-safe (`centralManager?.foo(...)`).
- `centralManagerDidUpdateState` and other delegate callbacks: unchanged (only fire when a manager exists).

## Error handling

- Bridge enabled + Bluetooth permission denied: existing `startScan()` error path (`"Bluetooth permission denied. Open Settings → HDZap → Bluetooth."`) covers it. The user can either grant permission or flip the toggle OFF.
- Bridge disabled mid-session while connected: the disconnect path handles cleanup; the user sees no error (they asked for it).
- User flips toggle OFF then ON quickly: the OFF path's nil-out runs first; the ON path then creates a fresh `CBCentralManager`. The old `connectedPeripheral` reference is gone, so no stale-connection state survives the round-trip.

## Testing

- **Unit:** none — this is glue across UI + CoreBluetooth, both of which are hard to fake. The existing test suite stays as-is.
- **Manual checklist:**
  1. Fresh install (delete app, reinstall): launches with toggle OFF, no Bluetooth permission prompt, TimerView shows no "Not connected" warning. Settings shows toggle only.
  2. Toggle ON: first time triggers Bluetooth permission prompt. Settings reveals M5StickS3 / Pairing / OSD layout rows. Scan finds the bridge. Pair, see laps on goggle OSD.
  3. Toggle OFF while connected: bridge disconnects, M5Stick LCD goes to idle, app returns to standalone-timer mode.
  4. Toggle OFF → ON without quitting app: re-instantiates central manager, scan works, previously-paired bridge appears in the discovered list and reconnects when tapped. (The in-memory `connectedPeripheral` reference is gone with the old central manager, so iOS's `didDisconnect`-driven auto-reconnect path does NOT fire after OFF→ON — the user explicitly taps Scan, then Connect. This is intentional and matches the rest of the connection flow.)
  5. Upgrade migration: install a build with prior `lastKnownUID` present, install this build over it. Verify toggle defaults to ON.
  6. Upgrade migration (no prior pairing): install a build with no `lastKnownUID`, install this build. Verify toggle defaults to OFF.

## Alternatives considered

**Auto-scan when the toggle is flipped ON.** Rejected because the user has already just performed an explicit action (flipping the toggle); requiring one more tap on "Scan" is consistent with the rest of the connection flow and avoids a surprise scan when the user just wanted to look at the toggle.

**Keep `CBCentralManager` alive always; hide UI only.** Rejected because it would still trigger the Bluetooth permission prompt for users who don't own the hardware, defeating the main UX win.

**Put the toggle in TimerView, not Settings.** Rejected — Settings is the right home for an install-once preference. TimerView's masthead is for transient state.

**Three-way control (Disabled / Auto / Always-on).** Rejected as YAGNI. A binary toggle covers both populations.
