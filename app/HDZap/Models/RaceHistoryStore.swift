import Foundation
import os

/// On-disk store for completed races. Persists to a single JSON file under
/// `Library/Application Support/HDZap/race-history.json` — Application
/// Support survives backups and is the appropriate home for app-managed
/// state the user didn't author manually.
///
/// Reads happen once at init (off the main thread); subsequent reads are
/// served from the in-memory `records` array. Writes serialize the whole
/// array on every mutation; races are short and infrequent so the cost is
/// negligible compared to the complexity of incremental updates.
@MainActor
@Observable
final class RaceHistoryStore {
    /// Most-recent first by `endedAt`.
    private(set) var records: [RaceRecord] = []

    /// Most recent persistence failure surfaced for UI banners. Cleared on
    /// the next successful mutation. Without this, a save failure would
    /// only show up at next launch when the missing race "vanishes" —
    /// the operator deserves to know at the moment their action didn't
    /// reach disk.
    private(set) var lastPersistError: String?

    /// Set when Application Support couldn't be resolved at init. The
    /// previous silent fallback to `temporaryDirectory` looked fine until
    /// iOS reaped the tmp directory, producing a "history vanished" support
    /// class with no breadcrumb. Surfacing keeps the operator from trusting
    /// a store that can't actually persist.
    private(set) var setupError: String?

    private let fileURL: URL?
    private let fileManager: FileManager
    private let log = Logger(subsystem: "sh.saqoo.HDZap", category: "RaceHistoryStore")

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        do {
            self.fileURL = try Self.defaultFileURL(fileManager: fileManager)
        } catch {
            self.fileURL = nil
            self.setupError = "Couldn't locate Application Support: \(error.localizedDescription)"
            log.fault("RaceHistoryStore setup failed: \(String(describing: error), privacy: .public)")
        }
        #if DEBUG
        // Screenshot mode would race against `loadFromDiskAsync()`:
        // TimerView's `.onAppear` seeds five known records, but the
        // detached load could land after that and overwrite them with
        // whatever's already on disk in the simulator's container.
        // Skip the load entirely so the seed wins unconditionally.
        // `seedForScreenshot` bypasses `commit()`, so the developer's
        // real `race-history.json` is never written either.
        if ProcessInfo.processInfo.arguments.contains("-screenshotHistory") {
            return
        }
        #endif
        loadFromDiskAsync()
    }

    // MARK: - Public API

    func add(_ record: RaceRecord) {
        // Ordered insert by `endedAt` descending so a backfilled or
        // out-of-order record can't silently break the newest-first
        // contract. Dedup-by-id at the same time so a duplicate save
        // (e.g. a future retry path) doesn't double-list one race in the
        // SwiftUI `ForEach`.
        var next = records.filter { $0.id != record.id }
        let insertAt = next.firstIndex(where: { $0.endedAt < record.endedAt }) ?? next.endIndex
        next.insert(record, at: insertAt)
        commit(next)
    }

    func delete(id: UUID) {
        commit(records.filter { $0.id != id })
    }

    func deleteAll() {
        commit([])
    }

    /// Drop a previously surfaced error from the UI without touching the
    /// records — pairs with the BLE error-log "dismiss" idiom.
    func clearLastPersistError() { lastPersistError = nil }

    #if DEBUG
    /// Seed in-memory records for App Store screenshot capture. Skips disk
    /// persistence so a screenshot run can't overwrite the developer's
    /// real history. Sorted newest-first to match the live store's
    /// `records` contract. See docs/screenshot-capture.md.
    func seedForScreenshot(_ next: [RaceRecord]) {
        records = next.sorted(by: { $0.endedAt > $1.endedAt })
    }
    #endif

    // MARK: - Persistence

    /// Mutate + persist with rollback. The previous design left
    /// `records` mutated even when `persist()` threw, so a save failure
    /// would look successful on screen and the user only found out at
    /// next launch that nothing reached disk.
    private func commit(_ next: [RaceRecord]) {
        let previous = records
        records = next
        do {
            try persist()
            lastPersistError = nil
        } catch {
            records = previous
            lastPersistError = persistErrorMessage(for: error)
            log.error("Failed to persist race history: \(String(describing: error), privacy: .public)")
        }
    }

    /// Off-main-actor read so launch isn't blocked by the file's I/O.
    /// JSON decode happens on a background priority; the resulting
    /// records hop back to the main actor for the `records =` assignment.
    private func loadFromDiskAsync() {
        guard let fileURL else { return }
        let fm = fileManager
        let logger = log
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                () -> (records: [RaceRecord]?, decodeFailed: Bool) in
                guard fm.fileExists(atPath: fileURL.path) else {
                    return (nil, false)
                }
                do {
                    let data = try Data(contentsOf: fileURL)
                    let decoded = try Self.decoder.decode([RaceRecord].self, from: data)
                    return (decoded.sorted(by: { $0.endedAt > $1.endedAt }), false)
                } catch {
                    logger.error("Failed to load race history: \(String(describing: error), privacy: .public)")
                    return (nil, true)
                }
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let loaded = result.records {
                    self.records = loaded
                } else if result.decodeFailed {
                    self.quarantineCorruptFile()
                }
            }
        }
    }

    /// Move an unreadable payload aside so a future debugging session can
    /// inspect what couldn't be decoded. If the rename fails (most often
    /// a same-second name collision or out-of-space), the original file
    /// is *deleted* — leaving it would let the next `[.atomic]` write
    /// silently overwrite it, breaking the inspect-later promise.
    private func quarantineCorruptFile() {
        guard let fileURL else { return }
        let dir = fileURL.deletingLastPathComponent()
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(6)
        let backup = dir.appendingPathComponent(
            "race-history.corrupt-\(stamp)-\(suffix).json",
            isDirectory: false
        )
        do {
            try fileManager.moveItem(at: fileURL, to: backup)
            log.error("Quarantined corrupt history at \(backup.lastPathComponent, privacy: .public)")
        } catch {
            log.fault("Couldn't preserve corrupt history; removing to recover: \(String(describing: error), privacy: .public)")
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func persist() throws {
        guard let fileURL else { throw PersistError.noStorage }
        try ensureDirectoryExists(for: fileURL)
        let data = try Self.encoder.encode(records)
        // Atomic write so a crash mid-write can't truncate the file to
        // zero bytes; the previous good copy remains until the rename
        // succeeds.
        try data.write(to: fileURL, options: [.atomic])
    }

    private func ensureDirectoryExists(for url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private static func defaultFileURL(fileManager: FileManager) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true)
        return base
            .appendingPathComponent("HDZap", isDirectory: true)
            .appendingPathComponent("race-history.json", isDirectory: false)
    }

    /// Distinct user-facing copy for the failure modes that warrant it —
    /// "out of storage" and "read-only volume" want a different framing
    /// than a generic "save failed".
    private func persistErrorMessage(for error: Error) -> String {
        if case PersistError.noStorage = error {
            return "Race storage isn't available — history won't persist this session."
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError:
                return "Couldn't save race: device is out of storage."
            case NSFileWriteVolumeReadOnlyError:
                return "Couldn't save race: storage is read-only."
            case NSFileWriteNoPermissionError:
                return "Couldn't save race: permission denied."
            default:
                break
            }
        }
        return "Couldn't save race: \(error.localizedDescription)"
    }

    private enum PersistError: Error { case noStorage }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
