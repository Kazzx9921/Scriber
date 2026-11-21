import Foundation

/// A thread-safe list persisted as JSON (`{"version": 1, "items": [...]}`), the source of truth
/// behind the observable stores. Reads and writes may come from any thread **and from more than
/// one process**: the app and the keyboard extension (in-keyboard capture saves history) share
/// these files in the App Group container.
///
/// - Every mutation is read-modify-write under an exclusive `flock` on a sibling lock file, and
///   re-reads the file first if another process replaced it, so two writers never drop each
///   other's changes. Writes are atomic (temp file + rename), so a reader never sees half a file.
/// - `read()` notices a file another process replaced (inode/size/mtime changed) and reloads it.
/// - After a write, a Darwin notification (`changeNotificationName`) tells the other process to
///   refresh its observable copy.
/// - A missing file starts empty. An unreadable file is moved aside (`*.corrupt-<time>.json`) so
///   it is not silently overwritten. Items that fail to decode (e.g. an enum case from another
///   app version) are skipped instead of discarding the whole file.
final class PersistentList<Element: Codable & Equatable & Sendable>: @unchecked Sendable {
    let fileURL: URL
    /// Darwin notification posted after every successful write of this file.
    let changeNotificationName: String
    private let lockURL: URL
    /// Guards `elements` / `stamp` and serialises file work within this process.
    private let lock = NSLock()
    private var elements: [Element]
    /// Identity of the file version `elements` reflects (nil: no file).
    private var stamp: FileStamp?

    static var formatVersion: Int { 1 }

    init(fileURL: URL) {
        self.fileURL = fileURL
        lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("." + fileURL.lastPathComponent + ".lock")
        changeNotificationName = "com.geekaz.Scriber.store." + Self.stableHash(fileURL.standardizedFileURL.path)
        elements = Self.load(from: fileURL)
        stamp = FileStamp(url: fileURL) // after load: a corrupt file was moved aside
    }

    func read() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        reloadIfReplaced()
        return elements
    }

    /// Applies `body` to the latest contents (re-read from disk if another process wrote them),
    /// then persists if anything changed. Returns the new contents.
    @discardableResult
    func mutate(_ body: (inout [Element]) -> Void) -> [Element] {
        lock.lock()
        let fileLock = CrossProcessFileLock(url: lockURL)
        reloadIfReplaced()
        let before = elements
        body(&elements)
        let after = elements
        let wrote = after != before && persist(after)
        fileLock.unlock()
        lock.unlock()
        if wrote { StoreChangeObserver.post(changeNotificationName) }
        return after
    }

    // MARK: - File I/O (call with `lock` held)

    private struct Envelope: Codable {
        var version: Int
        var items: LossyArray<Element>
    }

    private func reloadIfReplaced() {
        let current = FileStamp(url: fileURL)
        guard current != stamp else { return }
        elements = Self.load(from: fileURL)
        stamp = FileStamp(url: fileURL)
    }

    private func persist(_ snapshot: [Element]) -> Bool {
        do {
            let data = try JSONEncoder().encode(Envelope(version: Self.formatVersion, items: LossyArray(snapshot)))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            // Readable while the phone is locked (background dictation), like the Keychain items.
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: fileURL, options: options)
            stamp = FileStamp(url: fileURL)
            return true
        } catch {
            // Keep the in-memory state; the next mutation retries the write (unless another
            // process replaced the file meanwhile, whose contents then win).
            return false
        }
    }

    private static func load(from url: URL) -> [Element] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: data) { return envelope.items.elements }
        // Tolerate a bare array, e.g. a hand-made import file.
        if let array = try? decoder.decode(LossyArray<Element>.self, from: data) { return array.elements }
        moveAside(url)
        return []
    }

    private static func moveAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp)")
            .appendingPathExtension(url.pathExtension.isEmpty ? "json" : url.pathExtension)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    /// FNV-1a: stable across processes (Swift's `Hasher` is seeded per process).
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// Which version of a file is on disk. Atomic writes replace the inode, so any write by any
/// process changes the stamp.
struct FileStamp: Equatable {
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int
    var modifiedNanos: Int

    init?(url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = Int(info.st_mtimespec.tv_sec)
        modifiedNanos = Int(info.st_mtimespec.tv_nsec)
    }
}

/// Exclusive advisory lock (`flock`) on a file shared by the app and the keyboard. Held only for
/// a read-modify-write of a small JSON file, never across a suspension point. If the lock
/// cannot be taken within `timeout` (another process stuck mid-write), the caller proceeds
/// unlocked: saving with a small race beats not saving.
struct CrossProcessFileLock {
    private var fd: Int32 = -1

    init(url: URL, timeout: TimeInterval = 2) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard opened >= 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(opened, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                close(opened)
                return
            }
            usleep(2_000)
        }
        fd = opened
    }

    var isLocked: Bool { fd >= 0 }

    func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Darwin notification observer used by the stores to refresh their observable copy when the
/// other process wrote the file.
final class StoreChangeObserver: @unchecked Sendable {
    private static var center: CFNotificationCenter { CFNotificationCenterGetDarwinNotifyCenter() }
    private let handler: () -> Void

    init(name: String, handler: @escaping () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(Self.center, Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<StoreChangeObserver>.fromOpaque(observer).takeUnretainedValue().handler()
        }, name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(Self.center, Unmanaged.passUnretained(self).toOpaque())
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Decodes an array element by element, dropping elements that fail to decode.
struct LossyArray<Element: Codable>: Codable {
    var elements: [Element]

    init(_ elements: [Element]) { self.elements = elements }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(Discard.self)
            }
        }
        elements = result
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for element in elements { try container.encode(element) }
    }

    /// Consumes one value of any shape.
    private struct Discard: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
