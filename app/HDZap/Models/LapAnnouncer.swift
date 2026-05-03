import AVFoundation
import Foundation
import UIKit
import os

/// Subsystem-scoped logger so messages reach the unified logging system
/// (`log stream`, Console.app, `idevicesyslog`) instead of `print()`'s
/// stdout/stderr — which only the attached debugger sees on iOS.
private let log = Logger(subsystem: "sh.saqoo.HDZap", category: "LapAnnouncer")

/// UserDefaults keys + defaults shared between LapAnnouncer (the consumer)
/// and SettingsView (the editor). Centralized so a typo in one site can't
/// silently disconnect the two — both reach for the same constants.
enum LapAnnouncerDefaults {
    static let enabledKey = "lapTTSEnabled"
    static let languageKey = "lapTTSLanguage"
    static let voiceIdentifierKey = "lapTTSVoiceIdentifier"
    static let rateKey = "lapTTSRate"
    static let pitchKey = "lapTTSPitch"
    static let announceBestKey = "lapTTSAnnounceBest"

    /// Mirrors `AVSpeechUtteranceDefaultSpeechRate` (iOS 18 = 0.5). Hardcoded
    /// so SettingsView and HDZapApp can register and bind the default
    /// without transitively importing AVFoundation; debug-asserted at
    /// `LapAnnouncer.init` so the next SDK that retunes the constant trips
    /// a precondition rather than silently drifting.
    static let defaultRate: Float = 0.5
    static let defaultPitch: Float = 1.0
    /// Empirical bounds verified on iOS 18 with the system fallback voices
    /// (Samantha en-US, Kyoko Enhanced ja-JP): below 0.30 the voice trails
    /// into incomprehensible mush; above 0.65 the engine chops sub-second
    /// decimals together. Re-test if Apple retunes the rate curve (changed
    /// materially between iOS 13 and 16).
    static let minRate: Float = 0.3
    static let maxRate: Float = 0.65
    static let minPitch: Float = 0.75
    static let maxPitch: Float = 1.5

    /// Resolved at app launch from `Locale.current` — Japanese users get JP
    /// announcements out of the box, everyone else falls back to English.
    /// Stored as the language's raw value so it can be passed straight to
    /// `UserDefaults.register(defaults:)`.
    static var defaultLanguageRaw: String {
        LapAnnouncerLanguage.systemDefault.rawValue
    }
}

/// Language used for both the announcement phrase and the voice picker
/// filter. The picker only shows voices that match the selected language —
/// asking a Japanese voice to read "Lap 5" produces unintelligible output,
/// so they're kept apart by construction.
enum LapAnnouncerLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    /// `LocalizedStringResource` (not `String`) so the SwiftUI picker label
    /// goes through the catalog. A plain `String` here would dispatch to
    /// `Text(_ content: String)`, which skips localization — leaving the
    /// xcstrings entry as dead code.
    var displayName: LocalizedStringResource {
        switch self {
        case .english: return "English"
        case .japanese: return "Japanese"
        }
    }

    /// Prefix used to filter `AVSpeechSynthesisVoice.speechVoices()`.
    /// Apple uses BCP-47 like `en-US`, `en-GB`, `ja-JP` — the two-letter
    /// language tag is the common stem.
    var voiceLanguagePrefix: String { rawValue }

    /// Voice tag used when no per-language voice has been picked yet.
    /// `AVSpeechSynthesisVoice(language:)` resolves this to the system's
    /// preferred voice for that locale.
    var fallbackVoiceLanguage: String {
        switch self {
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        }
    }

    /// Picks the announcement language from the system locale on first
    /// launch. Anything that isn't an explicit Japanese device defaults to
    /// English — the announcement text needs to match the chosen voice and
    /// adding a third language is a follow-up, not a silent fallback.
    /// Read once at first launch via `register(defaults:)`; the operator
    /// can override (or switch back) via Settings → Audio → Language.
    static var systemDefault: LapAnnouncerLanguage {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return lang == "ja" ? .japanese : .english
    }
}

