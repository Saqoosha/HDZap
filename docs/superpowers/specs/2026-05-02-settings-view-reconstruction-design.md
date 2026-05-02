# Settings View Reconstruction — Design

Date: 2026-05-02
Scope: iOS app (`app/HDZap`) only. No firmware changes.

## Goals

Reconstruct the iOS settings sheet (currently `ConnectionView`) so it covers more than connection:

1. **Race time configurable** (currently hard-coded 90 s).
2. **Highlight color hue configurable** (currently hard-coded pink `#DB65A9`, used in 20+ places via `EditorialTheme.accent`).
3. **Current UID rendered in decimal** (matching M5Stick's `96,210,83,138,178,0` format) above the pairing controls, with hex as a caption.
4. **Section reorganization** so app-config, hardware state, and pairing controls each form a coherent block.

## Non-goals

- Firmware OSD layout / colors. Goggle OSD is monochrome; this work is iOS-side chrome only.
- Refactoring the BLE flow, pairing state machine, or `BluetoothManager`. Section moves only relabel/regroup.

The file + struct **are renamed** from `ConnectionView` to `SettingsView` — the navigation title and entry point already say "Settings" conceptually, and the view's responsibilities now extend beyond connection.

## Section layout (final)

```
1. Error              (conditional, top)
2. Race               (target lap + race time + target pace)
3. Appearance         (accent hue slider + preview)
4. Bluetooth          (status + scan/disconnect + discovered devices, merged)
5. Current UID        (decimal main + hex caption + restore-previous button)
6. Pairing            (mode picker + Apply + Pairing Status banner + TX UID Capture, merged)
7. Debug              (Send Test OSD)
```

Rationale:
- Race + Appearance are app-only settings (touchable without M5Stick). Group at top.
- Bluetooth → Current UID → Pairing is the "connect → see current state → change it" flow. Middle.
- Debug last — operator probe, rarely touched.
- Error stays conditional at the very top (existing behavior; unchanged).

## 1. Race time

### Persistence

- New key: `@AppStorage("raceSessionLimit") raceSessionLimit: Int` (seconds, integer).
- Range: **60–180 s, step 5 s**. Default: **90 s**.
- Clamp on read (mirroring `RaceMetrics.clampedTargetLapCount`).

### Constant unification

Two duplicate `static let sessionLimit: TimeInterval = 90` exist today:
- `RaceMetrics.sessionLimit`
- `EditorialTheme.sessionLimit`

Both are removed. The value flows from `@AppStorage` directly to:
- `TimerView` (`timeUp`, `remaining`, `progress`)
- `RaceMetrics.init?(...)` — add a required `sessionLimit: TimeInterval` parameter
- `RaceMetrics.targetLapSeconds(for:sessionLimit:)` — add a required `sessionLimit:` parameter

Why thread the parameter explicitly instead of reading `@AppStorage` inside `RaceMetrics`: keeps the model layer free of `SwiftUI`/`Foundation.UserDefaults` coupling and keeps the type a pure value (preserves testability — call sites pass any value).

### UI

In the **Race** section:

```
Stepper "Target lap"     [ 7 ]   (existing — clamps 2..99)
Stepper "Race time"      [ 90s ] (new — clamps 60..180, step 5)
Row     "Target pace"    [ 15.00s ] (read-only — recomputes via targetLapSeconds(for:sessionLimit:))
```

Footer copy update: replace the current "90 seconds is fixed. Target pace is 90 / (target lap - 1)." with "Target pace is race time / (target lap - 1)."

## 2. Accent hue (OKLCH)

### Persistence

- New key: `@AppStorage("accentHue") accentHue: Double` (degrees, 0..360).
- Default: **derived from current pink `#DB65A9` via OKLCH conversion**. Computed once and committed as a literal — no runtime dependency on the conversion path for the default.
  - Approximate target: L ≈ 0.66, C ≈ 0.14, H ≈ 350°. Recompute exactly during implementation and commit the literal.

### Color model: OKLCH (not HSB)

OKLCH keeps **perceptual lightness constant** as hue rotates. With HSB, sweeping hue from pink to yellow makes the accent visibly brighter, which would wreck the "Best lap marker pops out from ink" contrast at certain hues.

Implementation lives in a new helper file `app/HDZap/Utils/OKLCH.swift`:

```swift
// Convert OKLCH (L 0..1, C 0..~0.4, H 0..360°) to a SwiftUI Color
// via OKLab → linear sRGB → gamma-encoded sRGB.
// Gamut handling: if any linear sRGB channel lies outside [0, 1],
// reduce C by binary search until in-gamut. (Reduces saturation
// rather than hue-shifting — preserves the user's chosen hue.)
func oklchColor(L: Double, C: Double, H: Double) -> Color
```

References for the conversion math:
- OKLab/OKLCH: <https://bottosson.github.io/posts/oklab/>
- sRGB gamma: standard `linearToSRGB` piecewise function

`EditorialTheme` exposes:

```swift
extension EditorialTheme {
    // L and C are fixed; H comes from the @AppStorage value.
    static let accentL: Double = 0.66
    static let accentC: Double = 0.14
    static func accent(hue: Double) -> Color {
        oklchColor(L: accentL, C: accentC, H: hue)
    }
}
```

The hard-coded `static let accent: Color = ...` is removed.

### Distribution to views: Environment

20+ call sites read `EditorialTheme.accent` today. Threading a parameter through every view is intrusive. Reading `@AppStorage` in every view is fine but couples each view to the storage key.

Use a SwiftUI `EnvironmentKey`:

```swift
private struct AccentHueKey: EnvironmentKey {
    static let defaultValue: Double = 350.0  // commit exact OKLCH-derived value
}
extension EnvironmentValues {
    var accentHue: Double {
        get { self[AccentHueKey.self] }
        set { self[AccentHueKey.self] = newValue }
    }
}
```

`HDZapApp` (or `ContentView`) reads `@AppStorage("accentHue")` once and applies:

```swift
.environment(\.accentHue, hue)
.tint(EditorialTheme.accent(hue: hue))
```

Each existing call site changes from `EditorialTheme.accent` to a local computed:

```swift
@Environment(\.accentHue) private var accentHue
private var accent: Color { EditorialTheme.accent(hue: accentHue) }
```

…then references `accent` instead of `EditorialTheme.accent`. Small per-view diff, no state plumbing.

### UI

In the **Appearance** section:

```
Slider 0..360                (background: OKLCH gradient at fixed L/C, no thumb tint)
Hue value caption            ("321°")
Preview block                (a "LAP 7" sample row + an inline progress dot in the chosen accent)
Button "Reset to default"    (resets to default hue)
```

The slider track is rendered as a horizontal gradient sampled at `oklchColor(L:accentL, C:accentC, H:t)` for t in 0..360 — gives the user a perceptual preview of the entire choice space.

## 3. Current UID display

### Format

- **Main line**: `formatUIDDecimal(uid)` → `96,210,83,138,178,0`. `.body.monospaced()`. Matches M5Stick LCD (`%u,%u,%u,%u,%u,%u`).
- **Caption**: `formatUID(uid)` → `60:D2:53:8A:B2:00`. `.caption.monospaced()`, `.foregroundStyle(.secondary)`. For cross-checking against ELRS Configurator, MAC tools, etc.

### New helper

In `UIDUtils.swift`:

```swift
func formatUIDDecimal(_ uid: [UInt8]) -> String {
    uid.map { String($0) }.joined(separator: ",")
}
```

### Section position

Move from below `gogglePairingSection` to above it, right under the Bluetooth section. Reasoning: "what's set now" is read-only verification; users want to see it before deciding whether to change it.

The "Restore previous goggle" button stays inside this section, with both decimal main + hex caption for the rollback target too.

### Other UID-displaying sites

For consistency, update:
- **TX UID Capture** "Captured TX UID" row: same decimal main + hex caption format.
- **Apply alert message** (`applyAlertMessage(for:)`): hex form is fine here — the alert is a transient confirmation referencing technical IDs. Keep `formatUID` (hex). Decision: don't touch the alert copy in this PR; the goggle-decimal vs hex tradeoff there is its own concern.
- **Bind Phrase preview** ("UID: ..." caption when typing a phrase): keep hex (the phrase derivation produces a MAC, hex is the natural form).
- **Manual UID parsed/normalized echo**: keep hex. The user can already type either format; the echo confirms in canonical hex.

## 4. Bluetooth + Discovered Devices merge

Single section "Bluetooth":

```
Status row                        (dot + Connected/Disconnected)
Device row                        (only if connected)
HStack: [Scan] [Disconnect]
─── hairline divider ───
Discovered devices list           (or "No devices found" caption)
```

Footer: short hint about scanning behavior.

## 5. Pairing merge

Single section "Pairing":

```
Picker "Mode" [Bind Phrase | Manual UID | New Pairing]
Mode-specific input                (TextField / hint copy)
Resolved UID preview               (hex; existing behavior)
Button [Apply UID / Pair with new goggle]
─── (visible only when pairingPhase != .idle) ───
Pairing Status banner              (Applying / Verifying / Success / Rolled back / ...)
─── hairline divider ───
TX UID Capture controls            (Start / Stop, captured UID with Apply)
```

Footer: existing copy about flashed bind phrases overriding runtime bind.

The `pairingStatusSection`'s body is inlined into this section as a conditional view; no behavioral change.

## File touch list

**New:**
- `app/HDZap/Utils/OKLCH.swift` — OKLCH → `Color` helper + gamut clip.
- `app/HDZap/Views/SettingsView.swift` (renamed from `ConnectionView.swift`).
- `EnvironmentKey` for accent hue is added inline in `EditorialTheme.swift` (next to `accent(hue:)`) to keep file count small and the related symbols colocated.

**Modified:**
- `app/HDZap/Models/RaceMetrics.swift` — drop `sessionLimit` constant, thread `sessionLimit:` parameter through `init?` and `targetLapSeconds(for:)`.
- `app/HDZap/Views/EditorialTheme.swift` — drop `sessionLimit`, replace `accent` constant with `accent(hue:)` function, add OKLCH-derived defaults.
- `app/HDZap/Views/TimerView.swift` — read `@AppStorage("raceSessionLimit")`; switch `EditorialTheme.accent` references to env-driven local computed; pass `sessionLimit` to `RaceMetrics.init`.
- `app/HDZap/Views/ContentView.swift` — read `@AppStorage("accentHue")`, apply `.environment(\.accentHue, ...)` and `.tint(...)` at the root.
- `app/HDZap/Utils/UIDUtils.swift` — add `formatUIDDecimal`.
- `app/HDZap/HDZapApp.swift` — wire any AppStorage defaults (UserDefaults registration if needed).
- `app/HDZap.xcodeproj/project.pbxproj` — regenerate via `xcodegen generate` after file moves.

**Removed:**
- `app/HDZap/Views/ConnectionView.swift` (replaced by `SettingsView.swift`).

## AppStorage key registration

Both new keys (`raceSessionLimit`, `accentHue`) get registered with their defaults in the app entry point so the very first read returns sane values:

```swift
UserDefaults.standard.register(defaults: [
    "raceSessionLimit": 90,
    "accentHue": <oklch-derived-default>,
])
```

## Validation / testing

- Manual: tap settings → bump race time → confirm `TimerView`'s remaining/progress reflects new limit and `Target pace` updates live.
- Manual: tap settings → drag hue slider → confirm Best lap marker, summary band highlight, and progress dot all change in lockstep.
- Manual: connect M5Stick → confirm Current UID renders as decimal main + hex caption matching the M5Stick LCD.
- Build: `xcodegen generate && xcodebuild -scheme HDZap -destination 'platform=iOS,id=<device>' build` (BLE testing requires physical device).

## Open questions / deferred

- Firmware never receives the new race time. RotorHazard pace lines on the goggle OSD still come from firmware-side formatting — there's no plumbing to push the iOS race time across. If the user later wants the goggle pace line to honor the iOS race time, that's a separate plumbing PR (BLE characteristic + firmware persistence).
- Accent hue does not affect the goggle OSD (monochrome). Stays iOS-only.
