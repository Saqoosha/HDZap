import Foundation
import os

/// On-disk store for completed races. Persists to a single JSON file under
/// `Library/Application Support/HDZap/race-history.json` — Application
/// Support survives backups and is the appropriate home for app-managed
/// state the user didn't author manually.
///
/// Reads happen once at init; subsequent reads are served from the in-memory
/// `records` array. Writes serialize the whole array on every mutation;
/// races are short and infrequent so the cost is negligible compared to the
/// complexity of incremental updates.
@MainActor
@Observable
final class RaceHistoryStore {
    /// Most-recent first. SwiftUI sees this via `@Observable`.
    private(set) var records: [RaceRecord] = []

    private let fileURL: URL
    private let fileManager: FileManager
    private let log = Logger(subsystem: "sh.saqoo.HDZap", category: "RaceHistoryStore")

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = Self.defaultFileURL(fileManager: fileManager)
        loadFromDisk()
    }

    // MARK: - Public API

    func add(_ record: RaceRecord) {
        records.insert(record, at: 0)
        persist()
    }

    func delete(id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        records.removeAll()
        persist()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try Self.decoder.decode([RaceRecord].self, from: data)
            // Always present newest-first regardless of how an older payload
            // was ordered on disk.
            records = decoded.sorted(by: { $0.endedAt > $1.endedAt })
        } catch {
            log.error("Failed to load race history: \(String(describing: error), privacy: .public)")
            // Move the unreadable payload aside instead of overwriting it —
            // a future debugging session may want to inspect what couldn't
            // be decoded (schema drift after an in-place model change).
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: fileURL, to: backup)
        }
    }

    private func persist() {
        do {
            try ensureDirectoryExists()
            let data = try Self.encoder.encode(records)
            // Atomic write so a crash mid-write can't truncate the file to
            // zero bytes; the previous good copy remains until the rename
            // succeeds.
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            log.error("Failed to persist race history: \(String(describing: error), privacy: .public)")
        }
    }

    private func ensureDirectoryExists() throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir,
                                            withIntermediateDirectories: true)
        }
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true))
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("HDZap", isDirectory: true)
            .appendingPathComponent("race-history.json", isDirectory: false)
    }

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