/// Speaks lap times through the device speaker so the operator gets audio
/// confirmation without looking at the phone. Wraps AVSpeechSynthesizer +
/// AVAudioSession; activation is deferred until the first announcement so
/// the audio session isn't disturbed for users who never enable TTS.
///
/// SettingsView is the writer for voice / rate / pitch / language; this
/// class is the reader. Both reach for the same `LapAnnouncerDefaults.*`
/// keys, and every setting is read fresh inside `speak()` so Settings
/// edits apply on the next lap with no explicit wiring.
@MainActor
@Observable
final class LapAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// True only after `setCategory` *and* `setActive(true)` succeed —
    /// either failure leaves the flag false so the next utterance retries
    /// instead of silently never reactivating.
    private var sessionConfigured = false

    /// Set when AVAudioSession activation throws so the UI can show a
    /// banner like "Audio unavailable — announcements muted". Cleared on
    /// the next successful activation. Race operator with the phone in a
    /// chest pocket can't see Console.app, so silent log-only failure
    /// would defeat the whole point of audio confirmation.
    private(set) var lastAudioError: String?

    override init() {
        super.init()
        synthesizer.delegate = self
        // Tripwire for `defaultRate` drifting away from
        // `AVSpeechUtteranceDefaultSpeechRate` in a future SDK.
        assert(LapAnnouncerDefaults.defaultRate == AVSpeechUtteranceDefaultSpeechRate,
               "LapAnnouncerDefaults.defaultRate (\(LapAnnouncerDefaults.defaultRate)) drifted from AVSpeechUtteranceDefaultSpeechRate (\(AVSpeechUtteranceDefaultSpeechRate)) — re-verify and update.")
        // Voice dump runs off the main actor so app launch isn't blocked
        // by `speechVoices()` on a device with hundreds of installed voices.
        Task.detached(priority: .background) {
            LapAnnouncerVoiceCatalog.dumpInstalledVoicesOnce()
        }
    }

    func announceLap(_ lap: Lap, isBest: Bool) {
        let announceBest = UserDefaults.standard.object(forKey: LapAnnouncerDefaults.announceBestKey) as? Bool ?? true
        speak(phrase(for: lap, isBest: isBest && announceBest))
    }

    /// Used by the Settings "Test voice" button so the user can preview the
    /// current voice/rate/pitch combo and confirm the phone isn't muted
    /// before relying on it during a race. Always passes `isBest: true` so
    /// the preview exercises every phrase piece (lap number, time, best-lap
    /// suffix) — independent of the `announceBest` toggle.
    func announceTest() {
        let sample = Lap(id: 3, time: 12.34)
        speak(phrase(for: sample, isBest: true))
    }

    /// Drops any in-flight or queued speech.
    func cancel() {
        let stopped = synthesizer.stopSpeaking(at: .immediate)
        if !stopped {
            // `false` from `stopSpeaking` means "no utterance was speaking"
            // — benign during RESET, but logged so an unexpected failure
            // (e.g. synth in stuck state) surfaces in Console.
            log.debug("stopSpeaking returned false (no utterance to stop)")
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    /// Deactivate the audio session as soon as the utterance ends so other
    /// apps' audio fully un-ducks instead of staying suppressed for the
    /// rest of the app's lifetime. `.notifyOthersOnDeactivation` cues
    /// background-audio apps to ramp back up promptly.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.deactivateSession() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.deactivateSession() }
    }

    // MARK: - Internals

    private func speak(_ phrase: String) {
        configureSessionIfNeeded()
        // Drop the previous utterance: if laps fire faster than the synth
        // can speak, the operator wants the latest time, not a backlog
        // running seconds behind the actual race.
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = currentVoice()
        utterance.rate = currentRate()
        utterance.pitchMultiplier = currentPitch()
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    /// `.duckOthers` lets the operator's racing playlist keep playing — it
    /// just dips during each announcement. `.playback` (vs `.ambient`) means
    /// announcements still play when the ringer switch is set to silent,
    /// which matters because the phone is often in a chest pocket / on a
    /// table during a race and the operator can't reach the switch.
    /// `.spokenAudio` mode signals "this is speech, not music" so iOS keeps
    /// Bluetooth devices from staying ducked between announcements.
    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
            sessionConfigured = true
            lastAudioError = nil
        } catch {
            // Don't latch sessionConfigured = true — the next utterance
            // should retry. Most likely cause: another app holds an
            // exclusive audio category (Voice Memos recording, active
            // call). A race operator can't read Console.app from their
            // pocket, so we also surface the error to the UI via
            // `lastAudioError` and fire a haptic so they know audio
            // didn't take.
            log.error("AVAudioSession activation failed: \(error.localizedDescription, privacy: .public)")
            lastAudioError = "Audio unavailable: \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func deactivateSession() {
        guard sessionConfigured else { return }
        // A new utterance can land between `didCancel` / `didFinish` being
        // queued (off-main) and this Task running on the main actor. If the
        // synth is mid-speech, deactivating now would cut audio off — let
        // the next `didFinish` / `didCancel` retry instead.
        guard !synthesizer.isSpeaking else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            sessionConfigured = false
        } catch {
            log.error("AVAudioSession deactivation failed: \(error.localizedDescription, privacy: .public)")
            // Reset to false so the next utterance reruns the full
            // `setCategory` + `setActive(true)` path. A redundant reactivate
            // is microseconds; a stuck `sessionConfigured = true` would
            // silently disable TTS without re-logging in
            // `configureSessionIfNeeded`.
            sessionConfigured = false
        }
    }

    private func currentLanguage() -> LapAnnouncerLanguage {
        let raw = UserDefaults.standard.string(forKey: LapAnnouncerDefaults.languageKey)
            ?? LapAnnouncerDefaults.defaultLanguageRaw
        guard let language = LapAnnouncerLanguage(rawValue: raw) else {
            log.error("Unknown lap TTS language raw value '\(raw, privacy: .public)'; defaulting to English.")
            return .english
        }
        return language
    }

    private func currentVoice() -> AVSpeechSynthesisVoice? {
        let language = currentLanguage()
        let id = UserDefaults.standard.string(forKey: LapAnnouncerDefaults.voiceIdentifierKey) ?? ""

        // Honor the saved voice only if it matches the current announcement
        // language. Without this check, switching language would happily
        // hand a `ja-JP` phrase to an `en-US` voice (or vice versa) and the
        // engine would mispronounce numerals into nonsense.
        if !id.isEmpty {
            if let voice = AVSpeechSynthesisVoice(identifier: id) {
                if voice.language.hasPrefix(language.voiceLanguagePrefix) {
                    return voice
                }
                // Voice exists but is the wrong language. SettingsView's
                // `onChange(of: ttsLanguageRaw)` clears `voiceIdentifier`
                // when the user switches in-app, but a Shortcuts / MDM /
                // iCloud-sync write or an iOS region change can leave a
                // mismatched id. Log so the silent quality drop is
                // observable in `log stream`.
                log.info("Saved voice '\(id, privacy: .public)' is \(voice.language, privacy: .public); announcement language is \(language.fallbackVoiceLanguage, privacy: .public). Using system default for the announcement language.")
            } else {
                // Saved identifier no longer resolves: voice was uninstalled
                // or the device was restored to a phone that doesn't have
                // it. SettingsView's `voiceMissing` banner covers the UX,
                // but log so the issue shows up in `log stream` output too.
                log.info("Saved voice '\(id, privacy: .public)' no longer installed; using system default for \(language.fallbackVoiceLanguage, privacy: .public).")
            }
        }
        return AVSpeechSynthesisVoice(language: language.fallbackVoiceLanguage)
    }

    private func currentRate() -> Float {
        // `@AppStorage` stores Double; `AVSpeechUtterance.rate` is Float.
        // Use `object(forKey:) as? Double` (matching `announceBest`) so a
        // missing key falls back to the registered default rather than the
        // default-initialized `0.0` that `double(forKey:)` returns.
        let raw = UserDefaults.standard.object(forKey: LapAnnouncerDefaults.rateKey) as? Double
        let value = raw.map(Float.init) ?? LapAnnouncerDefaults.defaultRate
        return min(LapAnnouncerDefaults.maxRate, max(LapAnnouncerDefaults.minRate, value))
    }

    private func currentPitch() -> Float {
        let raw = UserDefaults.standard.object(forKey: LapAnnouncerDefaults.pitchKey) as? Double
        let value = raw.map(Float.init) ?? LapAnnouncerDefaults.defaultPitch
        return min(LapAnnouncerDefaults.maxPitch, max(LapAnnouncerDefaults.minPitch, value))
    }

    private func phrase(for lap: Lap, isBest: Bool) -> String {
        // Two decimals matches what most pilots can act on — milliseconds
        // are too granular to parse by ear in the half-second the operator
        // has between laps. AVSpeechSynthesizer reads "12.34" naturally as
        // "twelve point three four" (en) / "12てん34" (ja).
        let timeStr = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"),
                             max(0, lap.time))
        switch currentLanguage() {
        case .english:
            return isBest
                ? "Lap \(lap.id), \(timeStr), best lap"
                : "Lap \(lap.id), \(timeStr)"
        case .japanese:
            // Idiomatic FPV-racing phrasing in Japanese: "ラップN" matches
            // the on-screen counter, "ベストラップ" is the standard call for
            // a new fastest lap on circuit race broadcasts.
            return isBest
                ? "ラップ\(lap.id)、\(timeStr)、ベストラップ"
                : "ラップ\(lap.id)、\(timeStr)"
        }
    }
}

