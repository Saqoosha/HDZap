import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "sh.saqoo.HDZap", category: "TTSCache")

/// Local disk cache for Premium TTS audio. Same canonical key shape as the Worker's R2
/// cache (provider|voice|lang|rate|pitch|model|text → hex SHA-256), so the layers stack
/// cleanly: local hit → 0 RTT, local miss + R2 hit → ~150 ms, double-miss → ~400 ms
/// provider cold call. The R2 fetch on the way down also warms this cache, so a phrase a
/// user hears once is essentially free forever (up to the LRU cap).
///
/// Cached payloads are provider-specific raw bytes:
///   - Polly / Azure: raw mp3 — fed straight to `AVAudioPlayer(contentsOf:)` on hit
///   - Cartesia: raw s16le 24 kHz PCM concatenated from the SSE stream (we strip the SSE
///     wrapper before caching since it adds ~30% overhead and we don't need the framing
///     when serving a finished file from disk)
final class TTSCache {
    static let shared = TTSCache()

    private let directory: URL
    /// 50 MB cap. ~5 KB per Polly/Azure mp3 and ~100 KB per Cartesia 2-sec PCM utterance,
    /// so this fits the whole 55-voice picker sample set plus thousands of race phrases
    /// without thrashing. Falls back to LRU eviction at 50% retention when exceeded so we
    /// don't flap right at the boundary.
    private let maxBytes: Int = 50 * 1024 * 1024

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory = caches.appendingPathComponent("HDZapTTS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log.notice("TTSCache dir: \(self.directory.path, privacy: .public)")
    }

    /// Canonical hex SHA-256 of every parameter that affects the generated audio. Stable
    /// across sessions and mirrors `buildCacheKey()` in the Worker so the two layers refer
    /// to the same logical entity even though they store it independently.
    func key(
        provider: PremiumVoiceProvider,
        voice: String,
        lang: String,
        rate: Double,
        pitch: Double,
        model: String,
        text: String
    ) -> String {
        let canonical = [
            provider.rawValue,
            voice,
            lang,
            String(format: "%.3f", rate),
            String(format: "%.3f", pitch),
            model,
            text,
        ].joined(separator: "|")
        let hash = SHA256.hash(data: Data(canonical.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a file URL if the cache holds an entry for this key+provider. Touches the
    /// file's mtime so the LRU evictor will spare frequently-used entries.
    func url(forKey key: String, provider: PremiumVoiceProvider) -> URL? {
        let fileURL = directory.appendingPathComponent(filename(key: key, provider: provider))
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return fileURL
    }

    /// Persist `data` to disk under `key`. Best-effort; failures are logged but don't
    /// propagate because a cache miss just falls through to a paid provider call — no
    /// user-visible regression.
    func save(key: String, provider: PremiumVoiceProvider, data: Data) {
        let fileURL = directory.appendingPathComponent(filename(key: key, provider: provider))
        do {
            try data.write(to: fileURL, options: .atomic)
            log.notice("cached \(data.count, privacy: .public) bytes as \(fileURL.lastPathComponent, privacy: .public)")
            evictIfNeeded()
        } catch {
            log.error("cache save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// File extension chosen by provider — `.mp3` for Polly/Azure (raw mp3 bytes,
    /// AVAudioPlayer reads straight from the file), `.pcm` for Cartesia (raw s16le 24 kHz
    /// PCM, loaded into an AVAudioPCMBuffer for the engine path).
    private func filename(key: String, provider: PremiumVoiceProvider) -> String {
        switch provider {
        case .cartesia: return "\(key).pcm"
        case .polly, .azure: return "\(key).mp3"
        }
    }

    /// After every successful write, check the total cache footprint. If we're over the
    /// cap, delete oldest-by-mtime first until we're down to ~half the cap. Halving rather
    /// than evicting-to-just-under-cap avoids thrashing if a user is doing a long
    /// audition session where every preview is near-cap.
    private func evictIfNeeded() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var withMeta: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0
        for url in entries {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let mtime = values?.contentModificationDate ?? .distantPast
            withMeta.append((url, size, mtime))
            total += size
        }
        guard total > maxBytes else { return }
        log.notice("evict: total=\(total, privacy: .public) > cap=\(self.maxBytes, privacy: .public)")
        withMeta.sort { $0.mtime < $1.mtime }
        let halfCap = maxBytes / 2
        for entry in withMeta {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= halfCap { break }
        }
    }
}
