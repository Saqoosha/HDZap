import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "sh.saqoo.HDZap", category: "PremiumTTS")

/// UserDefaults keys for the DEBUG-only Premium TTS dev panel. These let an internal tester
/// override the Worker URL / Bearer at runtime without rebuilding. Production playback
/// pulls the bearer from `SubscriptionManager.currentJWS` via the `jwsProvider` closure —
/// these defaults are only consulted when no JWS is available (panel test, free preview).
enum PremiumTTSDevDefaults {
    static let workerURLKey = "_premiumWorkerURL"
    static let bearerKey = "_premiumWorkerBearer"
    static let voiceIdKey = "_premiumWorkerVoiceId"
    static let defaultWorkerURL = "https://hdzap-premium.saqoosha.workers.dev/tts"
    static let defaultVoiceId = "06950fa3-534d-46b3-93bb-f852770ea0b5"  // Takeshi - Hero (JA)
}

/// Which upstream TTS service should the Worker call for a given voice. Each provider returns
/// a different audio format on the wire — the synth uses this to pick the decode path.
enum PremiumVoiceProvider: String, Codable {
    /// Cartesia Sonic 3.5 — SSE event stream of base64-encoded raw PCM s16le @ 24kHz.
    case cartesia
    /// AWS Polly Neural via SigV4 (Cognito Identity Pool) — chunked mp3 over HTTPS.
    case polly
    /// Azure AI Speech Neural via subscription key — chunked mp3 over HTTPS.
    case azure

    /// `<prosody rate>` (or equivalent) support per provider as of 2026-05.
    ///   - Cartesia Sonic 3.5: prosody controls explicitly disabled in the preview release
    ///   - Polly Neural: rate yes via `<prosody rate>` percentage
    ///   - Azure Neural: rate yes via SSML
    var supportsRate: Bool {
        switch self {
        case .cartesia: return false
        case .polly, .azure: return true
        }
    }

    /// `<prosody pitch>` support. Polly Neural REJECTS pitch with "Unsupported Neural
    /// feature" — only Standard voices accept it, and our catalog ships Neural only.
    /// Cartesia Sonic 3.5 also disabled it in preview. So only Azure is fully covered.
    var supportsPitch: Bool {
        switch self {
        case .cartesia, .polly: return false
        case .azure: return true
        }
    }
}

/// One row in the voice picker. `provider` decides Worker routing and audio format on the
/// client; the same `id` namespace per provider is opaque to us (Cartesia UUIDs, Polly Pascal
/// names, Azure full locale-qualified names).
struct PremiumVoiceOption: Identifiable, Hashable {
    let id: String
    let label: String
    let lang: String
    let provider: PremiumVoiceProvider
}

