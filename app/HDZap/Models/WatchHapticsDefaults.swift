import Foundation

/// `@AppStorage` key + default for the Apple Watch countdown-haptics
/// toggle. Centralized so SettingsView (the editor) and WatchBridge
/// (the consumer mirroring it into RaceSnapshot.hapticsEnabled) can't
/// disagree on the storage key — a typo would silently fork the
/// preference into a parallel slot.
enum WatchHapticsDefaults {
    static let enabledKey = "watchHapticsEnabled"
    /// Off by default. Toggling on triggers the watch's HealthKit
    /// authorization prompt, which we don't want to surface for users
    /// who never asked for the feature.
    static let defaultEnabled = false
}
