import Foundation
import Observation
import ScriberShared

public enum ModeStoreError: Error, Equatable, Sendable {
    case notFound
    /// Shipped modes can be edited, disabled and restored, not deleted: the pre-modes request enum
    /// (`.translate`, `.edit`) and the migration point at them.
    case builtInCannotBeDeleted
    /// 「還原預設」 only applies to shipped modes.
    case notBuiltIn
    /// The change would leave no enabled mode.
    case lastEnabledMode
}

/// The user's modes (PRD §2–§3), JSON in the App Group container (`modes.json`; on macOS in
/// Application Support), readable and writable by the app and the keyboard extension.
///
/// Invariants, restored on every read and write (`normalized`):
/// - every shipped mode exists (missing ones are added back with their shipped settings);
/// - ids are unique (first copy wins);
/// - at least one mode is enabled (聽寫 is re-enabled if none is);
/// - exactly one mode is the default, and it is enabled (聽寫 if possible, else the first enabled).
///
/// Nothing is written until something changes: with no file the store is the six shipped modes.
/// A file that cannot be read is moved aside (`modes.corrupt-<time>.json`) and the store falls back
/// to the shipped modes. A file whose envelope is readable but some of whose modes are not is
/// copied aside (`modes.unreadable-<time>.json`) before the next write drops them.
///
/// Same threading model as `DictionaryStore`: `modes` is the observable copy (main thread), the
/// file is the source of truth (any thread, both processes, atomic writes under a file lock).
@Observable
public final class ModeStore: @unchecked Sendable {
    public static let shared = ModeStore()
    /// How many recently used modes are remembered (the iOS mode key toggles between the last two).
    public static let recentCapacity = 4

    /// All modes, in the user's order.
    public private(set) var modes: [DictationModeConfig] = []
    @ObservationIgnored private let list: PersistentList<DictationModeConfig>
    @ObservationIgnored private let recentsDefaults: UserDefaults
    @ObservationIgnored private var changeObserver: StoreChangeObserver?

    static let recentsKey = "modes.recentIDs"

    /// `recents`: where the recently-used list is kept (the App Group defaults by default).
    public init(fileURL: URL? = nil, recents: UserDefaults? = nil) {
        let url = fileURL ?? AppGroup.containerURL.appendingPathComponent("modes.json")
        Self.backUpUnreadableModes(at: url)
        list = PersistentList(fileURL: url)
        recentsDefaults = recents ?? AppGroup.defaults
        modes = Self.normalized(list.read())
        changeObserver = StoreChangeObserver(name: list.changeNotificationName) { [weak self] in self?.publish() }
    }

    // MARK: Reading

    /// Thread-safe snapshot, invariants applied.
    public func snapshot() -> [DictationModeConfig] { Self.normalized(list.read()) }

    public func mode(id: String) -> DictationModeConfig? { snapshot().first { $0.id == id } }

    /// The mode the normal hotkey / mic button uses.
    public var defaultMode: DictationModeConfig { Self.defaultMode(in: snapshot()) }

    public var enabledModes: [DictationModeConfig] { snapshot().filter(\.isEnabled) }

    /// Re-reads the file (e.g. when a screen appears); cheap when nothing changed.
    public func reload() { publish() }

    // MARK: Editing

    /// Adds a mode the user made, at the end. A clashing or shipped id is replaced by a new UUID.
    /// `isDefault` on the new mode makes it the default.
    @discardableResult
    public func add(_ newMode: DictationModeConfig) -> DictationModeConfig {
        var added = newMode
        added.version = DictationModeConfig.currentVersion
        list.mutate { modes in
            var current = Self.normalized(modes)
            if added.isBuiltIn || current.contains(where: { $0.id == added.id }) { added.id = UUID().uuidString }
            if added.isDefault {
                added.isEnabled = true
                for index in current.indices { current[index].isDefault = false }
            }
            current.append(added)
            modes = Self.normalized(current)
        }
        publish()
        return self.mode(id: added.id) ?? added
    }

