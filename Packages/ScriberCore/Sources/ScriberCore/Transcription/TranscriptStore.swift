import Foundation
import Observation
import ScriberShared

/// A saved transcript as listed (the text itself is loaded on demand).
public struct TranscriptSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var date: Date
    public var duration: TimeInterval
    public var engine: STTProviderKind
    /// First characters of the text, for the list.
    public var preview: String
    public var characters: Int
    /// Parts that could not be transcribed.
    public var missingCount: Int
    public var canExportSRT: Bool

    public init(_ record: TranscriptRecord) {
        id = record.id
        title = record.title
        date = record.date
        duration = record.duration
        engine = record.engine
        preview = String(record.paragraphs.lazy.filter { !$0.isMissing }.map(\.text).joined(separator: " ").prefix(160))
        characters = record.characterCount
        missingCount = record.missingCount
        canExportSRT = record.canExportSRT
    }
}

/// File transcripts, kept apart from dictation history (`HistoryStore`): an index (`index.json`,
/// newest first) plus one JSON file per transcript in `Transcripts/` of the app's data folder
/// (`AppGroup.containerURL`). Survives relaunch; list, rename, delete. Thread model like
/// `HistoryStore`: `items` is main-thread UI state, everything else is safe from any thread.
@Observable
public final class TranscriptStore: @unchecked Sendable {
    public static let shared = TranscriptStore()

    public private(set) var items: [TranscriptSummary] = []
    @ObservationIgnored public let directory: URL
    @ObservationIgnored private let index: PersistentList<TranscriptSummary>
    @ObservationIgnored private var changeObserver: StoreChangeObserver?
    @ObservationIgnored private let fileLock = NSLock()

    public init(directory: URL? = nil) {
        let folder = directory ?? AppGroup.containerURL.appendingPathComponent("Transcripts", isDirectory: true)
        self.directory = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        index = PersistentList(fileURL: folder.appendingPathComponent("index.json"))
        items = Self.sorted(index.read())
        changeObserver = StoreChangeObserver(name: index.changeNotificationName) { [weak self] in self?.publish() }
    }

    public func reload() { publish() }

    /// The full transcript, nil if it was deleted.
    public func record(id: UUID) -> TranscriptRecord? {
        fileLock.lock(); defer { fileLock.unlock() }
        guard let data = try? Data(contentsOf: bodyURL(id)) else { return nil }
        return try? JSONDecoder().decode(TranscriptRecord.self, from: data)
    }

    /// Inserts or replaces (same id). A title the user changed in the meantime is kept.
    @discardableResult
    public func save(_ record: TranscriptRecord) -> Bool {
        var record = record
        if let existing = index.read().first(where: { $0.id == record.id }) { record.title = existing.title }
        do {
            let data = try JSONEncoder().encode(record)
            fileLock.lock()
            defer { fileLock.unlock() }
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: bodyURL(record.id), options: options)
        } catch {
            DiagLog.log("transcribe", "store: save failed (\(type(of: error)))")
            return false
        }
        let summary = TranscriptSummary(record)
        index.mutate { items in
            items.removeAll { $0.id == summary.id }
            items.append(summary)
            items = Self.sorted(items)
        }
        publish()
        return true
    }

    public func rename(id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var record = record(id: id) else { return }
        record.title = String(trimmed.prefix(200))
        if let data = try? JSONEncoder().encode(record) {
            fileLock.lock()
            try? data.write(to: bodyURL(id), options: .atomic)
            fileLock.unlock()
        }
        index.mutate { items in
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].title = record.title }
        }
        publish()
    }

    public func remove(ids: Set<UUID>) {
        fileLock.lock()
        for id in ids { try? FileManager.default.removeItem(at: bodyURL(id)) }
        fileLock.unlock()
        index.mutate { items in items.removeAll { ids.contains($0.id) } }
        publish()
    }

    public func snapshot() -> [TranscriptSummary] { Self.sorted(index.read()) }

    private func bodyURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func sorted(_ items: [TranscriptSummary]) -> [TranscriptSummary] {
        items.sorted { $0.date > $1.date }
    }

    private func publish() {
        if Thread.isMainThread {
            let latest = Self.sorted(index.read())
            if latest != items { items = latest }
        } else {
            DispatchQueue.main.async { [self] in publish() }
        }
    }
}
