import Foundation
import Observation
import ScriberShared
import Security

// CONTRACT FILE — implementations owned by the "zh-TW + stores" agent.

public struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Correct spelling, e.g. "Claude Code", "鹿野".
    public var term: String
    /// Optional mis-hearings to replace with `term`, e.g. ["cloud code", "克勞德扣"].
    public var soundsLike: [String]
    public init(id: UUID = UUID(), term: String, soundsLike: [String] = []) {
        self.id = id; self.term = term; self.soundsLike = soundsLike
    }
}

public struct HistoryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var mode: DictationMode
    public var rawTranscript: String
    public var finalText: String
    public var sttProvider: STTProviderKind
    public var polishProvider: PolishProviderKind
    public var totalMillis: Int
    public init(id: UUID = UUID(), date: Date = Date(), mode: DictationMode, rawTranscript: String, finalText: String,
                sttProvider: STTProviderKind, polishProvider: PolishProviderKind, totalMillis: Int) {
        self.id = id; self.date = date; self.mode = mode; self.rawTranscript = rawTranscript
        self.finalText = finalText; self.sttProvider = sttProvider; self.polishProvider = polishProvider
        self.totalMillis = totalMillis
    }
}

/// API keys in the Keychain, shared by the app and the keyboard extension.
///
/// Generic-password items (service = `service`, account = `APIKeyKind.rawValue`), accessible
/// after first unlock so the background audio session can read them while the phone is locked.
/// Values are never logged.
///
/// Access group: both targets carry `keychain-access-groups = $(AppIdentifierPrefix)com.geekaz.Scriber.shared`
/// and the resolved name in their Info.plist (`ScriberKeychainAccessGroup`), so the keyboard can
/// run the pipeline itself (in-keyboard capture). Keys saved by earlier builds live in the app's
/// own default group (its application identifier), which the keyboard cannot see; the first
/// keychain access in each process migrates them (see `migrateLegacyItems()`). When the group
/// cannot be resolved or used (unsigned/simulator builds, `swift test`, a missing entitlement:
/// errSecMissingEntitlement) everything falls back to the old group-less behaviour.
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()
    /// Info.plist key holding the resolved shared access group.
    public static let accessGroupInfoKey = "ScriberKeychainAccessGroup"
    static let sharedGroupSuffix = "com.geekaz.Scriber.shared"

    /// "<TeamID>.com.geekaz.Scriber.shared" from the running bundle's Info.plist, or nil when it
    /// was not expanded at build time (no team prefix) or is absent (tests).
    ///
    /// Always nil on macOS: the Mac app is a single process (nothing to share keys with) and is not
    /// provisioned for keychain access groups, so it uses plain generic-password items in the
    /// user's login keychain, readable by this app's signature only.
    public static var sharedAccessGroup: String? {
        #if os(macOS)
        return nil
        #else
        guard let raw = Bundle.main.object(forInfoDictionaryKey: accessGroupInfoKey) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasSuffix(sharedGroupSuffix), !value.contains("$("),
              value.count > sharedGroupSuffix.count + 1, !value.hasPrefix(".") else { return nil }
        return value
        #endif
    }

    private let service: String
    private let backend: KeychainBackend
    /// Diagnostics sink (kinds and OSStatus codes only, never values).
    private let log: (String) -> Void
    private let lock = NSLock()
    // Guarded by `lock`.
    private var group: String?
    private var migrationDone = false

    public convenience init(service: String = "com.geekaz.Scriber.apikeys") {
        self.init(service: service, accessGroup: Self.sharedAccessGroup)
    }

    /// `accessGroup` nil keeps the group-less behaviour (no migration).
    public convenience init(service: String, accessGroup: String?) {
        self.init(service: service, accessGroup: accessGroup, backend: .system)
    }

    init(service: String, accessGroup: String?, backend: KeychainBackend,
         log: @escaping (String) -> Void = { DiagLog.log("keychain", $0) }) {
        self.service = service
        self.group = accessGroup
        self.backend = backend
        self.log = log
    }

    /// The access group in use, or nil when running group-less.
    public var accessGroup: String? {
        lock.lock(); defer { lock.unlock() }
        return group
    }

    public func key(for kind: APIKeyKind) -> String? {
        migrateIfNeeded()
        if let group = accessGroup {
            let (status, data) = readData(kind, group: group)
            if status == errSecSuccess, let value = Self.decode(data) { return value }
            if status == errSecMissingEntitlement { disableGroup(status: status) }
            // Not in the shared group (yet): a key the migration could not move is still usable here.
        }
        return Self.decode(readData(kind, group: nil).data)
    }

    /// Pass nil or empty to delete.
    public func setKey(_ value: String?, for kind: APIKeyKind) {
        storeKey(value, for: kind)
    }

    public func hasKey(for kind: APIKeyKind) -> Bool { key(for: kind)?.isEmpty == false }

    /// Same as `setKey`, returning the Security framework status (tests use it to detect a
    /// keychain that is unavailable in the current process).
    @discardableResult
    func storeKey(_ value: String?, for kind: APIKeyKind) -> OSStatus {
        migrateIfNeeded()
        // Pasted keys often carry a trailing newline; API keys never contain whitespace.
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            // Group-less delete removes every copy this process can see (shared and legacy).
            let status = backend.delete(baseQuery(kind, group: nil))
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let data = Data(trimmed.utf8)
        if let group = accessGroup {
            let status = upsert(kind, data: data, group: group)
            if status == errSecSuccess {
                // An older copy in the legacy group must not shadow or resurrect this one.
                for legacy in itemGroups(kind).filter({ $0 != group }) {
                    _ = backend.delete(baseQuery(kind, group: legacy))
                }
                return status
            }
            guard status == errSecMissingEntitlement else { return status }
            disableGroup(status: status)
        }
        return upsert(kind, data: data, group: nil)
    }

    // MARK: Migration

    /// Moves keys saved by builds before the shared access group into it: read the old item,
    /// write it to the shared group, verify the copy reads back identical, then delete the old
    /// item. A key already present in the shared group wins (it was written by this code, which
    /// also removes legacy copies). Idempotent and safe from either process and from several
    /// threads: the keyboard simply cannot see the app's legacy group and finds nothing to do;
    /// a concurrent copy shows up as errSecDuplicateItem and is verified like our own.
    /// Nothing is deleted unless the shared copy is confirmed. Returns the kinds moved.
    @discardableResult
    public func migrateLegacyItems() -> [APIKeyKind] {
        guard let group = accessGroup else { return [] }
        var moved: [APIKeyKind] = []
        for kind in APIKeyKind.allCases {
            let groups = itemGroups(kind)
            let legacy = groups.filter { $0 != group }
            guard !legacy.isEmpty else { continue }
            var sharedConfirmed = groups.contains(group)
            if !sharedConfirmed {
                for source in legacy {
                    let (readStatus, data) = readData(kind, group: source)
                    guard readStatus == errSecSuccess, let data, !data.isEmpty else { continue }
                    var add = baseQuery(kind, group: group)
                    add[kSecValueData as String] = data
                    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                    let status = backend.add(add)
                    if status == errSecSuccess || status == errSecDuplicateItem {
                        sharedConfirmed = readData(kind, group: group).data == data
                        if !sharedConfirmed {
                            log("migrate \(kind.rawValue): shared copy did not verify, legacy kept")
                        }
                    } else {
                        log("migrate \(kind.rawValue): add to shared group failed status=\(status), legacy kept")
                        if status == errSecMissingEntitlement { disableGroup(status: status) }
                    }
                    break
                }
            }
            guard sharedConfirmed else { continue }
            for source in legacy {
                let status = backend.delete(baseQuery(kind, group: source))
                if status != errSecSuccess, status != errSecItemNotFound {
                    log("migrate \(kind.rawValue): delete legacy failed status=\(status)")
                }
            }
            moved.append(kind)
        }
        if !moved.isEmpty {
            log("migrated \(moved.map(\.rawValue).joined(separator: ",")) into the shared group")
        }
        return moved
    }

    private func migrateIfNeeded() {
        lock.lock()
        let run = !migrationDone && group != nil
        migrationDone = true
        lock.unlock()
        if run { migrateLegacyItems() }
    }

    private func disableGroup(status: OSStatus) {
        lock.lock()
        let was = group
        group = nil
        lock.unlock()
        if was != nil {
            log("shared access group unusable (status=\(status)); using the default group")
        }
    }

    // MARK: Security calls

    /// Access groups holding an item for `kind` that this process can see.
    private func itemGroups(_ kind: APIKeyKind) -> [String] {
        var query = baseQuery(kind, group: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = backend.copyMatching(query)
        guard status == errSecSuccess else { return [] }
        let items = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        var seen = Set<String>()
        return items.compactMap { $0[kSecAttrAccessGroup as String] as? String }.filter { seen.insert($0).inserted }
    }

    private func readData(_ kind: APIKeyKind, group: String?) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(kind, group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = backend.copyMatching(query)
        return (status, status == errSecSuccess ? result as? Data : nil)
    }

    private func upsert(_ kind: APIKeyKind, data: Data, group: String?) -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = backend.update(baseQuery(kind, group: group), attributes)
        guard status == errSecItemNotFound else { return status }
        var add = baseQuery(kind, group: group)
        add.merge(attributes) { _, new in new }
        return backend.add(add)
    }

    private static func decode(_ data: Data?) -> String? {
        guard let data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    private func baseQuery(_ kind: APIKeyKind, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }
}

