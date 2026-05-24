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
    static let countdownEnabledKey = "lapTTSCountdownEnabled"
    static let countdownStartSecondsKey = "lapTTSCountdownStartSeconds"

    /// "system" (built-in `AVSpeechSynthesizer`) or "premium" (cloud TTS via the hdzap-premium
    /// Worker). Stored as a raw string so it can be `@AppStorage`-bound directly. When set to
    /// "premium" but no `premiumVoiceIdentifierKey` is selected, `speak()` falls back to the
    /// system engine so the operator isn't left in silence.
    static let engineKey = "lapTTSEngine"
    /// Selected voice ID from `PremiumVoiceCatalog` — Polly Pascal name / Azure
    /// locale-qualified name depending on which provider the entry belongs to. Empty string
    /// means "no premium voice picked yet".
    static let premiumVoiceIdentifierKey = "lapTTSPremiumVoiceIdentifier"
    /// Premium speech rate multiplier (1.0 = baseline cadence). Applied to Polly + Azure via
    /// SSML `<prosody rate>` in the Worker, honoured by both Polly and Azure. 1.4× is the
    /// default because race announcers tend to talk fast — YourLaps shipped
    /// `<prosody rate="x-fast">` (~1.4-1.5×) for years.
    static let premiumRateKey = "lapTTSPremiumRate"
    /// Premium pitch multiplier as semitone offset (0 = neutral). Azure honours it via SSML
    /// `<prosody pitch>`; Polly Neural rejects it ("Unsupported Neural feature") so the
    /// pitch field is omitted from Polly requests on the client side.
    static let premiumPitchKey = "lapTTSPremiumPitch"
    static let defaultEngine = "system"
    static let defaultPremiumVoiceIdentifier = ""
    static let defaultPremiumRate: Double = 1.4
    static let defaultPremiumPitch: Double = 0.0
    /// Bounds chosen so the SSML stays in the natural-sounding range — too slow gets robotic
    /// and too fast becomes unintelligible. ~0.7× to 2.0× is the sweet spot for both engines.
    static let minPremiumRate: Double = 0.7
    static let maxPremiumRate: Double = 2.0
    /// Semitone offset: roughly ±5 semitones keeps the voice recognisable. Beyond that Polly
    /// in particular starts producing chipmunk / monster artifacts.
    static let minPremiumPitch: Double = -5.0
    static let maxPremiumPitch: Double = 5.0

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
    /// Final-seconds countdown ("10", "9", "8", ...) default — off.
    /// Opt-in like the master toggle: silent until the operator asks
    /// for it.
    static let defaultCountdownEnabled = false
    /// How many of the final seconds to call out when countdown is on.
    /// 10 lands the first call at the standard FPV "10 to go" cue;
    /// the bounds below let the operator widen (15) or tighten (5).
    static let defaultCountdownStartSeconds = 10
    /// Empirical bounds. Below 5 the first call ("5") leaves no time
    /// to react before the FINAL lap window opens; above 15 the count
    /// runs longer than most operators want over the start of a
    /// closing-pace lap.
    static let minCountdownStartSeconds = 5
    static let maxCountdownStartSeconds = 15
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
    /// Cloud TTS path (Polly / Azure). Owned here so AudioSettingsView can reach it
    /// via `@Environment` for the dev panel, and so speak() can route to it when the operator
    /// has selected the "premium" engine. The premium synth manages its own AVAudioSession +
    /// AVAudioEngine — sharing one session with `synthesizer` here would force both to fight
    /// over `setCategory`, so they each activate independently and the warm-keeper stays out
    /// of the premium path.
    let premiumSynth = PremiumSpeechSynthesizer()
    /// Currently-running prewarm `Task` from `prewarmFixedPhrases()`. Held so a
    /// race-critical utterance (LAP / Start / Last lap / FINAL) can cancel the
    /// in-flight prefetch burst before its own Worker request goes out — without
    /// this, an upstream provider's per-IP rate limit could 429 the user-visible utterance
    /// because 3 prewarm prefetches are already inflight on the same provider.
    /// `premiumUtteranceEnded` re-fires `prewarmFixedPhrases` after the utterance
    /// finishes; the prefetch idempotency (cache-hit short-circuit) means resumed
    /// prewarms only fetch the phrases the cancelled run hadn't reached yet.
    private var currentPrewarmTask: Task<Void, Never>?
    /// True only after `setCategory` *and* `setActive(true)` succeed —
    /// either failure leaves the flag false so the next utterance retries
    /// instead of silently never reactivating.
    private var sessionConfigured = false

    /// When true, `deactivateSession` is a no-op so the AVAudioSession
    /// stays active across utterances. Lets the operator hold the
    /// session for the duration of a race — without this hold, every
    /// announcement pays a setActive(true)/setActive(false) round-trip,
    /// and even though both syscalls run on a background queue the
    /// route-change interruption notifications iOS posts to other
    /// audio apps land on the main thread and observably stutter the
    /// UI right at the start and end of each utterance. TimerView
    /// flips this on at fresh START (before `announceStart()` so the
    /// session activated from that call stays put) and off on FINAL
    /// / manual STOP / RESET. Setting it back to false while the
    /// synth is idle triggers an immediate deactivate via `didSet`;
    /// while speaking, the next `didFinish` / `didCancel` picks it up.
    var sessionHoldActive = false {
        didSet {
            guard oldValue && !sessionHoldActive else { return }
            // Gate on the inflight counter, NOT `synth.isSpeaking`:
            // `speak()` increments the counter synchronously *before*
            // dispatching to `synthQueue`, while `isSpeaking` only
            // flips true once the synth worker has actually picked
            // up the utterance. Without the counter check, a
            // hold-release that fires right after `announceFinal`
            // sees an "idle" synth, deactivates the session, and
            // races the about-to-run summary speak — which then
            // stutters because its session is mid-deactivation.
            // Counter==0 means "no work pending or in flight"; the
            // delegate path will call `deactivateSession` once the
            // queue actually drains.
            if inflightUtteranceCount == 0 && !synthesizer.isSpeaking {
                deactivateSession()
            }
        }
    }

    /// Voice resolution result cached across utterances. Constructing
    /// an `AVSpeechSynthesisVoice` does enough disk + metadata work
    /// that calling it from every `speak()` shows up as ~10–30 ms of
    /// main-thread stutter right at voice-start — and the underlying
    /// selection (language + identifier) only changes when the
    /// operator edits Settings, not between announcements. The
    /// composite key lets us recompute on a real change while reusing
    /// the resolved voice on the steady-state countdown / lap path.
    private var cachedVoice: AVSpeechSynthesisVoice?
    private var cachedVoiceKey: String?
    /// Serial queue for AVAudioSession syscalls. `setActive(true)` blocks
    /// 50–200ms, `setActive(false)` blocks 100–300ms (it sends ducking-end
    /// notifications to other audio apps). Running them on the main actor
    /// produced a visible UI hitch right after each lap announcement
    /// finished. The queue is serial so an activate / deactivate pair can't
    /// reorder against each other on a fast lap-tap-then-finish sequence.
    private let audioSessionQueue = DispatchQueue(label: "sh.saqoo.HDZap.LapAnnouncer.audioSession",
                                                  qos: .userInitiated)

    /// Dedicated serial queue for `AVSpeechSynthesizer` calls. Apple's
    /// docs are silent on thread-safety, but empirical reports across
    /// iOS 16/17/18 consistently show that the per-utterance UI hitch
    /// at voice-start is caused by `speak()` taking an internal lock
    /// on the calling thread and stalling main for ~30 ms during
    /// audio-engine handoff. Moving the call off main eliminates the
    /// stutter while leaving the synth's worker-thread rendering
    /// unchanged. Serial so a `stopSpeaking` + `speak` pair issued
    /// for a fast LAP-tap-during-countdown sequence can't reorder.
    private let synthQueue = DispatchQueue(label: "sh.saqoo.HDZap.LapAnnouncer.synth",
                                           qos: .userInteractive)

    /// Warm-keeper engine + silent player. AVSpeechSynthesizer's
    /// per-utterance hitch is the audio-output HAL cold-starting:
    /// after ~1 s of idle the synth lets the playback path go to
    /// sleep, and the *next* `speak()` pays the wake-up cost on
    /// main. The operator saw exactly this — "10" stutters but "9",
    /// "8", "7" are fine (the 1 s gap keeps the HAL warm between
    /// them), and a LAP tap that lands seconds after the last
    /// utterance also stutters. Streaming a continuous zero-amplitude
    /// buffer through our own `AVAudioPlayerNode` while a race is in
    /// flight keeps the HAL warm; subsequent `synth.speak()` calls
    /// mix into the same active output and skip the wake-up.
    ///
    /// `warmKeeperAttached` survives across start/stop so the
    /// attach/connect dance only runs once per `LapAnnouncer`
    /// lifetime (cheap, but avoids redundant graph churn between
    /// races).
    private let warmKeeperEngine = AVAudioEngine()
    private let warmKeeperNode = AVAudioPlayerNode()
    private var warmKeeperAttached = false
    private var warmKeeperRunning = false

    /// Number of utterances that have been enqueued via `speak()` and
    /// haven't yet fired `didFinish` / `didCancel`. Counter, not a
    /// bool, because countdowns + lap calls can stack: the LAP path
    /// passes `cancelInflight: true` which fires `didCancel` for the
    /// preempted countdown *and* `didFinish` for the lap utterance
    /// itself, so balancing increments-on-speak with decrements-on-
    /// delegate keeps the count accurate across cancel-then-speak
    /// sequences. Used by `stopWarmKeeperWhenIdle()` to defer the
    /// engine stop past the final summary instead of cutting it off.
    private var inflightUtteranceCount = 0
    /// Set by `stopWarmKeeperWhenIdle()` so the next time
    /// `inflightUtteranceCount` drops to 0 (the queue is empty), the
    /// warm-keeper engine actually stops. Without this two-step the
    /// race-end summary's speak — enqueued just before TimerView
    /// asks for the stop — would land on an already-stopped engine
    /// and pay the HAL cold-start cost we built the warm-keeper to
    /// avoid.
    private var stopWarmKeeperPending = false

    /// Set when AVAudioSession activation throws so the UI can show a
    /// banner like "Audio unavailable — announcements muted". Cleared on
    /// the next successful activation. Race operator with the phone in a
    /// chest pocket can't see Console.app, so silent log-only failure
    /// would defeat the whole point of audio confirmation.
    private(set) var lastAudioError: String?

    /// Live audio-output latency for the current route plus a small
    /// fixed allowance for AVSpeechSynthesizer render + handoff time.
    /// AirPods report ~150–200 ms (BT codec round-trip + jitter
    /// buffer); USB-C / Lightning headphones and the built-in speaker
    /// report tens of ms. Reading the system value means the
    /// countdown lead-time auto-tracks the current route — if the
    /// operator yanks AirPods mid-race, the next number fires with
    /// the smaller built-in-speaker compensation instead of staying
    /// 150 ms early forever.
    ///
    /// The +0.05 s is the empirical synthesis-and-enqueue overhead
    /// of `AVSpeechUtterance` for a one- or two-syllable numeral —
    /// `outputLatency` measures only the audio session's output
    /// buffer, not the speech pipeline upstream of it. The raw value
    /// is clamped to `≥ 0`: the property is documented to return 0
    /// for an inactive session, but Apple has historically tightened
    /// "undefined" to specific sentinels (NaN, -1) without warning,
    /// and any negative value here would make
    /// `fireAtElapsed = sessionLimit − n − leadSec` overshoot
    /// `sessionLimit` and silently kill the countdown.
    ///
    /// The minimum is `0.05` (the synth-overhead floor): before
    /// `startWarmKeeper()` activates the session the route latency
    /// reads as 0, but the synth overhead is still there.
    var estimatedOutputLatency: TimeInterval {
        max(0, AVAudioSession.sharedInstance().outputLatency) + 0.05
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        // NB: do NOT set `synthesizer.usesApplicationAudioSession =
        // false` — the synth needs to share our AVAudioSession so
        // the warm-keeper engine started by `startWarmKeeper()` can
        // keep the audio-output HAL hot for it. With `false`, the
        // synth uses its own private internal session and the
        // warm-keeper has no effect on its per-utterance cold-start.
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

    /// Mirrors the System synth's `didFinish` / `didCancel` delegate — decrement the
    /// inflight counter and attempt session deactivation. Premium playback runs through
    /// `PremiumSpeechSynthesizer.onEnd` callbacks, which call this so the warm-keeper /
    /// session-hold lifecycle stays symmetric across both engines. Picker / paywall
    /// previews bypass `LapAnnouncer.speak` and therefore MUST NOT pass this as their
    /// `onEnd` — they never incremented the counter, so they have nothing to decrement.
    private func premiumUtteranceEnded() {
        utteranceDidEnd()
        deactivateSession()
        // Resume the prewarm `speak()` cancelled before invoking `speakAsync`.
        // `prefetch` is idempotent on cache hits, so the restarted run only
        // re-fetches phrases the cancelled batch didn't reach (in practice,
        // most of the countdown numbers when the cancel happened on the first
        // Start cue). Race-time cadence makes this comfortably re-converge
        // before countdown fires: Start utterance ≈ 1 s, race timer ≈ 30+ s
        // before countdown starts, leaving the resumed prewarm plenty of
        // window. Each subsequent LAP / Last lap / FINAL re-fires too — no-op
        // once the cache is fully populated.
        //
        // BUT only when the queue is fully drained — `onEnd` callbacks from a
        // cancelled prior utterance (e.g. Start cue replaced mid-flight by a
        // countdown tick) fire while a fresh utterance is still mid-play, and
        // resuming prewarm there would re-bombard the provider with parallel
        // requests during the exact window we're trying to keep clear. The
        // last utterance to complete will see `inflightUtteranceCount == 0`
        // and will run the resume itself.
        guard inflightUtteranceCount == 0 else { return }
        prewarmFixedPhrases()
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
    /// gets an audio cue when they tap START. Session warm-up is now
    /// owned by `startWarmKeeper()` (called synchronously before
    /// this utterance is enqueued), so the announcement is purely
    /// the operator cue.
    func announceStart() {
        switch currentLanguage() {
        case .english: speak("Start")
        case .japanese: speak("スタート")
        }
    }

    /// Announces "Last lap!" / "ラストラップ！" the instant race time
    /// runs out so the pilot knows the lap they're flying is the
    /// FINAL lap. Fires once per race, gated by the same TTS master
    /// toggle as the rest of the announcer; warm-keeper is still
    /// running at this point (TimerView only releases it on the
    /// FINAL/STOP/RESET path) so the HAL stays hot and the call
    /// avoids the cold-start hitch.
    func announceLastLap() {
        switch currentLanguage() {
        case .english: speak("Last lap!")
        case .japanese: speak("ファイナルラップです")
        }
    }

    /// Speaks a single countdown number near race end.
    /// AVSpeechSynthesizer reads bare numerals naturally in both en
    /// (`ten` / `nine`) and ja (`じゅう` / `きゅう`) voices, so no
    /// per-language phrasing is needed.
    ///
    /// Guard on `inflightUtteranceCount == 0`, not `isSpeaking`:
    /// `speak()` is dispatched to `synthQueue` and the counter is
    /// incremented synchronously *before* the dispatch, while
    /// `isSpeaking` only flips true once the synth worker picks up
    /// the utterance. Reading `isSpeaking` would let a countdown
    /// number slip past a still-pending lap callout that hasn't
    /// reached the synth yet, and the operator would then hear the
    /// stale number out-of-order after the lap announcement
    /// finished. The counter check covers both the in-flight and
    /// the queued cases.
    ///
    /// Dropping is safe — `nextCountdownN` in `TimerView` is only
    /// advanced after this method is called (regardless of whether
    /// `speak()` actually fired), so a dropped number is simply
    /// skipped; the next 60 Hz `.onChange(of: elapsedTime)` tick
    /// already targets the next-smaller integer and lands when the
    /// synth has cleared. `cancelInflight: false` matches that
    /// design: a LAP or FINAL utterance does *not* preempt the
    /// count via `speak()`'s cancel path (it preempts the count
    /// only by passing this guard), but the counter check makes the
    /// `cancelInflight: false` parameter effectively unreachable on
    /// the steady-state countdown path — only the start-of-count
    /// case (idle synth) ever passes the guard.
    func announceCountdown(_ seconds: Int) {
        // Premium engine: route through `speakOverlap` so consecutive countdown
        // numbers can play CONCURRENTLY at the audio level. At higher Premium
        // rates (Azure 1.45 ×, etc.) each utterance runs ~1.4 s, so the 1-second
        // tick would otherwise drop alternate numbers via the
        // `inflightUtteranceCount` guard. The overlap pool's `AVAudioPlayerNode`s
        // mix at `mainMixerNode`, so "10" can still be ringing out while "9"
        // starts and the listener hears both. LAP / Start / Last lap utterances
        // go through the primary `playerNode` and stop the overlap pool so the
        // higher-priority callout is heard cleanly.
        //
        // **Cache miss in Premium is silently dropped, NOT fallen back to
        // System voice.** Falling back would route through `speak()` → premium
        // `speakAsync()` → `cancel()`, which tears down the overlap pool and
        // disrupts every subsequent countdown tick for the duration of the live
        // Worker fetch (~600-1000 ms). `prewarmFixedPhrases` reliably warms
        // every countdown phrase on Settings dismissal, so a miss here means
        // the operator started the race before prewarm completed — one
        // dropped number is better than collapsing the whole countdown into a
        // single long System-voice utterance plus drops.
        if let premiumVoice = currentPremiumVoiceIfActive() {
            configureSessionIfNeeded()
            premiumSynth.speakOverlap(
                text: String(seconds),
                lang: premiumVoice.lang,
                voice: premiumVoice,
            )
            return
        }
        // System engine path — the original drop guard stays so the
        // single-channel `AVSpeechSynthesizer` doesn't pile up utterances.
        guard inflightUtteranceCount == 0 else { return }
        speak(String(seconds), cancelInflight: false)
    }

    /// Starts the silent warm-keeper stream so the audio-output HAL
    /// stays hot for the duration of a race. Called by TimerView at
    /// fresh START, paired with `stopWarmKeeper()` on every race-end
    /// path (FINAL / manual STOP / RESET). Idempotent.
    func startWarmKeeper() {
        guard !warmKeeperRunning else { return }
        warmKeeperRunning = true

        // The session has to be active before `AVAudioEngine.start()`
        // can attach to it. We pay the 50–200 ms setCategory/setActive
        // cost synchronously here — the operator's tap on the START
        // button hides it, and it's a once-per-race expense.
        configureSessionSync()
        guard sessionConfigured else {
            // configureSessionSync already wrote the root-cause to
            // lastAudioError + fired the haptic. Bail out before
            // `warmKeeperEngine.start()` runs on an inactive session
            // and overwrites the diagnostic with a misleading
            // "engine start failed" cascade error.
            warmKeeperRunning = false
            return
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44100,
                                   channels: 1,
                                   interleaved: false)
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: 4410) else {
            log.error("warm-keeper buffer allocation failed (format nil or PCMBuffer nil)")
            lastAudioError = "Audio warm-up unavailable — announcements may stutter at race start."
            warmKeeperRunning = false
            return
        }
        // 100 ms looped — short enough that `.stop()` cuts cleanly at
        // race end (worst-case ~100 ms tail before silence), long
        // enough that any internal restart at the loop boundary stays
        // well below audibility. AVAudioPCMBuffer's sample storage is
        // *not* guaranteed to be zero-initialized — the allocator
        // typically returns zeroed pages but it isn't part of the
        // contract, and an uninitialized chunk would replay through
        // the speaker as a click/burst loud enough to startle the
        // operator. Memset is a few µs once per race start.
        buffer.frameLength = 4410
        if let channels = buffer.floatChannelData {
            let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
            for c in 0..<Int(format.channelCount) {
                memset(channels[c], 0, bytes)
            }
        }

        if !warmKeeperAttached {
            warmKeeperEngine.attach(warmKeeperNode)
            warmKeeperEngine.connect(warmKeeperNode,
                                     to: warmKeeperEngine.mainMixerNode,
                                     format: format)
            warmKeeperAttached = true
        }

        do {
            if !warmKeeperEngine.isRunning {
                try warmKeeperEngine.start()
            }
            warmKeeperNode.scheduleBuffer(buffer,
                                          at: nil,
                                          options: .loops,
                                          completionHandler: nil)
            warmKeeperNode.play()
        } catch {
            // Hide-the-error here defeats the whole point of the
            // warm-keeper: silently failing means the operator's
            // countdown audio stutters and they have no idea why.
            // Surface the same lastAudioError + haptic pair that
            // session activation uses, so the existing
            // AudioSettingsView banner picks it up.
            log.error("warm-keeper start failed: \(error.localizedDescription, privacy: .public)")
            lastAudioError = "Audio warm-up failed — announcements may stutter at race start: \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            warmKeeperRunning = false
        }
    }

    /// Stops the silent warm-keeper. Audio HAL is allowed to idle
    /// back down once the engine is stopped — fine outside a race.
    func stopWarmKeeper() {
        // Any pending deferred stop is now superseded by the
        // immediate stop. Without this clear, a RESET that lands
        // mid-summary would stop the engine here, then a second
        // stop from the deferred path would fire later (no-op via
        // the `warmKeeperRunning` guard but still misleading state).
        stopWarmKeeperPending = false
        guard warmKeeperRunning else { return }
        warmKeeperRunning = false
        warmKeeperNode.stop()
        warmKeeperEngine.stop()
    }

    /// Asks for the warm-keeper to stop once the synth queue drains.
    /// Used by the FINAL-lap and STOP-with-laps paths so the race-
    /// end summary — which has just been enqueued — still plays
    /// through a warm HAL. The actual stop fires from
    /// `utteranceDidEnd()` the moment `inflightUtteranceCount` drops
    /// to 0. If the synth is already idle (e.g. TTS was disabled so
    /// no summary was enqueued), stop immediately.
    func stopWarmKeeperWhenIdle() {
        if inflightUtteranceCount == 0 {
            stopWarmKeeper()
        } else {
            stopWarmKeeperPending = true
        }
    }

    /// Synchronous variant of `configureSessionIfNeeded` for callers
    /// that need the session active before the next syscall (engine
    /// start). Routes the setCategory/setActive pair through
    /// `audioSessionQueue.sync` so this activate can't reorder
    /// against a previous `deactivateSession()`'s queued
    /// `setActive(false)` — otherwise the operator's RESET → immediate
    /// START sequence would have the queued deactivate land *after*
    /// our activate, deactivating the session we just brought up and
    /// leaving `sessionConfigured == true` lying about it.
    private func configureSessionSync() {
        guard !sessionConfigured else { return }
        var setupError: Error?
        audioSessionQueue.sync {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true, options: [])
            } catch {
                setupError = error
            }
        }
        if let setupError {
            log.error("AVAudioSession activation (sync) failed: \(setupError.localizedDescription, privacy: .public)")
            lastAudioError = "Audio unavailable: \(setupError.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } else {
            sessionConfigured = true
            lastAudioError = nil
        }
    }

    /// Drops any in-flight or queued speech. Dispatched through the
    /// same serial `synthQueue` as `speak()` so a cancel can't race
    /// past a queued speak that hasn't started yet — otherwise RESET
    /// could fire its `stopSpeaking` *before* the just-enqueued lap
    /// utterance reached the synth, leaving the lap to play after
    /// the visible state was already wiped.
    func cancel() {
        // Premium synth gets stopped unconditionally — `cancel()` is also a no-op there if
        // nothing is in flight, so the cheap call is fine even on a System-only race.
        premiumSynth.cancel()

        let synth = synthesizer
        synthQueue.async {
            // `stopSpeaking` returns false when there's nothing to
            // cancel — benign during RESET in the no-utterance case
            // but worth logging so a stuck-synth state (synth
            // refusing to stop while still reporting `isSpeaking ==
            // true`) shows up in Console for diagnosis instead of
            // silently lingering until the next session activate.
            if !synth.stopSpeaking(at: .immediate) {
                log.debug("cancel: stopSpeaking returned false (no utterance to stop)")
            }
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    /// Deactivate the audio session as soon as the utterance ends so other
    /// apps' audio fully un-ducks instead of staying suppressed for the
    /// rest of the app's lifetime. `.notifyOthersOnDeactivation` cues
    /// background-audio apps to ramp back up promptly.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.utteranceDidEnd()
            self.deactivateSession()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.utteranceDidEnd()
            self.deactivateSession()
        }
    }

    /// Decrement the in-flight counter and, if the queue is now empty
    /// AND TimerView has asked for a deferred warm-keeper stop, run
    /// it now. Centralized so `didFinish` and `didCancel` stay in
    /// sync — a missing decrement on either path would leave the
    /// warm-keeper running past the race end, ducking other apps'
    /// audio forever.
    private func utteranceDidEnd() {
        let newCount = inflightUtteranceCount - 1
        if newCount < 0 {
            // The invariant is +1 in `speak()` paired with exactly one
            // didFinish or didCancel from the synth. Underflow means
            // one of: a delegate callback fired twice for the same
            // utterance, a callback fired for an utterance we never
            // counted, or `speak()` was bypassed for an enqueue. Any
            // of those would silently corrupt warm-keeper / session
            // lifecycle decisions downstream, so log and assert in
            // debug — the `max(0, ...)` keeps release builds limping
            // along instead of permanently gating `deactivateSession`.
            log.error("inflightUtteranceCount underflow (\(self.inflightUtteranceCount, privacy: .public) -> \(newCount, privacy: .public)) — speak/utteranceDidEnd asymmetry")
            assertionFailure("inflightUtteranceCount underflow")
        }
        inflightUtteranceCount = max(0, newCount)
        if stopWarmKeeperPending && inflightUtteranceCount == 0 {
            stopWarmKeeperPending = false
            stopWarmKeeper()
        }
    }

    // MARK: - Internals

    /// `cancelInflight: true` (default) drops anything currently
    /// speaking — the right call for laps and the race-end summary
    /// where the latest event is what the operator needs. Countdown
    /// numbers pass `false` so consecutive ticks queue end-to-end
    /// instead of clipping each previous numeral.
    private func speak(_ phrase: String, cancelInflight: Bool = true) {
        // Premium routing: when the operator has selected the Premium engine AND has picked a
        // voice from the cloud catalog, dispatch the utterance to the cloud synth instead of
        // AVSpeechSynthesizer. Fall through to the system path on any of:
        //   - engine = "system" (explicit choice)
        //   - no premium voice picked yet (operator hasn't completed setup)
        //   - voice ID no longer matches a catalog entry (Premium catalog changed)
        // Falling through means the operator never gets surprised silence — worst case the
        // system voice speaks, which is what they'd have heard before opting in to Premium.
        if let premiumVoice = currentPremiumVoiceIfActive() {
            // Activate the shared session up front — Premium reuses the same `.playback /
            // .spokenAudio / .duckOthers` configuration, and the warm-keeper engine relies
            // on this having run at least once. Symmetric with the System path below.
            configureSessionIfNeeded()
            // Cancel any in-flight prewarm so the user-visible utterance doesn't race
            // against the prefetch burst for the upstream provider's per-IP rate limit.
            // Without this, tapping Start while prewarm is still issuing 3 concurrent
            // prefetches would make `speakAsync`'s Worker call the 4th simultaneous
            // request — the provider 429s, the Worker propagates it, and the operator's
            // Start cue silently fails. `premiumUtteranceEnded` re-fires the prewarm once
            // utterance ends; prefetch is idempotent on cache hits, so the resumed run
            // only picks up phrases the cancelled run hadn't reached.
            currentPrewarmTask?.cancel()
            currentPrewarmTask = nil
            // Treat a Premium utterance exactly like a System one for inflight bookkeeping.
            // Increment here; the matching decrement (+ deactivateSession) fires via the
            // `onEnd` callback when the Premium synth's utterance ends — drained, cancelled
            // by a subsequent `speakAsync`, or errored. Picker / paywall previews call
            // `premiumSynth.speakAsync(...)` directly without passing `onEnd`, so they do
            // NOT trigger this decrement (and they never incremented, so they don't need to).
            inflightUtteranceCount += 1
            premiumSynth.speakAsync(
                text: phrase,
                lang: premiumVoice.lang,
                voice: premiumVoice,
                onEnd: { [weak self] in self?.premiumUtteranceEnded() },
            )
            return
        }

        configureSessionIfNeeded()

        // Build the utterance on main (cheap allocation + cached voice
        // resolution + UserDefaults reads), then hand the synth calls
        // off to a serial background queue so the ~30 ms enqueue lock
        // inside `AVSpeechSynthesizer.speak()` doesn't stall the
        // SwiftUI render cycle right at voice-start.
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = currentVoice()
        utterance.rate = currentRate()
        utterance.pitchMultiplier = currentPitch()
        utterance.volume = 1.0

        let synth = synthesizer
        inflightUtteranceCount += 1
        synthQueue.async {
            // `cancelInflight` is evaluated on this serial queue —
            // not on main when speak() was called — so it can't be
            // stale. Reading `synth.isSpeaking` on main and dispatching
            // the decision risks the cancel being skipped when the
            // previous speak is still pending in this same queue
            // (`isSpeaking` is still false at the time of the read);
            // by the time *this* closure runs that earlier speak has
            // already begun, and the `cancelInflight: true` contract
            // demands it be preempted. A `stopSpeaking` on an idle
            // synth is a documented no-op; the debug log keeps the
            // "stuck synth" observability the pre-refactor cancel()
            // had.
            if cancelInflight {
                let stopped = synth.stopSpeaking(at: .immediate)
                if !stopped {
                    log.debug("speak: stopSpeaking returned false (no utterance to cancel)")
                }
            }
            synth.speak(utterance)
        }
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
        // `sessionConfigured = true` only flips after `setActive`
        // actually succeeds — an optimistic pre-dispatch flag lets
        // `configureSessionSync` see "true" while the async setActive
        // is still mid-flight and proceed against a not-yet-active
        // session.
        //
        // The activation Task ends with a `deactivateSession()` call
        // because `didFinish`'s deactivate Task can be scheduled
        // before this activation Task lands on the main actor —
        // Task @MainActor ordering across separate Task entries is
        // not strictly FIFO. Without the retry, the deactivate sees
        // `!sessionConfigured` and early-returns, leaving the
        // session active forever for short out-of-race utterances
        // (Test Voice, ad-hoc lap call).
        audioSessionQueue.async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true, options: [])
                Task { @MainActor [weak self] in
                    self?.sessionConfigured = true
                    self?.lastAudioError = nil
                    // Re-evaluate any pending deactivate that bailed
                    // out on a stale `!sessionConfigured` read.
                    self?.deactivateSession()
                }
            } catch {
                // Most likely cause: another app holds an exclusive audio
                // category (Voice Memos recording, active call). A race
                // operator can't read Console.app from their pocket, so we
                // also surface the error to the UI via `lastAudioError`
                // and fire a haptic so they know audio didn't take.
                log.error("AVAudioSession activation failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor [weak self] in
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
        // Same race the `sessionHoldActive` didSet has to guard against:
        // an utterance can be queued (counter incremented in `speak()`)
        // but not yet dispatched to the synth worker. Deactivating the
        // session in that window glitches the about-to-start playback.
        // The delegate path always decrements the counter *before*
        // calling back into here, so when it drops to 0 we know the
        // last utterance is fully done and it's safe to deactivate.
        guard inflightUtteranceCount == 0 else { return }
        // Hold mode: TimerView wants the session kept active across
        // utterances during a race. The next `sessionHoldActive = false`
        // either deactivates immediately (via `didSet` when synth is
        // idle) or falls through to the subsequent `didFinish` /
        // `didCancel` once the in-flight utterance ends.
        guard !sessionHoldActive else { return }
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

        // Cache hit: the operator hasn't changed Settings since last
        // resolve, so the same AVSpeechSynthesisVoice object is still
        // valid. Skips the `AVSpeechSynthesisVoice(identifier:)` /
        // `(language:)` construction that otherwise runs on every
        // utterance.
        let key = "\(language.rawValue)|\(id)"
        if cachedVoiceKey == key, let cached = cachedVoice {
            return cached
        }

        let resolved = resolveVoice(language: language, identifier: id)
        // Only cache a successful resolution. Caching nil would pin
        // the synth to its hidden default voice forever once a
        // transient voice-data outage happens (Settings → Spoken
        // Content → Voices is mid-download, locale just changed,
        // etc.); on the next utterance we'd hand AVSpeechSynthesizer
        // a `nil` voice and never retry. Leaving the cache empty
        // means the next call re-tries the lookup — usually free
        // once the voice is back on disk.
        if let resolved {
            cachedVoiceKey = key
            cachedVoice = resolved
        }
        return resolved
    }

    private func resolveVoice(language: LapAnnouncerLanguage, identifier id: String) -> AVSpeechSynthesisVoice? {
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
        let fallback = AVSpeechSynthesisVoice(language: language.fallbackVoiceLanguage)
        if fallback == nil {
            // No voice at all for this language — the system has no
            // installed voice for, say, `ja-JP`, possibly because the
            // operator restored to a region that doesn't ship one or
            // the voice-data download is mid-flight. Without this
            // surface, AVSpeechSynthesizer falls back to its hidden
            // default voice silently and the operator hears `en-US`
            // for a `ja-JP`-tagged race — easy to miss until a lap
            // time reads as gibberish numbers.
            log.error("No AVSpeechSynthesisVoice available for \(language.fallbackVoiceLanguage, privacy: .public) — synth will fall back to system default voice")
            lastAudioError = "No voice installed for \(language.fallbackVoiceLanguage). Install one in Settings → Accessibility → Spoken Content → Voices."
        }
        return fallback
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

    /// Returns the selected cloud voice IF the operator is set up to use the Premium engine
    /// right now — engine prefence is "premium", a voice has been picked, and that voice ID
    /// still resolves in the current catalog. Returning nil drops the caller back to the
    /// system AVSpeechSynthesizer path, which is the right behaviour for every "premium isn't
    /// ready yet" case so the operator never hears silence.
    private func currentPremiumVoiceIfActive() -> PremiumVoiceOption? {
        let defaults = UserDefaults.standard
        let engine = defaults.string(forKey: LapAnnouncerDefaults.engineKey)
            ?? LapAnnouncerDefaults.defaultEngine
        guard engine == "premium" else { return nil }
        let voiceId = (defaults.string(forKey: LapAnnouncerDefaults.premiumVoiceIdentifierKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceId.isEmpty else { return nil }
        return PremiumVoiceCatalog.voices.first { $0.id == voiceId }
    }

    /// Best-effort: pre-populate the Premium TTS local cache for every phrase that has
    /// a fixed, deterministic string (countdown numbers + start / last-lap cues) in the
    /// currently selected language + voice. Idempotent — phrases already on disk are
    /// skipped inside `PremiumSpeechSynthesizer.prefetch`. No-op when the operator is on
    /// the System engine, since `AVSpeechSynthesizer` has no network round-trip to hide.
    ///
    /// Why: Premium TTS cold playback runs 600–1000 ms on Azure/Polly and the 1-second
    /// countdown tick drops alternate numbers via `announceCountdown`'s `inflightUtteranceCount`
    /// guard. Prefetching once per (language × voice) change collapses every countdown
    /// number plus the start / last-lap cues to a near-zero local cache read at race time.
    ///
    /// Wired to two triggers:
    ///   1. App launch (after `SubscriptionManager.start()` so `jwsProvider` is wired —
    ///      the JWS itself may still be nil at this moment, but the bearer fallback in
    ///      `PremiumSpeechSynthesizer.prefetch` (panel bearer → `BuildSecrets.workerBearer`)
    ///      makes a missing JWS non-fatal for prefetching).
    ///   2. Settings sheet dismissal in `TimerView` (`.onChange(of: showSettings)` on the
    ///      true → false transition). Catches every Premium control change in one place:
    ///      voice, language, engine toggle, countdown duration, AND the rate / pitch
    ///      sliders. Per-`@AppStorage` onChange hooks were tried first and discarded —
    ///      they fired multiple times per Settings session, missed rate / pitch entirely
    ///      (per-tick prewarm would burn API on exploratory drags), and required
    ///      boilerplate per setting. The dismissal point is the operator's "done
    ///      tweaking, about to race" moment — exactly when the cache needs to be warm.
    ///
    /// Fires on a detached Task so the caller doesn't await; the cache writes are pure
    /// disk side-effects with no UI dependency.
    func prewarmFixedPhrases() {
        guard let voice = currentPremiumVoiceIfActive() else { return }
        let phrases = fixedPrewarmPhrases(for: currentLanguage())
        let synth = premiumSynth
        let lang = voice.lang
        // Cancel any prior prewarm before starting fresh — repeated Settings
        // dismissals (or `premiumUtteranceEnded` re-fires) would otherwise stack
        // up multiple concurrent TaskGroups, multiplying the upstream per-IP load.
        currentPrewarmTask?.cancel()
        currentPrewarmTask = Task.detached { @MainActor in
            // Streaming TaskGroup with bounded concurrency. Firing all 14
            // phrases in parallel previously triggered the upstream provider's
            // per-IP rate limit (Worker propagates upstream 429 verbatim), so
            // some prefetches dropped on a voice switch and the next race lost
            // countdown numbers. A cap of 3 keeps the burst inside the provider
            // allowance while still finishing the whole prewarm in ~3-5 s on a
            // warm network. Polly and Azure are both more permissive than the
            // cap, but the cap is the floor in case future providers are tighter.
            let maxConcurrent = 3
            await withTaskGroup(of: Void.self) { group in
                var iterator = phrases.makeIterator()
                // Seed up to `maxConcurrent` tasks.
                for _ in 0..<maxConcurrent {
                    guard let phrase = iterator.next() else { break }
                    group.addTask { @MainActor in
                        await synth.prefetch(text: phrase, lang: lang, voice: voice)
                    }
                }
                // For each completion, top up with the next pending phrase
                // so the inflight count stays at the cap until exhausted.
                while await group.next() != nil {
                    guard let phrase = iterator.next() else { continue }
                    group.addTask { @MainActor in
                        await synth.prefetch(text: phrase, lang: lang, voice: voice)
                    }
                }
            }
        }
    }

    /// The set of strings `LapAnnouncer` will ever pass to `speak()` whose value is
    /// fixed (independent of lap time / number / total). Kept in sync with
    /// `announceStart()`, `announceLastLap()`, and `announceCountdown()` — any new
    /// fixed phrase must be added here or it won't be prewarmed.
    private func fixedPrewarmPhrases(for language: LapAnnouncerLanguage) -> [String] {
        let countdownMax = (UserDefaults.standard.object(forKey: LapAnnouncerDefaults.countdownStartSecondsKey) as? Int)
            ?? LapAnnouncerDefaults.defaultCountdownStartSeconds
        let upper = max(LapAnnouncerDefaults.minCountdownStartSeconds,
                        min(LapAnnouncerDefaults.maxCountdownStartSeconds, countdownMax))
        var phrases = (1...upper).map { String($0) }
        switch language {
        case .english:
            phrases.append("Start")
            phrases.append("Last lap!")
        case .japanese:
            phrases.append("スタート")
            phrases.append("ファイナルラップです")
        }
        return phrases
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
                // `、` (instead of a space) between the lap number and the lap time is required
                // for the Polly/Azure cloud voices to read "12.34" as the cardinal
                // "じゅうにてん さんよん" — without the punctuation the synth in particular falls
                // into digit-by-digit phone-number reading ("いちに さんよん"). System TTS handles
                // both forms identically, so the same string works for both engines.
                return "ラップ\(lastLap.id)、\(lastLapStr)秒、トータル\(lapCount)周、\(totalJP)、ベストラップは\(bestStr)秒でした"
            }
            return "\(lapCount)周、\(totalJP)、ベストラップは\(bestStr)秒でした"
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
    /// practice the function is invoked exactly once per app launch
    /// from `LapAnnouncer.init`'s background `Task.detached`, so the
    /// unsynchronized read/write of `lastDumpedVoiceIds` can't race.
    /// Marking it explicitly silences the Swift 6 warning and
    /// documents the single-caller invariant — adding a second caller
    /// (e.g. from AudioSettingsView's `.onAppear`) would invalidate
    /// this and require a real lock.
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
