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

    /// `0.5` matches `AVSpeechUtteranceDefaultSpeechRate` (a runtime value
    /// we can't put in a static let). Captured here so SettingsView can
    /// register it via `UserDefaults.register(defaults:)` without importing
    /// AVFoundation just for the constant.
    static let defaultRate: Float = 0.5
    static let defaultPitch: Float = 1.0
    static let minRate: Float = 0.3   // < 0.3 trails into incomprehensible
    static let maxRate: Float = 0.65  // > 0.65 chops decimals together
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

    var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語"
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
/// Voice / rate / pitch are read from UserDefaults at speak time — the
/// SettingsView writes them via @AppStorage, and the announcer picks up the
/// latest value on the next lap without any explicit wiring.
@MainActor
@Observable
final class LapAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private var sessionConfigured = false

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
    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
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
        if !id.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: id),
           voice.language.hasPrefix(language.voiceLanguagePrefix) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: language.fallbackVoiceLanguage)
    }

    private func currentRate() -> Float {
        // @AppStorage stores Double; AVSpeechUtterance.rate is Float. Read as
        // Double (0 means "key absent" — fall back to the default rather than
        // letting the synth try rate=0, which trails to silence).
        let raw = UserDefaults.standard.double(forKey: LapAnnouncerDefaults.rateKey)
        let value = raw == 0 ? LapAnnouncerDefaults.defaultRate : Float(raw)
        return min(LapAnnouncerDefaults.maxRate, max(LapAnnouncerDefaults.minRate, value))
    }

    private func currentPitch() -> Float {
        let raw = UserDefaults.standard.double(forKey: LapAnnouncerDefaults.pitchKey)
        let value = raw == 0 ? LapAnnouncerDefaults.defaultPitch : Float(raw)
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
    struct Entry: Identifiable, Hashable {
        let id: String          // AVSpeechSynthesisVoice.identifier
        let displayName: String // "Samantha (en-US, Enhanced)"
        let language: String
        /// Drives sort order so Premium voices float to the top of the
        /// picker — they're the highest-quality option (iOS 17+ Siri voices
        /// land here) and most users want them picked first when installed.
        let qualityRank: Int
    }

    /// Lists installed voices for `language`, sorted Premium → Enhanced →
    /// Default, then alphabetically by name. The picker also exposes a
    /// "System default" entry for `id == ""`, so this list can be empty
    /// without breaking selection.
    static func availableVoices(for language: LapAnnouncerLanguage) -> [Entry] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language.voiceLanguagePrefix) }
            .map { v in
                let qualityTag: String
                let rank: Int
                switch v.quality {
                case .premium: qualityTag = ", Premium"; rank = 0
                case .enhanced: qualityTag = ", Enhanced"; rank = 1
                default: qualityTag = ""; rank = 2
                }
                return Entry(
                    id: v.identifier,
                    displayName: "\(v.name) (\(v.language)\(qualityTag))",
                    language: v.language,
                    qualityRank: rank
                )
            }
            .sorted { lhs, rhs in
                if lhs.qualityRank != rhs.qualityRank { return lhs.qualityRank < rhs.qualityRank }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.displayName < rhs.displayName
            }
    }
}
