# Settings View Reconstruction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the iOS settings sheet to support configurable race time, configurable accent hue (OKLCH), and decimal UID display, with sections regrouped into Race / Appearance / Bluetooth+Devices / Current UID / Pairing+TX / Debug.

**Architecture:** Two new `@AppStorage` keys (`raceSessionLimit`, `accentHue`) drive runtime values. `RaceMetrics` becomes pure (race-time threaded as parameter, no static constant). Accent color is generated via OKLCH→sRGB conversion in a new helper, distributed to views via a SwiftUI `EnvironmentKey`. `ConnectionView` is renamed to `SettingsView` and its sections regrouped.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 18, xcodegen.

**Spec:** [`docs/superpowers/specs/2026-05-02-settings-view-reconstruction-design.md`](../specs/2026-05-02-settings-view-reconstruction-design.md)

**Test strategy:** This iOS target has no unit-test infrastructure. Verification is per-task **build pass** (`xcodebuild build`) + **manual UI check** on simulator. Where pure logic is added (OKLCH math), reference values are embedded as `#Preview`/inline asserts via `assert(...)` so a runtime check fires once on app launch in DEBUG builds.

---

## Task 1: Add `formatUIDDecimal` helper

**Files:**
- Modify: `app/HDZap/Utils/UIDUtils.swift`

- [ ] **Step 1: Add the helper next to `formatUID`**

Insert after `formatUID` (around line 38):

```swift
/// Format a UID as comma-separated decimal bytes — matches what the
/// HDZero goggle and the M5Stick LCD display (`%u,%u,%u,%u,%u,%u`).
/// Use this for the "Current UID" headline; pair it with `formatUID`
/// (hex) as a small caption for cross-checking against MAC tools.
func formatUIDDecimal(_ uid: [UInt8]) -> String {
    uid.map { String($0) }.joined(separator: ",")
}
```

- [ ] **Step 2: Verify build**

Run from repo root:
```sh
cd app && xcodegen generate && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```sh
git add app/HDZap/Utils/UIDUtils.swift
git commit -m "$(cat <<'EOF'
ios: add formatUIDDecimal helper

- Comma-separated decimal byte format matching M5Stick LCD ("%u,%u,..").
- Will back the new Current UID display in the Settings view rebuild.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add OKLCH → SwiftUI Color helper

**Files:**
- Create: `app/HDZap/Utils/OKLCH.swift`
- Modify: `app/project.yml` (no — `sources: HDZap` already globs the dir)

- [ ] **Step 1: Create the helper file**

Write `app/HDZap/Utils/OKLCH.swift`:

```swift
import SwiftUI

/// OKLCH (Lightness / Chroma / Hue) → SwiftUI `Color`.
///
/// Why OKLCH: as hue rotates, perceptual lightness stays constant. Plain HSB
/// makes yellows visibly brighter than blues at the same B value, which would
/// wreck the "Best lap marker pops out from ink" contrast at certain hues.
///
/// Pipeline: OKLCH → OKLab → linear sRGB → gamma-encoded sRGB.
/// References: <https://bottosson.github.io/posts/oklab/>
///
/// Gamut handling: if the requested chroma puts any linear sRGB channel
/// outside [0, 1], chroma is reduced via binary search until in-gamut.
/// This preserves the user's chosen hue (over hue-shifting fallback).
func oklchColor(L: Double, C: Double, H: Double) -> Color {
    let (r, g, b) = oklchToSRGB(L: L, C: C, H: H)
    return Color(red: r, green: g, blue: b)
}

/// Returns gamma-encoded sRGB in [0, 1]^3.
func oklchToSRGB(L: Double, C: Double, H: Double) -> (Double, Double, Double) {
    var lo: Double = 0
    var hi: Double = max(0, C)
    var (r, g, b) = oklabToLinearSRGB(L: L, a: hi * cos(H * .pi / 180.0), b: hi * sin(H * .pi / 180.0))

    if inGamut(r, g, b) {
        return (gammaEncode(r), gammaEncode(g), gammaEncode(b))
    }

    // Binary-search the largest in-gamut chroma that preserves L and H.
    for _ in 0..<24 {
        let mid = (lo + hi) / 2
        let triple = oklabToLinearSRGB(L: L, a: mid * cos(H * .pi / 180.0), b: mid * sin(H * .pi / 180.0))
        if inGamut(triple.0, triple.1, triple.2) {
            lo = mid
            (r, g, b) = triple
        } else {
            hi = mid
        }
    }
    return (gammaEncode(r), gammaEncode(g), gammaEncode(b))
}

private func inGamut(_ r: Double, _ g: Double, _ b: Double) -> Bool {
    let eps = 1e-6
    return r >= -eps && r <= 1 + eps && g >= -eps && g <= 1 + eps && b >= -eps && b <= 1 + eps
}

/// OKLab → linear sRGB. Source: Björn Ottosson's reference implementation.
private func oklabToLinearSRGB(L: Double, a: Double, b: Double) -> (Double, Double, Double) {
    let l_ = L + 0.3963377774 * a + 0.2158037573 * b
    let m_ = L - 0.1055613458 * a - 0.0638541728 * b
    let s_ = L - 0.0894841775 * a - 1.2914855480 * b

    let l = l_ * l_ * l_
    let m = m_ * m_ * m_
    let s = s_ * s_ * s_

    let r =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return (r, g, bl)
}

/// Linear sRGB → gamma-encoded sRGB (clamped to [0, 1]).
private func gammaEncode(_ x: Double) -> Double {
    let v = max(0, min(1, x))
    if v <= 0.0031308 { return 12.92 * v }
    return 1.055 * pow(v, 1.0 / 2.4) - 0.055
}

#if DEBUG
/// Sanity check: convert the legacy pink (#DB65A9) → OKLCH → back, hue should
/// be near 350°. Fires once on first reference in DEBUG.
func _oklchSanityCheck() {
    // Reference OKLCH for #DB65A9: L≈0.6611 C≈0.1408 H≈356°
    let (r, g, b) = oklchToSRGB(L: 0.6611, C: 0.1408, H: 356.0)
    let r8 = Int((r * 255).rounded())
    let g8 = Int((g * 255).rounded())
    let b8 = Int((b * 255).rounded())
    assert(abs(r8 - 0xDB) <= 2 && abs(g8 - 0x65) <= 2 && abs(b8 - 0xA9) <= 2,
           "OKLCH→sRGB drift: got \(r8),\(g8),\(b8) want 219,101,169")
}
#endif
```

