import AVFoundation
import Foundation
import UIKit
import os

/// Subsystem-scoped logger so messages reach the unified logging system
/// (`log stream`, Console.app, `idevicesyslog`) instead of `print()`'s
/// stdout/stderr — which only the attached debugger sees on iOS.
private let log = Logger(subsystem: "sh.saqoo.HDZap", category: "LapAnnouncer")

/// UserDefaults keys + defaults shared between LapAnnouncer (the consumer)
/// and AudioSettingsView (the editor). Centralized so a typo in one site
/// can't silently disconnect the two — both reach for the same constants.
enum LapAnnouncerDefaults {
    static let enabledKey = "lapTTSEnabled"
    static let languageKey = "lapTTSLanguage"
    static let voiceIdentifierKey = "lapTTSVoiceIdentifier"
    static let rateKey = "lapTTSRate"
    static let pitchKey = "lapTTSPitch"
    static let announceBestKey = "lapTTSAnnounceBest"

    /// Mirrors `AVSpeechUtteranceDefaultSpeechRate` (iOS 18 = 0.5). Hardcoded
    /// so AudioSettingsView and HDZapApp can register and bind the default
    /// without transitively importing AVFoundation; debug-asserted at
    /// `LapAnnouncer.init` so the next SDK that retunes the constant trips
    /// a precondition rather than silently drifting.
    static let defaultRate: Float = 0.5
    static let defaultPitch: Float = 1.0
    /// Master toggle default — off, so the app stays silent until the
    /// operator explicitly opts in to TTS announcements.
    static let defaultEnabled = false
    /// "best lap" callout default — on. Cheap, useful, and only fires
    /// at the moments that warrant a callout.
    static let defaultAnnounceBest = true
    /// Empty string == "use the system default voice for the selected
    /// language" inside `LapAnnouncer.currentVoice()`. Keeps every
    /// `@AppStorage` site, the Reset button, and HDZapApp's register
    /// block reaching for the same symbol — no typo or drift surface.
    static let defaultVoiceIdentifier = ""
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
/// AudioSettingsView is the writer for voice / rate / pitch / language;
/// this class is the reader. Both reach for the same
/// `LapAnnouncerDefaults.*` keys, and every setting is read fresh inside
/// `speak()` so Settings edits apply on the next lap with no explicit
/// wiring.
@MainActor
@Observable
final class LapAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// True only after `setCategory` *and* `setActive(true)` succeed —
    /// either failure leaves the flag false so the next utterance retries
    /// instead of silently never reactivating.
    private var sessionConfigured = false
    /// Serial queue for AVAudioSession syscalls. `setActive(true)` blocks
    /// 50–200ms, `setActive(false)` blocks 100–300ms (it sends ducking-end
    /// notifications to other audio apps). Running them on the main actor
    /// produced a visible UI hitch right after each lap announcement
    /// finished. The queue is serial so an activate / deactivate pair can't
    /// reorder against each other on a fast lap-tap-then-finish sequence.
    private let audioSessionQueue = DispatchQueue(label: "sh.saqoo.HDZap.LapAnnouncer.audioSession",
                                                  qos: .userInitiated)

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
        let announceBest = UserDefaults.standard.object(forKey: LapAnnouncerDefaults.announceBestKey) as? Bool
            ?? LapAnnouncerDefaults.defaultAnnounceBest
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

    /// Announces the race-over summary: optional last lap + total lap
    /// count + total race time + best-lap time. Called once when the
    /// session transitions to ended.
    ///
    /// Pass `lastLap` on the FINAL-button path so the just-recorded
    /// lap is folded into a single utterance (the per-lap callout is
    /// suppressed so it doesn't preempt the summary). Pass `nil` from
    /// the manual-STOP path — that lap was already announced by the
    /// previous LAP tap.
    func announceFinal(lastLap: Lap?,
                       lapCount: Int,
                       totalTime: TimeInterval,
                       bestLapTime: TimeInterval?) {
        speak(finalPhrase(lastLap: lastLap,
                          lapCount: lapCount,
                          totalTime: totalTime,
                          bestLapTime: bestLapTime))
    }

