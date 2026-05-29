import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "sh.saqoo.HDZap", category: "TTSCache")

/// Local disk cache for Premium TTS audio. Same canonical key shape as the Worker's R2
/// cache (provider|voice|lang|rate|pitch|text → hex SHA-256), so the layers stack
/// cleanly: local hit → 0 RTT, local miss + R2 hit → ~150 ms, double-miss → ~400 ms
/// provider cold call. The R2 fetch on the way down also warms this cache, so a phrase a
/// user hears once is essentially free forever (up to the LRU cap).
///
/// Every cached payload is raw s16le mono PCM at the provider's native sample rate
/// (Polly 16 kHz, Azure 24 kHz). On cache hit we load the file into an `AVAudioPCMBuffer`
/// and schedule it on the same player path the streaming code uses.
final class TTSCache {
    static let shared = TTSCache()

    private let directory: URL
    /// 50 MB cap. Every entry is raw s16le mono PCM (16 kHz Polly = ~32 KB/sec, 24 kHz
    /// Azure = ~48 KB/sec), so a typical 2-second race phrase lands between 64 and 96 KB.
    /// The cap holds hundreds of unique phrases plus the entire 30-voice picker sample
    /// set without thrashing. Falls back to LRU eviction at 50% retention when exceeded
    /// so we don't flap right at the boundary.
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
        text: String
    ) -> String {
        // "v6" prefix invalidates earlier cache entries. v5 (leading-only silence
        // trim) is structurally fine, but the canonical-key shape changed when the
        // Cartesia provider was removed — the trailing `model` segment (only ever
        // set to "sonic-3.5" for Cartesia) is gone, so v5 keys hash differently
        // from v6 even for identical Polly / Azure inputs. Bump the prefix again on
        // any future canonical-key change so stale entries get re-fetched instead
        // of replaying with the wrong shape. The Worker's R2 cache carries its own
        // "v3" prefix (a different SHA-256 over a different canonical string), so
        // local and remote layers are structurally independent by design; only
        // update the Worker prefix if R2 itself stores something new.
        let canonical = [
            "v6",
            provider.rawValue,
            voice,
            lang,
            String(format: "%.3f", rate),
            String(format: "%.3f", pitch),
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

    /// File extension is `.pcm` for every provider — all three now stream raw s16le mono
    /// bytes (just at different sample rates), so the cached payload is uniformly raw PCM
    /// that the synth loads into AVAudioPCMBuffer on cache hit. The `provider` argument
    /// stays on the API for future per-provider sub-paths; pre-migration `.mp3` cache
    /// files become orphans and evict naturally via the LRU.
    private func filename(key: String, provider: PremiumVoiceProvider) -> String {
        _ = provider
        return "\(key).pcm"
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
