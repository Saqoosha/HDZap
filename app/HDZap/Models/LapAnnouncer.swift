import AVFoundation
import Foundation

/// UserDefaults keys + defaults shared between LapAnnouncer (the consumer)
/// and SettingsView (the editor). Centralized so a typo in one site can't
/// silently disconnect the two — both reach for the same constants.
enum LapAnnouncerDefaults {
    static let enabledKey = "lapTTSEnabled"
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
    /// before relying on it during a race.
    func announceTest() {
        speak("Lap 3, 12.34, best lap")
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

    private func currentVoice() -> AVSpeechSynthesisVoice? {
        let id = UserDefaults.standard.string(forKey: LapAnnouncerDefaults.voiceIdentifierKey) ?? ""
        if !id.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        // Fall back to the system's preferred en-US voice. We deliberately
        // pin to en-US rather than `Locale.current` because the announcement
        // text ("Lap 5, 12.34") is English; a Japanese system voice asked to
        // read English numerals mispronounces them.
        return AVSpeechSynthesisVoice(language: "en-US")
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
        // "twelve point three four" with the en-US voice.
        let timeStr = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"),
                             max(0, lap.time))
        if isBest {
            return "Lap \(lap.id), \(timeStr), best lap"
        }
        return "Lap \(lap.id), \(timeStr)"
    }
}

/// Catalogs the installed speech voices so SettingsView can render a Picker.
/// Filtered to English voices because the announcement text is English; a
/// non-English voice asked to read "Lap 5, 12.34" mispronounces it.
struct LapAnnouncerVoiceCatalog {
    struct Entry: Identifiable, Hashable {
        let id: String          // AVSpeechSynthesisVoice.identifier
        let displayName: String // "Samantha (en-US, Enhanced)"
        let language: String
    }

    static func availableEnglishVoices() -> [Entry] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .map { v in
                let qualityTag: String
                switch v.quality {
                case .premium: qualityTag = ", Premium"
                case .enhanced: qualityTag = ", Enhanced"
                default: qualityTag = ""
                }
                return Entry(
                    id: v.identifier,
                    displayName: "\(v.name) (\(v.language)\(qualityTag))",
                    language: v.language
                )
            }
            .sorted { lhs, rhs in
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.displayName < rhs.displayName
            }
    }
}