    /// Saves a changed mode. Its place in the list is kept. Setting `isDefault` makes it the
    /// default; clearing it on the current default does nothing (use `setDefault` on another mode).
    /// Disabling the default moves the default to 聽寫 (or, if that is disabled too, the first
    /// enabled mode).
    public func update(_ mode: DictationModeConfig) throws {
        try edit { modes in
            guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { throw ModeStoreError.notFound }
            let wasDefault = modes[index].isDefault
            var updated = mode
            updated.version = DictationModeConfig.currentVersion
            updated.isDefault = wasDefault || mode.isDefault
            if mode.isDefault, !wasDefault {
                updated.isEnabled = true
                for other in modes.indices { modes[other].isDefault = false }
            }
            if !updated.isEnabled, !modes.contains(where: { $0.id != mode.id && $0.isEnabled }) {
                throw ModeStoreError.lastEnabledMode
            }
            if !updated.isEnabled, updated.isDefault {
                updated.isDefault = false // the default moves to the first enabled mode
            }
            modes[index] = updated
        }
    }

    /// Removes a mode the user made.
    public func delete(id: String) throws {
        if BuiltInModeID(rawValue: id) != nil { throw ModeStoreError.builtInCannotBeDeleted }
        try edit { modes in
            guard let index = modes.firstIndex(where: { $0.id == id }) else { throw ModeStoreError.notFound }
            if modes[index].isEnabled, !modes.contains(where: { $0.id != id && $0.isEnabled }) {
                throw ModeStoreError.lastEnabledMode
            }
            modes.remove(at: index)
        }
    }

    /// A copy of any mode as a new mode the user owns, right after the original. Not the default.
    @discardableResult
    public func duplicate(id: String) throws -> DictationModeConfig {
        var copy: DictationModeConfig?
        try edit { modes in
            guard let index = modes.firstIndex(where: { $0.id == id }) else { throw ModeStoreError.notFound }
            var made = modes[index]
            made.id = UUID().uuidString
            made.isDefault = false
            made.isEnabled = true
            modes.insert(made, at: index + 1)
            copy = made
        }
        return copy!
    }

    public func setEnabled(_ enabled: Bool, id: String) throws {
        guard var changed = self.mode(id: id) else { throw ModeStoreError.notFound }
        changed.isEnabled = enabled
        try update(changed)
    }

    /// Makes `id` the default mode (enabling it if needed).
    public func setDefault(id: String) throws {
        try edit { modes in
            guard let index = modes.firstIndex(where: { $0.id == id }) else { throw ModeStoreError.notFound }
            for other in modes.indices { modes[other].isDefault = false }
            modes[index].isDefault = true
            modes[index].isEnabled = true
        }
    }

    /// Puts a shipped mode back to its shipped settings. Its place in the list, whether it is
    /// enabled, and whether it is the default stay as they are.
    public func restoreDefault(id: String) throws {
        guard let builtIn = BuiltInModeID(rawValue: id) else { throw ModeStoreError.notBuiltIn }
        try edit { modes in
            guard let index = modes.firstIndex(where: { $0.id == id }) else { throw ModeStoreError.notFound }
            var restored = DictationModeConfig.builtIn(builtIn)
            restored.isEnabled = modes[index].isEnabled
            restored.isDefault = modes[index].isDefault
            modes[index] = restored
        }
    }

