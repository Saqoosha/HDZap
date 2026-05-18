import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "sh.saqoo.HDZap", category: "PremiumTTS")

/// UserDefaults keys for the DEBUG-only Premium TTS test harness. Production code will
/// read the bearer from a StoreKit 2 entitlement, not these defaults.
enum PremiumTTSDevDefaults {
    static let workerURLKey = "_premiumWorkerURL"
    static let bearerKey = "_premiumWorkerBearer"
    static let voiceIdKey = "_premiumWorkerVoiceId"
    static let defaultWorkerURL = "https://hdzap-premium.saqoosha.workers.dev/tts"
    static let defaultVoiceId = "06950fa3-534d-46b3-93bb-f852770ea0b5"  // Takeshi - Hero (JA)
}

/// One row in the voice picker shown by the dev test panel.
struct PremiumVoiceOption: Identifiable, Hashable {
    let id: String
    let label: String
    let lang: String
}

/// Stock Cartesia voice IDs. Japanese set = all 22 voices Cartesia ships for `language: "ja"`
/// as of the live `GET /voices` snapshot on 2026-05-18. English set = a handpicked few that fit
/// the race-announcer / friendly-narrator personas; the full English library is 375 voices and
/// not worth surfacing in a picker without a search field.
enum PremiumVoiceCatalog {
    static let voices: [PremiumVoiceOption] = [
        // Japanese — all 22 voices in alphabetical-by-display-name order
        .init(id: "498e7f37-7fa3-4e2c-b8e2-8b6e9276f956", label: "Aiko - Calming Voice", lang: "ja"),
        .init(id: "446f922f-c43a-4aad-9a8b-ad2af568e882", label: "Akira - Professional Colleague", lang: "ja"),
        .init(id: "63d6f469-8c2c-489d-b53f-d36f0bbdcd4b", label: "Ayako", lang: "ja"),
        .init(id: "31c55968-a9f4-4115-8831-3a16952179c8", label: "Ayumi - Sales Guide", lang: "ja"),
        .init(id: "a759ecc5-ac21-487e-88c7-288bdfe76999", label: "Daichi - Baritone Narrator", lang: "ja"),
        .init(id: "e8a863c6-22c7-4671-86ca-91cacffc038d", label: "Daisuke - Businessman", lang: "ja"),
        .init(id: "c7eafe22-8b71-40cd-850b-c5a3bbd8f8d2", label: "Emi - Soft-Spoken Friend", lang: "ja"),
        .init(id: "97e7d7a9-dfaa-4758-a936-f5f844ac34cc", label: "Fuji - Positive Colleague", lang: "ja"),
        .init(id: "861213b7-f057-45c8-9527-0f4c144f1a03", label: "Haruka - Gracious Guide", lang: "ja"),
        .init(id: "d0ff6870-dd30-420d-8568-d756d806ea62", label: "Hinata - Graceful Guide", lang: "ja"),
        .init(id: "1d210168-d764-462c-8ab6-288a6d5a9579", label: "Hiroshi - Dependable Director", lang: "ja"),
        .init(id: "44863732-e415-4084-8ba1-deabe34ce3d2", label: "Kaori - Friendly Narrator", lang: "ja"),
        .init(id: "9436e723-612d-4114-aeb0-fa00d4d639bf", label: "Katsuya - Promo Host", lang: "ja"),
        .init(id: "6b92f628-be90-497c-8f4c-3b035002df71", label: "Kenji - Calm Man", lang: "ja"),
        .init(id: "177df681-25b1-48c2-bb47-03ca5fa27f0a", label: "Ren - Calm Navigator", lang: "ja"),
        .init(id: "9e7ef2cf-b69c-46ac-9e35-bbfd73ba82af", label: "Ren - High-Energy Character", lang: "ja"),
        .init(id: "0cd0cde2-3b93-42b5-bcb9-f214a591aa29", label: "Sayuri - Peppy Colleague", lang: "ja"),
        .init(id: "b8e1169c-f16a-4064-a6e0-95054169e553", label: "Takashi - Professional Conversationalist", lang: "ja"),
        .init(id: "06950fa3-534d-46b3-93bb-f852770ea0b5", label: "Takeshi - Hero", lang: "ja"),
        .init(id: "49e02441-83ea-4c77-bda8-79fdd7f07e92", label: "Tohru - Career Coach", lang: "ja"),
        .init(id: "59d4fd2f-f5eb-4410-8105-58db7661144f", label: "Yuki - Calm Woman", lang: "ja"),
        .init(id: "2b568345-1d48-4047-b25f-7baccf842eb0", label: "Yumiko - Friendly Agent", lang: "ja"),
        // English — handpicked picks for FPV race-announcer use
        .init(id: "2f22b9bc-b0eb-4cb6-b5ae-0c099a0fdfad", label: "Scott - Sportscaster", lang: "en"),
        .init(id: "820a3788-2b37-4d21-847a-b65d8a68c99a", label: "Tyler - Friendly Salesman", lang: "en"),
        .init(id: "62305e79-9d39-4643-b003-5e0b096fe4f4", label: "Madison - Happy Best Friend", lang: "en"),
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

/// Streams Cartesia-via-Worker SSE audio into `AVAudioPlayerNode`.
///
/// Pipeline:
/// 1. POST text/voice/lang to the Worker `/tts` endpoint with a Bearer (DEBUG: from UserDefaults;
///    later: from StoreKit 2 entitlement).
/// 2. Read the response body as a streaming byte sequence (`URLSession.AsyncBytes`).
/// 3. Parse SSE events on the fly — `data: { type:"chunk", data:"<base64 pcm>" }`.
/// 4. Base64-decode each chunk into raw PCM s16le 24kHz mono.
/// 5. Wrap in `AVAudioPCMBuffer` and schedule on a player node attached to a private
///    `AVAudioEngine`. The mixer auto-resamples to the output device's native rate.
///
/// Audio session: configures `.playback` + `.spokenAudio` + `.duckOthers` independently of
/// `LapAnnouncer` for now. When Phase 2 integration lands, the two synthesisers will share
/// one session (and one warm-keeper) via a `SpeechRouter`.
@MainActor
@Observable
final class PremiumSpeechSynthesizer {
    /// Cartesia returns `pcm_s16le` at 24kHz mono. We convert to Float32 on the fly because
    /// AVAudioEngine's mixer is happiest with floats — going through Int16 hit silent failures
    /// on iOS 18/26 where `int16ChannelData` returned nil and the buffer scheduled as silence.
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

    /// Buffers that arrived while the engine wasn't running yet — keep them so we can flush
    /// them in order once `engine.start()` succeeds. Without this the first chunk gets lost
    /// to the 0–50 ms gap between scheduling and engine startup.
    private var pendingPreEngineBuffers: [AVAudioPCMBuffer] = []

    var isPlaying: Bool = false
    var lastError: String?
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

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: Self.sourceFormat)
        engineAttached = true
        // `prepare()` allocates the rendering resources up front. Without it the first
        // scheduleBuffer can race with engine.start() and drop the buffer on the floor.
        engine.prepare()
        log.notice("engine init: outputFormat=\(self.engine.outputNode.outputFormat(forBus: 0).description, privacy: .public)  mixerFormat=\(self.engine.mainMixerNode.outputFormat(forBus: 0).description, privacy: .public)")
    }