- [ ] **Step 2: Verify build**

Run:
```sh
cd app && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Verify reference values**

Open `HDZap.xcodeproj` in Xcode, add a temporary `#Preview { Text("\(oklchToSRGB(L: 0.6611, C: 0.1408, H: 356.0))") }` to `OKLCH.swift`, run preview, confirm output is approximately `(0.86, 0.39, 0.66)` (= 219/255, 101/255, 169/255). Remove the preview before commit.

- [ ] **Step 4: Commit**

```sh
git add app/HDZap/Utils/OKLCH.swift
git commit -m "$(cat <<'EOF'
ios: add OKLCH to sRGB Color helper

- Pure-Swift OKLCH→OKLab→linear sRGB→sRGB pipeline (Björn Ottosson).
- Binary-search chroma reduction for out-of-gamut requests, preserving
  the requested hue and lightness.
- Sanity-check assert against the legacy pink (#DB65A9) in DEBUG.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Thread `sessionLimit` through `RaceMetrics`

**Files:**
- Modify: `app/HDZap/Models/RaceMetrics.swift`

- [ ] **Step 1: Drop the static constant and require `sessionLimit:` on init + targetLapSeconds**

Replace the relevant pieces of `RaceMetrics.swift`:

Remove:
```swift
static let sessionLimit: TimeInterval = 90
```

Change `targetLapSeconds(for:)` from:
```swift
static func targetLapSeconds(for count: Int) -> TimeInterval {
    sessionLimit / Double(clampedTargetLapCount(count) - 1)
}
```
to:
```swift
static func targetLapSeconds(for count: Int, sessionLimit: TimeInterval) -> TimeInterval {
    sessionLimit / Double(clampedTargetLapCount(count) - 1)
}
```

Change `init?(laps:targetLapCount:paceOverride:)` signature to:
```swift
init?(laps: [Lap],
      targetLapCount rawTargetLapCount: Int,
      sessionLimit: TimeInterval,
      paceOverride: Int? = nil) {
    guard let last = laps.last, !laps.isEmpty else { return nil }
    let target = Self.clampedTargetLapCount(rawTargetLapCount)
    let total = laps.reduce(0) { $0 + $1.time }
    guard total > 0 else { return nil }

    targetLapCount = target
    targetLapSec = Self.targetLapSeconds(for: target, sessionLimit: sessionLimit)
    lapNumber = last.id
    lapCount = laps.count
    lastLapSec = last.time
    avgLapSec = total / Double(laps.count)
    remainingLaps = max(1, target - laps.count)
    diffSec = total - (Double(laps.count) * targetLapSec)
    perLapSec = -diffSec / Double(remainingLaps)

    if let paceOverride {
        paceLaps = paceOverride
    } else {
        let remainingSec = max(0, sessionLimit - total)
        let futureLaps = avgLapSec > 0 ? Int((remainingSec / avgLapSec).rounded(.up)) : 0
        paceLaps = laps.count + futureLaps
    }
}
```

- [ ] **Step 2: Verify build fails at call sites**

Run:
```sh
cd app && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20
```
Expected: build FAILS with errors at `TimerView.swift` and `ConnectionView.swift` referencing `targetLapSeconds(for:)` (missing `sessionLimit:`) and `RaceMetrics(laps:targetLapCount:paceOverride:)` (missing `sessionLimit:`).

- [ ] **Step 3: (Do not commit yet — Tasks 4 + 7 + 9 fix call sites)**

---

## Task 4: `EditorialTheme` — drop `sessionLimit`, add `accent(hue:)` + `AccentHueKey`

**Files:**
- Modify: `app/HDZap/Views/EditorialTheme.swift`

- [ ] **Step 1: Replace the constants and add the EnvironmentKey**

In `EditorialTheme.swift`, remove:
```swift
static let accent = Color(red: 0xdb / 255.0, green: 0x65 / 255.0, blue: 0xa9 / 255.0)

