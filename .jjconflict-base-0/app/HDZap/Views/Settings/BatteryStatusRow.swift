import SwiftUI

/// Battery dot + caption used by ConnectionSettingsView. Charging
/// overrides the alarm tier so the cyan dot appears the moment the
/// stick is plugged in, regardless of the percent at that moment. When
/// not charging, the color is driven entirely by the firmware-decided
/// `batteryAlarm` tier so a future tweak to the firmware thresholds
/// doesn't require a matching change here. Stroke (vs. fill) signals
/// the firmware hasn't yet pushed a battery frame — older firmware
/// without `batteryUUID`, or the sub-second window between connect and
/// the first notify.
struct BatteryStatusRow: View {
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        HStack {
            batteryDot
            VStack(alignment: .leading) {
                Text("Battery").font(.body)
                Text(batteryCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var batteryDot: some View {
        if bluetooth.batteryPercent == nil {
            Circle().stroke(.secondary, lineWidth: 1).frame(width: 10, height: 10)
        } else {
            Circle().fill(batteryDotColor).frame(width: 10, height: 10)
        }
    }

    private var batteryDotColor: Color {
        if bluetooth.isCharging { return .cyan }
        switch bluetooth.batteryAlarm {
        case .critical: return .red
        case .low: return .orange
        case .none: return .green
        }
    }

    private var batteryCaption: String {
        guard let raw = bluetooth.batteryPercent else { return "—" }
        // Cast UInt8 → Int so the catalog-lookup key uses %lld. Without
        // the cast, Foundation's LocalizationValue picks %u for UInt8,
        // which never hits the %lld%%-keyed JP entries — every caption
        // would silently fall back to English on a JP device.
        let pct = Int(raw)
        if bluetooth.isCharging { return String(localized: "\(pct)% · Charging") }
        switch bluetooth.batteryAlarm {
        case .critical(let silenced):
            return silenced
                ? String(localized: "\(pct)% · Critical (silenced)")
                : String(localized: "\(pct)% · Critical — press button on device to silence")
        case .low(let silenced):
            return silenced
                ? String(localized: "\(pct)% · Low (silenced)")
                : String(localized: "\(pct)% · Low — press button on device to silence")
        case .none:
            return String(localized: "\(pct)%")
        }
    }
}
