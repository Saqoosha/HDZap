import SwiftUI

/// Color + font tokens for the Editorial Console design.
/// Matches the prototype palette: warm paper background, ink-black text,
/// hairline rules at 10% ink, accent pink for live state and best-lap markers.
enum EditorialTheme {
    static let paper = Color(red: 247.0 / 255, green: 245.0 / 255, blue: 238.0 / 255)
    static let ink = Color(red: 21.0 / 255, green: 20.0 / 255, blue: 15.0 / 255)
    // Derived from `ink` so the relationship "every text/rule on this canvas
    // is the same hue at decreasing opacity" stays mechanical — change ink
    // and the rest follow.
    static let sub = ink.opacity(0.55)
    static let dim = ink.opacity(0.32)
    static let hair = ink.opacity(0.10)
    static let hairStrong = ink.opacity(0.18)
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

/// Uppercase, tracked, monospaced micro-label used as section markers and
/// metric captions throughout the editorial canvas.
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

/// Time-string formatters tuned for the editorial layout: tabular-numeric
/// monospace, fixed widths, truncated (not rounded) so a lap displayed at
/// `00:05.99` never momentarily reads `00:06.00` before the timer ticks.
enum EditorialFormat {
    /// `MM:SS.fff` (or fewer ms digits). `msDigits` is clamped to 1...3 — 0
    /// produces a dangling `.`, anything above 3 is meaningless given the
    /// underlying integer-millisecond resolution.
    static func time(_ interval: TimeInterval, msDigits: Int = 2, showMs: Bool = true) -> String {
        let totalMs = max(0, Int((interval * 1000).rounded(.down)))
        let m = totalMs / 60_000
        let s = (totalMs % 60_000) / 1000
        let f = totalMs % 1000
        let mm = String(format: "%02d", m)
        let ss = String(format: "%02d", s)
        if !showMs { return "\(mm):\(ss)" }
        let clamped = min(3, max(1, msDigits))
        let fStr = String(format: "%03d", f).prefix(clamped)
        return "\(mm):\(ss).\(fStr)"
    }

    /// `S.cc` (seconds + centiseconds, no minutes). Truncated, not rounded.
    /// Used in the summary band where Best/Avg are always well under a minute
    /// in normal use; if a lap exceeds 60s the seconds field just keeps
    /// counting (`74.32`) instead of wrapping into a non-existent minutes field.
    static func timeShort(_ interval: TimeInterval) -> String {
        let totalMs = max(0, Int((interval * 1000).rounded(.down)))
        let s = totalMs / 1000
        let cs = (totalMs % 1000) / 10
        return String(format: "%d.%02d", s, cs)
    }

    /// Signed `±S.cc` against best lap. Argument is in *seconds* (TimeInterval).
    /// Uses U+2212 minus, not the ASCII hyphen, for typographic consistency
    /// with the rest of the editorial layout.
    static func delta(_ seconds: TimeInterval) -> String {
        let sign = seconds >= 0 ? "+" : "−"
        let abs = Swift.abs(seconds)
        if abs < 1.0 {
            let cents = Int((abs * 1000).rounded(.down))
            return String(format: "%@0.%02d", sign, cents / 10)
        }
        let s = Int(abs.rounded(.down))
        let cents = Int(((abs - TimeInterval(s)) * 100).rounded(.down))
        return String(format: "%@%d.%02d", sign, s, cents)
    }
}