/// The four SecItem calls, injectable so the migration can be tested against a fake keychain
/// with access groups (`swift test` on macOS has no entitlements).
struct KeychainBackend: @unchecked Sendable {
    var copyMatching: (_ query: [String: Any]) -> (OSStatus, AnyObject?)
    var add: (_ attributes: [String: Any]) -> OSStatus
    var update: (_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    var delete: (_ query: [String: Any]) -> OSStatus

    static let system = KeychainBackend(
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

/// Personal dictionary, persisted as JSON in the App Group container. Main-actor UI state.
///
/// `entries` is the observable copy for SwiftUI and changes on the main thread only; mutations
/// from another thread are applied immediately to the thread-safe store and reach `entries` on
/// the next main-queue turn. `snapshot()` and `applyReplacements` are safe from any thread.
@Observable
public final class DictionaryStore: @unchecked Sendable {
    public static let shared = DictionaryStore()
    public private(set) var entries: [DictionaryEntry] = []
    @ObservationIgnored private let list: PersistentList<DictionaryEntry>
    @ObservationIgnored private var changeObserver: StoreChangeObserver?

    public init(fileURL: URL? = nil) {
        list = PersistentList(fileURL: fileURL ?? AppGroup.containerURL.appendingPathComponent("dictionary.json"))
        entries = list.read()
        // The other process (app or keyboard) wrote the file: refresh `entries`.
        changeObserver = StoreChangeObserver(name: list.changeNotificationName) { [weak self] in self?.publish() }
    }

    /// Re-reads the file (e.g. when a screen appears); cheap when nothing changed.
    public func reload() { publish() }
    /// Appends the entry, or replaces the entry with the same id.
    public func add(_ entry: DictionaryEntry) {
        list.mutate { entries in
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
        publish()
    }
    /// Replaces the entry with the same id; does nothing if it was removed meanwhile.
    public func update(_ entry: DictionaryEntry) {
        list.mutate { entries in
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        }
        publish()
    }
    public func remove(ids: Set<UUID>) {
        list.mutate { entries in entries.removeAll { ids.contains($0.id) } }
        publish()
    }
    /// Thread-safe snapshot for the pipeline.
    public func snapshot() -> [DictionaryEntry] { list.read() }
    /// Applies every `soundsLike → term` replacement (case-insensitive for Latin).
    ///
    /// Longest match first, one pass (replacements are not re-scanned). Latin patterns only match
    /// whole words ("pr" never fires inside "prompt"); CJK patterns match as substrings and
    /// regardless of Simplified/Traditional script. See `DictionaryReplacer`.
    public func applyReplacements(to text: String) -> String {
        DictionaryReplacer(entries: list.read()).apply(to: text)
    }

    /// Suggested starter entries (common zh/en tech terms and their usual mis-hearings), offered
    /// in the UI as「加入建議詞彙」. Never added automatically. Loaded from `BuiltInDictionary.json`.
    public static let builtInEntries: [DictionaryEntry] = {
        struct Seed: Decodable { var term: String; var soundsLike: [String] }
        guard let url = Bundle.module.url(forResource: "BuiltInDictionary", withExtension: "json", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "BuiltInDictionary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let seeds = try? JSONDecoder().decode([Seed].self, from: data) else { return [] }
        return seeds.map { DictionaryEntry(term: $0.term, soundsLike: $0.soundsLike) }
    }()

    private func publish() {
        if Thread.isMainThread {
            let latest = list.read()
            if latest != entries { entries = latest }
        } else {
            DispatchQueue.main.async { [self] in publish() }
        }
    }
}

/// Recent dictations, newest first, capped (e.g. 200), JSON in the App Group container.
///
/// Same threading model as `DictionaryStore`: `add` may be called from a background task.
@Observable
public final class HistoryStore: @unchecked Sendable {
    public static let shared = HistoryStore()
    public static let capacity = 200
    public private(set) var items: [HistoryItem] = []
    @ObservationIgnored private let list: PersistentList<HistoryItem>
    @ObservationIgnored private var changeObserver: StoreChangeObserver?

    public init(fileURL: URL? = nil) {
        list = PersistentList(fileURL: fileURL ?? AppGroup.containerURL.appendingPathComponent("history.json"))
        // Repair order/cap of whatever was on disk (on the latest contents, under the file lock,
        // only writing when something is off).
        let loaded = list.read()
        items = Self.normalized(loaded) == loaded ? loaded : list.mutate { $0 = Self.normalized($0) }
        // The other process (app or keyboard) wrote the file: refresh `items`.
        changeObserver = StoreChangeObserver(name: list.changeNotificationName) { [weak self] in self?.publish() }
    }

    /// Re-reads the file (e.g. when the history screen appears); cheap when nothing changed.
    public func reload() { publish() }
    /// Inserts by date (newest first) and drops the oldest beyond `capacity`.
    public func add(_ item: HistoryItem) {
        list.mutate { items in
            items.removeAll { $0.id == item.id }
            let index = items.firstIndex { $0.date <= item.date } ?? items.endIndex
            items.insert(item, at: index)
            if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
        }
        publish()
    }
    public func remove(ids: Set<UUID>) {
        list.mutate { items in items.removeAll { ids.contains($0.id) } }
        publish()
    }
    public func clear() {
        list.mutate { $0.removeAll() }
        publish()
    }
    /// Thread-safe snapshot.
    public func snapshot() -> [HistoryItem] { list.read() }

    private static func normalized(_ items: [HistoryItem]) -> [HistoryItem] {
        var seen = Set<UUID>()
        let unique = items.filter { seen.insert($0.id).inserted }
        // Stable sort: equal dates keep their stored order.
        let sorted = unique.enumerated().sorted { a, b in
            a.element.date != b.element.date ? a.element.date > b.element.date : a.offset < b.offset
        }.map(\.element)
        return Array(sorted.prefix(capacity))
    }

    private func publish() {
        if Thread.isMainThread {
            let latest = list.read()
            if latest != items { items = latest }
        } else {
            DispatchQueue.main.async { [self] in publish() }
        }
    }
}
