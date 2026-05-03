import AVFoundation
import Foundation

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

    /// `0.5` is the value of `AVSpeechUtteranceDefaultSpeechRate` (iOS 18).
    /// Hardcoded so HDZapApp and SettingsView can register and bind the
    /// default without transitively importing AVFoundation. Re-verify if
    /// Apple changes the constant in a future SDK.
    static let defaultRate: Float = 0.5
    static let defaultPitch: Float = 1.0
    /// Empirical bounds on iOS 18 with Siri Voice 2 (en-US/ja-JP):
    /// below 0.30 the voice trails into incomprehensible mush; above 0.65
    /// the engine chops sub-second decimals together. Re-test if Apple
    /// retunes the rate curve (changed materially between iOS 13 and 16).
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

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func announceLap(_ lap: Lap, isBest: Bool) {
        let announceBest = UserDefaults.standard.object(forKey: LapAnnouncerDefaults.announceBestKey) as? Bool ?? true
        speak(phrase(for: lap, isBest: isBest && announceBest))
    }

    /// Used by the Settings "Test voice" button so the user can preview the
    /// current voice/rate/pitch combo and confirm the phone isn't muted
    /// before relying on it during a race. Uses lap 3 + 12.34s + best so all
    /// three phrase pieces (lap number, time, best-lap suffix) are exercised.
    func announceTest() {
        let sample = Lap(id: 3, time: 12.34)
        speak(phrase(for: sample, isBest: true))
    }

    /// Drop any in-flight or queued speech. Called from RESET so a stale
    /// announcement from the previous run doesn't keep talking after the
    /// session has been wiped.
    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
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
        } catch {
            // Don't latch sessionConfigured = true here — the next utterance
            // should retry. Most likely cause: another app holds an
            // exclusive audio category (Voice Memos recording, active
            // call). Logging keeps a Console.app trail when "TTS is silent
            // mid-race" gets reported.
            print("LapAnnouncer: AVAudioSession activation failed: \(error.localizedDescription)")
        }
    }

    private func deactivateSession() {
        guard sessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            sessionConfigured = false
        } catch {
            print("LapAnnouncer: AVAudioSession deactivation failed: \(error.localizedDescription)")
            // Leave sessionConfigured = true — the session is still active
            // even though we couldn't clean up. Next utterance will reuse
            // it via the `guard !sessionConfigured` short-circuit.
        }
    }

    private func currentLanguage() -> LapAnnouncerLanguage {
        let raw = UserDefaults.standard.string(forKey: LapAnnouncerDefaults.languageKey)
            ?? LapAnnouncerDefaults.defaultLanguageRaw
        return LapAnnouncerLanguage(rawValue: raw) ?? .english
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
                // Voice exists but is the wrong language — silent fall-through
                // is fine here (e.g. mid-language-switch race window).
            } else {
                // Saved identifier no longer resolves: voice was uninstalled
                // or the device was restored to a phone that doesn't have
                // it. SettingsView's `voiceMissing` banner covers the UX,
                // but log so the issue shows up in `log stream` output too.
                print("LapAnnouncer: saved voice '\(id)' no longer installed; using system default for \(language.fallbackVoiceLanguage).")
            }
        }
        return AVSpeechSynthesisVoice(language: language.fallbackVoiceLanguage)
    }

    private func currentRate() -> Float {
        // `@AppStorage` stores Double; `AVSpeechUtterance.rate` is Float.
        // Use `object(forKey:) as? Double` (matching `announceBest`) so a
        // genuine value of `0.0` and "key absent" stay distinguishable —
        // `register(defaults:)` already supplies the default, but routing
        // through the same nil-check protects against a stale plist or a
        // legacy debug build that wrote 0 directly.
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
struct LapAnnouncerVoiceCatalog {
    /// Voice quality tier. Sort order matches the integer raw value (lower =
    /// higher quality) so the Picker can show Premium first. iOS 17+ Siri
    /// voices land in `.premium`, the legacy "Enhanced" downloadables in
    /// `.enhanced`, the compact base voices in `.standard`.
    enum Quality: Int, Comparable {
        case premium = 0
        case enhanced = 1
        case standard = 2

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        init(_ quality: AVSpeechSynthesisVoiceQuality) {
            switch quality {
            case .premium: self = .premium
            case .enhanced: self = .enhanced
            default: self = .standard
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
        let id: String          // AVSpeechSynthesisVoice.identifier
        let displayName: String // "Samantha (en-US, Enhanced)"
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
}
