import Foundation

/// Build-time-injected secrets that ship with the binary. **Render before building**:
///
///     cd app && op inject -i HDZap/Models/Speech/BuildSecrets.swift.tpl -o HDZap/Models/Speech/BuildSecrets.swift
///
/// The rendered `BuildSecrets.swift` is gitignored — never commit the resolved file.
///
/// The Worker has two auth tiers: an Apple-signed JWS (subscribers, verified against Apple
/// Root CA G3 in `workers/hdzap-premium/src/appleJws.ts`) and this baked-in dev bearer
/// (free preview path, used for voice auditions before a purchase). Only the preview path
/// touches this value at runtime — the moment `SubscriptionManager.currentJWS` is non-nil
/// the synth ships the JWS instead.
enum BuildSecrets {
    /// Bearer the Worker accepts on the fallback (non-JWS) path. The preview surface in
    /// the paywall + dev panel sends this; entitled subscribers send their JWS instead.
    static let workerBearer = "{{ op://Personal/HDZap Worker Dev Bearer/credential }}"
}