/// Catalogs the installed speech voices so SettingsView can render a Picker.
/// Filtered to the selected announcement language because asking a voice to
/// read text in the wrong language ("Lap 5, 12.34" through a `ja-JP` voice,
/// or vice versa) produces unintelligible output.
///
/// Deliberately not `@MainActor` so `dumpInstalledVoicesOnce()` can run on a
/// background detached task without hopping back to main — `speechVoices()`
/// is the bulk of the work and doesn't need the main thread.
enum LapAnnouncerVoiceCatalog {
    /// Voice quality tier. Sort order matches the integer raw value (lower =
    /// higher quality) so the Picker shows Premium first. The compact base
    /// voices land in `.standard`, the downloadable Enhanced bundles in
    /// `.enhanced`, the high-quality neural bundles (when Apple exposes
    /// them to third-party apps for that locale) in `.premium`.
    ///
    /// Note: the "Siri Voice 1/2" bundles in iOS Settings → Accessibility →
    /// Spoken Content → Voices are **not** the same as `.premium`. Apple
    /// intentionally locks those Siri-shared bundles out of
    /// `AVSpeechSynthesizer` for third-party apps to prevent Siri
    /// impersonation; if a Siri voice is selected via identifier, the
    /// system silently substitutes a fallback at synthesis time.
    /// (Source: Apple Developer Forums #682438.)
    enum Quality: Int, Comparable {
        case premium = 0
        case enhanced = 1
        case standard = 2

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        init(_ quality: AVSpeechSynthesisVoiceQuality) {
            switch quality {
            case .premium: self = .premium
            case .enhanced: self = .enhanced
            case .default: self = .standard
            // `@unknown default` so a future SDK that adds, say, `.neural`
            // emits a build warning instead of silently bucketing a top-tier
            // voice into `.standard` and ranking it at the bottom.
            @unknown default: self = .standard
            }
        }

