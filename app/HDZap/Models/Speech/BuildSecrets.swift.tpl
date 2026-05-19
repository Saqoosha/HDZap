import Foundation

/// Build-time-injected secrets that ship with the binary. **Render before building**:
///
///     cd app && op inject -i HDZap/Models/Speech/BuildSecrets.swift.tpl -o HDZap/Models/Speech/BuildSecrets.swift
///
/// The rendered `BuildSecrets.swift` is gitignored — never commit the resolved file. The
/// stub at the bottom (`#if !BUILD_SECRETS_RENDERED`) is a compile guard so a fresh checkout
/// fails fast with a clear message instead of silently shipping an empty bearer.
///
/// Long-term plan: replace this baked-in bearer with per-user JWS verification in the
/// Worker (see [`workers/hdzap-premium/src/index.ts`](../../../../workers/hdzap-premium/src/index.ts)
/// for the planned `verifyAppleJws` hook). Until that lands, every subscriber ships with
/// the same dev bearer — fine for TestFlight, not fine for App Store release.
enum BuildSecrets {
    /// Bearer the Worker validates via `Authorization: Bearer <value>`. Currently the Worker
    /// gates `/tts` on a single shared dev bearer; once JWS verification is in place this
    /// becomes irrelevant (the StoreKit JWS replaces it on the wire).
    static let workerBearer = "{{ op://Personal/HDZap Worker Dev Bearer/credential }}"
}