/// Time-attack window. Final lap is the one in flight when this elapses.
static let sessionLimit: TimeInterval = 90
```

Add inside `enum EditorialTheme`:
```swift
/// OKLCH lightness for the accent. Fixed; only hue is user-adjustable.
static let accentL: Double = 0.66
/// OKLCH chroma for the accent. Fixed.
static let accentC: Double = 0.14
/// Default accent hue in degrees — derived from the legacy pink #DB65A9.
static let defaultAccentHue: Double = 356.0

/// Resolve the accent color for a given hue (degrees).
static func accent(hue: Double) -> Color {
    oklchColor(L: accentL, C: accentC, H: hue)
}
```

Append at file scope (below the `EditorialTheme` enum, alongside the other extensions):
```swift
private struct AccentHueKey: EnvironmentKey {
    static let defaultValue: Double = EditorialTheme.defaultAccentHue
}

extension EnvironmentValues {
    /// Active accent hue in degrees. Read with `@Environment(\.accentHue)`
    /// and feed into `EditorialTheme.accent(hue:)` to render.
    var accentHue: Double {
        get { self[AccentHueKey.self] }
        set { self[AccentHueKey.self] = newValue }
    }
}
```

- [ ] **Step 2: Verify build still fails (callers untouched)**

Run:
```sh
cd app && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20
```
Expected: build FAILS with errors at all `EditorialTheme.accent` and `EditorialTheme.sessionLimit` call sites in `TimerView.swift` and `ContentView.swift`.

- [ ] **Step 3: (Do not commit yet — call sites fixed in Tasks 6 + 7)**

---

## Task 5: Register AppStorage defaults

**Files:**
- Modify: `app/HDZap/HDZapApp.swift`

- [ ] **Step 1: Register defaults in `init`**

Replace `HDZapApp.swift` body with:

```swift
import SwiftUI

@main
struct HDZapApp: App {
    @State private var bluetoothManager = BluetoothManager()
    @State private var lapTimer = LapTimer()

    init() {
        // Register defaults so the very first @AppStorage read returns sane
        // values rather than 0 / 0.0 — applies before any view materializes.
        UserDefaults.standard.register(defaults: [
            "raceSessionLimit": 90,
            "accentHue": EditorialTheme.defaultAccentHue,
            "targetLapCount": RaceMetrics.defaultTargetLapCount,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bluetoothManager)
                .environment(lapTimer)
        }
    }
}
```

- [ ] **Step 2: (Build still failing — wait for Tasks 6 + 7)**

---

## Task 6: `ContentView` — apply accent env + tint from AppStorage

**Files:**
- Modify: `app/HDZap/Views/ContentView.swift`

- [ ] **Step 1: Replace the body**

```swift
import SwiftUI

struct ContentView: View {
    @AppStorage("accentHue") private var accentHue: Double = EditorialTheme.defaultAccentHue

    var body: some View {
        TimerView()
            .preferredColorScheme(.light)
            .tint(EditorialTheme.accent(hue: accentHue))
            .environment(\.accentHue, accentHue)
    }
}
```

- [ ] **Step 2: (Build still failing in TimerView — fixed in Task 7)**

---

## Task 7: `TimerView` — read `raceSessionLimit` + accent env

**Files:**
- Modify: `app/HDZap/Views/TimerView.swift`

- [ ] **Step 1: Add AppStorage + Environment + local computed**

At the top of `TimerView` (just after the existing `@AppStorage("targetLapCount") ...` line, around line 12), add:
```swift
@AppStorage("raceSessionLimit") private var raceSessionLimit: Int = 90
@Environment(\.accentHue) private var accentHue: Double
private var accent: Color { EditorialTheme.accent(hue: accentHue) }
private var sessionLimit: TimeInterval { TimeInterval(raceSessionLimit) }
```

- [ ] **Step 2: Replace `EditorialTheme.sessionLimit` references**

In `TimerView.swift`:
- Line `private var timeUp: Bool { lapTimer.elapsedTime >= EditorialTheme.sessionLimit }` → `EditorialTheme.sessionLimit` becomes `sessionLimit`
- Line `private var remaining: TimeInterval { max(0, EditorialTheme.sessionLimit - lapTimer.elapsedTime) }` → `sessionLimit`
- Line `private var progress: Double { min(1, lapTimer.elapsedTime / EditorialTheme.sessionLimit) }` → `sessionLimit`

- [ ] **Step 3: Pass `sessionLimit:` into `RaceMetrics` and `targetLapSeconds`**

`refreshMetricsSnapshot` (line ~580) becomes:
```swift
@discardableResult
private func refreshMetricsSnapshot(paceOverride: Int? = nil) -> RaceMetrics? {
    let metrics = RaceMetrics(laps: lapTimer.laps,
                              targetLapCount: clampedTargetLapCount,
                              sessionLimit: sessionLimit,
                              paceOverride: paceOverride)
    metricsSnapshot = metrics
    return metrics
}
```

`targetSummaryValue` (line ~44) becomes:
```swift
private var targetSummaryValue: String {
    let targetLapSec = RaceMetrics.targetLapSeconds(for: clampedTargetLapCount, sessionLimit: sessionLimit)
    return "\(clampedTargetLapCount)L@\(RaceMetrics.seconds(targetLapSec, decimals: 2))"
}
```

- [ ] **Step 4: Replace all `EditorialTheme.accent` with the local `accent`**

Use grep to confirm count then replace mechanically inside `TimerView.swift` only:
```sh
rg -n 'EditorialTheme\.accent' app/HDZap/Views/TimerView.swift
```
Expected: ~13 hits. Replace each `EditorialTheme.accent` with `accent` in this file.

Note: leave `EditorialTheme.accent(hue:)` calls (function form, with parentheses) untouched if any exist — only the bare `EditorialTheme.accent` token is being replaced.

For inner private `View` types in this file (`SummaryColumn`, `LapRow`, `BigTime`, etc.) that read `EditorialTheme.accent` directly, switch them to take an `accent: Color` parameter (already follows this pattern for `BigTime` at line 611 — it has `let accent: Color`). For the others, add `let accent: Color` and pass `accent` from the parent.

Concretely:
- `SummaryColumn` (line ~653): add `let accent: Color`. Change line 663 from `.foregroundStyle(highlight ? EditorialTheme.accent : EditorialTheme.ink)` to `.foregroundStyle(highlight ? accent : EditorialTheme.ink)`.
- Update `summaryBand` (line ~352) to pass `accent: accent` to each `SummaryColumn(...)` invocation.
- For lap rows (lines ~698, ~703, ~711, ~767), they're inline in `lapRowsWithTrend` so they can read `accent` from the enclosing `TimerView` directly — no parameter threading needed.

- [ ] **Step 5: Verify build passes**

Run:
```sh
cd app && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manual UI smoke-test**

