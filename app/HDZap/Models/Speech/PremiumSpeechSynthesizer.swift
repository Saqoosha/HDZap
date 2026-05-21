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
    static let defaultVoiceId = "Takumi"  // Polly · Takumi (male, Neural, JA)
}

/// Which upstream TTS service should the Worker call for a given voice. The Worker returns
/// raw s16le mono PCM regardless of provider; only the sample rate differs (see `sampleRateFor`).
enum PremiumVoiceProvider: String, Codable {
    /// AWS Polly Neural via SigV4 (Cognito Identity Pool) — raw PCM at 16 kHz over HTTPS.
    case polly
    /// Azure AI Speech Neural via subscription key — raw PCM at 24 kHz over HTTPS.
    case azure

    /// `<prosody rate>` (or equivalent) support per provider as of 2026-05. Both Polly Neural
    /// (`<prosody rate>` percentage) and Azure Neural (SSML) honour rate.
    var supportsRate: Bool { true }

    /// `<prosody pitch>` support. Polly Neural REJECTS pitch with "Unsupported Neural
    /// feature" — only Standard voices accept it, and our catalog ships Neural only.
    /// So only Azure is fully covered.
    var supportsPitch: Bool {
        switch self {
        case .polly: return false
        case .azure: return true
        }
    }
}

/// One row in the voice picker. `provider` decides Worker routing and audio format on the
/// client; the same `id` namespace per provider is opaque to us (Polly Pascal names, Azure
/// full locale-qualified names).
struct PremiumVoiceOption: Identifiable, Hashable {
    let id: String
    let label: String
    let lang: String
    let provider: PremiumVoiceProvider
}

