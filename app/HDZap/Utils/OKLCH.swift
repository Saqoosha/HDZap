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
    // Reject non-finite inputs and clamp L to [0, 1] before the
    // pipeline. A NaN H would propagate through cos/sin to NaN
    // channels, which SwiftUI then renders as solid black with no
    // diagnostic — better to fail loud in DEBUG and fall back to
    // mid-gray in release.
    guard L.isFinite, C.isFinite, H.isFinite else {
        assertionFailure("oklchToSRGB given non-finite input L=\(L) C=\(C) H=\(H)")
        return (0.5, 0.5, 0.5)
    }
    let L = min(1, max(0, L))
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
/// be near 356°. Fires once on first reference in DEBUG.
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
