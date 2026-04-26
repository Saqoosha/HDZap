import SwiftUI

/// Color + font tokens for the Editorial Console design.
/// Matches the prototype palette: warm paper background, ink-black text,
/// hairline rules at 10% ink, accent pink for live state and best-lap markers.
enum EditorialTheme {
    static let paper = Color(red: 247.0 / 255, green: 245.0 / 255, blue: 238.0 / 255)
    static let ink = Color(red: 21.0 / 255, green: 20.0 / 255, blue: 15.0 / 255)
    static let sub = Color(red: 21.0 / 255, green: 20.0 / 255, blue: 15.0 / 255).opacity(0.55)
    static let dim = Color(red: 21.0 / 255, green: 20.0 / 255, blue: 15.0 / 255).opacity(0.32)
    static let hair = Color(red: 21.0 / 255, green: 20.0 / 255, blue: 15.0 / 255).opacity(0.10)
    static let hairStrong = Color(red: 21.0 / 255, green: 20.0 / 255, blue: 15.0 / 255).opacity(0.18)
    static let accent = Color(red: 0xdb / 255.0, green: 0x65 / 255.0, blue: 0xa9 / 255.0)

    /// Time-attack window. Final lap is the one in flight when this elapses.
    static let sessionLimit: TimeInterval = 90
}

extension Font {
    /// JetBrains Mono substitute — SF Mono via `.monospaced`.
    static func editorialMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Space Grotesk substitute for the hero timer — SF Rounded.
    static func editorialDisplay(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Mono-cap label modifier — uppercase tracking for masthead, headers, summary labels.
struct MonoCapLabel: ViewModifier {
    let size: CGFloat
    let tracking: CGFloat
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(.editorialMono(size, weight: .regular))
            .tracking(tracking)
            .foregroundStyle(color)
            .textCase(.uppercase)
    }
}

extension View {
    func monoCap(size: CGFloat, tracking: CGFloat = 1.6, color: Color = EditorialTheme.sub) -> some View {
        modifier(MonoCapLabel(size: size, tracking: tracking, color: color))
    }
}

/// `formatTime(elapsed, msDigits: 2)` etc., matching the prototype.
enum EditorialFormat {
    static func time(_ interval: TimeInterval, msDigits: Int = 2, showMs: Bool = true) -> String {
        let totalMs = max(0, Int((interval * 1000).rounded(.down)))
        let m = totalMs / 60_000
        let s = (totalMs % 60_000) / 1000
        let f = totalMs % 1000
        let mm = String(format: "%02d", m)
        let ss = String(format: "%02d", s)
        if !showMs { return "\(mm):\(ss)" }
        let fStr = String(format: "%03d", f).prefix(msDigits)
        return "\(mm):\(ss).\(fStr)"
    }

    /// `S.MM` form (no minutes) for compact summary cells where laps are
    /// always sub-minute. Sub-second pads to e.g. `0.92`.
    static func timeShort(_ interval: TimeInterval) -> String {
        let totalMs = max(0, Int((interval * 1000).rounded(.down)))
        let s = totalMs / 1000
        let cs = (totalMs % 1000) / 10
        return String(format: "%d.%02d", s, cs)
    }

    static func delta(_ ms: TimeInterval) -> String {
        let sign = ms >= 0 ? "+" : "−"
        let abs = Swift.abs(ms)
        if abs < 1.0 {
            let cents = Int((abs * 1000).rounded(.down))
            return String(format: "%@0.%02d", sign, cents / 10)
        }
        let s = Int(abs.rounded(.down))
        let cents = Int(((abs - TimeInterval(s)) * 100).rounded(.down))
        return String(format: "%@%d.%02d", sign, s, cents)
    }
}