        var displayTag: String {
            switch self {
            case .premium: return ", Premium"
            case .enhanced: return ", Enhanced"
            case .standard: return ""
            }
        }
    }

    struct Entry: Identifiable, Hashable {
        /// Empty string is a sentinel meaning "use the system default voice
        /// for the current language" — the picker uses it for the implicit
        /// "System default" row.
        let id: String
        let displayName: String
        let language: String
        let quality: Quality
    }

    /// Lists installed voices for `language`, sorted Premium → Enhanced →
    /// Default, then alphabetically by name. The picker also exposes a
    /// "System default" entry for `id == ""`, so this list can be empty
    /// without breaking selection.
    static func availableVoices(for language: LapAnnouncerLanguage) -> [Entry] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language.voiceLanguagePrefix) }
            .map { v in
                let quality = Quality(v.quality)
                return Entry(
                    id: v.identifier,
                    displayName: "\(v.name) (\(v.language)\(quality.displayTag))",
                    language: v.language,
                    quality: quality
                )
            }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.displayName < rhs.displayName
            }
    }

    /// Re-dumps the installed-voice list to the unified log when the set of
    /// identifiers changes (initial population, voice install, voice
    /// uninstall). Cheap; only fires on diff. Called from `LapAnnouncer.init`
    /// at startup. Also handy when a support report says "Kyoko Enhanced is
    /// selected but sounds like the compact voice" — cross-reference the log
    /// against the actual `speechVoices()` state at that moment.
    ///
    /// `nonisolated(unsafe)` because the catalog isn't `@MainActor`. In
    /// practice the function is invoked from `LapAnnouncer.init`'s
    /// background `Task.detached` once per launch and from the main-actor
    /// SettingsView body when Audio settings render — never concurrently —
    /// so the unsynchronized read/write doesn't actually race. Marking it
    /// explicitly silences the Swift 6 warning and documents the intent.
    nonisolated(unsafe) private static var lastDumpedVoiceIds: Set<String> = []
    static func dumpInstalledVoicesOnce() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let ids = Set(voices.map(\.identifier))
        guard ids != lastDumpedVoiceIds else { return }
        lastDumpedVoiceIds = ids
        log.info("speechVoices() returned \(voices.count, privacy: .public) voices")
        for v in voices {
            log.info("  \(v.language, privacy: .public) \(v.name, privacy: .public) [\(v.identifier, privacy: .public)] quality=\(v.quality.rawValue, privacy: .public)")
        }
    }
}