    /// Moves modes like SwiftUI's `onMove`.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        list.mutate { modes in
            var current = Self.normalized(modes)
            let moving = source.sorted().filter { current.indices.contains($0) }.map { current[$0] }
            let before = source.filter { $0 < destination }.count
            for index in source.sorted(by: >) where current.indices.contains(index) { current.remove(at: index) }
            let target = max(0, min(current.count, destination - before))
            current.insert(contentsOf: moving, at: target)
            modes = current
        }
        publish()
    }

    /// Puts the modes in this order; modes not listed keep their relative order after them.
    public func reorder(ids: [String]) {
        list.mutate { modes in
            let current = Self.normalized(modes)
            var listed: [DictationModeConfig] = []
            var seen = Set<String>()
            for id in ids where seen.insert(id).inserted {
                if let mode = current.first(where: { $0.id == id }) { listed.append(mode) }
            }
            modes = listed + current.filter { !seen.contains($0.id) }
        }
        publish()
    }

    // MARK: Recently used (iOS mode key, PRD §6.2)

    /// Records that a mode was just used.
    public func noteUsed(id: String) {
        var ids = recentsDefaults.stringArray(forKey: Self.recentsKey) ?? []
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        recentsDefaults.set(Array(ids.prefix(Self.recentCapacity)), forKey: Self.recentsKey)
    }

    /// Up to `limit` enabled modes, most recently used first, filled up with the default mode and
    /// then the list order. `recentModeIDs(limit: 2)` is the pair the iOS mode key toggles between.
    public func recentModeIDs(limit: Int = 2) -> [String] {
        let modes = snapshot()
        let enabled = Set(modes.filter(\.isEnabled).map(\.id))
        var result: [String] = []
        let candidates = (recentsDefaults.stringArray(forKey: Self.recentsKey) ?? [])
            + [Self.defaultMode(in: modes).id] + modes.map(\.id)
        for id in candidates where enabled.contains(id) && !result.contains(id) {
            result.append(id)
            if result.count == limit { break }
        }
        return result
    }

    // MARK: Migration support

    /// Records the Mac's 說話改字 / 翻譯 modifier keys (`VariantModifier` raw values: none, shift,
    /// control, option, command) as the hotkeys of 改寫 / 翻譯. Called by the migration and, until
    /// the mode editor exists (M2), whenever those keys change in 設定 → 快捷鍵. Stored only:
    /// in M1 the Mac hotkey settings still decide what the keys do.
    public func setLegacyVariantHotkeys(editModifier: String, translateModifier: String) {
        list.mutate { modes in
            var current = Self.normalized(modes)
            for (id, modifier) in [(BuiltInModeID.rewrite, editModifier), (.translate, translateModifier)] {
                guard let index = current.firstIndex(where: { $0.id == id.rawValue }) else { continue }
                current[index].trigger.hotkey = ModeHotkey.withMainTrigger(modifier)
            }
            modes = current
        }
        publish()
    }

    /// Writes the current (normalized) modes if there is no file yet.
    func persistIfMissing() {
        list.mutate { modes in modes = Self.normalized(modes) }
    }

    // MARK: Invariants

    static func normalized(_ stored: [DictationModeConfig]) -> [DictationModeConfig] {
        var seen = Set<String>()
        var modes = stored.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        for builtIn in BuiltInModeID.allCases where !seen.contains(builtIn.rawValue) {
            var mode = DictationModeConfig.builtIn(builtIn)
            mode.isDefault = false
            modes.append(mode)
        }
        let fallbackID = BuiltInModeID.dictate.rawValue
        if !modes.contains(where: \.isEnabled), let index = modes.firstIndex(where: { $0.id == fallbackID }) {
            modes[index].isEnabled = true
        }
        let defaultIndex = modes.firstIndex { $0.isDefault && $0.isEnabled }
            ?? modes.firstIndex { $0.id == fallbackID && $0.isEnabled }
            ?? modes.firstIndex(where: \.isEnabled)!
        for index in modes.indices { modes[index].isDefault = index == defaultIndex }
        return modes
    }

    static func defaultMode(in modes: [DictationModeConfig]) -> DictationModeConfig {
        modes.first(where: \.isDefault) ?? normalized(modes).first(where: \.isDefault)!
    }

    // MARK: Private

    /// Applies `body` to the latest normalized modes under the file lock; nothing is written if it throws.
    private func edit(_ body: (inout [DictationModeConfig]) throws -> Void) throws {
        var failure: Error?
        list.mutate { modes in
            var current = Self.normalized(modes)
            do {
                try body(&current)
                modes = Self.normalized(current)
            } catch {
                failure = error
            }
        }
        publish()
        if let failure { throw failure }
    }

    /// Keeps a copy of a file whose modes this version cannot all read, before a write drops them.
    private static func backUpUnreadableModes(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [Any] else { return }
        struct Probe: Decodable {
            var items: [Item]
            struct Item: Decodable {
                var mode: DictationModeConfig?
                init(from decoder: Decoder) throws { mode = try? DictationModeConfig(from: decoder) }
            }
        }
        let readable = (try? JSONDecoder().decode(Probe.self, from: data))?.items.compactMap(\.mode).count ?? 0
        guard readable < items.count else { return }
        let backup = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension("json")
        try? FileManager.default.copyItem(at: url, to: backup)
        DiagLog.log("modes", "modes.json has \(items.count - readable) unreadable mode(s); copy kept aside")
    }

    private func publish() {
        if Thread.isMainThread {
            let latest = Self.normalized(list.read())
            if latest != modes { modes = latest }
        } else {
            DispatchQueue.main.async { [self] in publish() }
        }
    }
}