/// Premium TTS voice catalog (Cartesia 22 JA + 3 EN, Polly 3 JA + 11 EN Neural, Azure 7 JA
/// + 9 EN Neural). Polly + Azure each ship far more voices than this — we keep the menu
/// scoped to race-announcer / friendly-narrator personas (US/UK/AU accents covered across
/// providers) so the picker stays scannable mid-race.
enum PremiumVoiceCatalog {
    static let voices: [PremiumVoiceOption] = [
        // ── Cartesia JA (all 22) ───────────────────────────────────────────────────
        .init(id: "498e7f37-7fa3-4e2c-b8e2-8b6e9276f956", label: "Cartesia · Aiko - Calming",                 lang: "ja", provider: .cartesia),
        .init(id: "446f922f-c43a-4aad-9a8b-ad2af568e882", label: "Cartesia · Akira - Professional",           lang: "ja", provider: .cartesia),
        .init(id: "63d6f469-8c2c-489d-b53f-d36f0bbdcd4b", label: "Cartesia · Ayako",                          lang: "ja", provider: .cartesia),
        .init(id: "31c55968-a9f4-4115-8831-3a16952179c8", label: "Cartesia · Ayumi - Sales Guide",            lang: "ja", provider: .cartesia),
        .init(id: "a759ecc5-ac21-487e-88c7-288bdfe76999", label: "Cartesia · Daichi - Baritone",              lang: "ja", provider: .cartesia),
        .init(id: "e8a863c6-22c7-4671-86ca-91cacffc038d", label: "Cartesia · Daisuke - Businessman",          lang: "ja", provider: .cartesia),
        .init(id: "c7eafe22-8b71-40cd-850b-c5a3bbd8f8d2", label: "Cartesia · Emi - Soft-Spoken",              lang: "ja", provider: .cartesia),
        .init(id: "97e7d7a9-dfaa-4758-a936-f5f844ac34cc", label: "Cartesia · Fuji - Positive",                lang: "ja", provider: .cartesia),
        .init(id: "861213b7-f057-45c8-9527-0f4c144f1a03", label: "Cartesia · Haruka - Gracious",              lang: "ja", provider: .cartesia),
        .init(id: "d0ff6870-dd30-420d-8568-d756d806ea62", label: "Cartesia · Hinata - Graceful",              lang: "ja", provider: .cartesia),
        .init(id: "1d210168-d764-462c-8ab6-288a6d5a9579", label: "Cartesia · Hiroshi - Director",             lang: "ja", provider: .cartesia),
        .init(id: "44863732-e415-4084-8ba1-deabe34ce3d2", label: "Cartesia · Kaori - Friendly Narrator",      lang: "ja", provider: .cartesia),
        .init(id: "9436e723-612d-4114-aeb0-fa00d4d639bf", label: "Cartesia · Katsuya - Promo Host",           lang: "ja", provider: .cartesia),
        .init(id: "6b92f628-be90-497c-8f4c-3b035002df71", label: "Cartesia · Kenji - Calm",                   lang: "ja", provider: .cartesia),
        .init(id: "177df681-25b1-48c2-bb47-03ca5fa27f0a", label: "Cartesia · Ren - Calm Navigator",           lang: "ja", provider: .cartesia),
        .init(id: "9e7ef2cf-b69c-46ac-9e35-bbfd73ba82af", label: "Cartesia · Ren - High-Energy",              lang: "ja", provider: .cartesia),
        .init(id: "0cd0cde2-3b93-42b5-bcb9-f214a591aa29", label: "Cartesia · Sayuri - Peppy",                 lang: "ja", provider: .cartesia),
        .init(id: "b8e1169c-f16a-4064-a6e0-95054169e553", label: "Cartesia · Takashi - Professional",         lang: "ja", provider: .cartesia),
        .init(id: "06950fa3-534d-46b3-93bb-f852770ea0b5", label: "Cartesia · Takeshi - Hero",                 lang: "ja", provider: .cartesia),
        .init(id: "49e02441-83ea-4c77-bda8-79fdd7f07e92", label: "Cartesia · Tohru - Career Coach",           lang: "ja", provider: .cartesia),
        .init(id: "59d4fd2f-f5eb-4410-8105-58db7661144f", label: "Cartesia · Yuki - Calm Woman",              lang: "ja", provider: .cartesia),
        .init(id: "2b568345-1d48-4047-b25f-7baccf842eb0", label: "Cartesia · Yumiko - Friendly Agent",        lang: "ja", provider: .cartesia),
        // ── Polly JA (3 Neural) ─────────────────────────────────────────────────────
        .init(id: "Takumi", label: "Polly · Takumi (male, Neural)",   lang: "ja", provider: .polly),
        .init(id: "Kazuha", label: "Polly · Kazuha (female, Neural)", lang: "ja", provider: .polly),
        .init(id: "Tomoko", label: "Polly · Tomoko (female, Neural)", lang: "ja", provider: .polly),
        // ── Azure JA (7 Neural) ─────────────────────────────────────────────────────
        .init(id: "ja-JP-DaichiNeural", label: "Azure · Daichi (male)",   lang: "ja", provider: .azure),
        .init(id: "ja-JP-KeitaNeural",  label: "Azure · Keita (male)",    lang: "ja", provider: .azure),
        .init(id: "ja-JP-NaokiNeural",  label: "Azure · Naoki (male)",    lang: "ja", provider: .azure),
        .init(id: "ja-JP-AoiNeural",    label: "Azure · Aoi (female)",    lang: "ja", provider: .azure),
        .init(id: "ja-JP-MayuNeural",   label: "Azure · Mayu (female)",   lang: "ja", provider: .azure),
        .init(id: "ja-JP-NanamiNeural", label: "Azure · Nanami (female)", lang: "ja", provider: .azure),
        .init(id: "ja-JP-ShioriNeural", label: "Azure · Shiori (female)", lang: "ja", provider: .azure),
        // ── Cartesia EN (handpicked) ────────────────────────────────────────────────
        .init(id: "2f22b9bc-b0eb-4cb6-b5ae-0c099a0fdfad", label: "Cartesia · Scott - Sportscaster",      lang: "en", provider: .cartesia),
        .init(id: "820a3788-2b37-4d21-847a-b65d8a68c99a", label: "Cartesia · Tyler - Friendly Salesman", lang: "en", provider: .cartesia),
        .init(id: "62305e79-9d39-4643-b003-5e0b096fe4f4", label: "Cartesia · Madison - Best Friend",     lang: "en", provider: .cartesia),
        // ── Polly EN (Neural, handpicked) ───────────────────────────────────────────
        // Newscaster-style (Matthew, Joanna, Stephen, Ruth) reads numbers cleanest for
        // race calls; conversational picks (Joey, Brian, Arthur) round out the menu.
        .init(id: "Matthew",  label: "Polly · Matthew (US male, newscaster)", lang: "en", provider: .polly),
        .init(id: "Stephen",  label: "Polly · Stephen (US male, newscaster)", lang: "en", provider: .polly),
        .init(id: "Joey",     label: "Polly · Joey (US male)",                lang: "en", provider: .polly),
        .init(id: "Joanna",   label: "Polly · Joanna (US female, newscaster)", lang: "en", provider: .polly),
        .init(id: "Ruth",     label: "Polly · Ruth (US female, newscaster)",  lang: "en", provider: .polly),
        .init(id: "Kendra",   label: "Polly · Kendra (US female)",            lang: "en", provider: .polly),
        .init(id: "Brian",    label: "Polly · Brian (UK male)",               lang: "en", provider: .polly),
        .init(id: "Arthur",   label: "Polly · Arthur (UK male)",              lang: "en", provider: .polly),
        .init(id: "Amy",      label: "Polly · Amy (UK female)",               lang: "en", provider: .polly),
        .init(id: "Emma",     label: "Polly · Emma (UK female)",              lang: "en", provider: .polly),
        .init(id: "Olivia",   label: "Polly · Olivia (AU female)",            lang: "en", provider: .polly),
        // ── Azure EN (Neural, handpicked) ───────────────────────────────────────────
        // Davis / Tony / Guy are the strongest US-male picks for race calls; Aria + Jenny
        // are Azure's most natural US females. Ryan + Sonia add a UK option.
        .init(id: "en-US-DavisNeural",  label: "Azure · Davis (US male)",   lang: "en", provider: .azure),
        .init(id: "en-US-TonyNeural",   label: "Azure · Tony (US male)",    lang: "en", provider: .azure),
        .init(id: "en-US-GuyNeural",    label: "Azure · Guy (US male)",     lang: "en", provider: .azure),
        .init(id: "en-US-JasonNeural",  label: "Azure · Jason (US male)",   lang: "en", provider: .azure),
        .init(id: "en-US-AriaNeural",   label: "Azure · Aria (US female)",  lang: "en", provider: .azure),
        .init(id: "en-US-JennyNeural",  label: "Azure · Jenny (US female)", lang: "en", provider: .azure),
        .init(id: "en-US-SaraNeural",   label: "Azure · Sara (US female)",  lang: "en", provider: .azure),
        .init(id: "en-GB-RyanNeural",   label: "Azure · Ryan (UK male)",    lang: "en", provider: .azure),
        .init(id: "en-GB-SoniaNeural",  label: "Azure · Sonia (UK female)", lang: "en", provider: .azure),
    ]

    static func voices(for lang: String) -> [PremiumVoiceOption] {
        voices.filter { $0.lang == lang }
    }
}

enum PremiumTTSError: Error, LocalizedError {
    case missingConfig(String)
    case invalidURL
    case http(Int, String)
    case streamFailure(String)
    case engineFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig(let what):  return "Premium TTS not configured: \(what)"
        case .invalidURL:                return "Premium TTS worker URL is invalid"
        case .http(let code, let body):  return "Worker returned \(code): \(body.prefix(120))"
        case .streamFailure(let s):      return "Audio stream failure: \(s)"
        case .engineFailure(let s):      return "AVAudioEngine failure: \(s)"
        }
    }
}

/// Streams cloud TTS audio (Cartesia SSE, Polly + Azure raw PCM) into `AVAudioPlayerNode`.
///
/// Pipeline:
/// 1. POST text/voice/lang to the Worker `/tts` endpoint. The Bearer is the Apple-signed
///    JWS for entitled subscribers (via `jwsProvider`) or the baked-in dev bearer otherwise.
/// 2. Read the response body as a streaming byte sequence (`URLSession.AsyncBytes`).
/// 3. Decode each provider's wire format: Cartesia is SSE-framed base64 PCM s16le 24 kHz;
///    Polly + Azure are raw chunked PCM (Polly 16 kHz, Azure 24 kHz).
/// 4. Wrap each chunk in `AVAudioPCMBuffer` (24 kHz → direct, 16 kHz → AVAudioConverter
///    upsample) and schedule on a player node attached to a private `AVAudioEngine`.
///
/// Audio session: configures `.playback` + `.spokenAudio` + `.duckOthers` independently of
/// `LapAnnouncer`. Both synthesisers share the same `AVAudioSession` (process-singleton)
/// and the same category options, so concurrent `setActive(true)` calls are idempotent.
@MainActor
@Observable
final class PremiumSpeechSynthesizer: NSObject {
    /// Returns the Apple-signed JWS for the active entitlement, else nil. When non-nil,
    /// the JWS is sent as the Bearer token and the Worker validates it against Apple Root
    /// CA G3 — the path real race-time playback takes. When nil, the synth falls back to
    /// `BuildSecrets.workerBearer` (the preview path the picker uses pre-subscription).
    var jwsProvider: () -> String? = { nil }