    /// Stops any in-flight request and playback. Idempotent.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        if playerNode.isPlaying { playerNode.stop() }
        pendingBuffers = 0
        pendingPreEngineBuffers.removeAll()
        isPlaying = false
        note("cancel")
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

    /// Fire-and-forget version of `speak(text:lang:voice:)` for `Button` action callbacks.
    func speakAsync(text: String, lang: String, voice: String) {
        log.notice("speakAsync invoked from button: text=\"\(text, privacy: .public)\" voice=\(voice, privacy: .public) lang=\(lang, privacy: .public)")
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            do {
                try await self?.speak(text: text, lang: lang, voice: voice)
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = error.localizedDescription
                    self?.isPlaying = false
                    log.error("speak failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func speak(text: String, lang: String, voice: String) async throws {
        note("speak called")
        let defaults = UserDefaults.standard
        let urlString = defaults.string(forKey: PremiumTTSDevDefaults.workerURLKey)
            ?? PremiumTTSDevDefaults.defaultWorkerURL
        let bearer = (defaults.string(forKey: PremiumTTSDevDefaults.bearerKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bearer.isEmpty else {
            note("bearer empty")
            throw PremiumTTSError.missingConfig("Worker bearer not set (paste it in the dev panel)")
        }
        guard let url = URL(string: urlString) else { note("invalid URL"); throw PremiumTTSError.invalidURL }

        note("configuring session")
        try configureSession()
        note("session OK")
        try await sendAndStream(url: url, bearer: bearer, text: text, lang: lang, voice: voice)
        note("speak completed")
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

    private func sendAndStream(url: URL, bearer: String, text: String, lang: String, voice: String) async throws {
        log.notice("speak start: url=\(url.absoluteString, privacy: .public) voice=\(voice, privacy: .public) lang=\(lang, privacy: .public) chars=\(text.count, privacy: .public)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "voice": voice,
            "lang": lang,
            "model": "sonic-3.5",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let t0 = Date()
        lastFirstAudioMs = nil
        isPlaying = true
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

        try await parseSSE(bytes: bytes, startedAt: t0)
        // The network stream is done; whatever's still queued in playerNode will finish on its own.
        // We only flip isPlaying false when the player drains — but that's hard to observe per-buffer
        // without an audio tap, so as a reasonable proxy we just flip it here. The dev panel can
        // re-issue speak() at any time; the cancel() path inside speakAsync handles preemption.
        isPlaying = false
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

    // MARK: - PCM → AVAudioPCMBuffer → AVAudioPlayerNode

    private func schedulePCM(_ pcm: Data, startedAt t0: Date) throws {
        // Source is s16le mono → frameCount = byteCount / 2. Target buffer is Float32 mono so the
        // mixer doesn't have to deal with int16 quirks.
        let frameCount = AVAudioFrameCount(pcm.count / 2)
        guard frameCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.sourceFormat, frameCapacity: frameCount) else {
            throw PremiumTTSError.engineFailure("PCMBuffer allocation failed")
        }
        buffer.frameLength = frameCount

        // Convert s16le → float32 [-1, 1]. `floatChannelData?[0]` must be non-nil for
        // non-interleaved float32 mono — if it ever returns nil that's the audio is silent" bug
        // re-emerging and we want to know immediately.
        guard let dst = buffer.floatChannelData?[0] else {
            log.error("PCMBuffer.floatChannelData was nil — buffer would play silence")
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
        // Only log first chunk's peak — confirms PCM data isn't all zeroes.
        if lastFirstAudioMs == nil {
            log.notice("first chunk peak amplitude: \(peak, privacy: .public) (out of 32767)")
        }

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
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // The completion callback fires on a background queue. Bounce to MainActor so the
            // counter and observable flag don't race against the speak() coroutine.
            Task { @MainActor [weak self] in
                guard let self else { return }
                pendingBuffers = max(0, pendingBuffers - 1)
            }
        }
    }
}