/// Premium TTS voice catalog (Polly 3 JA + 11 EN Neural, Azure 7 JA + 9 EN Neural). Polly +
/// Azure each ship far more voices than this — we keep the menu scoped to race-announcer /
/// friendly-narrator personas (US/UK/AU accents covered across providers) so the picker
/// stays scannable mid-race.
enum PremiumVoiceCatalog {
    static let voices: [PremiumVoiceOption] = [
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

/// Streams Polly + Azure raw PCM into `AVAudioPlayerNode`.
///
/// Pipeline:
/// 1. POST text/voice/lang to the Worker `/tts` endpoint. The Bearer is the Apple-signed
///    JWS for entitled subscribers (via `jwsProvider`) or the baked-in dev bearer otherwise.
/// 2. Read the response body as a streaming byte sequence (`URLSession.AsyncBytes`).
/// 3. Both providers stream raw chunked s16le mono PCM (Polly 16 kHz, Azure 24 kHz).
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

    /// Engine source format: 24 kHz Float32 mono. Azure streams at the native 24 kHz
    /// (manual `Int16 → Float32` in `buildBuffer24kHz`); Polly's 16 kHz path routes
    /// through `AVAudioConverter` to upsample. Float32 is the engine mixer's preferred
    /// type — Int16 hit silent failures on iOS 18 where `int16ChannelData` returned nil
    /// and the buffer scheduled as silence.
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

    /// Pool of additional `AVAudioPlayerNode`s used by `speakOverlap` for countdown
    /// numbers. All four nodes are attached to `engine.mainMixerNode` at init time
    /// alongside the primary `playerNode`, so the mixer sums any concurrently-playing
    /// utterances at the hardware level — "10" can still be ringing out when "9"
    /// starts, and the listener hears both. Sized at 4 because Azure at 1.45 × rate
    /// runs each countdown number to ~1.4-1.7 seconds; with a 1-second tick the
    /// pool only needs to cover the maximum number of *simultaneously* playing
    /// utterances at any moment (~2), and 4 gives headroom for short utterances
    /// that briefly stack 3-4 deep.
    ///
    /// Selection is **strict round-robin** — `overlapRoundRobinIndex` increments
    /// each call. `AVAudioPlayerNode.isPlaying` stays `true` after a scheduled
    /// buffer drains (until the node is explicitly stopped), so it cannot be used
    /// to detect free vs busy. Round-robin sidesteps that by simply rotating
    /// through the pool: with 4 nodes × ~1.4 s utterance / 1 s tick, by the time
    /// we cycle back to the same node its previous buffer has long finished and
    /// the new buffer plays immediately. If the cycle catches up to a still-busy
    /// node (extremely rare), the new buffer is **queued** behind the current one
    /// — audible as a small delay rather than dropped silence.
    private static let overlapPoolSize = 4
    private var overlapNodes: [AVAudioPlayerNode] = []
    private var overlapRoundRobinIndex = 0

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
    /// without depending on os_log capture.
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

    /// True once `playPCMFromStream` has consumed the entire response body.
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
        // Pool of overlap nodes for `speakOverlap` — all parallel into the mixer.
        for _ in 0..<Self.overlapPoolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: Self.sourceFormat)
            overlapNodes.append(node)
        }
        engineAttached = true
        // `prepare()` allocates the rendering resources up front. Without it the first
        // scheduleBuffer can race with engine.start() and drop the buffer on the floor.
        engine.prepare()
        log.notice("engine init: outputFormat=\(self.engine.outputNode.outputFormat(forBus: 0).description, privacy: .public)  mixerFormat=\(self.engine.mainMixerNode.outputFormat(forBus: 0).description, privacy: .public)  overlapPool=\(Self.overlapPoolSize, privacy: .public)")
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
        // Belt-and-braces: explicitly stop+reset every overlap node BEFORE the
        // `engine.reset()` below. `engine.reset()` flushes their internal buffers
        // too (they share the engine graph), but `AVAudioPlayerNode.isPlaying`
        // is observed to lag the engine reset, so a subsequent `speakOverlap`
        // could see `isPlaying == true` on a node whose render state was already
        // wiped. Doing it explicitly here keeps the node's external state and
        // internal state in lockstep before the engine-wide reset.
        stopOverlapPlayback()
        if engine.isRunning { engine.stop() }
        // `engine.reset()` flushes the AudioUnit-side render state — `mainMixerNode`
        // and the output unit's internal buffers — so the tail of a previous
        // utterance can't bleed into the next playback once `engine.start()` runs
        // again. Symptom that motivated this: paywall / picker sample preview
        // finished, operator tapped Start, and the new "スタート" playback opened
        // with a phantom "ト" from the previous utterance's tail — not from the
        // sample's last syllable (the JA sample text "ラップ3、12.34、ベストラップ"
        // ends in "プ", not "ト"), so the bleed was the prior race's own "スタート"
        // tail or a prewarm-buffered chunk that survived `stop()`.
        //
        // **`engine.reset()` does NOT reset the `AVAudioPlayerNode`s' scheduled
        // buffer queues or their `isPlaying` flags** — those are per-node state
        // that requires `node.stop()` + `node.reset()`. The primary `playerNode`
        // is handled at the top of `cancel()`; the overlap pool is handled by
        // `stopOverlapPlayback()` above. Without that explicit teardown, an
        // overlap node would survive `engine.reset()` reporting `isPlaying ==
        // true` while its internal render state was already wiped — the next
        // `speakOverlap` would skip the `play()` call and schedule into a node
        // that never renders.
        //
        // Called unconditionally — safe on a stopped engine, free insurance for
        // the first-run path.
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
        // No overlap restoration needed — overlap nodes were hard-stopped on LAP
        // start (not muted), so they're already in a fresh state ready for the
        // next `speakOverlap`. `isPlaying = false` above also lets new overlap
        // calls pass the LAP-active guard inside `speakOverlap`.
        cb?()
    }

    /// Hard-stop every overlap node and clear their scheduled-buffer queues. Used
    /// when a LAP / Start / FINAL announce arrives and the operator's priority
    /// shifts to the main utterance — countdown numbers currently ringing out are
    /// cut off mid-syllable so the LAP message is heard cleanly. Paired with the
    /// `isPlaying` guard inside `speakOverlap`, which refuses to schedule new
    /// overlay buffers while the primary utterance is active.
    private func stopOverlapPlayback() {
        for node in overlapNodes {
            if node.isPlaying { node.stop() }
            node.reset()
        }
    }

    /// Resets all debug counters so the next Speak shows a clean timeline.
    func resetDebug() {
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
    /// stream write path can save under the same key without re-deriving it.
    /// Cleared on completion / failure so a subsequent miss writes to the right entry.
    private var currentCacheKey: String?
    /// Paired with `currentCacheKey` — the provider whose audio bytes we'll be saving, so
    /// `TTSCache.save()` can label the file correctly.
    private var currentCacheProvider: PremiumVoiceProvider?

    /// Sample rate of the PCM stream for the in-flight speak(). Azure sends
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

    /// Decoded raw PCM accumulated across the streamed response for this speak() call.
    /// We write the concatenated bytes to `TTSCache` once the stream completes. Cleared at
    /// the start of every speak() so a partial stream from a prior failed call can't bleed
    /// into the next entry.
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
        // Hard-stop the overlap pool while the primary utterance is speaking. LAP /
        // Start / FINAL announces represent the operator's current priority — any
        // countdown numbers already ringing out (from `speakOverlap`) must be cut
        // off so the LAP message is heard cleanly. `speakOverlap` also reads
        // `isPlaying` and refuses to schedule new overlay buffers while the primary
        // utterance is active, so once we get here all current AND future overlay
        // counts are suppressed until `notifyEnd` flips `isPlaying` back to false.
        stopOverlapPlayback()
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
            //
            // Retry once on HTTP 429: Polly and Azure both have per-second TPS caps
            // that a burst of prewarm requests can occasionally clip even with the
            // concurrency cap of 3 in `prewarmFixedPhrases`. A single delayed retry
            // after ~1 s clears the limit in practice. Two retries felt excessive —
            // the operator can re-trigger prewarm by closing + re-opening Settings
            // if the cache still has gaps.
            var data: Data
            var response: URLResponse
            (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                log.debug("prefetch 429 — retrying after 1 s for key=\(cacheKey.prefix(12), privacy: .public)")
                // Propagate cancellation through the sleep: if `currentPrewarmTask`
                // is cancelled while we're waiting (e.g. user tapped Start), the
                // sleep throws CancellationError, which bubbles to the outer
                // `do { ... } catch { log.debug(...) }` and exits cleanly without
                // issuing the retry request. `try?` here would swallow the
                // cancellation and burn an extra network call on the very
                // provider we just stepped aside for.
                try await Task.sleep(nanoseconds: 1_000_000_000)
                (data, response) = try await URLSession.shared.data(for: req)
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                log.debug("prefetch http fail: \(String(describing: response), privacy: .public)")
                return
            }
            // Polly + Azure both stream raw s16le PCM — the response body IS the audio.
            let pcm = data
            // Pathological 1-byte response would produce `evenCount = 0` after the
            // `& ~1` mask below — a zero-byte cached file then throws "empty PCM
            // chunk" on every cache hit and silently breaks that phrase forever.
            // One s16le frame = 2 bytes; anything below is structurally invalid.
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

    /// Cache-hit playback that bypasses the primary `playerNode` queue so the new
    /// utterance can sound concurrently with whatever is already speaking. Used by
    /// `LapAnnouncer.announceCountdown` for the per-second numbers — at higher rates
    /// (Azure 1.45 ×, etc.) each utterance may run ~1.4 s, making consecutive
    /// 1-second ticks overlap. The pool of `overlapNodes` is wired into
    /// `mainMixerNode` alongside the primary `playerNode`, so the mixer sums all
    /// active nodes at the hardware level — the listener hears "10" tailing out
    /// behind "9" instead of "9" being dropped by an `inflightUtteranceCount`
    /// guard.
    ///
    /// Cache-hit only on purpose: `prewarmFixedPhrases` reliably warms every
    /// countdown phrase before the race, and a cache miss here would either fall
    /// through to the cancel-on-new primary path (defeating the overlap) or pay a
    /// 600-1000 ms cold-fetch Worker round-trip (the very latency overlap is
    /// trying to avoid). When the cache miss happens — rare in practice — the call
    /// returns false and the caller can decide to drop the announce or fall back.
    ///
    /// Does NOT participate in `pendingOnEnd` / `notifyEnd` / `isPlaying` —
    /// overlap utterances are fire-and-forget. The primary path's volume-mute on
    /// LAP ensures countdown numbers stop sounding while LAP speaks; new overlap
    /// calls during LAP inherit the muted node volume and stay silent until
    /// `notifyEnd` restores it.
    @discardableResult
    func speakOverlap(text: String, lang: String, voice: PremiumVoiceOption) -> Bool {
        // LAP / Start / FINAL announces hard-stop the overlap pool on speakAsync
        // entry; while one of those is in flight (`isPlaying == true`), refuse to
        // schedule new overlay buffers so a stray countdown tick can't sneak in
        // behind the LAP message. The countdown number is dropped (returns true
        // — caller treats as "handled, did nothing"); the next countdown after
        // `notifyEnd` flips `isPlaying` false will resume normally.
        if isPlaying {
            log.notice("speakOverlap suppressed (primary speaking): text=\"\(text, privacy: .public)\"")
            return true
        }
        let cacheKey = buildCacheKey(text: text, lang: lang, voice: voice)
        guard let cacheFileURL = TTSCache.shared.url(forKey: cacheKey, provider: voice.provider) else {
            log.notice("speakOverlap miss: text=\"\(text, privacy: .public)\" voice=\(voice.id, privacy: .public)")
            return false
        }
        do {
            try configureSession()
            let pcm = try Data(contentsOf: cacheFileURL)
            let sampleRate = Self.sampleRateFor(voice.provider)
            let buffer = try buildOverlapBuffer(pcm: pcm, sampleRate: sampleRate)
            // Strict round-robin — rotate through the pool by index. `isPlaying`
            // cannot be used to detect free vs busy because `AVAudioPlayerNode`
            // stays in the `isPlaying` state until explicitly stopped, even after
            // a scheduled buffer drains. With 4 nodes × ~1.4 s utterance / 1 s
            // tick the previous occupancy of any node is comfortably done before
            // the cycle wraps; in the rare worst case the new buffer queues
            // behind the current on the same node (small audible delay) instead
            // of being dropped.
            let nodeIndex = overlapRoundRobinIndex % overlapNodes.count
            overlapRoundRobinIndex &+= 1
            let node = overlapNodes[nodeIndex]
            // The engine may not be running on the first overlap of a session
            // (cold launch with no LAP yet). Start it lazily — same pattern as
            // `schedulePCM`. Safe to call when already running.
            if !engine.isRunning {
                try engine.start()
                log.notice("engine started (from speakOverlap)")
            }
            // Canonical order: `play()` before `scheduleBuffer`. Matches the
            // primary `schedulePCM` pattern. After `stopOverlapPlayback` (called
            // on LAP entry) the node is in a stopped state with an empty queue;
            // calling `play()` re-engages it for the new buffer.
            if !node.isPlaying {
                node.play()
            }
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: nil)
            log.notice("speakOverlap scheduled: text=\"\(text, privacy: .public)\" voice=\(voice.id, privacy: .public) frames=\(buffer.frameLength, privacy: .public) nodeIndex=\(nodeIndex, privacy: .public)")
            return true
        } catch {
            // Surface the error to the observable `lastError` so the Settings
            // banner (and any dev panel) can show it. `log.error` alone is
            // invisible at race time. The most likely concrete failure here is
            // `engine.start()` throwing because the audio session lost
            // priority — leaving the operator with a silent race needs to be
            // attributable.
            lastError = error.localizedDescription
            log.error("speakOverlap error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// One-shot PCM → AVAudioPCMBuffer conversion for the overlap pool. Does NOT
    /// share the `resampleConverter` state used by the primary playerNode's
    /// chunk-streaming path — that converter keeps a polyphase filter tail across
    /// chunks of a single utterance, which would corrupt both paths if reused.
    /// Overlap utterances are always one buffer, so a fresh converter per call is
    /// correct (and cheap — converter init is <1 ms).
    private func buildOverlapBuffer(pcm: Data, sampleRate: Double) throws -> AVAudioPCMBuffer {
        if sampleRate == Self.sourceFormat.sampleRate {
            return try buildBuffer24kHz(pcm)
        }
        let inputFrameCount = AVAudioFrameCount(pcm.count / 2)
        guard inputFrameCount > 0 else {
            throw PremiumTTSError.engineFailure("empty PCM payload")
        }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw PremiumTTSError.engineFailure("overlap input format init failed at \(sampleRate) Hz")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.sourceFormat) else {
            throw PremiumTTSError.engineFailure("overlap converter init failed")
        }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            throw PremiumTTSError.engineFailure("overlap input PCMBuffer alloc failed")
        }
        inputBuffer.frameLength = inputFrameCount
        guard let dst = inputBuffer.int16ChannelData?[0] else {
            throw PremiumTTSError.engineFailure("overlap int16ChannelData unavailable")
        }
        pcm.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(inputFrameCount) {
                dst[i] = src[i]
            }
        }
        let ratio = Self.sourceFormat.sampleRate / sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: Self.sourceFormat, frameCapacity: outputCapacity) else {
            throw PremiumTTSError.engineFailure("overlap output PCMBuffer alloc failed")
        }
        var consumed = false
        var convertError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let err = convertError, status == .error {
            throw PremiumTTSError.engineFailure("overlap convert failed: \(err.localizedDescription)")
        }
        return outputBuffer
    }

    /// Build the cache key for an in-flight speak(). Mirrors the Worker's `buildCacheKey` so
    /// the local + R2 layers refer to the same logical entity. When the provider doesn't
    /// honour a control (Polly: pitch), we substitute the default so two callers — one
    /// with a custom pitch that's irrelevant to this provider, one without — collapse to
    /// the same key. Matches the Worker's behaviour of clamping the body's rate/pitch
    /// with defaults before hashing.
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
        return TTSCache.shared.key(
            provider: voice.provider,
            voice: voice.id,
            lang: lang,
            rate: rate,
            pitch: pitch,
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
        // path activate for Polly's 16 kHz cache hits while Azure goes through the
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

    // MARK: - Network

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
        // Rate / pitch only meaningful for providers that actually honour them. Skipping the
        // fields entirely (vs sending defaults) makes the Worker side easier to reason about
        // — Polly never sees pitch (Neural voices reject it), Azure honours both.
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

        // Both providers stream raw s16le mono PCM as plain chunked octets. Sample rate
        // varies (Polly 16 kHz, Azure 24 kHz) so we stash it on the synth before draining
        // the stream and `schedulePCM` routes through AVAudioConverter when it's not the
        // engine's native 24 kHz.
        currentSampleRate = Self.sampleRateFor(voice.provider)

        // Raw s16le bytes on the wire — schedule each chunk as it arrives. First-audio
        // latency is the time-to-first-chunk, not the total HTTP transfer.
        try await playPCMFromStream(bytes: bytes, startedAt: t0)
        streamReceiveComplete = true
        if pendingBuffers == 0 { notifyEnd() }
    }

    /// Sample rate the Worker emits PCM at for each provider. Mirrors `sampleRateFor()` in
    /// the Worker — keep both in sync. Polly Neural's PCM mode caps at 16 kHz; Azure
    /// streams at the engine's native 24 kHz.
    private static func sampleRateFor(_ provider: PremiumVoiceProvider) -> Double {
        switch provider {
        case .polly: return 16000
        case .azure: return 24000
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

    // MARK: - Silence trim

    /// Crop leading near-silence from a raw s16le mono PCM payload. Polly Neural and
    /// Azure pad utterances with 50-200 ms of low-amplitude noise at the start; for a
    /// 1-second countdown ("ten" / "nine" / ...) that padding pushes total playback past
    /// the 1-second tick and the next number gets dropped by
    /// `LapAnnouncer.announceCountdown`'s `inflightUtteranceCount == 0` guard. Trimming
    /// the head before write lets the cached file replay starting at the first audible
    /// sample, saving ~100-150 ms per countdown utterance.
    ///
    /// **Trailing silence is deliberately NOT trimmed**. Earlier attempts (v3 at −36 dB
    /// / 15 ms padding, v4 at −50 dB / 60 ms padding) both chopped the natural decay of
    /// voiced consonants — Japanese trailing /n/ /ɯː/ /i/ and English /n/ /m/ fade
    /// through a long quiet tail that's still audible to a listener. Cutting before the
    /// decay completes produces a perceptual "stop short" feel even when the spectrogram
    /// confirms the audio truly ended. Leaving the trailing 50-200 ms of provider-added
    /// silence in costs nothing at race time (still well inside the 1-second tick after
    /// head trim + Azure 1.7x rate) and avoids the truncation perception entirely.
    ///
    /// Threshold: Int16 |sample| < `silenceThreshold` (≈ −50 dB) counts as silence.
    /// Padding: 60 ms before the first audible sample so the head doesn't start mid-onset.
    /// Returns the original `pcm` unchanged if the whole payload is below threshold (a
    /// zero-byte cache file would silently break every replay).
    private static let silenceThreshold: Int16 = 100
    private static func trimSilence(_ pcm: Data, sampleRate: Double) -> Data {
        let frameCount = pcm.count / 2
        guard frameCount > 0 else { return pcm }
        // ~60 ms leading padding: 960 frames @ 16 kHz, 1440 frames @ 24 kHz.
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
            // Entirely below threshold — return the untrimmed payload so a too-quiet
            // phrase still plays something instead of a zero-byte file.
            guard firstAudible >= 0 else { return pcm }
            let start = max(0, firstAudible - padFrames)
            let byteStart = start * 2
            return pcm.subdata(in: byteStart..<pcm.count)
        }
    }

    // MARK: - PCM → AVAudioPCMBuffer → AVAudioPlayerNode

    /// 24 kHz s16le mono → 24 kHz Float32 mono. Manual conversion path because it avoids
    /// the AVAudioConverter overhead. The Float32 target matches the engine's source
    /// format, so the buffer can be scheduled with zero further conversion.
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