    /// Cartesia returns `pcm_s16le` at 24kHz mono. We convert to Float32 on the fly because
    /// AVAudioEngine's mixer is happiest with floats — going through Int16 hit silent failures
    /// on iOS 18 where `int16ChannelData` returned nil and the buffer scheduled as silence.
    /// Conversion is trivial (`Float(s16) / 32768`) and runs once per chunk on the main actor.
    private static let sourceFormat: AVAudioFormat = {
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 24000,
                                    channels: 1,
                                    interleaved: false) else {
            preconditionFailure("AVAudioFormat init for 24kHz float32 mono failed — should be impossible")
        }
        return f
    }()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var engineAttached = false
    private var sessionConfigured = false

    /// `Task` we kick off in `speak(...)`. Cancelling it both aborts the URLSession stream
    /// (via `Task.checkCancellation`) AND tells the player to stop scheduling more buffers.
    private var currentTask: Task<Void, Never>?

    /// Tracks how many buffers we've scheduled but not yet heard back from. When this drops
    /// to 0 and the network task has finished, we can flip `isPlaying` off.
    private var pendingBuffers = 0

    /// Per-utterance monotonic counter. Bumped by `cancel()` (and implicitly by every fresh
    /// `speak()` which calls cancel first). Each scheduled buffer captures the generation
    /// active at schedule time; the completion callback only mutates state if its captured
    /// generation still matches the live one — stale callbacks from a cancelled utterance
    /// can no longer flip `isPlaying` false on a subsequent fresh utterance.
    private var currentGeneration: UInt64 = 0

    var isPlaying: Bool = false
    var lastError: String?

    /// Per-call completion callback registered by `speakAsync`. Fires exactly once per
    /// `speakAsync` invocation: when playback drains, when `cancel()` runs while this call
    /// is still the active one, or when the `speak()` Task throws. Callers that don't pass
    /// `onEnd` opt out of the notification — picker / paywall previews bypass
    /// `LapAnnouncer`'s `inflightUtteranceCount` increment, so they MUST NOT receive a
    /// decrement here or the counter goes negative and `utteranceDidEnd()`'s underflow
    /// assertion trips. Cleared inside `notifyEnd` after firing so the same speakAsync
    /// can't dispatch its callback twice.
    private var pendingOnEnd: (() -> Void)?
    /// Set when the first audio chunk reaches the speaker. Used by the dev panel to surface
    /// real-world TTFA next to the network-only number Python measured.
    private(set) var lastFirstAudioMs: Double?
    /// Observable counters so the dev panel can show "what's the synth actually doing right now"
    /// without depending on os_log capture. Updated on the main actor by the SSE parser.
    private(set) var debugSseLines = 0
    private(set) var debugSseEvents = 0
    private(set) var debugChunks = 0
    private(set) var debugBytesScheduled = 0
    private(set) var debugEngineRunning = false
    private(set) var debugPlayerPlaying = false
    private(set) var debugHttpStatus: Int = 0
    private(set) var debugPhase: String = "idle"
    private(set) var debugFlow: [String] = []  // timeline of state transitions, newest at top

    private func note(_ phase: String) {
        debugPhase = phase
        let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100))
        debugFlow.insert("\(ts)  \(phase)", at: 0)
        if debugFlow.count > 12 { debugFlow.removeLast() }
    }

    /// True once `parseSSE` (or the mp3 download loop) has consumed the entire response body.
    /// Used together with `pendingBuffers` so we only flip `isPlaying` false when BOTH the
    /// network is done AND every scheduled audio buffer has actually drained through the
    /// speaker — the previous logic flipped `isPlaying` at end-of-network, but for short
    /// utterances that's seconds before the audio finishes playing, which made the picker's
    /// stop icon revert to play far too early.
    private var streamReceiveComplete = false

    override init() {
        super.init()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: Self.sourceFormat)
        engineAttached = true
        // `prepare()` allocates the rendering resources up front. Without it the first
        // scheduleBuffer can race with engine.start() and drop the buffer on the floor.
        engine.prepare()
        log.notice("engine init: outputFormat=\(self.engine.outputNode.outputFormat(forBus: 0).description, privacy: .public)  mixerFormat=\(self.engine.mainMixerNode.outputFormat(forBus: 0).description, privacy: .public)")
    }

    /// Stops any in-flight request and playback. Idempotent. Bumps `currentGeneration` so
    /// queued completion callbacks from the cancelled utterance can't mutate state that
    /// belongs to a subsequent fresh utterance — `&+= 1` deliberately wraps on overflow
    /// so a 2^64 cancel storm doesn't trap (the buffers carrying a wrapped-around
    /// generation are long dead). Stops the AVAudioEngine too — leaving it running keeps
    /// `.duckOthers` ducking other apps' audio forever after a user-driven preview swap,
    /// which we hit during voice-picker auditions.
    func cancel() {
        currentGeneration &+= 1
        currentTask?.cancel()
        currentTask = nil
        if playerNode.isPlaying { playerNode.stop() }
        // `reset()` is the only way to drop scheduled buffers that haven't started
        // playing back yet — `stop()` alone leaves them in the node's internal queue,
        // and they will replay on the next `play()` even though we consider the
        // utterance cancelled.
        playerNode.reset()
        if engine.isRunning { engine.stop() }
        // `engine.reset()` flushes the pending buffers in every attached node — the
        // player above plus the main mixer and the output unit. Without this, the
        // tail of a previous utterance can sit in a downstream AudioUnit's internal
        // render buffer (a few ms worth) and bleed into the next playback once
        // `engine.start()` runs again. Symptom that motivated this: paywall / picker
        // sample preview finished, operator tapped Start, and the new "スタート"
        // playback opened with a phantom "ト" from the previous utterance's tail —
        // not from the sample's last syllable (the JA sample text "ラップ3、12.34、
        // ベストラップ" ends in "プ", not "ト"), so the bleed was the prior race's
        // own "スタート" tail or a prewarm-buffered chunk that survived `stop()`.
        // Called unconditionally — safe on a stopped engine, free insurance for the
        // first-run path.
        engine.reset()
        // Drop the polyphase resampler so a Polly → Polly preview-then-race sequence
        // can't carry filter-tail state from the previous utterance — the same class
        // of bleed `engine.reset()` solves for the AudioUnit side, but for the
        // sample-rate converter the synth holds independently of the engine graph.
        // `buildBufferResampled` lazy-inits a fresh converter on next use.
        resampleConverter = nil
        resampleConverterRate = 0
        pendingBuffers = 0
        streamReceiveComplete = false
        accumulatedPCM.removeAll(keepingCapacity: true)
        note("cancel")
        notifyEnd()
    }

    /// Fire the pending end-of-utterance callback exactly once per `speakAsync` call and
    /// clear it. Called from `cancel()`, the drained-buffer completion handler, the
    /// post-stream `isPlaying` flip, and the speakAsync catch path. Doesn't gate on
    /// `isPlaying` because the speakAsync call may have failed BEFORE `isPlaying = true`
    /// reached its assignment (e.g., `configureSession()` threw on a bad audio route);
    /// LapAnnouncer has already incremented `inflightUtteranceCount` by then and needs
    /// the matched decrement regardless of whether audio actually started.
    private func notifyEnd() {
        let cb = pendingOnEnd
        pendingOnEnd = nil
        isPlaying = false
        cb?()
    }

    /// Resets all debug counters so the next Speak shows a clean timeline.
    func resetDebug() {
        debugSseLines = 0
        debugSseEvents = 0
        debugChunks = 0
        debugBytesScheduled = 0
        debugEngineRunning = engine.isRunning
        debugPlayerPlaying = playerNode.isPlaying
        debugHttpStatus = 0
        debugFlow.removeAll()
        lastError = nil
        lastFirstAudioMs = nil
    }

    /// Cache key for the in-flight speak() request. Set at the top of `speak()` so the
    /// SSE and raw-PCM write paths can save under the same key without re-deriving it.
    /// Cleared on completion / failure so a subsequent miss writes to the right entry.
    private var currentCacheKey: String?
    /// Paired with `currentCacheKey` — the provider whose audio bytes we'll be saving, so
    /// `TTSCache.save()` can label the file correctly.
    private var currentCacheProvider: PremiumVoiceProvider?

    /// Sample rate of the PCM stream for the in-flight speak(). Cartesia + Azure send
    /// 24 kHz so `schedulePCM` takes the fast manual-conversion path. Polly Neural's PCM
    /// output caps at 16 kHz, which routes through `resampleConverter` to upsample to the
    /// engine's 24 kHz before scheduling.
    private var currentSampleRate: Double = 24000

    /// Lazy-initialised resampler used only when `currentSampleRate != 24000`. Re-created
    /// when the rate changes (different provider in a new speak() call). The converter
    /// owns its internal state so reuse within a single utterance is correct, but a new
    /// rate needs a fresh one.
    private var resampleConverter: AVAudioConverter?
    private var resampleConverterRate: Double = 0

    /// Decoded raw PCM accumulated across the Cartesia SSE stream for this speak() call.
    /// We write the concatenated bytes to `TTSCache` once the stream completes — way more
    /// disk-efficient than caching the SSE wrapper (base64 + JSON framing adds ~30%).
    /// Cleared at the start of every speak() so a partial stream from a prior failed call
    /// can't bleed into the next entry.
    private var accumulatedPCM = Data()

    /// Fire-and-forget version of `speak(text:lang:voice:)` for `Button` action callbacks.
    /// Tears down any in-flight playback first (full `cancel()` — task, player, engine,
    /// buffers, pendingOnEnd-for-the-previous-call all fire/clear) before spawning the
    /// new task.
    ///
    /// `onEnd` is the completion callback for this specific call: it fires exactly once
    /// when the utterance ends (drain / cancel-while-active / error). `LapAnnouncer.speak`
    /// passes a decrement closure so `inflightUtteranceCount` stays balanced. Picker /
    /// paywall previews bypass `LapAnnouncer.speak` entirely (no increment), so they MUST
    /// NOT pass `onEnd` — otherwise the counter goes negative on every preview end.
    func speakAsync(
        text: String,
        lang: String,
        voice: PremiumVoiceOption,
        onEnd: (() -> Void)? = nil,
    ) {
        log.notice("speakAsync invoked: text=\"\(text, privacy: .public)\" provider=\(voice.provider.rawValue, privacy: .public) voice=\(voice.id, privacy: .public) lang=\(voice.lang, privacy: .public)")
        cancel()
        pendingOnEnd = onEnd
        // Set `isPlaying = true` BEFORE spawning the Task so any early-error path
        // (`bearer.isEmpty`, bad URL, `configureSession()` failure — all of which throw
        // before `speak()` would set it) still produces a clean end notification through
        // `notifyEnd` instead of leaking `LapAnnouncer.inflightUtteranceCount`.
        isPlaying = true
        // Capture the generation this Task represents — bumped to a fresh value by the
        // `cancel()` above. If a NEW `speakAsync` arrives while this Task is running, its
        // own `cancel()` will bump again, fire our `pendingOnEnd` cleanly, and start a
        // fresh Task. Our cancelled body's catch then sees the mismatch and bails without
        // calling `cancel()` again (which would tear down the new task).
        let myGeneration = currentGeneration
        currentTask = Task { [weak self] in
            do {
                try await self?.speak(text: text, lang: voice.lang, voice: voice)
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard myGeneration == self.currentGeneration else {
                        // Superseded by a newer speakAsync — the new call already
                        // fired our onEnd via its `cancel()`. Don't touch state that
                        // belongs to the now-active utterance.
                        log.debug("speakAsync catch: superseded (myGen=\(myGeneration, privacy: .public) currentGen=\(self.currentGeneration, privacy: .public)) — skipping cancel")
                        return
                    }
                    self.lastError = error.localizedDescription
                    log.error("speak failed: \(error.localizedDescription, privacy: .public)")
                    // Tear down audio + emit end-of-utterance for this still-current call.
                    self.cancel()
                }
            }
        }
    }

    func speak(text: String, lang: String, voice: PremiumVoiceOption) async throws {
        note("speak called (\(voice.provider.rawValue))")
        // Reset per-call cache state so a previous failure can't taint this entry.
        currentCacheKey = nil
        accumulatedPCM.removeAll(keepingCapacity: true)

        // Local disk lookup before any network. Same canonical key shape as the Worker R2
        // cache, so a phrase pulled down once (R2 hit OR cold-provider miss + cache write
        // here) plays in ~10 ms forever after, with zero RTT and zero provider cost.
        let cacheKey = buildCacheKey(text: text, lang: lang, voice: voice)
        if let cachedURL = TTSCache.shared.url(forKey: cacheKey, provider: voice.provider) {
            note("local-cache=hit key=\(cacheKey.prefix(12))")
            try configureSession()
            let t0 = Date()
            isPlaying = true
            streamReceiveComplete = true  // No streaming for cache hits — the file is the whole audio.
            lastError = nil
            try playFromCacheFile(url: cachedURL, voice: voice, startedAt: t0)
            return
        }
        note("local-cache=miss key=\(cacheKey.prefix(12))")
        currentCacheKey = cacheKey
        currentCacheProvider = voice.provider

        let defaults = UserDefaults.standard
        let urlString = defaults.string(forKey: PremiumTTSDevDefaults.workerURLKey)
            ?? PremiumTTSDevDefaults.defaultWorkerURL
        // Auth precedence:
        //   1. Apple-signed JWS from the active entitlement — the real subscriber path.
        //      Worker verifies it against Apple Root CA G3, so a leaked token is
        //      cryptographically useless to someone outside this Apple ID.
        //   2. Dev-panel bearer — runtime override for testing the preview path against
        //      a rotated Worker secret without rebuilding.
        //   3. Baked-in `BuildSecrets.workerBearer` — the default preview-path bearer
        //      every subscriber ships with. Used pre-subscription (auditioning voices)
        //      and in the dev panel's "Test voice" button.
        let jws = jwsProvider() ?? ""
        let panelBearer = (defaults.string(forKey: PremiumTTSDevDefaults.bearerKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bearer: String
        if !jws.isEmpty {
            bearer = jws
            note("auth=jws")
        } else if !panelBearer.isEmpty {
            bearer = panelBearer
            note("auth=panel-bearer")
        } else {
            bearer = BuildSecrets.workerBearer
            note("auth=baked-bearer")
        }
        guard !bearer.isEmpty else {
            note("bearer empty")
            throw PremiumTTSError.missingConfig("Worker bearer not set (render BuildSecrets.swift via `op inject`, or paste in the dev panel)")
        }
        guard let url = URL(string: urlString) else { note("invalid URL"); throw PremiumTTSError.invalidURL }

        note("configuring session")
        try configureSession()
        note("session OK")
        try await sendAndStream(url: url, bearer: bearer, text: text, lang: lang, voice: voice)
        note("speak completed")
    }

    /// Pre-populate the local TTS cache for `(text, lang, voice)` without scheduling any
    /// audio. Idempotent: if the entry already exists on disk this returns immediately.
    /// Used by `LapAnnouncer.prewarmFixedPhrases` to populate countdown numbers + the
    /// fixed phrases ("Start", "Last lap!" / equivalents) before race start so the
    /// 1-second countdown tick can't be defeated by cold-TTS latency (~600–1000 ms per
    /// number on Azure/Polly).
    ///
    /// Best-effort: all error paths (no bearer, bad URL, HTTP 4xx/5xx, parse failure)
    /// swallow silently — failure to prefetch must not block the UI or surface as a
    /// user-visible error. The real `speak()` call still runs against the same Worker
    /// later and will surface failures the normal way.
    ///
    /// Doesn't touch `AVAudioEngine`, `playerNode`, `currentTask`, `accumulatedPCM` or
    /// any `currentCache*` state — only the on-disk `TTSCache` is mutated. This makes
    /// it safe to call in parallel (`TaskGroup`) while a real `speakAsync` is playing.
    func prefetch(text: String, lang: String, voice: PremiumVoiceOption) async {
        let cacheKey = buildCacheKey(text: text, lang: lang, voice: voice)
        if TTSCache.shared.url(forKey: cacheKey, provider: voice.provider) != nil {
            return
        }

        let defaults = UserDefaults.standard
        let urlString = defaults.string(forKey: PremiumTTSDevDefaults.workerURLKey)
            ?? PremiumTTSDevDefaults.defaultWorkerURL
        let jws = jwsProvider() ?? ""
        let panelBearer = (defaults.string(forKey: PremiumTTSDevDefaults.bearerKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bearer: String
        if !jws.isEmpty {
            bearer = jws
        } else if !panelBearer.isEmpty {
            bearer = panelBearer
        } else {
            bearer = BuildSecrets.workerBearer
        }
        guard !bearer.isEmpty, let url = URL(string: urlString) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var bodyDict: [String: Any] = [
            "provider": voice.provider.rawValue,
            "text": text,
            "voice": voice.id,
            "lang": lang,
        ]
        if voice.provider == .cartesia { bodyDict["model"] = "sonic-3.5" }
        if voice.provider.supportsRate {
            let raw = defaults.object(forKey: LapAnnouncerDefaults.premiumRateKey) as? Double
            bodyDict["rate"] = raw ?? LapAnnouncerDefaults.defaultPremiumRate
        }
        if voice.provider.supportsPitch {
            let raw = defaults.object(forKey: LapAnnouncerDefaults.premiumPitchKey) as? Double
            bodyDict["pitch"] = raw ?? LapAnnouncerDefaults.defaultPremiumPitch
        }
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else { return }
        req.httpBody = body

        do {
            // `data(for:)` (not `bytes(for:)`) — prefetch isn't time-critical and we don't
            // want byte-by-byte MainActor iteration over a 50-100 KB PCM body. One shot,
            // whole body, parse once, write once.
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                log.debug("prefetch http fail: \(String(describing: response), privacy: .public)")
                return
            }
            let pcm: Data
            switch voice.provider {
            case .cartesia:
                // SSE body: walk each line, pull base64 PCM from `data: {...}` chunks. Same
                // shape `handleEventJSON` parses but without scheduling audio.
                var collected = Data()
                let bodyText = String(decoding: data, as: UTF8.self)
                for rawLine in bodyText.split(separator: "\n", omittingEmptySubsequences: false) {
                    let line = String(rawLine)
                    let payload: String
                    if line.hasPrefix("data: ") {
                        payload = String(line.dropFirst(6))
                    } else if line.hasPrefix("data:") {
                        payload = String(line.dropFirst(5))
                    } else {
                        continue
                    }
                    guard let pdata = payload.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] else {
                        continue
                    }
                    if obj["type"] as? String == "chunk",
                       let b64 = obj["data"] as? String,
                       let chunk = Data(base64Encoded: b64) {
                        collected.append(chunk)
                    }
                }
                pcm = collected
            case .polly, .azure:
                pcm = data
            }
            // `pcm.count < 2` covers two edge cases that would poison the cache:
            //   - Pathological 1-byte response (`evenCount = 0` after `& ~1` → zero-byte
            //     `evenPayload` → zero-byte cached file → `buildBuffer24kHz` throws "empty
            //     PCM chunk" on every cache hit, silently breaking that phrase forever).
            //   - Cartesia SSE stream that emits only non-`chunk` events (e.g. `done`
            //     with no audio), which collapses `collected` to empty here.
            // One s16le frame = 2 bytes, so anything below 2 bytes is structurally
            // invalid PCM and not worth saving.
            guard pcm.count >= 2 else { return }
            let evenCount = pcm.count & ~1
            let evenPayload = evenCount == pcm.count ? pcm : pcm.prefix(evenCount)
            let sampleRate = Self.sampleRateFor(voice.provider)
            let trimmed = Self.trimSilence(Data(evenPayload), sampleRate: sampleRate)
            // `trimSilence` can return its input unchanged if the payload is all-silent,
            // but the original empty-guard above prevents that input from being empty.
            // Defensive second-guard: a future trim algorithm that could return empty
            // (e.g. additional inner filtering) wouldn't poison the cache.
            guard trimmed.count >= 2 else { return }
            TTSCache.shared.save(key: cacheKey, provider: voice.provider, data: trimmed)
            log.debug("prefetch saved: key=\(cacheKey.prefix(12), privacy: .public) bytes=\(trimmed.count, privacy: .public) (pre-trim=\(evenPayload.count, privacy: .public))")
        } catch {
            log.debug("prefetch error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Build the cache key for an in-flight speak(). Mirrors the Worker's `buildCacheKey` so
    /// the local + R2 layers refer to the same logical entity. When the provider doesn't
    /// honour a control (Cartesia: neither rate nor pitch, Polly: pitch), we substitute the
    /// default so two callers — one with a custom rate that's irrelevant to this provider,
    /// one without — collapse to the same key. Matches the Worker's behaviour of clamping
    /// the body's rate/pitch with defaults before hashing.
    private func buildCacheKey(text: String, lang: String, voice: PremiumVoiceOption) -> String {
        let defaults = UserDefaults.standard
        let rate = voice.provider.supportsRate
            ? (defaults.object(forKey: LapAnnouncerDefaults.premiumRateKey) as? Double
                ?? LapAnnouncerDefaults.defaultPremiumRate)
            : LapAnnouncerDefaults.defaultPremiumRate
        let pitch = voice.provider.supportsPitch
            ? (defaults.object(forKey: LapAnnouncerDefaults.premiumPitchKey) as? Double
                ?? LapAnnouncerDefaults.defaultPremiumPitch)
            : LapAnnouncerDefaults.defaultPremiumPitch
        let model = voice.provider == .cartesia ? "sonic-3.5" : ""
        return TTSCache.shared.key(
            provider: voice.provider,
            voice: voice.id,
            lang: lang,
            rate: rate,
            pitch: pitch,
            model: model,
            text: text
        )
    }

    /// Cache-hit playback: load the on-disk file and play it through the same audio paths
    /// the streaming code uses (AVAudioPlayer for mp3, AVAudioPlayerNode + a single big
    /// AVAudioPCMBuffer for PCM). Sets `lastFirstAudioMs` so the picker's TTFA telemetry
    /// reflects "disk cache read" not "no audio ever started".
    private func playFromCacheFile(url: URL, voice: PremiumVoiceOption, startedAt t0: Date) throws {
        // Cache files for all providers now store raw s16le PCM at the provider's native
        // sample rate. Setting `currentSampleRate` before `schedulePCM` makes the resampler
        // path activate for Polly's 16 kHz cache hits while Cartesia/Azure go through the
        // 24 kHz fast path. One big buffer per utterance is fine — AVAudioPCMBuffer caps
        // are well above the few hundred KB an utterance produces.
        currentSampleRate = Self.sampleRateFor(voice.provider)
        let pcm = try Data(contentsOf: url)
        try schedulePCM(pcm, startedAt: t0)
        // The stream is complete by definition for a cache hit — flip the flag so the
        // buffer-completion callback can fire `notifyEnd()` once playback drains.
        streamReceiveComplete = true
        if pendingBuffers == 0 { notifyEnd() }
    }

    // MARK: - Session

    private func configureSession() throws {
        guard !sessionConfigured else { return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try s.setActive(true, options: [])
            sessionConfigured = true
        } catch {
            throw PremiumTTSError.engineFailure("AVAudioSession activation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Network + SSE

    private func sendAndStream(url: URL, bearer: String, text: String, lang: String, voice: PremiumVoiceOption) async throws {
        log.notice("speak start: url=\(url.absoluteString, privacy: .public) provider=\(voice.provider.rawValue, privacy: .public) voice=\(voice.id, privacy: .public) lang=\(lang, privacy: .public) chars=\(text.count, privacy: .public)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var bodyDict: [String: Any] = [
            "provider": voice.provider.rawValue,
            "text": text,
            "voice": voice.id,
            "lang": lang,
        ]
        // Cartesia is the only provider that takes a model parameter today; the Worker rejects
        // the field for the other two so we only send it for Cartesia.
        if voice.provider == .cartesia { bodyDict["model"] = "sonic-3.5" }
        // Rate / pitch only meaningful for providers that actually honour them. Skipping the
        // fields entirely (vs sending defaults) makes the Worker side easier to reason about
        // — Cartesia never sees them, Polly never sees pitch, Azure sees both.
        let defaults = UserDefaults.standard
        if voice.provider.supportsRate {
            let raw = defaults.object(forKey: LapAnnouncerDefaults.premiumRateKey) as? Double
            bodyDict["rate"] = raw ?? LapAnnouncerDefaults.defaultPremiumRate
        }
        if voice.provider.supportsPitch {
            let raw = defaults.object(forKey: LapAnnouncerDefaults.premiumPitchKey) as? Double
            bodyDict["pitch"] = raw ?? LapAnnouncerDefaults.defaultPremiumPitch
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let t0 = Date()
        lastFirstAudioMs = nil
        isPlaying = true
        streamReceiveComplete = false
        lastError = nil

        note("sending HTTP request")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw PremiumTTSError.streamFailure("response was not HTTP")
        }
        debugHttpStatus = http.statusCode
        note("HTTP \(http.statusCode) received")
        if !(200..<300).contains(http.statusCode) {
            // Drain a short prefix of the error body for the toast/log.
            var bodyPrefix = ""
            for try await byte in bytes {
                bodyPrefix.append(Character(Unicode.Scalar(byte)))
                if bodyPrefix.count >= 500 { break }
            }
            throw PremiumTTSError.http(http.statusCode, bodyPrefix)
        }

        // All three providers stream raw s16le PCM now — Cartesia via base64-in-SSE,
        // Polly/Azure via plain chunked octet stream. Sample rate varies (Polly 16 kHz,
        // others 24 kHz) so we stash it on the synth before draining the stream and
        // `schedulePCM` routes through AVAudioConverter when it's not the native 24 kHz.
        currentSampleRate = Self.sampleRateFor(voice.provider)

        switch voice.provider {
        case .cartesia:
            // Cartesia wraps each PCM chunk in an SSE `data:` event with a base64 payload.
            try await parseSSE(bytes: bytes, startedAt: t0)
            // Tell the buffer-completion callback the network side is done so it can fire
            // `notifyEnd()` after the last scheduled buffer plays out.
            streamReceiveComplete = true
            if pendingBuffers == 0 { notifyEnd() }
        case .polly, .azure:
            // Raw s16le bytes on the wire — schedule each chunk as it arrives. First-audio
            // latency is the time-to-first-chunk, not the total HTTP transfer.
            try await playPCMFromStream(bytes: bytes, startedAt: t0)
            streamReceiveComplete = true
            if pendingBuffers == 0 { notifyEnd() }
        }
    }

    /// Sample rate the Worker emits PCM at for each provider. Mirrors `sampleRateFor()` in
    /// the Worker — keep both in sync. Polly Neural's PCM mode caps at 16 kHz; Cartesia
    /// and Azure stream at the engine's native 24 kHz.
    private static func sampleRateFor(_ provider: PremiumVoiceProvider) -> Double {
        switch provider {
        case .polly: return 16000
        case .cartesia, .azure: return 24000
        }
    }

    /// Drain a chunked raw-PCM stream (Polly + Azure) and schedule each chunk on the
    /// player node as it arrives. The first chunk gets a small threshold (1 KB ≈ 32 ms
    /// at 16 kHz, ≈ 21 ms at 24 kHz) so first-audio latency is dominated by network +
    /// provider TTFA, not by iOS waiting for a fat buffer. Subsequent chunks ramp up to
    /// 4 KB so we don't pay schedule overhead on every yield.
    private func playPCMFromStream(bytes: URLSession.AsyncBytes, startedAt t0: Date) async throws {
        let firstChunkThreshold = 1024
        let steadyChunkThreshold = 4096
        var hasScheduledFirst = false
        var buffer = [UInt8]()
        buffer.reserveCapacity(steadyChunkThreshold)
        for try await byte in bytes {
            try Task.checkCancellation()
            if lastFirstAudioMs == nil {
                lastFirstAudioMs = Date().timeIntervalSince(t0) * 1000
                note("first byte @ \(Int(self.lastFirstAudioMs ?? 0))ms")
            }
            buffer.append(byte)
            let threshold = hasScheduledFirst ? steadyChunkThreshold : firstChunkThreshold
            if buffer.count >= threshold {
                let chunk = Data(buffer)
                buffer.removeAll(keepingCapacity: true)
                accumulatedPCM.append(chunk)
                try schedulePCM(chunk, startedAt: t0)
                if !hasScheduledFirst {
                    hasScheduledFirst = true
                    note("first chunk scheduled @ \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                }
            }
        }
        // Tail chunk (whatever didn't fill the steady buffer).
        if !buffer.isEmpty {
            let chunk = Data(buffer)
            accumulatedPCM.append(chunk)
            try schedulePCM(chunk, startedAt: t0)
        }
        log.notice("pcm stream done: \(self.accumulatedPCM.count, privacy: .public) bytes in \(Date().timeIntervalSince(t0) * 1000, privacy: .public) ms")
        if !accumulatedPCM.isEmpty, let key = currentCacheKey, let provider = currentCacheProvider {
            // Cache only complete s16le frames. If the upstream chunked an odd number of
            // bytes (rare but observed mid-stream), truncating now keeps the cached file
            // self-consistent — `pcm.count / 2` in `buildBuffer*` would drop that tail
            // byte too on every replay, so the saved blob is already what plays back.
            let evenCount = accumulatedPCM.count & ~1
            let evenPayload = evenCount == accumulatedPCM.count
                ? accumulatedPCM
                : accumulatedPCM.prefix(evenCount)
            // Trim provider-added silence before persisting so the cached replay is the
            // tightest possible — full rationale in `trimSilence`.
            let trimmed = Self.trimSilence(Data(evenPayload), sampleRate: currentSampleRate)
            TTSCache.shared.save(key: key, provider: provider, data: trimmed)
        }
    }

    /// Parse Cartesia's SSE stream. Each event Cartesia emits is `event: chunk\ndata: {…}\n\n`,
    /// where the `data:` line holds a complete JSON object on its own (no multi-line
    /// continuations). We *don't* buffer until the blank-line separator because
    /// `URLSession.AsyncBytes.lines` on iOS silently skips empty lines — relying on it once
    /// concatenated every event's JSON into one malformed blob and produced zero audio.
    /// Decoding each `data:` line standalone is correct for Cartesia's format and robust to
    /// the missing-empty-line quirk.
    private func parseSSE(bytes: URLSession.AsyncBytes, startedAt t0: Date) async throws {
        var lineCount = 0
        var eventCount = 0
        var chunkCount = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            lineCount += 1
            await MainActor.run { self.debugSseLines = lineCount }

            let payload: String
            if line.hasPrefix("data: ") {
                payload = String(line.dropFirst(6))
            } else if line.hasPrefix("data:") {
                payload = String(line.dropFirst(5))
            } else {
                continue  // `event:`, `:`-comment, or stray blank — not a payload
            }

            eventCount += 1
            if try handleEventJSON(payload, startedAt: t0) {
                chunkCount += 1
                await MainActor.run {
                    self.debugSseEvents = eventCount
                    self.debugChunks = chunkCount
                }
            }
        }
        log.notice("SSE done: lines=\(lineCount, privacy: .public) events=\(eventCount, privacy: .public) audioChunks=\(chunkCount, privacy: .public)")
        await MainActor.run {
            self.debugSseLines = lineCount
            self.debugSseEvents = eventCount
            self.debugChunks = chunkCount
        }
        // The Worker either streams real `data:` events or returns an error before headers
        // — but if Cartesia changes its event schema we'd see lines flowing without any
        // recognised chunks, parse cleanly to completion, and silently fall back to System
        // voice with no signal at all. Treat "lines but zero chunks" as a stream failure so
        // the caller's catch path runs and the dev panel surfaces what went wrong.
        if chunkCount == 0 && lineCount > 0 {
            throw PremiumTTSError.streamFailure("zero audio chunks decoded from \(lineCount) SSE lines — provider schema may have changed")
        }
        // Persist the concatenated PCM once the whole stream has drained cleanly. A
        // cancelled / errored stream throws before reaching here, so we never write a
        // partial utterance — which would play as a clipped audio file on every cache hit.
        if chunkCount > 0, let key = currentCacheKey, let provider = currentCacheProvider {
            let evenCount = accumulatedPCM.count & ~1
            let evenPayload = evenCount == accumulatedPCM.count
                ? accumulatedPCM
                : accumulatedPCM.prefix(evenCount)
            // Trim provider-added silence before persisting so the cached replay is the
            // tightest possible — full rationale in `trimSilence`.
            let trimmed = Self.trimSilence(Data(evenPayload), sampleRate: currentSampleRate)
            TTSCache.shared.save(key: key, provider: provider, data: trimmed)
        }
    }

    /// Returns true if this event produced an audio chunk (for stats).
    @discardableResult
    private func handleEventJSON(_ json: String, startedAt t0: Date) throws -> Bool {
        guard let data = json.data(using: .utf8) else {
            log.error("event utf8 decode failed")
            return false
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("event JSON parse failed: \(json.prefix(80), privacy: .public)")
            return false
        }
        let type = obj["type"] as? String

        if type == "chunk", let b64 = obj["data"] as? String, let pcm = Data(base64Encoded: b64) {
            // Accumulate the raw PCM so we can save the whole utterance to TTSCache at
            // the end of the stream. We append in-order before scheduling playback, which
            // means a cancelled-mid-stream call still gets dropped (the cache write only
            // happens on parseSSE's clean exit).
            accumulatedPCM.append(pcm)
            try schedulePCM(pcm, startedAt: t0)
            return true
        } else if type == "done" || (obj["done"] as? Bool == true) {
            log.debug("SSE done received")
        } else if type == "error" {
            let msg = (obj["error"] as? String) ?? "unknown"
            throw PremiumTTSError.streamFailure("server error: \(msg)")
        } else {
            log.debug("event ignored: type=\(type ?? "<nil>", privacy: .public)")
        }
        return false
    }

    // MARK: - Silence trim

    /// Crop leading + trailing near-silence from a raw s16le mono PCM payload, keeping a
    /// short audible-pad on each side so the result doesn't click. Polly Neural and Azure
    /// both pad utterances with 50-200 ms of low-amplitude noise on each end; for a
    /// 1-second countdown ("ten" / "nine" / ...) that padding pushes total playback past
    /// the 1-second tick and the next number gets dropped by
    /// `LapAnnouncer.announceCountdown`'s `inflightUtteranceCount == 0` guard. Trimming
    /// before write lets the cached file replay in real ~600-800 ms instead of ~1000-1200.
    ///
    /// Threshold: Int16 |sample| < `silenceThreshold` (≈ −50 dB) counts as silence. Set
    /// conservative because Japanese stops like "ト" / "プ" / "ス" decay through a long
    /// quiet tail (the consonant release after the vowel) that's still audible — an
    /// aggressive threshold (e.g. −36 dB) chops the consonant off entirely and the
    /// listener hears "スター" instead of "スタート". Padding: 60 ms on each side so even
    /// if the threshold cuts mid-decay, the unvoiced tail past the cut still plays.
    /// Returns the original `pcm` unchanged if the whole payload is below threshold
    /// (cache would otherwise be a zero-length file).
    private static let silenceThreshold: Int16 = 100
    private static func trimSilence(_ pcm: Data, sampleRate: Double) -> Data {
        let frameCount = pcm.count / 2
        guard frameCount > 0 else { return pcm }
        // ~60 ms padding: 960 frames @ 16 kHz, 1440 frames @ 24 kHz.
        let padFrames = Int((sampleRate * 0.060).rounded())

        return pcm.withUnsafeBytes { rawBuf -> Data in
            guard let base = rawBuf.bindMemory(to: Int16.self).baseAddress else { return pcm }
            var firstAudible = -1
            for i in 0..<frameCount {
                if abs(Int32(base[i])) >= Int32(Self.silenceThreshold) {
                    firstAudible = i
                    break
                }
            }
            // Entirely below threshold — caller falls back to writing the untrimmed payload
            // so a too-quiet phrase still plays something instead of a zero-byte file.
            guard firstAudible >= 0 else { return pcm }
            var lastAudible = firstAudible
            for i in stride(from: frameCount - 1, through: firstAudible, by: -1) {
                if abs(Int32(base[i])) >= Int32(Self.silenceThreshold) {
                    lastAudible = i
                    break
                }
            }
            let start = max(0, firstAudible - padFrames)
            let endExclusive = min(frameCount, lastAudible + 1 + padFrames)
            let byteStart = start * 2
            let byteEnd = endExclusive * 2
            return pcm.subdata(in: byteStart..<byteEnd)
        }
    }

    // MARK: - PCM → AVAudioPCMBuffer → AVAudioPlayerNode

    /// 24 kHz s16le mono → 24 kHz Float32 mono. Manual conversion path because it avoids
    /// the AVAudioConverter overhead and matches what we used since the Cartesia-only
    /// days. The Float32 target matches the engine's source format, so the buffer can
    /// be scheduled with zero further conversion.
    private func buildBuffer24kHz(_ pcm: Data) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(pcm.count / 2)
        guard frameCount > 0 else {
            throw PremiumTTSError.engineFailure("empty PCM chunk")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.sourceFormat, frameCapacity: frameCount) else {
            throw PremiumTTSError.engineFailure("PCMBuffer allocation failed")
        }
        buffer.frameLength = frameCount
        guard let dst = buffer.floatChannelData?[0] else {
            throw PremiumTTSError.engineFailure("floatChannelData unavailable")
        }
        var peak: Int16 = 0
        pcm.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(frameCount) {
                let s = src[i]
                if abs(Int32(s)) > abs(Int32(peak)) { peak = s }
                dst[i] = Float(s) / 32768.0
            }
        }
        if lastFirstAudioMs == nil {
            log.notice("first chunk peak amplitude: \(peak, privacy: .public)")
        }
        return buffer
    }

    /// Non-24 kHz s16le mono (currently only Polly @ 16 kHz) → 24 kHz Float32 mono via
    /// AVAudioConverter. The converter is held on the synth across chunks within one
    /// utterance so its sample-rate filter state (a few-tap polyphase resampler) carries
    /// over and the upsampled audio is continuous, no audible seams between chunks.
    private func buildBufferResampled(_ pcm: Data) throws -> AVAudioPCMBuffer {
        let inputFrameCount = AVAudioFrameCount(pcm.count / 2)
        guard inputFrameCount > 0 else {
            throw PremiumTTSError.engineFailure("empty PCM chunk")
        }
        // Lazy-init / re-init the converter when the rate changes between calls.
        if resampleConverter == nil || resampleConverterRate != currentSampleRate {
            guard let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: currentSampleRate,
                channels: 1,
                interleaved: true
            ) else {
                throw PremiumTTSError.engineFailure("input format init failed at \(currentSampleRate) Hz")
            }
            guard let converter = AVAudioConverter(from: inputFormat, to: Self.sourceFormat) else {
                throw PremiumTTSError.engineFailure("converter init failed")
            }
            resampleConverter = converter
            resampleConverterRate = currentSampleRate
        }
        guard let converter = resampleConverter else {
            throw PremiumTTSError.engineFailure("converter unexpectedly nil")
        }
        // Build the interleaved Int16 input buffer.
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.inputFormat,
            frameCapacity: inputFrameCount
        ) else {
            throw PremiumTTSError.engineFailure("input PCMBuffer allocation failed")
        }
        inputBuffer.frameLength = inputFrameCount
        guard let dst = inputBuffer.int16ChannelData?[0] else {
            throw PremiumTTSError.engineFailure("int16ChannelData unavailable (interleaved mono)")
        }
        pcm.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(inputFrameCount) {
                dst[i] = src[i]
            }
        }
        // Estimate output frame count with headroom — upsampling produces more frames than
        // input. ratio + small extra for the resampler's filter tail.
        let ratio = Self.sourceFormat.sampleRate / currentSampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.sourceFormat,
            frameCapacity: outputCapacity
        ) else {
            throw PremiumTTSError.engineFailure("output PCMBuffer allocation failed")
        }
        var consumed = false
        var convertError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            if consumed {
                // Signal "no more input THIS call" — the converter keeps its sample-rate
                // filter state for the next chunk's convert() call.
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let err = convertError, status == .error {
            throw PremiumTTSError.engineFailure("convert failed: \(err.localizedDescription)")
        }
        return outputBuffer
    }

    private func schedulePCM(_ pcm: Data, startedAt t0: Date) throws {
        let buffer: AVAudioPCMBuffer
        if currentSampleRate == Self.sourceFormat.sampleRate {
            buffer = try buildBuffer24kHz(pcm)
        } else {
            buffer = try buildBufferResampled(pcm)
        }
        let frameCount = buffer.frameLength

        // Start the engine on first chunk. Doing it lazily keeps the cold-start cost off the
        // network's critical path until we actually have audio to play.
        if !engine.isRunning {
            do {
                try engine.start()
                log.notice("engine started OK")
            } catch {
                log.error("engine.start() failed: \(error.localizedDescription, privacy: .public)")
                throw PremiumTTSError.engineFailure("engine.start() failed: \(error.localizedDescription)")
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
            log.notice("playerNode.play() called")
        }

        pendingBuffers += 1
        if lastFirstAudioMs == nil {
            lastFirstAudioMs = Date().timeIntervalSince(t0) * 1000
            log.notice("first audio scheduled @ \(self.lastFirstAudioMs ?? 0, privacy: .public) ms, frames=\(frameCount, privacy: .public)")
        }
        let scheduledGeneration = currentGeneration
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // The completion callback fires on a background queue. Bounce to MainActor so the
            // counter and observable flag don't race against the speak() coroutine. Drop
            // the update if `cancel()` has bumped the generation — a stale callback from a
            // superseded utterance must not flip `isPlaying` false on the fresh utterance
            // that took its slot (cache-hit start paths set `streamReceiveComplete = true`
            // before scheduling, which would otherwise let a stale callback win the race).
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard scheduledGeneration == self.currentGeneration else { return }
                pendingBuffers = max(0, pendingBuffers - 1)
                if streamReceiveComplete && pendingBuffers == 0 {
                    note("PCM drained, isPlaying=false")
                    notifyEnd()
                }
            }
        }
    }
}