    /// Announces the race start ("Start" / "スタート") so the operator
    /// gets an audio cue when they tap START. Doubles as a warm-up for
    /// the audio session so the first lap announcement isn't delayed by
    /// the initial `setActive(true)` round-trip.
    func announceStart() {
        switch currentLanguage() {
        case .english: speak("Start")
        case .japanese: speak("スタート")
        }
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
        // Optimistically mark configured so a fast double-tap doesn't queue
        // the activation twice. The background result reverts the flag if
        // the syscall fails so the next utterance retries.
        sessionConfigured = true
        audioSessionQueue.async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true, options: [])
                Task { @MainActor [weak self] in
                    self?.lastAudioError = nil
                }
            } catch {
                // Most likely cause: another app holds an exclusive audio
                // category (Voice Memos recording, active call). A race
                // operator can't read Console.app from their pocket, so we
                // also surface the error to the UI via `lastAudioError`
                // and fire a haptic so they know audio didn't take.
                log.error("AVAudioSession activation failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor [weak self] in
                    self?.sessionConfigured = false
                    self?.lastAudioError = "Audio unavailable: \(error.localizedDescription)"
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func deactivateSession() {
        guard sessionConfigured else { return }
        // A new utterance can land between `didCancel` / `didFinish` being
        // queued (off-main) and this method running on the main actor. If
        // the synth is mid-speech, deactivating now would cut audio off —
        // let the next `didFinish` / `didCancel` retry instead.
        guard !synthesizer.isSpeaking else { return }
        sessionConfigured = false
        audioSessionQueue.async {
            do {
                try AVAudioSession.sharedInstance()
                    .setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
                log.error("AVAudioSession deactivation failed: \(error.localizedDescription, privacy: .public)")
                // `sessionConfigured` is already false — next utterance
                // reactivates fresh, which is the right recovery path.
            }
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
        let id = UserDefaults.standard.string(forKey: LapAnnouncerDefaults.voiceIdentifierKey)
            ?? LapAnnouncerDefaults.defaultVoiceIdentifier

        // Honor the saved voice only if it matches the current announcement
        // language. Without this check, switching language would happily
        // hand a `ja-JP` phrase to an `en-US` voice (or vice versa) and the
        // engine would mispronounce numerals into nonsense.
        if !id.isEmpty {
            if let voice = AVSpeechSynthesisVoice(identifier: id) {
                if voice.language.hasPrefix(language.voiceLanguagePrefix) {
                    return voice
                }
                // Voice exists but is the wrong language.
                // AudioSettingsView's `onChange(of: ttsLanguageRaw)`
                // clears `voiceIdentifier` when the user switches
                // in-app, but a Shortcuts / MDM / iCloud-sync write or
                // an iOS region change can leave a mismatched id. Log
                // so the silent quality drop is observable in `log
                // stream`.
                log.info("Saved voice '\(id, privacy: .public)' is \(voice.language, privacy: .public); announcement language is \(language.fallbackVoiceLanguage, privacy: .public). Using system default for the announcement language.")
            } else {
                // Saved identifier no longer resolves: voice was uninstalled
                // or the device was restored to a phone that doesn't have
                // it. AudioSettingsView's `voiceMissing` banner covers
                // the UX, but log so the issue shows up in `log stream`
                // output too.
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

    private func finalPhrase(lastLap: Lap?,
                             lapCount: Int,
                             totalTime: TimeInterval,
                             bestLapTime: TimeInterval?) -> String {
        let bestStr = bestLapTime.map(truncatedSecondsString(_:))
        let lastLapStr = lastLap.map { truncatedSecondsString($0.time) }
        switch currentLanguage() {
        case .english:
            guard let bestStr else { return "Race complete. No laps recorded." }
            let totalEN = englishMinSecString(totalTime)
            if let lastLap, let lastLapStr {
                return "Lap \(lastLap.id), \(lastLapStr) seconds. Total \(lapCount) laps in \(totalEN). Best lap was \(bestStr) seconds."
            }
            return "\(lapCount) laps in \(totalEN). Best lap was \(bestStr) seconds."
        case .japanese:
            guard let bestStr else { return "レース終了。ラップ記録なし。" }
            let totalJP = japaneseMinSecString(totalTime)
            if let lastLap, let lastLapStr {
                return "ラップ\(lastLap.id) \(lastLapStr)秒、トータル\(lapCount)周、\(totalJP)、ベストラップは\(bestStr)秒でした"
            }
            return "\(lapCount)周 \(totalJP)、ベストラップは\(bestStr)秒でした"
        }
    }

    /// Truncates `seconds` to hundredths and formats as "S.SS" — matches
    /// the on-screen display, which floors to milliseconds (see BigTime /
    /// EditorialFormat.time). Using `%.2f` instead would round at the
    /// hundredths boundary and disagree with the display, so 00:18.00 on
    /// screen ends up as "18.01秒" in speech for a lap timed at e.g.
    /// 18.005s.
    private func truncatedSecondsString(_ seconds: TimeInterval) -> String {
        let hundredths = Int((max(0, seconds) * 100).rounded(.down))
        let whole = hundredths / 100
        let frac = hundredths % 100
        return "\(whole).\(String(format: "%02d", frac))"
    }

    /// Splits seconds into a "M minute(s) SS.SS seconds" string for the
    /// English race summary. Drops the minute portion when total < 60 so
    /// `45.66` doesn't read as "zero minutes forty-five point six six".
    /// Uses the same truncate-to-hundredths rule as `truncatedSecondsString`
    /// so the spoken total agrees with the display.
    private func englishMinSecString(_ time: TimeInterval) -> String {
        let (minutes, secStr) = minutesAndSecondsString(time)
        if minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") \(secStr) seconds"
        }
        return "\(secStr) seconds"
    }

    /// Same split for Japanese — produces "M分SS.SS秒" or just "SS.SS秒"
    /// when total < 60. The Siri/Otoya voices read "1分45.66秒" naturally
    /// as "いっぷんよんじゅうごてんろくろくびょう".
    private func japaneseMinSecString(_ time: TimeInterval) -> String {
        let (minutes, secStr) = minutesAndSecondsString(time)
        if minutes > 0 {
            return "\(minutes)分\(secStr)秒"
        }
        return "\(secStr)秒"
    }

    /// Truncate-then-split helper used by both language formatters.
    /// Computes hundredths once via `.rounded(.down)` so a value like
    /// 65.999s splits as 1m 5.99s, never 1m 6.00s.
    private func minutesAndSecondsString(_ time: TimeInterval) -> (minutes: Int, secStr: String) {
        let totalHundredths = Int((max(0, time) * 100).rounded(.down))
        let totalSeconds = totalHundredths / 100
        let frac = totalHundredths % 100
        let minutes = totalSeconds / 60
        let s = totalSeconds % 60
        return (minutes, "\(s).\(String(format: "%02d", frac))")
    }

    private func phrase(for lap: Lap, isBest: Bool) -> String {
        // Two decimals matches what most pilots can act on — milliseconds
        // are too granular to parse by ear in the half-second the operator
        // has between laps. AVSpeechSynthesizer reads "12.34" naturally as
        // "twelve point three four" (en) / "12てん34" (ja). Truncated (not
        // rounded) so the spoken time agrees with the on-screen display.
        let timeStr = truncatedSecondsString(lap.time)
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

/// Catalogs the installed speech voices so AudioSettingsView can render a Picker.
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
    /// AudioSettingsView body when its body renders — never concurrently —
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