Run app in simulator. Confirm:
- Timer view renders (pink accent, 90s window — same as before)
- Best lap marker still pink
- Progress dot still pink

- [ ] **Step 7: Commit (large checkpoint)**

```sh
git add app/HDZap/Models/RaceMetrics.swift app/HDZap/Views/EditorialTheme.swift app/HDZap/Views/ContentView.swift app/HDZap/Views/TimerView.swift app/HDZap/HDZapApp.swift
git commit -m "$(cat <<'EOF'
ios: thread race time + accent hue from AppStorage

- RaceMetrics: drop static sessionLimit, take it as init/targetLapSeconds
  parameter so the model stays a pure value type.
- EditorialTheme: replace hard-coded pink with accent(hue:) using OKLCH;
  add AccentHueKey EnvironmentKey for distribution.
- ContentView: read @AppStorage("accentHue"), apply tint + environment.
- TimerView: read @AppStorage("raceSessionLimit"), pass through to
  RaceMetrics; switch all bare EditorialTheme.accent references to a
  local computed driven by the environment value.
- HDZapApp: register UserDefaults defaults so first read is sane.

No behavioral change yet — runtime values match the previous constants.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Rename `ConnectionView` → `SettingsView` (file + struct + caller)

**Files:**
- Move: `app/HDZap/Views/ConnectionView.swift` → `app/HDZap/Views/SettingsView.swift`
- Modify: every caller of `ConnectionView()`

- [ ] **Step 1: Find caller(s)**

```sh
rg -n 'ConnectionView' app/HDZap/
```
Expected hits: file itself + at least one `ConnectionView()` invocation in `TimerView.swift` (the sheet presentation site).

- [ ] **Step 2: Move + rename the struct**

```sh
git mv app/HDZap/Views/ConnectionView.swift app/HDZap/Views/SettingsView.swift
```

Inside the moved file, change `struct ConnectionView: View {` to `struct SettingsView: View {`. Leave the rest of the file unchanged for this task.

- [ ] **Step 3: Update callers**

In `TimerView.swift`, replace `ConnectionView()` with `SettingsView()` (single hit).

- [ ] **Step 4: Regenerate project + build**

```sh
cd app && xcodegen generate && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```sh
git add app/HDZap/Views/SettingsView.swift app/HDZap/Views/TimerView.swift app/HDZap.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
ios: rename ConnectionView -> SettingsView

- File + struct rename only; no behavior change.
- The view's responsibilities now extend beyond connection (race time,
  appearance, etc. coming next) so the existing nav title "Settings"
  matches the type name.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Reorder sections + add navigation title

**Files:**
- Modify: `app/HDZap/Views/SettingsView.swift`

- [ ] **Step 1: Replace the `body` `List` block**

Replace the existing List body inside `var body` with the new section order. Final body:

```swift
var body: some View {
    NavigationStack {
        List {
            errorSection
            raceSection            // new
            appearanceSection      // new
            bluetoothSection       // merged: status + scan + discovered
            currentUIDSection      // moved up from below
            pairingSection         // merged: pairing + status banner + TX UID
            osdTestSection
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { clampTargetLapCountSetting() }
        .alert(applyAlertTitle, isPresented: applyAlertBinding, presenting: pendingApply) { pending in
            Button("Cancel", role: .cancel) { pendingApply = nil }
            Button("Apply", role: .destructive) {
                let mode = pending.mode
                pendingApply = nil
                Task { await runPairingFlow(mode: mode) }
            }
        } message: { pending in
            Text(applyAlertMessage(for: pending))
        }
    }
}
```

The renamed/merged section accessors (`raceSection`, `appearanceSection`, `bluetoothSection`, `pairingSection`) are introduced in Tasks 10–13. For now: rename the existing `raceTargetSection` to `raceSection`, the existing `bleStatusSection` to `bluetoothSection`, and the existing `gogglePairingSection` to `pairingSection` so the new `body` compiles. `appearanceSection` will be a stub.

Add the stub at the bottom of the file (above the closing `}` of the struct):
```swift
@ViewBuilder
private var appearanceSection: some View {
    // Filled in in Task 11
    EmptyView()
}
```

Remove the old direct references that have moved or merged: delete the `discoveredDevicesSection` accessor (logic folds into `bluetoothSection` in Task 12) and the `pairingStatusSection` + `txSniffSection` accessors (fold into `pairingSection` in Task 13). For now, keep their bodies intact; Task 12 + 13 will inline them.

Wait — to avoid a non-building checkpoint, **do this rename mechanically only**:
- Rename `raceTargetSection` → `raceSection` (single accessor rename; body unchanged here, Task 10 fills it)
- Rename `bleStatusSection` → `bluetoothSection` (Task 12 merges discovered devices into it)
- Rename `gogglePairingSection` → `pairingSection` (Task 13 merges status + TX into it)
- Leave `discoveredDevicesSection`, `pairingStatusSection`, `txSniffSection`, `currentUIDSection`, `osdTestSection` accessors alone for now — they aren't referenced by the new `body` so they become dead code temporarily; Task 12 and 13 fold their content in and delete them.

Actually that introduces an unused-symbol warning. To keep the build clean: after renaming `body` references, **delete the unused accessors** (`discoveredDevicesSection`, `pairingStatusSection`, `txSniffSection`) **but stash their body content** as comments in this commit, or just hold off this task until after 12+13 land.

Resolution: skip the body switch in this task. **Task 9 is now: rename the three accessors only.** Section reordering + body switch happens in Task 13 once the merged accessors exist.

So this task becomes:

- [ ] **Step 1 (revised): Rename accessors mechanically**

```sh
cd app/HDZap/Views
# Rename the three accessor names; the body still references the old names
# in Task 9, so update both definition and reference call sites.
```

Use sed-like edits:
- `private var raceTargetSection: some View {` → `private var raceSection: some View {`
- Reference `raceTargetSection` in `body` → `raceSection`
- `private var bleStatusSection: some View {` → `private var bluetoothSection: some View {`
- Reference `bleStatusSection` in `body` → `bluetoothSection`
- `private var gogglePairingSection: some View {` → `private var pairingSection: some View {`
- Reference `gogglePairingSection` in `body` → `pairingSection`

- [ ] **Step 2: Verify build**

```sh
cd app && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```sh
git add app/HDZap/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
ios: rename settings sections to match upcoming layout

- raceTargetSection -> raceSection
- bleStatusSection -> bluetoothSection
- gogglePairingSection -> pairingSection

No body changes; sets up Tasks 10-14 for content + reorder.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Race section — add `raceSessionLimit` Stepper

**Files:**
- Modify: `app/HDZap/Views/SettingsView.swift`

- [ ] **Step 1: Add the AppStorage binding**

Near the top of `SettingsView`, alongside `@AppStorage("targetLapCount") private var targetLapCount = ...`, add:
```swift
@AppStorage("raceSessionLimit") private var raceSessionLimit: Int = 90
```

- [ ] **Step 2: Replace `raceSection` body**

Find:
```swift
private var raceSection: some View {
    Section {
        Stepper(value: $targetLapCount,
                in: RaceMetrics.minTargetLapCount...RaceMetrics.maxTargetLapCount) {
            HStack {
                Text("Target lap")
                Spacer()
                Text("\(RaceMetrics.clampedTargetLapCount(targetLapCount))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }

        HStack {
            Text("Target pace")
            Spacer()
            Text("\(RaceMetrics.seconds(RaceMetrics.targetLapSeconds(for: targetLapCount), decimals: 2))s")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    } header: {
        Text("Race Target")
    } footer: {
        Text("90 seconds is fixed. Target pace is 90 / (target lap - 1).")
            .font(.caption2)
    }
}
```

Replace with:
```swift
private var raceSection: some View {
    Section {
        Stepper(value: $targetLapCount,
                in: RaceMetrics.minTargetLapCount...RaceMetrics.maxTargetLapCount) {
            HStack {
                Text("Target lap")
                Spacer()
                Text("\(RaceMetrics.clampedTargetLapCount(targetLapCount))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }

        Stepper(value: $raceSessionLimit, in: 60...180, step: 5) {
            HStack {
                Text("Race time")
                Spacer()
                Text("\(raceSessionLimit)s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }

        HStack {
            Text("Target pace")
            Spacer()
            Text("\(RaceMetrics.seconds(RaceMetrics.targetLapSeconds(for: targetLapCount, sessionLimit: TimeInterval(raceSessionLimit)), decimals: 2))s")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    } header: {
        Text("Race")
    } footer: {
        Text("Target pace is race time ÷ (target lap − 1).")
            .font(.caption2)
    }
}
```

- [ ] **Step 3: Verify build**

```sh
cd app && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual check**

Run in simulator → tap settings → bump Race time stepper from 90 → 120 → confirm "Target pace" recalculates live. Close settings and re-open: 120 persists.

Verify TimerView reflects the new race time: with race time at 120, the session bar should fill at half the speed compared to 60.

- [ ] **Step 5: Commit**

```sh
git add app/HDZap/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
ios: settings race section — configurable race time

- Add Race time stepper (60-180s, step 5, default 90).
- Section renamed Race Target -> Race; footer wording updated to
  reference the configurable race time.
- Target pace now recomputes against the chosen race time.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Appearance section — accent hue slider + preview

**Files:**
- Modify: `app/HDZap/Views/SettingsView.swift`

- [ ] **Step 1: Add AppStorage binding**

Alongside the other `@AppStorage` declarations:
```swift
@AppStorage("accentHue") private var accentHue: Double = EditorialTheme.defaultAccentHue
```

- [ ] **Step 2: Replace the `appearanceSection` stub**

Replace:
```swift
@ViewBuilder
private var appearanceSection: some View {
    EmptyView()
}
```

With:
```swift
private var appearanceSection: some View {
    Section {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Highlight color")
                Spacer()
                Text("\(Int(accentHue.rounded()))°")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $accentHue, in: 0...360, step: 1)
                .background(
                    LinearGradient(
                        colors: stride(from: 0.0, through: 360.0, by: 30.0).map {
                            EditorialTheme.accent(hue: $0)
                        },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .clipShape(.capsule)
                    .frame(height: 6)
                    .padding(.horizontal, 2)
                    .opacity(0.45)
                )
                .tint(EditorialTheme.accent(hue: accentHue))

            HStack(spacing: 12) {
                Circle()
                    .fill(EditorialTheme.accent(hue: accentHue))
                    .frame(width: 14, height: 14)
                Text("Best lap")
                    .foregroundStyle(EditorialTheme.accent(hue: accentHue))
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button("Reset") { accentHue = EditorialTheme.defaultAccentHue }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    } header: {
        Text("Appearance")
    } footer: {
        Text("Hue used for the live timer, best-lap marker, and split highlights.")
            .font(.caption2)
    }
}
```

- [ ] **Step 3: Verify build**

```sh
cd app && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual check**

Open settings → Appearance section → drag hue slider. Confirm:
- Hue degree label updates live.
- Preview circle + "Best lap" text change color in lockstep.
- Slider thumb tint also tracks.
- Close settings, return to TimerView: best-lap markers, summary band highlight, and progress dot all reflect the chosen hue.
- Re-open settings: chosen hue persists.
- Tap Reset: returns to legacy pink.

- [ ] **Step 5: Commit**

```sh
git add app/HDZap/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
ios: settings appearance section — accent hue slider

- 0..360° hue slider over an OKLCH gradient track (perceptually
  uniform lightness across the choice space).
- Live preview chip + "Best lap" sample text; Reset returns to the
  legacy pink.
- Persists via @AppStorage("accentHue"); applied in ContentView via
  .tint + accentHue environment.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Merge Bluetooth + Discovered Devices into one section

**Files:**
- Modify: `app/HDZap/Views/SettingsView.swift`

- [ ] **Step 1: Replace `bluetoothSection` body and delete `discoveredDevicesSection`**

Replace the existing `bluetoothSection` (formerly `bleStatusSection`) with:

```swift
private var bluetoothSection: some View {
    Section {
        HStack {
            Text("Status")
            Spacer()
            Circle()
                .fill(bluetooth.isConnected ? .green : .red)
                .frame(width: 10, height: 10)
            Text(bluetooth.isConnected ? "Connected" : "Disconnected")
                .foregroundStyle(.secondary)
        }

        if bluetooth.isConnected, let name = bluetooth.connectedDeviceName {
            HStack {
                Text("Device")
                Spacer()
                Text(name).foregroundStyle(.secondary)
            }
        }

        HStack(spacing: 12) {
            Button(bluetooth.isScanning ? "Scanning..." : "Scan") {
                bluetooth.startScan()
            }
            .disabled(bluetooth.isScanning)

            if bluetooth.isConnected {
                Button("Disconnect", role: .destructive) {
                    bluetooth.disconnect()
                }
            }
        }

        if bluetooth.discoveredDevices.isEmpty {
            Text("No devices found")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(bluetooth.discoveredDevices, id: \.identifier) { peripheral in
                HStack {
                    VStack(alignment: .leading) {
                        Text(peripheral.name ?? "Unknown")
                            .font(.body)
                        Text(peripheral.identifier.uuidString.prefix(8) + "...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") {
                        bluetooth.connect(peripheral)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    } header: {
        Text("Bluetooth")
    }
}
```

Delete the entire `private var discoveredDevicesSection: some View { ... }` accessor.

- [ ] **Step 2: Verify build**

```sh
cd app && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual check**

Settings → Bluetooth section now shows status, scan controls, AND discovered devices in one section. Tapping Scan still triggers scanning; discovered M5Sticks listed below; Connect still works.

- [ ] **Step 4: Commit**

```sh
git add app/HDZap/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
ios: settings — merge Bluetooth and Discovered Devices

- Status, scan/disconnect controls, and the discovered-devices list
  now live in a single section.
- Removes the awkward two-section split where the same hardware was
  surfaced twice.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Move + reformat Current UID section, merge Pairing + Status + TX, switch body order

**Files:**
- Modify: `app/HDZap/Views/SettingsView.swift`

This is the largest cosmetic-but-mechanical task. Doing it in one commit keeps the section-order switch atomic.

- [ ] **Step 1: Update `currentUIDSection` to decimal main + hex caption**

Replace the existing `currentUIDSection` body:

```swift
@ViewBuilder
private var currentUIDSection: some View {
    if let uid = bluetooth.currentUID {
        Section("Current UID") {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatUIDDecimal(uid))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text(formatUID(uid))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // One-tap rollback: only show when we have a stash AND it
            // differs from current UID (else Restore would be a no-op).
            if let prev = bluetooth.previousUID, prev != uid {
                Button {
                    if bluetooth.sendUIDConfig(mode: .manualUID(prev)) {
                        bluetooth.recordPreviousUID(nil)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restore previous goggle")
                        Text(formatUIDDecimal(prev))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(formatUID(prev))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Merge `pairingStatusSection` + `txSniffSection` into `pairingSection`**

Replace the existing `pairingSection` body. The new body is the old `gogglePairingSection` content (Picker + mode-specific input + Apply button) followed by the inlined pairing-status banner and the inlined TX UID Capture controls. Critically, **scope the conditional rendering so each only appears when relevant** — same predicates as today.

```swift
private var pairingSection: some View {
    Section {
        Picker("Mode", selection: $selectedMode) {
            Text("Bind Phrase").tag(UIDConfigMode.bindPhrase)
            Text("Manual UID").tag(UIDConfigMode.manualUID)
            Text("New Pairing").tag(UIDConfigMode.newPairing)
        }
        .pickerStyle(.segmented)

        switch selectedMode {
        case .bindPhrase:
            TextField("Bind phrase", text: $bindPhrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !bindPhrase.isEmpty {
                let uid = uidFromBindPhrase(bindPhrase)
                Text("UID: \(formatUID(uid))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .manualUID:
            TextField("60:D2:53:8A:B2:00 or 96 210 83 138 178 0", text: $manualUIDText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            Text("Hex matches the iOS/M5Stick display; decimal matches what HDZero goggles show.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !manualUIDText.isEmpty {
                switch parseUID(manualUIDText) {
                case .failure(let err):
                    Text(err.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                case .success(let raw):
                    let normalized = normalizeUID(raw)
                    let showParsed = !manualUIDText.contains(":") || normalized != raw
                    if showParsed {
                        let label = (normalized != raw) ? "Normalized" : "Parsed"
                        Text("\(label): \(formatUID(normalized))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .newPairing:
            Text("Put your goggle in bind mode (ELRS menu → Bind), then tap Pair below. The M5Stick will switch to a fresh pairing ID and broadcast it to the goggle in one step.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        switch selectedMode {
        case .bindPhrase, .manualUID:
            Button("Apply UID") { applyUID() }
                .disabled(!canApplyUID)
        case .newPairing:
            Button("Pair with new goggle") { applyUID() }
                .disabled(!bluetooth.isReady)
        }

        // Pairing status banner — only shown when a pairing flow is active.
        if pairingPhase != .idle {
            pairingStatusContent
        }

        // TX UID Capture — only when connected and supported.
        if bluetooth.isConnected && bluetooth.isTXSniffAvailable {
            Divider()
            txSniffContent
        }
    } header: {
        Text("Pairing")
    } footer: {
        VStack(alignment: .leading, spacing: 4) {
            Text("If your goggle's backpack was flashed with a fixed bind phrase via ELRS Configurator, that phrase always wins after a reboot — New Pairing won't stick.")
            Text("Use Bind Phrase mode with the same phrase that was flashed, or reflash the backpack with the new phrase.")
        }
        .font(.caption2)
    }
}
```

Now extract the two inline sub-views — `pairingStatusContent` and `txSniffContent`. Add these as helpers in `SettingsView`:

```swift
@ViewBuilder
private var pairingStatusContent: some View {
    switch pairingPhase {
    case .idle:
        EmptyView()
    case .applying:
        HStack(spacing: 8) {
            ProgressView()
            Text("Switching pairing… waiting for goggle to settle.")
        }
    case .verifying:
        HStack(spacing: 8) {
            ProgressView()
            Text("Verifying lap times can reach the goggle…")
        }
    case .success:
        Label("Pairing works — lap times will appear on this goggle.",
              systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    case .rolledBack:
        Label("Goggle didn't accept the new pairing. Restored the previous one.",
              systemImage: "arrow.uturn.backward.circle.fill")
            .foregroundStyle(.orange)
    case .failedNoRollback:
        Label("Goggle didn't accept the new pairing, and there was no previous pairing to fall back to.",
              systemImage: "xmark.circle.fill")
            .foregroundStyle(.red)
    case .verifyFailedSameUID:
        Label("Goggle didn't ack the verify packet, but the pairing on the M5Stick is unchanged — try again, or move closer to the goggle.",
              systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    case .timedOut:
        let restoreVisible = bluetooth.currentUID != nil
            && bluetooth.previousUID != nil
            && bluetooth.previousUID != bluetooth.currentUID
        let restoreHint = restoreVisible
            ? " — try again, or use Restore previous goggle."
            : " — try again."
        Label("No verification result. The M5Stick may be disconnected\(restoreHint)",
              systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }
}

@ViewBuilder
private var txSniffContent: some View {
    Text("TX UID Capture")
        .monoCap(size: 11, tracking: 1.4)

    if bluetooth.isTXSniffActive {
        HStack(spacing: 8) {
            ProgressView()
            Text("Waiting for TX bind packet…")
                .foregroundStyle(.secondary)
        }
        Button("Stop", role: .destructive) {
            _ = bluetooth.stopTXSniff()
        }
    } else {
        Button("Start TX UID Capture") {
            bluetooth.clearCapturedTXUID()
            _ = bluetooth.startTXSniff()
        }
    }

    if let uid = bluetooth.capturedTXUID {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Captured TX UID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatUIDDecimal(uid))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text(formatUID(uid))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Apply") {
                bluetooth.recordPreviousUID(bluetooth.currentUID)
                _ = bluetooth.sendUIDConfig(mode: .manualUID(uid))
                _ = bluetooth.stopTXSniff()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    Text("Press Bind on the TX to broadcast its UID. The TX's existing goggle binding is unaffected.")
        .font(.caption2)
        .foregroundStyle(.secondary)
}
```

Delete the now-unused `pairingStatusSection` and `txSniffSection` accessors entirely.

- [ ] **Step 3: Switch the `body` to the final section order**

Inside `var body`, replace the `List { ... }` content with:

```swift
List {
    errorSection
    raceSection
    appearanceSection
    bluetoothSection
    currentUIDSection
    pairingSection
    osdTestSection
}
```

(All other modifiers — `.navigationTitle`, `.toolbar`, `.onAppear`, `.alert` — stay as-is.)

- [ ] **Step 4: Verify build**

```sh
cd app && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual check**

Run in simulator + connect to physical M5Stick (BLE requires real device for full check; simulator covers layout):

- Section order: Error (if active) / Race / Appearance / Bluetooth / Current UID / Pairing / Debug.
- Current UID: shows decimal `96,210,83,138,178,0` as the headline, hex `60:D2:53:8A:B2:00` as small caption.
- Pairing section: Mode picker → Apply → status banner appears in the same section after Apply (no jump to a different section).
- TX UID Capture: appears at the bottom of Pairing only when connected; "Captured TX UID" row shows decimal main + hex caption.
- Restore previous goggle button (when applicable): decimal main + hex caption.

- [ ] **Step 6: Commit**

```sh
git add app/HDZap/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
ios: settings layout reconstruction

- Section order: Error / Race / Appearance / Bluetooth / Current UID
  / Pairing / Debug.
- Current UID moves above Pairing; renders decimal (M5Stick format)
  as the headline with hex as a small caption. Restore-previous
  button uses the same dual format.
- Pairing section absorbs the pairing-status banner and the TX UID
  Capture controls so the whole pairing flow lives in one section.
- TX UID Capture's Captured row also uses decimal main + hex caption.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Final verification

**Files:** none.

- [ ] **Step 1: Run on simulator + verify everything**

```sh
cd app && xcodegen generate && xcodebuild -scheme HDZap -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Open the resulting app in the simulator.

Walkthrough:
1. **Race time**: Settings → Race → bump to 120s → close. TimerView's session bar fills slower (120s window). Best-lap pacing target updates accordingly.
2. **Accent hue**: Settings → Appearance → drag hue slider to ~120° (green). Best lap, progress dot, primary button tint, summary highlight all rotate to green. Reset → returns to default pink (~356°).
3. **Current UID**: Settings → Current UID is above Pairing. Decimal main, hex caption. Restore-previous button (if a stash exists) shows same dual format.
4. **Pairing flow**: Apply a (test-safe) UID → status banner appears in the SAME section right below Apply. No section jump.
5. **TX UID Capture** (requires hardware): inside Pairing section, captured UID row shows decimal main + hex caption.
6. **Bluetooth**: status, scan/disconnect, and discovered-devices list all in one section.
7. **Persistence**: kill app → relaunch → race time + accent hue both persist.

- [ ] **Step 2: Final repo state check**

```sh
git log --oneline main.. | head -20
rg -n 'EditorialTheme\.sessionLimit|EditorialTheme\.accent\b(?!\()' app/HDZap/ || echo "OK — no stale references"
```
Expected: linear commit history (one commit per task above), no stale `EditorialTheme.sessionLimit` or bare `EditorialTheme.accent` references (only `EditorialTheme.accent(hue:)` function calls).

- [ ] **Step 3: Push when user approves**

(Out of scope for the plan — wait for the user's "ship it" before pushing or PRing.)

---

## Self-review notes

**Spec coverage:**
- Race time configurable → Tasks 3, 5, 7, 10
- Accent hue configurable (OKLCH) → Tasks 2, 4, 5, 6, 7, 11
- UID decimal display → Tasks 1, 13
- Section reorganization (Race/Appearance/Bluetooth-merged/UID/Pairing-merged/Debug) → Tasks 9, 12, 13
- ConnectionView → SettingsView rename → Task 8
- Section moves only relabel/regroup (no BLE flow refactor) → preserved across all tasks
- AppStorage default registration → Task 5

**Type consistency:**
- `RaceMetrics.targetLapSeconds(for:sessionLimit:)` — used in Tasks 3, 7, 10 with consistent label
- `RaceMetrics(laps:targetLapCount:sessionLimit:paceOverride:)` — used in Task 7 only
- `EditorialTheme.accent(hue:)` and `EnvironmentValues.accentHue` — defined in Task 4, consumed in Tasks 6, 7, 11
- `formatUIDDecimal(_:)` — defined Task 1, consumed Task 13
- `oklchColor(L:C:H:)` — defined Task 2, consumed Task 4 (transitively)

**Placeholder scan:** none.
